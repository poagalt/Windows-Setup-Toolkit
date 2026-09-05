Set-StrictMode -Version Latest

$script:WDUnattendNs = 'urn:schemas-microsoft-com:unattend'

# The manifest is authored against Set-ItemProperty -Type, and reg.exe will not
# take those names.
$script:WDRegKinds = @{
    'DWord'        = 'REG_DWORD'
    'QWord'        = 'REG_QWORD'
    'String'       = 'REG_SZ'
    'ExpandString' = 'REG_EXPAND_SZ'
    'Binary'       = 'REG_BINARY'
    'MultiString'  = 'REG_MULTI_SZ'
}

# Per-user values go here, not HKCU: during specialize nobody is signed in, and
# writing the default profile is what makes every account created later inherit
# the setting.
$script:WDDefaultHiveMount = 'HKU\WDDEFAULT'
$script:WDDefaultHiveFile  = 'C:\Users\Default\NTUSER.DAT'

function New-WDUnattendOptions {
    [pscustomobject]@{
        ComputerName    = ''            # empty lets Windows generate one
        Organization    = ''
        Owner           = ''

        AccountName     = 'User'
        AccountPassword = ''
        AccountGroup    = 'Administrators'
        AccountHint     = 'No hint set'
        AutoLogon       = $false
        # Windows decrements this at each automatic sign-in and stops, which
        # makes "once, so the first-logon work can run" a different answer from
        # "never ask again".
        AutoLogonCount  = 1
        # Each entry is @{ Name; Password; Group }; an entry with no name is
        # dropped.
        ExtraAccounts   = @()
        # Empty leaves it disabled, which is what Windows does.
        AdminPassword   = ''

        UILanguage      = 'en-US'
        SystemLocale    = 'en-US'
        UserLocale      = 'en-US'
        # Not written to the file - it is the form's own answer to whether the
        # two locales follow the display language.
        SyncLocales     = $true
        InputLocale     = '0409:00000409'
        TimeZone        = ''            # empty leaves Setup's own default

        ProductKey      = ''            # empty emits no key at all
        ImageName       = ''            # e.g. 'Windows 11 Pro'
        ImageIndex      = 0             # 0 means "use the name, or ask"
        AcceptEula      = $true

        BypassMicrosoftAccount = $true
        BypassInternet         = $true
        BypassHardwareChecks   = $true

        PrivacyOff             = $true
        ApplyToDefaultProfile  = $true
        # Deliberately the reverse of Windows' default: 24H2 turns device
        # encryption on where the machine qualifies and sends the key to
        # whatever account signs in, which on a local account is nowhere anybody
        # can reach.
        NoDeviceEncryption     = $true

        NetworkLocation = 'Home'        # Home | Work | Other
        HideWireless    = $true
        EnableRdp       = $false

        DiskLayout      = 'none'        # none | wipe-gpt | wipe-mbr
        DiskId          = 0
        EfiSizeMb       = 300
        WifiSsid        = ''
        WifiPassword    = ''
        WifiAuth        = 'WPA2PSK'     # WPA2PSK | WPA3SAE | open
        WifiHidden      = $false
        ExtraSpecialize = @()
        ExtraFirstLogon = @()

        # RunToolkit is the on/off and decides whether any of this is emitted;
        # RunPreset is only which one. 'profile' runs the selection named by
        # RunProfileFile.
        RunToolkit      = $false
        RunPreset       = 'Balanced'
        RunProfileFile  = ''

        IncludeDebloat  = $true
    }
}

function Get-WDUnattendRunCommands {
    param($Options)

    $dest = 'C:\Windows\Setup\Scripts\WinSetupToolkit'
    $scripts = 'C:\Windows\Setup\Scripts'

    $args2 = '-Console -Apply -SetupRun'
    if ([string]$Options.RunPreset -eq 'profile' -and [string]$Options.RunProfileFile) {
        $args2 = "-Console -Apply -SetupRun -ProfilePath `"$dest\$([string]$Options.RunProfileFile)`""
    } elseif ([string]$Options.RunPreset -and [string]$Options.RunPreset -ne 'profile') {
        $args2 = "-Console -Apply -SetupRun -Preset $([string]$Options.RunPreset)"
    }

    # SetupComplete.cmd runs before anybody can see it, so a missing script has
    # to be a no-op rather than an error dialog nobody is there to dismiss.
    $cmd = @(
        '@echo off'
        'rem Written by the Windows Setup Toolkit answer file. Windows Setup runs'
        'rem this as Local System after Setup finishes and before the logon screen.'
        'setlocal'
        "set ""WD=$dest"""
        'if not exist "%WD%\WinSetupToolkit.ps1" goto :done'
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%WD%\WinSetupToolkit.ps1"" $args2"
        ':done'
        'endlocal'
        'exit /b 0'
    ) -join "`r`n"

    # Base64 rather than escaping: this has to survive being an attribute value
    # inside XML inside a command line.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cmd))
    $copy = "`$d=Get-PSDrive -PSProvider FileSystem|Where-Object{Test-Path (Join-Path `$_.Root 'WinSetupToolkit\WinSetupToolkit.ps1')}|Select-Object -First 1;" +
            "if(`$d){Copy-Item (Join-Path `$d.Root 'WinSetupToolkit') '$dest' -Recurse -Force};" +
            "New-Item -ItemType Directory -Path '$scripts' -Force|Out-Null;" +
            "[IO.File]::WriteAllText('$scripts\SetupComplete.cmd',[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')))"
    $specialize = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$copy`""

    [pscustomobject]@{ Specialize = $specialize; SetupComplete = $cmd; Destination = $dest }
}

function ConvertTo-WDXmlText {
    # Element text only, so quotes are deliberately not escaped - &quot; in a
    # command line is six characters to the shell.
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function ConvertTo-WDRegData {
    param($Value, [string]$Kind)

    if ($Kind -eq 'Binary') {
        if ($Value -is [array]) {
            return (($Value | ForEach-Object { '{0:x2}' -f [int]$_ }) -join '')
        }
        return ([string]$Value).Replace(',', '').Replace(' ', '')
    }
    if ($Kind -eq 'MultiString' -and $Value -is [array]) {
        # reg.exe separates the strings with \0.
        return ($Value -join '\0')
    }
    if ($Value -is [bool]) { return $(if ($Value) { '1' } else { '0' }) }
    [string]$Value
}

function New-WDUnattendPayloadShell {
    [pscustomobject]@{
        Registry = @(); Appx = @(); Service = @(); Task = @()
        Feature  = @(); Capability = @(); Skipped = @()
    }
}

function Get-WDUnattendPayload {
    # What cannot be carried is reported rather than dropped: a generator that
    # silently halves the plan is worse than one that refuses.
    param([Parameter(Mandatory)]$Items)

    $reg     = New-Object System.Collections.Generic.List[psobject]
    $appx    = New-Object System.Collections.Generic.List[string]
    $svc     = New-Object System.Collections.Generic.List[psobject]
    $task    = New-Object System.Collections.Generic.List[psobject]
    $feat    = New-Object System.Collections.Generic.List[psobject]
    $cap     = New-Object System.Collections.Generic.List[psobject]
    $skipped = New-Object System.Collections.Generic.List[psobject]

    foreach ($item in @($Items)) {
        $id = [string](Get-Prop $item 'id' '')
        if (-not $id) { continue }

        $guards = @(Get-Prop $item 'guards' @())
        if ($guards.Count) {
            $skipped.Add([pscustomobject]@{
                Id = $id; Name = [string](Get-Prop $item 'name' $id)
                Why = "only applies to some machines ($($guards -join ', ')), and this file is written before the machine exists"
            })
            continue
        }

        $took = $false
        $why  = ''
        foreach ($a in @(Get-Prop $item 'actions' @())) {
            $type = [string](Get-Prop $a 'type' '')
            switch ($type) {
                'registry' {
                    $scope = [string](Get-Prop $a 'scope' 'machine')
                    foreach ($v in @(Get-Prop $a 'values' @())) {
                        $path = [string](Get-Prop $v 'path' '')
                        if (-not $path) { continue }
                        $reg.Add([pscustomobject]@{
                            ItemId = $id
                            Scope  = $scope
                            Path   = $path
                            Name   = [string](Get-Prop $v 'name' '')
                            Kind   = [string](Get-Prop $v 'kind' 'DWord')
                            Value  = (Get-Prop $v 'value' 0)
                            Delete = [bool](Get-Prop $v 'delete' $false)
                        })
                        $took = $true
                    }
                }
                'appx' {
                    foreach ($n in @(Get-Prop $a 'names' @())) {
                        if ($n) { $appx.Add([string]$n); $took = $true }
                    }
                }
                'service' {
                    $st = [string](Get-Prop $a 'startupType' 'Disabled')
                    foreach ($n in @(Get-Prop $a 'names' @())) {
                        if (-not $n) { continue }
                        $svc.Add([pscustomobject]@{
                            ItemId = $id; Name = [string]$n; StartupType = $st
                            Stop = [bool](Get-Prop $a 'stop' $false)
                        })
                        $took = $true
                    }
                }
                'task' {
                    foreach ($n in @(Get-Prop $a 'tasks' @())) {
                        if (-not $n) { continue }
                        $task.Add([pscustomobject]@{
                            ItemId = $id; Path = [string]$n
                            Delete = [bool](Get-Prop $a 'delete' $false)
                        })
                        $took = $true
                    }
                }
                'feature' {
                    $mode = [string](Get-Prop $a 'mode' 'remove')
                    foreach ($n in @(Get-Prop $a 'names' @())) {
                        if (-not $n) { continue }
                        $feat.Add([pscustomobject]@{ ItemId = $id; Name = [string]$n; Enable = ($mode -ieq 'enable') })
                        $took = $true
                    }
                }
                'capability' {
                    $mode = [string](Get-Prop $a 'mode' 'remove')
                    foreach ($n in @(Get-Prop $a 'names' @())) {
                        if (-not $n) { continue }
                        $cap.Add([pscustomobject]@{ ItemId = $id; Name = [string]$n; Install = ($mode -ieq 'install') })
                        $took = $true
                    }
                }
                'winget'     { $why = 'installs or removes software, which needs a network and a signed-in user' }
                'uninstall'  { $why = 'runs the program''s own uninstaller, which does not exist yet on a new install' }
                'script'     { $why = 'is a script handler, which acts on a running machine' }
                default      {
                    if (-not $why) { $why = "uses a $type action, which an answer file cannot express" }
                }
            }
        }
        if (-not $took) {
            $skipped.Add([pscustomobject]@{
                Id = $id; Name = [string](Get-Prop $item 'name' $id)
                Why = $(if ($why) { $why } else { 'has nothing an answer file can carry' })
            })
        }
    }

    [pscustomobject]@{
        Registry = $reg.ToArray()
        Appx     = @($appx | Sort-Object -Unique)
        Service  = $svc.ToArray()
        Task     = $task.ToArray()
        Feature  = $feat.ToArray()
        Capability = $cap.ToArray()
        Skipped  = $skipped.ToArray()
    }
}

function New-WDUnattendCommands {
    # The default user's hive is loaded once around every per-user write and
    # unloaded at the end, not per value.
    param($Options, $Payload)

    $cmds = New-Object System.Collections.Generic.List[string]

    # BypassNRO has to exist before OOBE starts, which is what makes specialize
    # the right pass rather than oobeSystem.
    if ($Options.BypassInternet) {
        $cmds.Add('reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f')
    }

    if ($Options.PrivacyOff) {
        foreach ($c in @(
            'reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f'
            'reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f'
            'reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" /v DisabledByGroupPolicy /t REG_DWORD /d 1 /f'
            'reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f'
            'reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableSoftLanding /t REG_DWORD /d 1 /f'
            'reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableCloudOptimizedContent /t REG_DWORD /d 1 /f'
            'reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" /v Value /t REG_SZ /d Deny /f'
            'reg add "HKLM\SOFTWARE\Microsoft\Settings\FindMyDevice" /v LocationSyncEnabled /t REG_DWORD /d 0 /f'
            'reg add "HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization" /v RestrictImplicitTextCollection /t REG_DWORD /d 1 /f'
            'reg add "HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization" /v RestrictImplicitInkCollection /t REG_DWORD /d 1 /f'
        )) { $cmds.Add($c) }
    }

    # Before anything can start encrypting: the policy is read at first boot,
    # and setting it later leaves a disk already under way.
    if ($Options.NoDeviceEncryption) {
        $cmds.Add('reg add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f')
    }

    if ($Options.EnableRdp) {
        $cmds.Add('reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f')
        # The rule group, not a port - Windows owns the port, and the group is
        # what the Settings toggle enables.
        $cmds.Add('cmd /c netsh advfirewall firewall set rule group="remote desktop" new enable=Yes ^& exit /b 0')
    }

    # connect needs a profile to exist, and "add profile user=all" is what makes
    # it the machine's rather than one account's.
    if ($Options.WifiSsid) {
        $ssid = ConvertTo-WDXmlText $Options.WifiSsid
        $hex  = (([System.Text.Encoding]::UTF8.GetBytes([string]$Options.WifiSsid) |
                  ForEach-Object { '{0:X2}' -f $_ }) -join '')
        $auth = switch ([string]$Options.WifiAuth) {
            'WPA3SAE' { 'WPA3SAE' }
            'open'    { 'open' }
            default   { 'WPA2PSK' }
        }
        $cipher = $(if ($auth -eq 'open') { 'none' } else { 'AES' })
        $sec = ''
        if ($auth -ne 'open') {
            $sec = '<sharedKey><keyType>passPhrase</keyType><protected>false</protected>' +
                   "<keyMaterial>$(ConvertTo-WDXmlText $Options.WifiPassword)</keyMaterial></sharedKey>"
        }
        $prof = '<?xml version="1.0"?>' +
                '<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">' +
                "<name>$ssid</name><SSIDConfig><SSID><hex>$hex</hex><name>$ssid</name></SSID>" +
                "$(if ($Options.WifiHidden) { '<nonBroadcast>true</nonBroadcast>' } else { '' })</SSIDConfig>" +
                '<connectionType>ESS</connectionType><connectionMode>auto</connectionMode>' +
                "<MSM><security><authEncryption><authentication>$auth</authentication>" +
                "<encryption>$cipher</encryption><useOneX>false</useOneX></authEncryption>$sec</security></MSM>" +
                '</WLANProfile>'
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($prof))
        $ps  = "`$p='C:\Windows\Temp\wd-wifi.xml';" +
               "[IO.File]::WriteAllBytes(`$p,[Convert]::FromBase64String('$b64'));" +
               "netsh wlan add profile filename=`$p user=all;" +
               "netsh wlan connect name='$([string]$Options.WifiSsid -replace "'", "''")';" +
               "Remove-Item `$p -Force -ErrorAction SilentlyContinue"
        $cmds.Add("powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$ps`"")
    }

    # The operator's own commands before the payload: these are theirs.
    foreach ($c in @($Options.ExtraSpecialize)) { if ($c) { $cmds.Add([string]$c) } }

    if ([bool]$Options.RunToolkit -and [string]$Options.RunPreset) {
        $cmds.Add((Get-WDUnattendRunCommands -Options $Options).Specialize)
    }

    if (-not $Options.IncludeDebloat) { return $cmds.ToArray() }

    $perUser = New-Object System.Collections.Generic.List[psobject]
    foreach ($r in @($Payload.Registry)) {
        if ($r.Scope -ieq 'machine') {
            $cmds.Add((New-WDRegCommand -Entry $r -Root 'HKLM'))
        } else {
            $perUser.Add($r)
        }
    }

    # Per-user values go to the default profile, bracketed by one load/unload.
    if ($perUser.Count -and $Options.ApplyToDefaultProfile) {
        $cmds.Add("reg load $($script:WDDefaultHiveMount) $($script:WDDefaultHiveFile)")
        foreach ($r in $perUser) {
            $cmds.Add((New-WDRegCommand -Entry $r -Root $script:WDDefaultHiveMount))
        }
        $cmds.Add("reg unload $($script:WDDefaultHiveMount)")
    }

    # Wrapped so a service or task absent from this image cannot fail the pass.
    # The file is written against a machine nobody has seen, so "not present" is
    # the expected case.
    foreach ($s in @($Payload.Service)) {
        $start = switch -Regex ([string]$s.StartupType) {
            'Disabled'  { 'disabled'; break }
            'Manual'    { 'demand';   break }
            'Automatic' { 'auto';     break }
            default     { 'disabled' }
        }
        if ($s.Stop) {
            $cmds.Add("cmd /c sc.exe stop `"$($s.Name)`" ^& exit /b 0")
        }
        $cmds.Add("cmd /c sc.exe config `"$($s.Name)`" start= $start ^& exit /b 0")
    }
    foreach ($t in @($Payload.Task)) {
        $verb = $(if ($t.Delete) { '/Delete /F' } else { '/Change /Disable' })
        if ($t.Path -match '[\*\?]') {
            # schtasks takes no wildcards, so a pattern needs an enumeration.
            $lit = ($t.Path -replace "'", "''")
            $act = $(if ($t.Delete) { 'Unregister-ScheduledTask -Confirm:$false' } else { 'Disable-ScheduledTask' })
            $cmds.Add("powershell.exe -NoProfile -ExecutionPolicy Bypass -Command " +
                      "`"Get-ScheduledTask | Where-Object{(`$_.TaskPath+`$_.TaskName) -like '$lit'} | " +
                      "$act -ErrorAction SilentlyContinue`"")
        } else {
            $cmds.Add("cmd /c schtasks.exe $verb /TN `"$($t.Path)`" ^& exit /b 0")
        }
    }

    # Against the running image, not offlineServicing: there a wrong feature
    # name fails the whole install rather than one line. /NoRestart everywhere,
    # or DISM returns 3010 and Setup reads a reboot request as failure.
    foreach ($f in @($Payload.Feature)) {
        $verb = $(if ($f.Enable) { '/Enable-Feature /All' } else { '/Disable-Feature' })
        $cmds.Add("cmd /c dism.exe /online $verb /FeatureName:$($f.Name) /NoRestart /Quiet ^& exit /b 0")
    }
    foreach ($c in @($Payload.Capability)) {
        $verb = $(if ($c.Install) { '/Add-Capability' } else { '/Remove-Capability' })
        $cmds.Add("cmd /c dism.exe /online $verb /CapabilityName:$($c.Name) /NoRestart /Quiet ^& exit /b 0")
    }

    # One command for the lot: a RunSynchronousCommand per package would put a
    # hundred PowerShell startups in the specialize pass.
    if (@($Payload.Appx).Count) {
        $list = (@($Payload.Appx) | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
        $ps = "`$p=@($list);`$all=Get-AppxProvisionedPackage -Online;" +
              "foreach(`$n in `$p){`$all|Where-Object{`$_.DisplayName -like `$n}|" +
              "ForEach-Object{Remove-AppxProvisionedPackage -Online -PackageName `$_.PackageName -ErrorAction SilentlyContinue}}"
        $cmds.Add("powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$ps`"")
    }

    $cmds.ToArray()
}

function New-WDRegCommand {
    # The path is quoted and the data is not - a quoted /d swallows the quotes
    # into the value.
    param($Entry, [string]$Root)

    $path = $Entry.Path
    # 'machine' and 'user' entries carry a full path with its own hive prefix;
    # per-hive entries are relative. Same rule as the live executor, so the two
    # cannot disagree.
    if ($Entry.Scope -ieq 'allusers' -or $Entry.Scope -ieq 'user') {
        $path = ($path -replace '^(HKCU:|HKEY_CURRENT_USER)\\?', '')
        $path = "$Root\$($path.TrimStart('\'))"
    } else {
        $path = $path -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU'
    }

    if ($Entry.Delete) {
        return "reg delete `"$path`" /v $($Entry.Name) /f"
    }
    $kind = $script:WDRegKinds[$Entry.Kind]
    if (-not $kind) { $kind = 'REG_DWORD' }
    $data = ConvertTo-WDRegData -Value $Entry.Value -Kind $Entry.Kind
    "reg add `"$path`" /v $($Entry.Name) /t $kind /d $data /f"
}

function New-WDUnattendXml {
    # amd64 only: arm64 needs its own component blocks, and shipping both
    # doubles the file for a case nobody has had yet.
    param(
        [Parameter(Mandatory)]$Options,
        $Payload
    )
    # Every list the command builder reads has to exist, or StrictMode turns a
    # missing one into a throw on the no-items path.
    if (-not $Payload) { $Payload = New-WDUnattendPayloadShell }

    $arch = 'amd64'
    $sb   = New-Object System.Text.StringBuilder
    $add  = { param([string]$Line) $null = $sb.AppendLine($Line) }

    & $add '<?xml version="1.0" encoding="utf-8"?>'
    & $add "<unattend xmlns=`"$($script:WDUnattendNs)`">"

    & $add '  <settings pass="windowsPE">'
    & $add "    <component name=`"Microsoft-Windows-International-Core-WinPE`" processorArchitecture=`"$arch`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`">"
    & $add "      <SetupUILanguage><UILanguage>$(ConvertTo-WDXmlText $Options.UILanguage)</UILanguage></SetupUILanguage>"
    & $add "      <InputLocale>$(ConvertTo-WDXmlText $Options.InputLocale)</InputLocale>"
    & $add "      <SystemLocale>$(ConvertTo-WDXmlText $Options.SystemLocale)</SystemLocale>"
    & $add "      <UILanguage>$(ConvertTo-WDXmlText $Options.UILanguage)</UILanguage>"
    & $add "      <UserLocale>$(ConvertTo-WDXmlText $Options.UserLocale)</UserLocale>"
    & $add '    </component>'
    & $add "    <component name=`"Microsoft-Windows-Setup`" processorArchitecture=`"$arch`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`">"

    # These run inside Setup, before it checks - by the time the installed OS
    # boots, the check has already refused.
    if ($Options.BypassHardwareChecks) {
        & $add '      <RunSynchronous>'
        $n = 1
        foreach ($v in @('BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck', 'BypassStorageCheck', 'BypassCPUCheck')) {
            & $add '        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">'
            & $add "          <Order>$n</Order>"
            & $add "          <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v $v /t REG_DWORD /d 1 /f</Path>"
            & $add '        </RunSynchronousCommand>'
            $n++
        }
        & $add '        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">'
        & $add "          <Order>$n</Order>"
        & $add '          <Path>reg add HKLM\SYSTEM\Setup\MoSetup /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f</Path>'
        & $add '        </RunSynchronousCommand>'
        & $add '      </RunSynchronous>'
    }

    # Absent unless deliberately turned on.
    if ($Options.DiskLayout -ne 'none') {
        $gpt = ($Options.DiskLayout -eq 'wipe-gpt')
        & $add '      <DiskConfiguration>'
        & $add '        <WillShowUI>OnError</WillShowUI>'
        & $add '        <Disk wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">'
        & $add "          <DiskID>$([int]$Options.DiskId)</DiskID>"
        & $add '          <WillWipeDisk>true</WillWipeDisk>'
        & $add '          <CreatePartitions>'
        if ($gpt) {
            # 300 MB is Microsoft's recommendation and 100 MB the old minimum.
            # Clamped: a 20 MB ESP fails halfway through the install with
            # nothing readable to say why.
            $efi = [int]$Options.EfiSizeMb
            if ($efi -lt 100)  { $efi = 100 }
            if ($efi -gt 2048) { $efi = 2048 }
            & $add "            <CreatePartition wcm:action=`"add`"><Order>1</Order><Type>EFI</Type><Size>$efi</Size></CreatePartition>"
            & $add '            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>'
            & $add '            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>'
            & $add '          </CreatePartitions>'
            & $add '          <ModifyPartitions>'
            & $add '            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>'
            & $add '            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>'
            & $add '            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>'
        } else {
            & $add '            <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Size>500</Size></CreatePartition>'
            & $add '            <CreatePartition wcm:action="add"><Order>2</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>'
            & $add '          </CreatePartitions>'
            & $add '          <ModifyPartitions>'
            & $add '            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>NTFS</Format><Label>System</Label><Active>true</Active></ModifyPartition>'
            & $add '            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>'
        }
        & $add '          </ModifyPartitions>'
        & $add '        </Disk>'
        & $add '      </DiskConfiguration>'
        & $add '      <ImageInstall>'
        & $add '        <OSImage>'
        # Index beats name: an index is unambiguous, a name has to match the
        # medium's wording exactly.
        if ([int]$Options.ImageIndex -gt 0) {
            & $add '          <InstallFrom>'
            & $add '            <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">'
            & $add '              <Key>/IMAGE/INDEX</Key>'
            & $add "              <Value>$([int]$Options.ImageIndex)</Value>"
            & $add '            </MetaData>'
            & $add '          </InstallFrom>'
        } elseif ($Options.ImageName) {
            & $add '          <InstallFrom>'
            & $add '            <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">'
            & $add '              <Key>/IMAGE/NAME</Key>'
            & $add "              <Value>$(ConvertTo-WDXmlText $Options.ImageName)</Value>"
            & $add '            </MetaData>'
            & $add '          </InstallFrom>'
        }
        $part = $(if ($gpt) { 3 } else { 2 })
        & $add "          <InstallTo><DiskID>$([int]$Options.DiskId)</DiskID><PartitionID>$part</PartitionID></InstallTo>"
        # No "create a recovery partition" switch: Setup only makes one when it
        # chooses the layout itself, and WinRE lands in C:\Recovery either way.
        & $add '        </OSImage>'
        & $add '      </ImageInstall>'
    } elseif ($Options.ImageName -or [int]$Options.ImageIndex -gt 0) {
        # No disk block, but still name the edition so Setup does not stop to
        # ask when the medium carries several.
        & $add '      <ImageInstall>'
        & $add '        <OSImage>'
        & $add '          <InstallFrom>'
        & $add '            <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">'
        & $add '              <Key>/IMAGE/NAME</Key>'
        & $add "              <Value>$(ConvertTo-WDXmlText $Options.ImageName)</Value>"
        & $add '            </MetaData>'
        & $add '          </InstallFrom>'
        & $add '        </OSImage>'
        & $add '      </ImageInstall>'
    }

    & $add '      <UserData>'
    & $add "        <AcceptEula>$(([string]$Options.AcceptEula).ToLower())</AcceptEula>"
    if ($Options.ProductKey) {
        & $add "        <ProductKey><Key>$(ConvertTo-WDXmlText $Options.ProductKey)</Key></ProductKey>"
    } else {
        # An empty key element tells Setup to stop asking on an edition that
        # activates digitally; omitting it entirely makes it ask.
        & $add '        <ProductKey><Key /></ProductKey>'
    }
    if ($Options.Organization) { & $add "        <Organization>$(ConvertTo-WDXmlText $Options.Organization)</Organization>" }
    if ($Options.Owner)        { & $add "        <FullName>$(ConvertTo-WDXmlText $Options.Owner)</FullName>" }
    & $add '      </UserData>'
    & $add '    </component>'
    & $add '  </settings>'

    & $add '  <settings pass="specialize">'
    & $add "    <component name=`"Microsoft-Windows-Shell-Setup`" processorArchitecture=`"$arch`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`">"
    if ($Options.ComputerName) { & $add "      <ComputerName>$(ConvertTo-WDXmlText $Options.ComputerName)</ComputerName>" }
    if ($Options.TimeZone)     { & $add "      <TimeZone>$(ConvertTo-WDXmlText $Options.TimeZone)</TimeZone>" }
    & $add '    </component>'

    $cmds = @(New-WDUnattendCommands -Options $Options -Payload $Payload)
    if ($cmds.Count) {
        & $add "    <component name=`"Microsoft-Windows-Deployment`" processorArchitecture=`"$arch`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`">"
        & $add '      <RunSynchronous>'
        $n = 1
        foreach ($c in $cmds) {
            & $add '        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">'
            & $add "          <Order>$n</Order>"
            & $add "          <Path>$(ConvertTo-WDXmlText $c)</Path>"
            & $add '        </RunSynchronousCommand>'
            $n++
        }
        & $add '      </RunSynchronous>'
        & $add '    </component>'
    }
    & $add '  </settings>'

    & $add '  <settings pass="oobeSystem">'
    & $add "    <component name=`"Microsoft-Windows-International-Core`" processorArchitecture=`"$arch`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`">"
    & $add "      <InputLocale>$(ConvertTo-WDXmlText $Options.InputLocale)</InputLocale>"
    & $add "      <SystemLocale>$(ConvertTo-WDXmlText $Options.SystemLocale)</SystemLocale>"
    & $add "      <UILanguage>$(ConvertTo-WDXmlText $Options.UILanguage)</UILanguage>"
    & $add "      <UserLocale>$(ConvertTo-WDXmlText $Options.UserLocale)</UserLocale>"
    & $add '    </component>'
    & $add "    <component name=`"Microsoft-Windows-Shell-Setup`" processorArchitecture=`"$arch`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`">"
    & $add '      <OOBE>'
    & $add "        <HideEULAPage>$(([string]$Options.AcceptEula).ToLower())</HideEULAPage>"
    & $add "        <HideWirelessSetupInOOBE>$(([string]$Options.HideWireless).ToLower())</HideWirelessSetupInOOBE>"
    & $add '        <HideLocalAccountScreen>true</HideLocalAccountScreen>'
    if ($Options.BypassMicrosoftAccount) {
        & $add '        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>'
    }
    # 3 is "do not turn on automatic updates or Defender express settings",
    # which answers the privacy page rather than skipping it with the defaults
    # left on.
    & $add "        <ProtectYourPC>$(if ($Options.PrivacyOff) { 3 } else { 1 })</ProtectYourPC>"
    $netLoc = [string]$Options.NetworkLocation
    if ($netLoc -notin @('Home','Work','Other')) { $netLoc = 'Home' }
    & $add "        <NetworkLocation>$netLoc</NetworkLocation>"
    & $add '      </OOBE>'

    # A defined local account is the real Microsoft-account bypass: OOBE skips
    # account creation when one exists, so no screen is left to insist on a
    # sign-in.
    $accounts = @()
    if ($Options.AccountName) {
        $accounts += [pscustomobject]@{ Name = $Options.AccountName; Password = $Options.AccountPassword; Group = $Options.AccountGroup }
    }
    foreach ($extra in @($Options.ExtraAccounts)) {
        if (-not $extra) { continue }
        $nm = [string](Get-Prop $extra 'Name' '')
        if (-not $nm) { continue }
        $gp = [string](Get-Prop $extra 'Group' 'Users')
        if (-not $gp) { $gp = 'Users' }
        $accounts += [pscustomobject]@{ Name = $nm; Password = [string](Get-Prop $extra 'Password' ''); Group = $gp }
    }
    if ($accounts.Count -or $Options.AdminPassword) {
        & $add '      <UserAccounts>'
        if ($Options.AdminPassword) {
            & $add '        <AdministratorPassword>'
            & $add "          <Value>$(ConvertTo-WDXmlText $Options.AdminPassword)</Value>"
            & $add '          <PlainText>true</PlainText>'
            & $add '        </AdministratorPassword>'
        }
        if ($accounts.Count) {
            & $add '        <LocalAccounts>'
            foreach ($acc in $accounts) {
                & $add '          <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">'
                & $add "            <Name>$(ConvertTo-WDXmlText $acc.Name)</Name>"
                & $add "            <DisplayName>$(ConvertTo-WDXmlText $acc.Name)</DisplayName>"
                & $add "            <Group>$(ConvertTo-WDXmlText $acc.Group)</Group>"
                & $add '            <Password>'
                & $add "              <Value>$(ConvertTo-WDXmlText $acc.Password)</Value>"
                # Plain text, said out loud: the alternative is base64, which is
                # not encryption and reads as though it were.
                & $add '              <PlainText>true</PlainText>'
                & $add '            </Password>'
                & $add '          </LocalAccount>'
            }
            & $add '        </LocalAccounts>'
        }
        & $add '      </UserAccounts>'
    }

    if ($Options.AutoLogon -and $Options.AccountName) {
        $n = [int]$Options.AutoLogonCount
        if ($n -lt 1) { $n = 1 }
        & $add '      <AutoLogon>'
        & $add "        <Username>$(ConvertTo-WDXmlText $Options.AccountName)</Username>"
        & $add '        <Enabled>true</Enabled>'
        & $add "        <LogonCount>$n</LogonCount>"
        & $add '        <Password>'
        & $add "          <Value>$(ConvertTo-WDXmlText $Options.AccountPassword)</Value>"
        & $add '          <PlainText>true</PlainText>'
        & $add '        </Password>'
        & $add '      </AutoLogon>'
    }

    $first = New-Object System.Collections.Generic.List[string]
    if ($Options.PrivacyOff) {
        $first.Add('reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy" /v TailoredExperiencesWithDiagnosticDataEnabled /t REG_DWORD /d 0 /f')
        $first.Add('reg add "HKCU\Software\Microsoft\Input\TIPC" /v Enabled /t REG_DWORD /d 0 /f')
        $first.Add('reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 0 /f')
    }
    foreach ($c in @($Options.ExtraFirstLogon)) { if ($c) { $first.Add([string]$c) } }
    # The toolkit run happens in SetupComplete.cmd before anybody signs in - see
    # Get-WDUnattendRunCommands. What is left here belongs to a user session.

    if ($first.Count) {
        & $add '      <FirstLogonCommands>'
        $n = 1
        foreach ($c in $first) {
            & $add '        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">'
            & $add "          <Order>$n</Order>"
            & $add "          <CommandLine>$(ConvertTo-WDXmlText $c)</CommandLine>"
            & $add '          <Description>Windows Setup Toolkit</Description>'
            & $add '        </SynchronousCommand>'
            $n++
        }
        & $add '      </FirstLogonCommands>'
    }
    & $add '    </component>'
    & $add '  </settings>'
    & $add '</unattend>'

    $sb.ToString()
}

function Test-WDUnattendXml {
    param([Parameter(Mandatory)][string]$Xml, $Options)

    $problems = New-Object System.Collections.Generic.List[string]
    $doc = $null
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($Xml)
    } catch {
        $problems.Add("the file is not valid XML: $($_.Exception.Message)")
        return [pscustomobject]@{ Ok = $false; Problems = $problems.ToArray() }
    }

    if ($doc.DocumentElement.Name -ne 'unattend') { $problems.Add('the root element is not <unattend>') }
    if ($doc.DocumentElement.NamespaceURI -ne $script:WDUnattendNs) { $problems.Add('the unattend namespace is wrong') }

    if ($Options) {
        if ($Options.BypassInternet -and $Xml -notmatch 'BypassNRO') {
            $problems.Add('the internet requirement bypass was asked for and is not in the file')
        }
        if ($Options.BypassMicrosoftAccount) {
            if ($Xml -notmatch 'HideOnlineAccountScreens') {
                $problems.Add('the Microsoft account bypass was asked for and HideOnlineAccountScreens is missing')
            }
            if ($Options.AccountName -and $Xml -notmatch '<LocalAccount ') {
                $problems.Add('the Microsoft account bypass needs a local account and none was written')
            }
        }
        if ($Options.BypassHardwareChecks -and $Xml -notmatch 'BypassTPMCheck') {
            $problems.Add('the hardware requirement bypasses were asked for and are not in the file')
        }
        if ($Options.PrivacyOff -and $Xml -notmatch 'AllowTelemetry') {
            $problems.Add('data collection was to be turned off and no telemetry policy was written')
        }
        # Asserted from the other direction: a file that wipes a disk nobody
        # asked it to wipe is the worst thing this can produce.
        if ($Options.DiskLayout -eq 'none' -and $Xml -match '<WillWipeDisk>') {
            $problems.Add('disks were to be left alone and the file wipes one')
        }
        # Every field that reaches the file is checked here, or the form grows a
        # control that collects an answer nothing acts on.
        if ($Options.WifiSsid -and $Xml -notmatch 'wlan add profile') {
            $problems.Add('a Wi-Fi network was given and no profile is written')
        }
        # RunToolkit as well as RunPreset: RunPreset holds a mode whether or not
        # the section is on, so checking it alone reports every default file as
        # broken.
        if ([bool]$Options.RunToolkit -and [string]$Options.RunPreset -and $Xml -notmatch 'WinSetupToolkit\.ps1') {
            $problems.Add('the toolkit was to run after Setup and nothing runs it')
        }
        # The copy step and the thing that runs it are two halves, either
        # droppable by an edit to the other. Asserted on the path because the
        # body is base64.
        if ([bool]$Options.RunToolkit -and [string]$Options.RunPreset -and $Xml -notmatch 'SetupComplete\.cmd') {
            $problems.Add('the toolkit was to run after Setup and no SetupComplete.cmd is written')
        }
        if (-not [bool]$Options.RunToolkit -and $Xml -match 'Setup\\Scripts\\WinSetupToolkit') {
            $problems.Add('auto-debloat is off and the file runs the toolkit anyway')
        }
        if ([bool]$Options.RunToolkit -and [string]$Options.RunPreset -eq 'profile' -and
            -not [string]$Options.RunProfileFile) {
            $problems.Add('a saved selection was chosen and no file was named')
        }
        if ($Options.AutoLogon -and $Options.AccountName -and $Xml -notmatch '<AutoLogon>') {
            $problems.Add('automatic sign-in was asked for and is not in the file')
        }
        if ($Options.EnableRdp -and $Xml -notmatch 'fDenyTSConnections') {
            $problems.Add('Remote Desktop was to be enabled and nothing enables it')
        }
    }

    # Order elements must be unique and contiguous within each block, or Setup
    # skips commands without saying which.
    foreach ($node in @($doc.GetElementsByTagName('RunSynchronous')) + @($doc.GetElementsByTagName('FirstLogonCommands'))) {
        $orders = @($node.ChildNodes | ForEach-Object { [int]$_.Order })
        if ($orders.Count -ne (@($orders | Sort-Object -Unique)).Count) {
            $problems.Add('two commands in one block share an Order number')
        }
    }

    [pscustomobject]@{ Ok = ($problems.Count -eq 0); Problems = $problems.ToArray() }
}

function Export-WDUnattend {
    # UTF-8 with no BOM: Setup reads this itself, and a BOM in front of the XML
    # declaration is the one thing it will not forgive.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Options,
        $Items
    )

    $payload = $null
    if ($Items) { $payload = Get-WDUnattendPayload -Items $Items }
    $xml = New-WDUnattendXml -Options $Options -Payload $payload

    $check = Test-WDUnattendXml -Xml $xml -Options $Options
    if (-not $check.Ok) {
        return New-WDResult -Status Failed -Message 'The answer file was not written' `
                            -Detail ($check.Problems -join '; ')
    }

    try {
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Path, $xml, $enc)
    } catch {
        return New-WDResult -Status Failed -Message 'Could not write the answer file' -Detail $_.Exception.Message
    }

    $carried = 0
    $left    = 0
    if ($payload) {
        $carried = @($payload.Registry).Count + @($payload.Appx).Count +
                   @($payload.Service).Count  + @($payload.Task).Count
        $left    = @($payload.Skipped).Count
    }
    $detail = "$carried setting$(if ($carried -ne 1) { 's' }) and app removals inlined"
    if ($left) { $detail += ", $left item$(if ($left -ne 1) { 's' }) left out because an answer file cannot carry them" }

    New-WDResult -Status Changed -Message "Answer file written to $Path" -Detail $detail
}

Export-ModuleMember -Function *-WD*
