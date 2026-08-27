<#
    Windows Setup answer files.

    An autounattend.xml at the root of the installation medium is read by Setup
    automatically. It answers every question Setup asks and can run commands at
    defined points, which means most of what this toolkit does afterwards can be
    done before the machine ever reaches a desktop - and a few things can ONLY be
    done there. Skipping the Microsoft account requirement is one. Deprovisioning
    an app so it was never staged for any account is another: there is no later
    moment at which "never installed" is still available.

    What this file does NOT do is run the toolkit. The generated answer file is
    self-contained - registry values and app deprovisioning inlined, nothing
    copied onto the medium, nothing to go stale. Anything needing a network or a
    signed-in user (winget installs, vendor uninstallers) cannot be expressed
    that way and is reported as left out rather than quietly dropped.

    Nothing here touches the current machine. The output is a file.
#>

Set-StrictMode -Version Latest

# Where the answer file can act, and what each pass is for. Kept as data because
# the ordering below reads as arbitrary otherwise.
#
#   windowsPE    Setup itself: language, disk, image, product key. The hardware
#                requirement bypasses have to land here, before Setup checks.
#   specialize   First boot of the installed OS, before any user exists. The
#                right place for machine policy and for deprovisioning.
#   oobeSystem   The out-of-box experience: the account, the privacy questions.

$script:WDUnattendNs = 'urn:schemas-microsoft-com:unattend'

# reg.exe type names, keyed by the manifest's PowerShell kind. The manifest is
# authored against Set-ItemProperty -Type, and reg.exe does not accept those
# names, so a table rather than a guess.
$script:WDRegKinds = @{
    'DWord'        = 'REG_DWORD'
    'QWord'        = 'REG_QWORD'
    'String'       = 'REG_SZ'
    'ExpandString' = 'REG_EXPAND_SZ'
    'Binary'       = 'REG_BINARY'
    'MultiString'  = 'REG_MULTI_SZ'
}

# The temporary mount point for the default user's hive. Anything the manifest
# scopes to a user has to go here rather than to HKCU: during specialize there
# is no logged-on user, and writing the default profile is what makes every
# account created later inherit the setting - which is strictly better than what
# the toolkit can do afterwards, where it can only reach accounts that exist.
$script:WDDefaultHiveMount = 'HKU\WDDEFAULT'
$script:WDDefaultHiveFile  = 'C:\Users\Default\NTUSER.DAT'

function New-WDUnattendOptions {
    <#
        The form's answers, defaulted to what the Standard shape means: the
        bypasses, a local account, region and keyboard, every privacy question
        answered off. The controls the Full shape adds are all present and all
        inert until set, so one object covers both and there is no second code
        path that only runs when somebody ticks the advanced box.

        DiskLayout defaults to 'none', and that is deliberate and load-bearing.
        A DiskConfiguration block wipes the target drive with no prompt and no
        confirmation, on whatever machine the medium is booted on. Setup asking
        where to install is a cheap price for that not happening by accident.
    #>
    [pscustomobject]@{
        # --- identity -----------------------------------------------------
        ComputerName    = ''            # empty lets Windows generate one
        Organization    = ''
        Owner           = ''

        # --- the local account, which is also the MSA bypass ---------------
        AccountName     = 'User'
        AccountPassword = ''
        AccountGroup    = 'Administrators'
        AccountHint     = 'No hint set'
        AutoLogon       = $false
        # How many times, when it is on. Windows counts down and stops, which is
        # what makes "sign in for me once so the first-logon work can run" a
        # different and much safer answer from "never ask for a password again".
        AutoLogonCount  = 1
        # Further accounts, for a machine somebody else also uses. A list rather
        # than a fixed second slot: there was exactly one, which made "a family
        # machine" a thing the form could not express, and the emitter below was
        # already a loop. Each entry is @{ Name; Password; Group }; an entry
        # with no name is dropped.
        ExtraAccounts   = @()
        # The built-in Administrator. Empty leaves it disabled, which is what
        # Windows does and what almost everybody should keep.
        AdminPassword   = ''

        # --- region -------------------------------------------------------
        UILanguage      = 'en-US'
        SystemLocale    = 'en-US'
        UserLocale      = 'en-US'
        # Not written to the file - the file gets the three answers above, which
        # is all Windows knows about. This is the form's own answer to "should
        # the two below follow the one above", and it lives here because the
        # page reads and writes every control it builds through this object, and
        # a control that is exempt from that is a control that can be forgotten.
        SyncLocales     = $true
        InputLocale     = '0409:00000409'
        TimeZone        = ''            # empty leaves Setup's own default

        # --- edition ------------------------------------------------------
        ProductKey      = ''            # empty emits no key at all
        ImageName       = ''            # e.g. 'Windows 11 Pro'
        ImageIndex      = 0             # 0 means "use the name, or ask"
        AcceptEula      = $true

        # --- the three bypasses -------------------------------------------
        BypassMicrosoftAccount = $true
        BypassInternet         = $true
        BypassHardwareChecks   = $true

        # --- privacy ------------------------------------------------------
        PrivacyOff             = $true
        ApplyToDefaultProfile  = $true
        # 24H2 silently turns device encryption on where the machine qualifies,
        # and the key goes to whatever account signs in - on a local account
        # that is nowhere anybody can reach, which is how a firmware update
        # costs somebody a disk. Deliberately the reverse of Windows' default.
        NoDeviceEncryption     = $true

        # --- the machine's own behavior ----------------------------------
        NetworkLocation = 'Home'        # Home | Work | Other
        HideWireless    = $true
        EnableRdp       = $false

        # --- Full only. Disks are off unless deliberately turned on. -------
        DiskLayout      = 'none'        # none | wipe-gpt | wipe-mbr
        DiskId          = 0
        EfiSizeMb       = 300
        WifiSsid        = ''
        WifiPassword    = ''
        WifiAuth        = 'WPA2PSK'     # WPA2PSK | WPA3SAE | open
        WifiHidden      = $false
        ExtraSpecialize = @()
        ExtraFirstLogon = @()

        # --- run the toolkit on the finished machine ----------------------
        # RunToolkit is the on/off and the only thing that decides whether any of
        # this is emitted; RunPreset is only "which one". They were one control
        # with '' meaning off, which forced the list's first entry to be "do not".
        # 'profile' runs the saved selection named by RunProfileFile.
        RunToolkit      = $false
        RunPreset       = 'Balanced'
        RunProfileFile  = ''

        # --- payload ------------------------------------------------------
        IncludeDebloat  = $true
    }
}

function Get-WDUnattendRunCommands {
    <#
        What makes the finished machine debloat itself: one specialize command
        and the SetupComplete.cmd it leaves behind.

        Two passes rather than one, for two reasons easy to miss:

          - THE STICK'S DRIVE LETTER IS NOT KNOWABLE. Not always D:, and not the
            same letter in specialize as in Windows PE. So the copy step searches
            every drive for a marker file.
          - THE STICK MAY BE GONE by the time the run happens - people pull it
            the moment Setup reboots. So the toolkit is copied to disk during
            specialize, while the medium is certainly attached, and run from
            there. C:\Windows\Setup\Scripts survives the reboot between passes.

        SetupComplete.cmd, NOT FirstLogonCommands. Setup runs it as Local System
        after Setup finishes and before the logon screen: no sign-in, no account
        context, no UAC - so the run does not need the created account to be an
        administrator, and nothing appears while somebody is using their new
        machine. The trade is that session 0 has no desktop; see -SetupRun for
        the report it writes instead.

        -Console IS NOT OPTIONAL. Without it the script takes the GUI branch,
        where -Apply only OPENS the window - so the old FirstLogonCommands entry
        waited for somebody to press Preview, and in session 0 would have waited
        forever behind an invisible window.
    #>
    param($Options)

    $dest = 'C:\Windows\Setup\Scripts\WinSetupToolkit'
    $scripts = 'C:\Windows\Setup\Scripts'

    $args2 = '-Console -Apply -SetupRun'
    if ([string]$Options.RunPreset -eq 'profile' -and [string]$Options.RunProfileFile) {
        $args2 = "-Console -Apply -SetupRun -ProfilePath `"$dest\$([string]$Options.RunProfileFile)`""
    } elseif ([string]$Options.RunPreset -and [string]$Options.RunPreset -ne 'profile') {
        $args2 = "-Console -Apply -SetupRun -Preset $([string]$Options.RunPreset)"
    }

    # The guard is the whole of the safety here. SetupComplete.cmd runs before
    # anybody can see it, so anything that goes wrong goes wrong invisibly - and
    # the one failure that is certain to happen sometimes is the copy step not
    # having found the medium. A missing script must be a no-op, not an error
    # dialog nobody is there to dismiss.
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

    # Base64 rather than an escaped here-string: this text has to survive being
    # an attribute value inside XML inside a command line, and every layer of
    # that has its own quoting rules. The same answer the Wi-Fi profile needed,
    # for the same reason.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cmd))
    $copy = "`$d=Get-PSDrive -PSProvider FileSystem|Where-Object{Test-Path (Join-Path `$_.Root 'WinSetupToolkit\WinSetupToolkit.ps1')}|Select-Object -First 1;" +
            "if(`$d){Copy-Item (Join-Path `$d.Root 'WinSetupToolkit') '$dest' -Recurse -Force};" +
            "New-Item -ItemType Directory -Path '$scripts' -Force|Out-Null;" +
            "[IO.File]::WriteAllText('$scripts\SetupComplete.cmd',[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')))"
    $specialize = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$copy`""

    [pscustomobject]@{ Specialize = $specialize; SetupComplete = $cmd; Destination = $dest }
}

function ConvertTo-WDXmlText {
    <#
        Escapes the three characters that cannot appear in element text. Not
        quotes: these all go in element content, never in an attribute, and
        escaping quotes there produces &quot; in a command line where the shell
        then sees six characters instead of one.
    #>
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function ConvertTo-WDRegData {
    <#
        A manifest value as reg.exe would take it. Binary is the awkward one -
        the manifest may carry a byte array, and reg.exe wants unbroken hex.
    #>
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
    <#
        An empty payload with every list present. One definition, so adding a
        payload kind cannot leave the no-items path throwing under StrictMode.
    #>
    [pscustomobject]@{
        Registry = @(); Appx = @(); Service = @(); Task = @()
        Feature  = @(); Capability = @(); Skipped = @()
    }
}

function Get-WDUnattendPayload {
    <#
        Splits manifest items into what an answer file can carry and what it
        cannot. All three exclusions are REPORTED, not dropped - a generator that
        silently halves the plan is worse than one that refuses:

          - needs a network or a signed-in user (winget, vendor uninstallers)
          - is a script handler: arbitrary PowerShell, nothing to inline
          - carries guards. A guard asks about the machine, and at the moment
            this file is written that machine does not exist - emitting anyway
            would apply a Dell-only fix to a ThinkPad.
    #>
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
    <#
        The specialize-pass command list, in the order it has to run.

        The default user's hive is loaded once around every per-user write and
        unloaded once at the end, rather than per value. reg.exe will not unload
        a hive something still holds open, and a load/unload pair per value is
        several hundred opportunities for one of them to fail and strand the
        mount.
    #>
    param($Options, $Payload)

    $cmds = New-Object System.Collections.Generic.List[string]

    # The network requirement. BypassNRO is read by OOBE when it decides
    # whether to insist on a connection; it has to exist before OOBE starts,
    # which is what makes specialize the right pass rather than oobeSystem.
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

    # Device encryption, before anything else has a chance to start it. The
    # policy is read at first boot; setting it afterwards leaves a disk that is
    # already encrypting.
    if ($Options.NoDeviceEncryption) {
        $cmds.Add('reg add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f')
    }

    if ($Options.EnableRdp) {
        $cmds.Add('reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f')
        # The rule group, not a port: Windows owns the port and the group is
        # what the Settings toggle enables.
        $cmds.Add('cmd /c netsh advfirewall firewall set rule group="remote desktop" new enable=Yes ^& exit /b 0')
    }

    # A profile written to disk and imported, not `netsh wlan connect` alone:
    # connect needs a profile to exist, and `add profile user=all` is what makes
    # it the machine's rather than one account's. Base64 because it is XML inside
    # XML inside a command line.
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
        # Through a file rather than a here-string on the command line: the
        # profile is XML inside XML inside a command line, and every layer of
        # quoting is a place for it to come apart.
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($prof))
        $ps  = "`$p='C:\Windows\Temp\wd-wifi.xml';" +
               "[IO.File]::WriteAllBytes(`$p,[Convert]::FromBase64String('$b64'));" +
               "netsh wlan add profile filename=`$p user=all;" +
               "netsh wlan connect name='$([string]$Options.WifiSsid -replace "'", "''")';" +
               "Remove-Item `$p -Force -ErrorAction SilentlyContinue"
        $cmds.Add("powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"$ps`"")
    }

    # Anything the operator typed for this pass, before the payload: these are
    # theirs and the payload is ours.
    foreach ($c in @($Options.ExtraSpecialize)) { if ($c) { $cmds.Add([string]$c) } }

    # The toolkit's own copy step, if the file is to run a preset afterwards.
    if ([bool]$Options.RunToolkit -and [string]$Options.RunPreset) {
        $cmds.Add((Get-WDUnattendRunCommands -Options $Options).Specialize)
    }

    if (-not $Options.IncludeDebloat) { return $cmds.ToArray() }

    # Machine-scoped manifest values go straight in.
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

    # Wrapped in cmd /c ... ^& exit /b 0 so a service or task absent from this
    # particular image cannot fail the pass. Matters more here than in a normal
    # run: the file is written against a machine nobody has seen, so "not
    # present" is the expected case rather than an error.
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

    # DISM against the RUNNING image, not the offlineServicing pass: that runs
    # before the machine's own servicing stack is live, where a wrong feature
    # name fails the whole install rather than one line of it.
    #
    # /NoRestart on every one, or DISM returns 3010 and Setup treats a reboot
    # request mid-specialize as a reason to start over.
    foreach ($f in @($Payload.Feature)) {
        $verb = $(if ($f.Enable) { '/Enable-Feature /All' } else { '/Disable-Feature' })
        $cmds.Add("cmd /c dism.exe /online $verb /FeatureName:$($f.Name) /NoRestart /Quiet ^& exit /b 0")
    }
    foreach ($c in @($Payload.Capability)) {
        $verb = $(if ($c.Install) { '/Add-Capability' } else { '/Remove-Capability' })
        $cmds.Add("cmd /c dism.exe /online $verb /CapabilityName:$($c.Name) /NoRestart /Quiet ^& exit /b 0")
    }

    # Deprovisioning. One command for the lot, because a RunSynchronousCommand
    # per package would put a hundred PowerShell startups in the specialize pass
    # and each one costs about a second.
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
    <#
        One manifest value as a reg.exe line. The path is quoted and the data is
        not: a quoted /d swallows the quotes into the value, which is how a
        REG_SZ ends up with literal quote marks in it.
    #>
    param($Entry, [string]$Root)

    $path = $Entry.Path
    # 'machine' and 'user' entries carry a full path with its own hive prefix;
    # per-hive entries are relative and get the root prepended. Same rule the
    # live executor follows, deliberately - two different path conventions is
    # how the answer file and the run would come to disagree.
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
    <#
        Assembles the document. Emitted for amd64 only: an arm64 machine needs
        its own component blocks and shipping both doubles the file to serve a
        case nobody generating this has yet had. Worth revisiting, and worth
        being explicit about rather than letting somebody discover it.
    #>
    param(
        [Parameter(Mandatory)]$Options,
        $Payload
    )
    # Every list the command builder reads has to exist here. Set-StrictMode
    # turns a missing one into a throw rather than a silent empty, which is what
    # caught this - adding a payload kind and forgetting this line is otherwise
    # a crash that only happens on the path with no items.
    if (-not $Payload) { $Payload = New-WDUnattendPayloadShell }

    $arch = 'amd64'
    $sb   = New-Object System.Text.StringBuilder
    $add  = { param([string]$Line) $null = $sb.AppendLine($Line) }

    & $add '<?xml version="1.0" encoding="utf-8"?>'
    & $add "<unattend xmlns=`"$($script:WDUnattendNs)`">"

    # ---------------------------------------------------------------- windowsPE
    & $add '  <settings pass="windowsPE">'
    & $add "    <component name=`"Microsoft-Windows-International-Core-WinPE`" processorArchitecture=`"$arch`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`">"
    & $add "      <SetupUILanguage><UILanguage>$(ConvertTo-WDXmlText $Options.UILanguage)</UILanguage></SetupUILanguage>"
    & $add "      <InputLocale>$(ConvertTo-WDXmlText $Options.InputLocale)</InputLocale>"
    & $add "      <SystemLocale>$(ConvertTo-WDXmlText $Options.SystemLocale)</SystemLocale>"
    & $add "      <UILanguage>$(ConvertTo-WDXmlText $Options.UILanguage)</UILanguage>"
    & $add "      <UserLocale>$(ConvertTo-WDXmlText $Options.UserLocale)</UserLocale>"
    & $add '    </component>'
    & $add "    <component name=`"Microsoft-Windows-Setup`" processorArchitecture=`"$arch`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`">"

    # The hardware requirement bypasses. These run inside Setup, before it
    # checks, which is the only moment they can be written - by the time the
    # installed OS boots the check has already refused.
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

    # Disks. Absent unless somebody deliberately turned this on - see the note
    # on New-WDUnattendOptions.
    if ($Options.DiskLayout -ne 'none') {
        $gpt = ($Options.DiskLayout -eq 'wipe-gpt')
        & $add '      <DiskConfiguration>'
        & $add '        <WillShowUI>OnError</WillShowUI>'
        & $add '        <Disk wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">'
        & $add "          <DiskID>$([int]$Options.DiskId)</DiskID>"
        & $add '          <WillWipeDisk>true</WillWipeDisk>'
        & $add '          <CreatePartitions>'
        if ($gpt) {
            # The EFI system partition. 300 MB is Microsoft's own recommendation
            # and 100 MB is the old minimum; some firmware updates and some
            # multi-boot setups want the room, so it is a field rather than a
            # constant. Clamped, because a 20 MB ESP produces an install that
            # fails halfway through with nothing readable to say why.
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
        # Index beats name when both are given: an index is unambiguous and a
        # name has to match the medium's wording exactly.
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
        # No "create a recovery partition" switch, deliberately: Setup only makes
        # one when IT chooses the layout, and a DiskConfiguration block naming
        # partitions is the operator choosing instead - WinRE lands in
        # C:\Recovery either way. A control that cannot affect its own file is
        # the same defect the Wi-Fi fields shipped with.
        & $add '        </OSImage>'
        & $add '      </ImageInstall>'
    } elseif ($Options.ImageName -or [int]$Options.ImageIndex -gt 0) {
        # No disk block, but still name the edition so Setup does not stop to
        # ask which one when the medium carries several.
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
        # An empty key element is what tells Setup to stop asking on an edition
        # that activates digitally. Omitting the element entirely makes it ask.
        & $add '        <ProductKey><Key /></ProductKey>'
    }
    if ($Options.Organization) { & $add "        <Organization>$(ConvertTo-WDXmlText $Options.Organization)</Organization>" }
    if ($Options.Owner)        { & $add "        <FullName>$(ConvertTo-WDXmlText $Options.Owner)</FullName>" }
    & $add '      </UserData>'
    & $add '    </component>'
    & $add '  </settings>'

    # --------------------------------------------------------------- specialize
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

    # -------------------------------------------------------------- oobeSystem
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
    # 3 is "do not turn on automatic updates or Windows Defender express
    # settings", which is what answers the privacy page rather than skipping it
    # with the defaults left on.
    & $add "        <ProtectYourPC>$(if ($Options.PrivacyOff) { 3 } else { 1 })</ProtectYourPC>"
    $netLoc = [string]$Options.NetworkLocation
    if ($netLoc -notin @('Home','Work','Other')) { $netLoc = 'Home' }
    & $add "        <NetworkLocation>$netLoc</NetworkLocation>"
    & $add '      </OOBE>'

    # A defined local account is the real Microsoft-account bypass: OOBE skips
    # account creation altogether when one already exists, so there is no screen
    # left to insist on a sign-in.
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
                # Plain text, and said out loud rather than hidden: the
                # alternative is base64, which is not encryption and reads as
                # though it were.
                & $add '              <PlainText>true</PlainText>'
                & $add '            </Password>'
                & $add '          </LocalAccount>'
            }
            & $add '        </LocalAccounts>'
        }
        & $add '      </UserAccounts>'
    }

    # Signing in without being asked. Counted rather than endless: Windows
    # decrements LogonCount at each automatic sign-in and stops when it runs
    # out, which is what makes "once, so the first-logon work can run" a
    # different answer from "never ask for a password again".
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
    # The toolkit run was the last entry here and is not any more: it happens in
    # SetupComplete.cmd, before anybody signs in. See Get-WDUnattendRunCommands.
    # What is left in this pass is what genuinely belongs to a user session -
    # the per-user registry writes above, and whatever the operator typed.

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
    <#
        Parses what was generated and checks the promises the form makes are
        actually in the file. A generator that emits well-formed XML saying the
        wrong thing is the failure mode worth catching, so this asserts content
        rather than just that it parsed.
    #>
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
        # The one that matters most, asserted from the other direction: a file
        # that wipes a disk nobody asked it to wipe is the worst thing this
        # generator could produce.
        if ($Options.DiskLayout -eq 'none' -and $Xml -match '<WillWipeDisk>') {
            $problems.Add('disks were to be left alone and the file wipes one')
        }
        # Every field that reaches the file has to be checked from here, or the
        # form grows a control that collects an answer nothing acts on - which
        # is what the Wi-Fi fields did for their whole first life.
        if ($Options.WifiSsid -and $Xml -notmatch 'wlan add profile') {
            $problems.Add('a Wi-Fi network was given and no profile is written')
        }
        # RunToolkit as well as RunPreset. RunPreset now holds a mode whether or
        # not the section is switched on - it is "which one", not "whether" -
        # so checking it alone reported every default file as broken.
        if ([bool]$Options.RunToolkit -and [string]$Options.RunPreset -and $Xml -notmatch 'WinSetupToolkit\.ps1') {
            $problems.Add('the toolkit was to run after Setup and nothing runs it')
        }
        # The copy step and the thing that runs it are two halves and either can
        # be dropped by an edit to the other. The .cmd body is base64 inside the
        # specialize command, so this asserts on the path it is written to
        # rather than on its contents.
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

    # Order elements have to be unique and contiguous within each block, or
    # Setup skips commands without saying which.
    foreach ($node in @($doc.GetElementsByTagName('RunSynchronous')) + @($doc.GetElementsByTagName('FirstLogonCommands'))) {
        $orders = @($node.ChildNodes | ForEach-Object { [int]$_.Order })
        if ($orders.Count -ne (@($orders | Sort-Object -Unique)).Count) {
            $problems.Add('two commands in one block share an Order number')
        }
    }

    [pscustomobject]@{ Ok = ($problems.Count -eq 0); Problems = $problems.ToArray() }
}

function Export-WDUnattend {
    <#
        Writes the file. UTF-8 without a BOM: Windows Setup reads the answer
        file itself, and a BOM in front of the XML declaration is the one thing
        it will not forgive.
    #>
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
