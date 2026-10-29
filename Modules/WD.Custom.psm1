$script:Handlers = @{}

function Register-WDHandler {
    param([string]$Name, [scriptblock]$Body)
    $script:Handlers[$Name] = $Body
}

function Get-WDHandlerNames {
    $script:Handlers.Keys | Sort-Object
}

function Invoke-WDScriptAction {
    param($Action, $Context)
    $name = [string](Get-Prop $Action 'handler' '')
    if (-not $script:Handlers.ContainsKey($name)) {
        return New-WDResult -Status Failed -Message "No handler registered named '$name'"
    }
    try {
        & $script:Handlers[$name] $Action $Context
    } catch {
        New-WDResult -Status Failed -Message "Handler '$name' errored" -Detail $_.Exception.Message
    }
}

# The Copilot key does not emit one scancode: firmware sends the chord Left
# Shift + Left Win + F23. That is why a Scancode Map remap cannot fix it -
# remapping F23 leaves the Shift and Win presses intact.

$script:VK = @{ LWin = 91; Shift = 16; LShift = 160; F23 = 134; RCtrl = 163 }

Register-WDHandler 'CopilotKeyToRightCtrl' {
    param($Action, $Context)

    # $machine, not $profile: that is an automatic variable holding the path to
    # the PowerShell profile script.
    $machine = $Context.Profile
    if ($machine.CopilotKey -eq 'Absent') {
        return New-WDResult -Status NotPresent -Message 'No Copilot key on this keyboard'
    }

    # Preferred: the native setting Microsoft added in build 27500.
    if ($machine.Build -ge 27500) {
        $r = Set-WDNativeCopilotKey -Context $Context
        if ($r.Status -in @('Changed','Removed')) { return $r }
        Write-WDLog 'Native Copilot key setting unavailable, falling back to PowerToys.' -Level Info -Item $Context.ItemId
    }

    # Fallback that works on every current build: PowerToys - but only one that
    # is there. This used to install it with winget, silently, from a
    # Conservative-tier option whose text never said so and with nothing
    # journalled to take it off again; and since the key detection answers
    # Unknown on any 2024-or-later machine it cannot prove has one, that was any
    # recent PC. No mode installs software. PowerToys is its own row under Add,
    # which runs earlier in the same plan.
    if (-not (Test-WDPowerToys)) {
        $queued = $false
        try { $queued = [bool]($Context.PlannedIds -and $Context.PlannedIds.Contains('add-powertoys')) } catch { }
        if ($Context.Preview -and $queued) {
            return New-WDResult -Status Changed -Message 'Would map Win+Shift+F23 to Right Ctrl in PowerToys, once this run has installed it'
        }
        return New-WDResult -Status Skipped -Message 'Needs PowerToys, which is not installed' `
                            -Detail 'Tick "PowerToys" under Add to have this run install it, or install it yourself, then run this option again.'
    }

    Set-WDPowerToysRemap -Context $Context
}

function Set-WDNativeCopilotKey {
    # The backing value moved during the preview cycle, so the write is verified
    # by reading it back rather than assumed.
    param($Context)

    $candidates = @(
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Copilot\CopilotKey'; Name = 'RemapTarget';   Value = 'RightControl' }
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell\Copilot\CopilotKey';    Name = 'RemapTarget';   Value = 'RightControl' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell\Copilot\CopilotKey';    Name = 'CopilotKeyMode';Value = 'RightControl' }
    )

    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c.Path)) { continue }
        if ($Context.Preview) {
            return New-WDResult -Status Changed -Message "Would set Copilot key to Right Ctrl via $($c.Path)"
        }
        try {
            Backup-WDRegistryKey -Path $c.Path
            Set-ItemProperty -LiteralPath $c.Path -Name $c.Name -Value $c.Value -Force -ErrorAction Stop
            $back = (Get-ItemProperty -LiteralPath $c.Path -Name $c.Name -ErrorAction Stop).$($c.Name)
            if ($back -eq $c.Value) {
                Add-WDJournal -ItemId $Context.ItemId -Type 'copilot-key' -Target $c.Path -Status 'Changed' `
                              -Undo @{ method = 'registry'; path = $c.Path; name = $c.Name; previous = '__ABSENT__'; kind = 'String' }
                return New-WDResult -Status Changed -Message 'Copilot key set to Right Ctrl (native setting)'
            }
        } catch { }
    }
    New-WDResult -Status Skipped -Message 'Native Copilot key setting not present on this build'
}

function Set-WDPowerToysRemap {
    param($Context)

    $ptRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys'
    $kbmDir = Join-Path $ptRoot 'Keyboard Manager'
    $cfg    = Join-Path $kbmDir 'default.json'

    # Windows reports the modifier as either generic Shift or Left Shift
    # depending on the keyboard driver, so map both.
    $wanted = @(
        @{ originalKeys = "$($script:VK.LWin);$($script:VK.LShift);$($script:VK.F23)"; newRemapKeys = "$($script:VK.RCtrl)" },
        @{ originalKeys = "$($script:VK.LWin);$($script:VK.Shift);$($script:VK.F23)";  newRemapKeys = "$($script:VK.RCtrl)" }
    )

    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message 'Would map Win+Shift+F23 to Right Ctrl in PowerToys'
    }

    try {
        if (-not (Test-Path -LiteralPath $kbmDir)) { $null = New-Item -ItemType Directory -Path $kbmDir -Force }

        $json = $null
        # A copy only when there was a file to copy: the journal used to name
        # "$cfg.wdbak" either way, so undoing a run that created the file
        # looked for a copy that had never been made, and failed.
        $bak = $null
        if (Test-Path -LiteralPath $cfg) {
            $bak = Get-WDBackupPath -Path $cfg -Context $Context
            Copy-Item -LiteralPath $cfg -Destination $bak -Force -ErrorAction SilentlyContinue
            try { $json = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json } catch { $json = $null }
        }
        if (-not $json) {
            $json = [pscustomobject]@{
                remapKeys       = [pscustomobject]@{ inProcess = @() }
                remapKeysToText = [pscustomobject]@{ inProcess = @() }
                remapShortcuts  = [pscustomobject]@{ global = @(); appSpecific = @() }
            }
        }
        if (-not $json.PSObject.Properties['remapShortcuts']) {
            $json | Add-Member -NotePropertyName remapShortcuts -NotePropertyValue ([pscustomobject]@{ global = @(); appSpecific = @() }) -Force
        }
        if (-not $json.remapShortcuts.PSObject.Properties['global'] -or $null -eq $json.remapShortcuts.global) {
            $json.remapShortcuts | Add-Member -NotePropertyName global -NotePropertyValue @() -Force
        }

        $global = @($json.remapShortcuts.global)
        $added  = 0
        foreach ($w in $wanted) {
            $exists = $global | Where-Object { $_.originalKeys -eq $w.originalKeys }
            if ($exists) {
                $exists.newRemapKeys = $w.newRemapKeys
            } else {
                $global += [pscustomobject]$w
                $added++
            }
        }
        $json.remapShortcuts.global = $global
        Write-WDJsonNoBom -Path $cfg -Object $json -Depth 12

        Add-WDJournal -ItemId $Context.ItemId -Type 'copilot-key' -Target $cfg -Status 'Changed' `
                      -Undo @{ method = 'file-restore'; file = $bak; target = $cfg }

        # Make sure the module is actually switched on - through the same merge
        # the PowerToys options use, which backs the file up per run and journals
        # it, so undoing this leaves Keyboard Manager as it was. It was edited
        # with no backup and no journal entry at all. Only a file PowerToys has
        # written: absent, it starts every module at its own default, and
        # Keyboard Manager's is on.
        $ptSettings = Join-Path $ptRoot 'settings.json'
        if (Test-Path -LiteralPath $ptSettings) {
            try {
                $null = Set-WDPowerToysJson -Path $ptSettings -Context $Context -Edit {
                    param($j)
                    if (-not $j.PSObject.Properties['enabled']) { $j | Add-Member -NotePropertyName 'enabled' -NotePropertyValue ([pscustomobject]@{}) -Force }
                    $j.enabled | Add-Member -NotePropertyName 'Keyboard Manager' -NotePropertyValue $true -Force
                }
            } catch {
                Write-WDLog "Keyboard Manager could not be switched on in PowerToys' settings: $($_.Exception.Message)" -Level Warn -Item $Context.ItemId
            }
        }

        # PowerToys reads its config only at start, and the engine is a separate
        # process from the tray app - it is the one that has to be bounced.
        $engine  = @(Get-Process -Name 'PowerToys.KeyboardManagerEngine' -ErrorAction SilentlyContinue)
        $running = @(Get-Process -Name 'PowerToys' -ErrorAction SilentlyContinue)
        $exe = ''
        if ($running.Count) { $exe = [string]$running[0].Path }
        if ($engine.Count -or $running.Count) {
            $engine  | Stop-Process -Force -ErrorAction SilentlyContinue
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 900
            if ($exe) { Start-Process -FilePath $exe -ErrorAction SilentlyContinue }
        }

        # Read back what is on disk rather than reporting the intent: PowerToys
        # owns this file and rewrites it in its own format when it feels like
        # it.
        $landed = $false
        try {
            $back = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
            foreach ($g in @($back.remapShortcuts.global)) {
                if ([string]$g.newRemapKeys -eq [string]$script:VK.RCtrl) { $landed = $true; break }
            }
        } catch { }

        if (-not $landed) {
            return New-WDResult -Status Partial `
                -Message 'Written to PowerToys, but not confirmed' `
                -Detail ("The remap was written to $cfg and PowerToys was restarted, but reading the file back " +
                         'did not show it. PowerToys rewrites this file in its own format and can drop or change ' +
                         'entries it did not create. Open PowerToys > Keyboard Manager > Remap a shortcut and ' +
                         'check that Win+Shift+F23 maps to Right Ctrl.')
        }

        # Not "the key now acts as Right Ctrl" - that is a claim about pressing
        # it, and nothing here has.
        New-WDResult -Status Changed `
            -Message 'Copilot key remapped to Right Ctrl in PowerToys' `
            -Detail "$added mapping(s) written to Keyboard Manager and confirmed in the config. PowerToys must stay installed and running at login for this to keep working."
    } catch {
        New-WDResult -Status Failed -Message 'Could not write PowerToys remap' -Detail $_.Exception.Message
    }
}

Register-WDHandler 'RemoveOneDrive' {
    param($Action, $Context)

    $steps  = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]

    # Known Folder Move first: OneDrive repoints Documents, Pictures, and
    # Desktop into its own folder, and uninstalling without putting them back
    # strands them. Every account the run reaches, not only the one running
    # it - the others kept their Desktop and Documents pointing into a OneDrive
    # folder nothing synced any more. Both spellings Windows stores: the named
    # values and the known-folder GUIDs beside them.
    $shellRel = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $kfm = @(
        @{ Name = 'Personal';                               Local = 'Documents' }
        @{ Name = '{F42EE2D3-909F-4907-8871-4C22FC0BF756}'; Local = 'Documents' }
        @{ Name = 'My Pictures';                            Local = 'Pictures' }
        @{ Name = '{0DDD015D-B06C-45D5-8C4C-F59713854639}'; Local = 'Pictures' }
        @{ Name = 'My Video';                               Local = 'Videos' }
        @{ Name = '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}'; Local = 'Videos' }
        @{ Name = 'My Music';                               Local = 'Music' }
        @{ Name = '{A0C69A99-21C8-4671-8703-7934162FCF1D}'; Local = 'Music' }
        @{ Name = 'Desktop';                                Local = 'Desktop' }
        @{ Name = '{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}'; Local = 'Desktop' }
    )
    $moved = New-Object System.Collections.Generic.List[string]
    $hives = @(Select-WDAccountHives -Hives (Get-WDUserHives) -Default $null -Accounts (Get-WDContextAccounts $Context))
    foreach ($h in $hives) {
        # Whose profile this hive is, so %USERPROFILE% in its values means that
        # person's folder rather than the one running this.
        $profileDir = $env:USERPROFILE
        if ([string]$h.Name -ne 'CurrentUser') {
            $profileDir = ''
            try { $profileDir = [string](Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($h.Name)" -Name 'ProfileImagePath' -ErrorAction Stop).ProfileImagePath } catch { }
            if (-not $profileDir) { continue }
            $profileDir = [Environment]::ExpandEnvironmentVariables($profileDir)
        }
        $key = Join-Path $h.Path $shellRel
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $into = '^' + [regex]::Escape($profileDir.TrimEnd('\')) + '\\OneDrive( - [^\\]+)?\\'
        foreach ($k in $kfm) {
            $cur = ''
            # Read unexpanded: %USERPROFILE% has to be resolved against this
            # hive's profile, not this process's.
            try {
                $rk = Get-Item -LiteralPath $key -ErrorAction Stop
                $cur = [string]$rk.GetValue($k.Name, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            } catch { continue }
            if (-not $cur) { continue }
            $expanded = $cur -ireplace '%USERPROFILE%', $profileDir.TrimEnd('\')
            if ($expanded -notmatch $into) { continue }
            $moved.Add("$($k.Name) ($($h.Name))")
            if ($Context.Preview) { continue }
            try {
                $local = Join-Path $profileDir $k.Local
                if (-not (Test-Path -LiteralPath $local)) {
                    $null = New-Item -ItemType Directory -Path $local -Force -ErrorAction Stop
                }
                Add-WDJournal -ItemId $Context.ItemId -Type 'registry' -Target "$key\$($k.Name)" -Status 'Changed' `
                              -Undo @{ method = 'registry'; path = $key; name = $k.Name; kind = 'ExpandString'; previous = $cur; raw = $true }
                # The form Windows itself writes, which follows the profile if
                # it ever moves.
                Set-ItemProperty -LiteralPath $key -Name $k.Name -Value "%USERPROFILE%\$($k.Local)" -Type ExpandString -Force -ErrorAction Stop
                Write-WDLog "$($k.Name) for $($h.Name) was redirected into OneDrive; pointed back at $local so it still resolves once OneDrive is gone. Anything stored in the OneDrive copy stays in your OneDrive account." `
                            -Level Warn -Item $Context.ItemId
            } catch {
                $failed.Add("could not point $($k.Name) for $($h.Name) back at the local profile: $($_.Exception.Message)")
            }
        }
    }
    if ($moved.Count) {
        $steps.Add("$($moved.Count) folder setting(s) pointed back at this PC ($($moved -join ', '))")
    }

    if (-not $Context.Preview) {
        Get-Process -Name 'OneDrive','FileCoAuth','Microsoft.SharePoint' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }

    # Every uninstaller present, in the order that matters. The uninstall
    # entries first and verbatim: a per-machine install registers
    # ".../OneDriveSetup.exe /uninstall /allusers", and running its setup with
    # plain /uninstall - all this ever did - left the per-machine copy under
    # Program Files standing (21 MB of it on this machine). Then the copies
    # under Program Files by path, then the in-box setup and the per-user ones.
    $cmds = New-Object System.Collections.Generic.List[psobject]
    foreach ($p in @(Get-WDInstalledPrograms | Where-Object { $_.DisplayName -like 'Microsoft OneDrive*' -and $_.UninstallString })) {
        $u = [string]$p.UninstallString
        $exe = $u; $argLine = ''
        if ($u -match '^\s*"([^"]+)"\s*(.*)$')        { $exe = $Matches[1]; $argLine = $Matches[2] }
        elseif ($u -match '^\s*(\S+\.exe)\s*(.*)$')   { $exe = $Matches[1]; $argLine = $Matches[2] }
        $cmds.Add([pscustomobject]@{ Exe = $exe; Args = $argLine; Why = "$($p.DisplayName) uninstall entry" })
    }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        foreach ($s in @(Get-ChildItem -Path (Join-Path $root 'Microsoft OneDrive\*\OneDriveSetup.exe') -ErrorAction SilentlyContinue)) {
            $cmds.Add([pscustomobject]@{ Exe = $s.FullName; Args = '/uninstall /allusers'; Why = 'per-machine install' })
        }
    }
    $setups = @(
        (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'),
        (Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDriveSetup.exe')
    )
    foreach ($dir in (Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive') -Directory -ErrorAction SilentlyContinue)) {
        $candidate = Join-Path $dir.FullName 'OneDriveSetup.exe'
        if (Test-Path -LiteralPath $candidate) { $setups += $candidate }
    }
    foreach ($s in ($setups | Sort-Object -Unique)) {
        $cmds.Add([pscustomobject]@{ Exe = $s; Args = '/uninstall'; Why = 'setup' })
    }

    $ran = $false
    # Kept apart from $failed: the in-box setups run after the real uninstaller
    # and answer with an error when it has already taken everything, which
    # reported a complete removal as "partly removed" (0x8004069B twice, on a
    # laptop where the uninstall entry had just done the job). Judged below
    # against whether OneDrive is actually still there.
    $setupFails = New-Object System.Collections.Generic.List[string]
    $done = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($c in $cmds) {
        if (-not (Test-Path -LiteralPath $c.Exe)) { continue }
        if (-not $done.Add("$($c.Exe)|$($c.Args)")) { continue }
        $ran = $true
        if ($Context.Preview) { $steps.Add("uninstall via $(Split-Path $c.Exe -Leaf) $($c.Args) ($($c.Why))"); continue }
        $r = Invoke-WDProcess -FilePath $c.Exe -ArgumentList @($c.Args) -TimeoutSeconds 300
        # Plain arithmetic: 0xFFFFFFFF is -1 to PowerShell 5.1, so masking with
        # it changes nothing.
        $u = [int64]$r.ExitCode; if ($u -lt 0) { $u += 4294967296 }
        $hex = '0x{0:X8}' -f $u
        if ($r.ExitCode -in @(0, 3010)) { $steps.Add("uninstaller ran ($($c.Why))") } else { $setupFails.Add("$($c.Why): $(Split-Path $c.Exe -Leaf) $($c.Args) exit $($r.ExitCode) ($hex)") }
    }

    if (-not $Context.Preview) {
        Clear-WDProgramCache
        # Its scheduled tasks, through the task executor so each definition is
        # exported first and the rollback can register it again - they were
        # unregistered here with nothing journalled.
        $t = Invoke-WDTaskAction -Context $Context -Action ([pscustomobject]@{ type = 'task'; tasks = @('\OneDrive*'); delete = $true })
        if ([string]$t.Status -in @('Changed', 'Removed')) { $steps.Add('scheduled tasks removed') }
        # The startup entries, every account plus the default profile, whose
        # OneDriveSetup value is what installs OneDrive for each new account.
        # Through the registry executor, so each is journalled.
        $null = Invoke-WDRegistryAction -Context $Context -Action ([pscustomobject]@{
            type = 'registry'; scope = 'allusers'
            values = @(
                [pscustomobject]@{ path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; name = 'OneDrive';      kind = 'String'; value = ''; delete = $true }
                [pscustomobject]@{ path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; name = 'OneDriveSetup'; kind = 'String'; value = ''; delete = $true }
            ) })
    }

    # Asked of the machine after the uninstallers, the same question the
    # "already done" probe asks: an uninstall entry, or OneDrive.exe in either
    # place it installs. The folders themselves go in the next action.
    if (-not $Context.Preview -and $setupFails.Count) {
        $left = @(Get-WDInstalledPrograms | Where-Object { $_.DisplayName -like 'Microsoft OneDrive*' }).Count -gt 0
        foreach ($exe in @((Join-Path ([string]$env:ProgramFiles) 'Microsoft OneDrive\OneDrive.exe'),
                           (Join-Path ([string]${env:ProgramFiles(x86)}) 'Microsoft OneDrive\OneDrive.exe'),
                           (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'))) {
            if (Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue) { $left = $true }
        }
        if ($left) {
            foreach ($f in $setupFails) { $failed.Add($f) }
        } elseif (@($steps | Where-Object { $_ -like 'uninstaller ran*' }).Count) {
            $steps.Add("OneDrive confirmed gone; the remaining setup copies had nothing left to remove ($($setupFails -join '; '))")
        } elseif ($steps.Count) {
            $steps.Add("OneDrive itself was not installed ($($setupFails -join '; '))")
        } else {
            # Nothing uninstalled and nothing there: the in-box setup stub
            # exists on every machine and errors when OneDrive never was.
            return New-WDResult -Status NotPresent -Message 'OneDrive not installed' -Detail ($setupFails -join '; ')
        }
    }

    if (-not $ran -and -not $steps.Count) { return New-WDResult -Status NotPresent -Message 'OneDrive not installed' }
    if ($failed.Count -and -not $steps.Count) { return New-WDResult -Status Failed -Message 'OneDrive removal failed' -Detail ($failed -join '; ') }
    if ($failed.Count) {
        return New-WDResult -Status Partial -Message 'OneDrive partly removed' -Detail ((($steps | Sort-Object -Unique) -join ', ') + ' | ' + ($failed -join '; '))
    }
    New-WDResult -Status Removed -Message 'OneDrive removed' -Detail (($steps | Sort-Object -Unique) -join ', ')
}

Register-WDHandler 'McAfeeScrub' {
    # McAfee's own uninstallers leave drivers, services, and a filter driver
    # behind. MCPR is the vendor's supported cleanup tool.
    param($Action, $Context)

    $found = Get-WDInstalledPrograms | Where-Object { $_.DisplayName -like '*McAfee*' -or $_.Publisher -like '*McAfee*' }
    if (-not $found) { return New-WDResult -Status NotPresent -Message 'No McAfee products installed' }
    if ($Context.Preview) {
        return New-WDResult -Status Removed -Message "Would remove $(@($found).Count) McAfee product(s)" `
                            -Detail (($found.DisplayName) -join ', ')
    }

    # Standard uninstall first; MCPR is only needed for the residue.
    $inner = Invoke-WDUninstallAction -Action ([pscustomobject]@{
        match = @('McAfee*','*McAfee*'); timeoutSeconds = 900 }) -Context $Context

    if (-not $Context.AllowDownloads) {
        return New-WDResult -Status $inner.Status `
            -Message "$($inner.Message) - residue left behind" `
            -Detail "$($inner.Detail) | Enable 'allow vendor cleanup downloads' to run McAfee's MCPR tool and remove the leftover drivers and services."
    }

    # MCPR is interactive - a terms page and a typed code - so it can only be
    # handed to the person at the screen. Run unattended (a guard, as SYSTEM)
    # there is nobody to finish it, and the run used to sit on it for twenty
    # minutes and then report McAfee "scrubbed" whatever had happened.
    $sys = $false
    try { $sys = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem } catch { }
    if ($sys) {
        return New-WDResult -Status $inner.Status -Message "$($inner.Message) - McAfee's cleanup tool needs someone at the screen" `
                            -Detail "$($inner.Detail) | Run this option from the toolkit window to be handed McAfee's MCPR tool for what the uninstaller left."
    }

    $url = 'https://download.mcafee.com/molbin/iss-loc/SupportTools/MCPR/MCPR.exe'
    $dst = Join-Path $Context.Session.RunDir 'MCPR.exe'
    try {
        Write-WDLog "Downloading McAfee MCPR from $url" -Level Info -Item $Context.ItemId
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -TimeoutSec 180
        # A downloaded executable about to run elevated is checked first: a
        # valid Authenticode signature, from McAfee.
        $sig = Get-AuthenticodeSignature -FilePath $dst -ErrorAction Stop
        if ([string]$sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or [string]$sig.SignerCertificate.Subject -notmatch 'McAfee') {
            Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
            return New-WDResult -Status $inner.Status -Message "$($inner.Message) - MCPR not run" `
                                -Detail "The downloaded MCPR.exe was not validly signed by McAfee ($($sig.Status)), so it was deleted unrun. Get it from mcafee.com if you want it."
        }
        Start-Process -FilePath $dst -ErrorAction Stop
        Set-WDRebootNeeded
        New-WDResult -Status $inner.Status -Message "$($inner.Message) - McAfee's MCPR cleanup is open on screen" `
                     -Detail "$($inner.Detail) | Follow MCPR's own steps to remove the drivers and services the uninstaller leaves behind, then restart." -Reboot
    } catch {
        New-WDResult -Status $inner.Status -Message "$($inner.Message) - MCPR scrub unavailable" -Detail $_.Exception.Message
    }
}

Register-WDHandler 'NortonScrub' {
    param($Action, $Context)

    $found = Get-WDInstalledPrograms | Where-Object { $_.DisplayName -match 'Norton|Symantec' }
    if (-not $found) { return New-WDResult -Status NotPresent -Message 'No Norton products installed' }
    if ($Context.Preview) {
        return New-WDResult -Status Removed -Message "Would remove $(@($found).Count) Norton product(s)" -Detail (($found.DisplayName) -join ', ')
    }

    $inner = Invoke-WDUninstallAction -Action ([pscustomobject]@{
        match = @('Norton*','Symantec*'); timeoutSeconds = 900 }) -Context $Context

    if (-not $Context.AllowDownloads) {
        return New-WDResult -Status $inner.Status -Message "$($inner.Message) - residue left behind" `
            -Detail "$($inner.Detail) | Enable vendor cleanup downloads to run Norton Remove and Reinstall."
    }

    $url = 'https://norton.com/nrnr'
    New-WDResult -Status $inner.Status `
        -Message "$($inner.Message) - finish with Norton's own tool" `
        -Detail "Norton Remove and Reinstall must be run interactively: $url"
}

Register-WDHandler 'VerifyDefender' {
    param($Action, $Context)

    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        if ($status.AntivirusEnabled -and $status.RealTimeProtectionEnabled) {
            # A check that passed. Nothing was done and nothing needed to be,
            # where Changed claimed this row was about to alter the machine.
            return New-WDResult -Status AlreadySet -Message 'Microsoft Defender is active and protecting this machine'
        }
        if ($Context.Preview) { return New-WDResult -Status Changed -Message 'Would re-enable Defender real-time protection' }

        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Start-Service -Name WinDefend -ErrorAction SilentlyContinue
        $after = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if ($after -and $after.RealTimeProtectionEnabled) {
            return New-WDResult -Status Changed -Message 'Defender real-time protection re-enabled'
        }
        New-WDResult -Status Blocked -Message 'Defender still inactive - reboot and check Windows Security' -Detail 'Third-party AV residue can hold Defender off until a restart.'
    } catch {
        New-WDResult -Status Skipped -Message 'Defender status unavailable' -Detail $_.Exception.Message
    }
}

Register-WDHandler 'RemoveInstallShortcuts' {
    # "Install without a desktop shortcut", after the fact: there is no portable
    # winget switch for it.
    param($Action, $Context)

    $since = $null
    try { $since = (Get-Item -LiteralPath $Context.Session.RunDir -ErrorAction Stop).CreationTime } catch { }
    if (-not $since) {
        return New-WDResult -Status Skipped -Message 'Could not tell when this run started, so nothing was removed'
    }

    $desktops = @(
        [Environment]::GetFolderPath('Desktop')
        [Environment]::GetFolderPath('CommonDesktopDirectory')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique

    $found = New-Object System.Collections.Generic.List[psobject]
    foreach ($d in $desktops) {
        try {
            Get-ChildItem -LiteralPath $d -File -Force -ErrorAction Stop |
                Where-Object { $_.Extension -in @('.lnk', '.url') -and $_.CreationTime -ge $since } |
                ForEach-Object { $found.Add($_) }
        } catch { }
    }

    if (-not $found.Count) {
        return New-WDResult -Status NotPresent -Message 'No new desktop shortcuts were created by this run'
    }

    $names = @($found | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } | Sort-Object -Unique)
    if ($Context.Preview) {
        return New-WDResult -Status Removed -Message "Would remove $($found.Count) new desktop shortcut(s)" `
                            -Detail ($names -join ', ')
    }

    # Recycled, not deleted: this is the one class of file the run creates on
    # somebody's desktop, and getting it wrong should cost a drag out of the
    # bin. Through the shared routine, which asks whether there is a bin to use
    # at all - this one used to recycle without asking, on a volume where that
    # quietly deletes - and deletes outright only in irreversible mode, which
    # empties the bin at the end anyway and would leave every entry journalled
    # here a promise nothing could keep.
    $gone = 0
    $why  = New-Object System.Collections.Generic.List[string]
    foreach ($f in $found) {
        if (Test-WDIrreversible) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $gone++ } catch { $why.Add("$($f.Name): $($_.Exception.Message)") }
            continue
        }
        $no = Remove-WDFileUndoable -Path $f.FullName -ItemId $Context.ItemId
        if ($no) { $why.Add("$($f.Name): $no") } else { $gone++ }
    }
    if (-not $gone) {
        return New-WDResult -Status Blocked -Message 'The new shortcuts could not be moved to the Recycle Bin' -Detail ($why -join '; ')
    }
    New-WDResult -Status Removed -Message "$gone new desktop shortcut(s) removed" `
                 -Detail "$($names -join ', '). Only shortcuts created during this run were touched."
}

# Startup entries that must survive even though they are not programs in the
# uninstall sense - audio stacks, security UI, input drivers.
$script:KeepStartup = @(
    'SecurityHealth*', 'Windows Defender*', 'WindowsDefender*', 'MSC*'
    'RTHDVCPL', 'RtkAudUService*', 'Realtek*', 'WavesSvc*', 'Dolby*', 'Nahimic*'
    'IgfxTray', 'HotKeysCmds', 'Persistence', 'IntelGraphics*', 'DellSupport*'
    'SynTPEnh*', 'SynTPStart', 'ETDCtrl*', 'ELAN*', 'ApntEx', 'Apoint'
    'NvBackend', 'NVIDIA*', 'AMD*', 'ATIPTA', 'StartCN'
    'Logitech*', 'LogiOptions*', 'Corsair*', 'SteelSeries*', 'Wacom*'
    'PowerToys*'    # required for the Copilot key remap to work
)

function Get-WDRunValues {
    # The values of one Run key, read through the key rather than as object
    # properties - a Run value named PSPath, or anything starting PS, is
    # otherwise indistinguishable from the provider's own.
    param([string]$Key)
    $out = New-Object System.Collections.Generic.List[psobject]
    if (-not (Test-Path -LiteralPath $Key -ErrorAction SilentlyContinue)) { return ,$out.ToArray() }
    try {
        $k = Get-Item -LiteralPath $Key -ErrorAction Stop
        foreach ($n in $k.GetValueNames()) {
            if (-not $n) { continue }
            $out.Add([pscustomobject]@{ Name = [string]$n; Command = [string]$k.GetValue($n) })
        }
    } catch { }
    ,$out.ToArray()
}

function New-WDStartupDisabledBytes {
    # Task Manager's own "disabled": a little-endian 3, then the FILETIME it was
    # switched off. 0x02 or 0x06 in the first byte is enabled, and an entry with
    # no StartupApproved value at all counts as enabled.
    $b = New-Object byte[] 12
    $b[0] = 3
    [Array]::Copy([BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()), 0, $b, 4, 8)
    ,$b
}

function Test-WDStartupApprovedOff {
    # The low bit of the first byte is what reads as disabled: 3 is Task
    # Manager's, and 7 is taken the same way rather than as enabled.
    param([string]$Key, [string]$Name)
    try {
        $bytes = [byte[]](Get-ItemProperty -LiteralPath $Key -Name $Name -ErrorAction Stop).$Name
        return ($bytes.Length -ge 1 -and ($bytes[0] -band 1) -eq 1)
    } catch { return $false }
}

Register-WDHandler 'DisableStartupEntries' {
    # Task Manager's own switch, not a deletion. Each Run value and Startup
    # folder file gets a StartupApproved entry marking it disabled - keyed by
    # its name, in the same hive as its source - and each packaged startup task
    # a State of 1, "disabled by the user", which the app itself cannot
    # overturn. Nothing is deleted, so Settings > Apps > Startup and Task
    # Manager list every entry as Disabled and turn it back on in one click.
    # It used to delete the Run values and rename the files, which put them
    # where no page could show them, and Steam put its own value straight back.
    param($Action, $Context)

    $protected = Get-WDProtectedPrograms -Profile $Context.Profile
    $isProtected = {
        param([string]$name, [string]$command)
        if (Test-WDPatternMatch $name $script:KeepStartup) { return $true }
        if (Test-WDPatternMatch $name $protected)          { return $true }
        foreach ($p in $protected) {
            # Match on the executable path too: Run value names are often
            # nothing like the product name in Add/Remove Programs.
            if ($command -and $command -like "*$($p.TrimEnd('*'))*") { return $true }
        }
        $false
    }

    $values  = New-Object System.Collections.Generic.List[psobject]
    $named   = New-Object System.Collections.Generic.List[string]
    $kept    = New-Object System.Collections.Generic.List[string]
    $already = New-Object System.Collections.Generic.List[string]
    $off     = New-WDStartupDisabledBytes
    $sa      = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

    $queue = {
        param([string]$Approved, [string]$Name, [string]$Label, [string]$Command)
        if (& $isProtected $Label $Command) { $kept.Add($Label); return }
        if (Test-WDStartupApprovedOff -Key $Approved -Name $Name) { $already.Add($Label); return }
        $values.Add([pscustomobject]@{ path = $Approved; name = $Name; kind = 'Binary'; value = $off })
        $named.Add($Label)
    }

    # Machine-wide Run keys, approved under HKLM - Run32 for the 32-bit one.
    foreach ($pair in @(
        @{ Src = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKLM:\$sa\Run" }
        @{ Src = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$sa\Run32" })) {
        foreach ($e in (Get-WDRunValues -Key $pair.Src)) { & $queue $pair.Approved $e.Name $e.Name $e.Command }
    }
    $common = [Environment]::GetFolderPath('CommonStartup')
    if ($common -and (Test-Path -LiteralPath $common)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $common -File -ErrorAction SilentlyContinue)) {
            if ($f.Extension -eq '.disabled') { continue }
            & $queue "HKLM:\$sa\StartupFolder" $f.Name $f.BaseName $f.FullName
        }
    }

    # Each selected account's own Run key, Startup folder, and packaged
    # startup tasks, approved in that account's hive. The default profile has
    # none of these to switch off.
    $roots = @(Select-WDAccountHives -Hives (Get-WDUserHives) -Default $null -Accounts (Get-WDContextAccounts $Context))
    foreach ($root in $roots) {
        foreach ($e in (Get-WDRunValues -Key (Join-Path $root.Path 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'))) {
            & $queue (Join-Path $root.Path "$sa\Run") $e.Name $e.Name $e.Command
        }

        $startup = ''
        if ([string]$root.Name -eq 'CurrentUser') { $startup = [Environment]::GetFolderPath('Startup') }
        else {
            try {
                $pdir = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($root.Name)" -Name 'ProfileImagePath' -ErrorAction Stop).ProfileImagePath)
                $startup = Join-Path $pdir 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
            } catch { }
        }
        if ($startup -and (Test-Path -LiteralPath $startup)) {
            foreach ($f in @(Get-ChildItem -LiteralPath $startup -File -ErrorAction SilentlyContinue)) {
                if ($f.Extension -eq '.disabled') { continue }
                & $queue (Join-Path $root.Path "$sa\StartupFolder") $f.Name $f.BaseName $f.FullName
            }
        }

        # Packaged (MSIX) startup tasks: State 2 is enabled, 1 disabled by the
        # user. 0 never enabled, 3 and 4 policy's - all three left alone.
        $apps = Join-Path $root.Path 'Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
        if (-not (Test-Path -LiteralPath $apps -ErrorAction SilentlyContinue)) { continue }
        foreach ($pkg in @(Get-ChildItem -LiteralPath $apps -ErrorAction SilentlyContinue)) {
            foreach ($task in @(Get-ChildItem -LiteralPath $pkg.PSPath -ErrorAction SilentlyContinue)) {
                $state = $null
                try { $state = [int](Get-ItemProperty -LiteralPath $task.PSPath -Name 'State' -ErrorAction Stop).State } catch { continue }
                $family = ([string]$pkg.PSChildName) -replace '_[^_]+$', ''
                $label  = "$($task.PSChildName) ($family)"
                if ($state -eq 1) { $already.Add($label); continue }
                if ($state -ne 2) { continue }
                if ((& $isProtected ([string]$task.PSChildName) '') -or (& $isProtected $family '')) { $kept.Add($label); continue }
                $tk = Join-Path (Join-Path $apps $pkg.PSChildName) $task.PSChildName
                $values.Add([pscustomobject]@{ path = $tk; name = 'State'; kind = 'DWord'; value = 1 })
                $values.Add([pscustomobject]@{ path = $tk; name = 'LastDisabledTime'; kind = 'QWord'; value = [int64][DateTime]::UtcNow.ToFileTimeUtc() })
                $named.Add($label)
            }
        }
    }

    $keptNote = $(if ($kept.Count) { " | kept as system dependencies: $((($kept | Sort-Object -Unique) -join ', '))" } else { '' })
    $offNote  = $(if ($already.Count) { " | already disabled: $((($already | Sort-Object -Unique) -join ', '))" } else { '' })
    if (-not $values.Count) {
        if ($already.Count) { return New-WDResult -Status AlreadySet -Message 'Every startup entry is already disabled' -Detail (($offNote + $keptNote).TrimStart(' |')) }
        if ($kept.Count) { return New-WDResult -Status Skipped -Message "All $($kept.Count) startup entries are system dependencies - none touched" -Detail $keptNote.TrimStart(' |') }
        return New-WDResult -Status NotPresent -Message 'No startup entries found'
    }

    $res = Invoke-WDRegistryAction -Action ([pscustomobject]@{ type = 'registry'; scope = 'machine'; values = $values.ToArray() }) -Context $Context
    if ([string]$res.Status -notin @('Changed', 'Removed')) { return $res }
    $verb = $(if ($Context.Preview) { 'Would disable' } else { 'Disabled' })
    New-WDResult -Status Changed -Message "$verb $($named.Count) startup entr$(if ($named.Count -eq 1) { 'y' } else { 'ies' })" `
                 -Detail ("$((($named | Sort-Object -Unique) -join ', '))$offNote$keptNote")
}

Register-WDHandler 'ScanStartup' {
    param($Action, $Context)

    $entries = New-Object System.Collections.Generic.List[psobject]
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($k in $runKeys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            $entries.Add([pscustomobject]@{ Source = $k; Name = $prop.Name; Command = $prop.Value })
        }
    }
    foreach ($folder in @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup'))) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
            $entries.Add([pscustomobject]@{ Source = $folder; Name = $f.BaseName; Command = $f.FullName })
        }
    }

    if (-not $entries.Count) { return New-WDResult -Status NotPresent -Message 'No startup entries found' }
    $out = Join-Path $Context.Session.RunDir 'startup-entries.csv'
    $entries | Export-Csv -LiteralPath $out -NoTypeInformation -Encoding UTF8
    New-WDResult -Status Changed -Message "$($entries.Count) startup entries listed" -Detail "Written to $out - nothing was disabled."
}

Register-WDHandler 'ClearRunLogs' {
    param($Action, $Context)

    $root = $Context.Session.Root
    if (-not (Test-Path -LiteralPath $root)) { return New-WDResult -Status NotPresent -Message 'No log folder to clean' }

    $current = Split-Path $Context.Session.RunDir -Leaf
    $old = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'run-*' -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -ne $current })
    if (-not $old.Count) { return New-WDResult -Status NotPresent -Message 'No previous runs to delete' }

    $bytes = 0
    foreach ($d in $old) {
        try { $bytes += (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
                         Measure-Object Length -Sum).Sum } catch { }
    }
    $mb = [Math]::Round($bytes / 1MB, 1)

    if ($Context.Preview) {
        return New-WDResult -Status Removed -Message "Would delete $($old.Count) old run folder(s), about $mb MB" `
                            -Detail 'Their rollback scripts and journals go with them.'
    }

    $gone = 0; $stuck = @()
    foreach ($d in $old) {
        try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $gone++ }
        catch { $stuck += $d.Name }
    }
    if ($gone -and -not $stuck.Count) {
        return New-WDResult -Status Removed -Message "$gone old run folder(s) deleted, about $mb MB freed"
    }
    if ($gone) {
        return New-WDResult -Status Partial -Message "$gone deleted, $($stuck.Count) in use" -Detail ($stuck -join ', ')
    }
    New-WDResult -Status Blocked -Message 'Could not delete the old run folders' -Detail ($stuck -join ', ')
}

Register-WDHandler 'RemoveUninstallLeftovers' {
    param($Action, $Context)

    # Assigned, never wrapped in @(). Get-WDUninstalledThisRun ends in ,@(...),
    # and wrapped, the loop ran once with $d bound to the whole list.
    $done = Get-WDUninstalledThisRun
    if (-not $done.Count) { return New-WDResult -Status NotPresent -Message 'Nothing was uninstalled this run' }

    # Never sweep a shared root: some installers write "C:\Program Files" into
    # InstallLocation. The list lives in WD.Core, because the process kill needs
    # the identical answer.
    # Some vendors declare their vendor root as the install location, so the
    # folder a program leaves behind can also be the folder another of that
    # vendor's programs lives in. Read fresh, after this run's uninstalls.
    Clear-WDProgramCache
    $liveRoots = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(Get-WDInstalledPrograms)) {
        $l = ([string]$p.InstallLocation).Trim().Trim('"').TrimEnd('\')
        if ($l) { $liveRoots.Add($l) }
    }

    $found = New-Object System.Collections.Generic.List[psobject]
    $held  = New-Object System.Collections.Generic.List[string]
    foreach ($d in $done) {
        $loc = Test-WDSweepableRoot -Path ([string]$d.InstallLocation)
        if (-not $loc) { continue }
        if (-not (Test-Path -LiteralPath $loc -PathType Container)) { continue }
        $root = ([string]$loc).TrimEnd('\')
        $owner = $null
        foreach ($l in $liveRoots) {
            if ($l -ieq $root -or $l.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { $owner = $l; break }
        }
        if ($owner) { $held.Add("$loc (still holds $owner)"); continue }
        # An empty shell is the uninstaller tidying up asynchronously, not a
        # leftover worth reporting.
        $bytes = 0
        try { $bytes = (Get-ChildItem -LiteralPath $loc -Recurse -File -Force -ErrorAction SilentlyContinue |
                        Measure-Object Length -Sum).Sum } catch { }
        if (-not $bytes) { continue }
        $found.Add([pscustomobject]@{ Name = $d.Name; Path = $loc; Bytes = [long]$bytes })
    }

    $heldNote = ''
    if ($held.Count) { $heldNote = " Left alone, another installed program lives there: $($held -join '; ')" }
    if (-not $found.Count) {
        if ($held.Count) { return New-WDResult -Status Skipped -Message 'Left alone: another installed program lives there' -Detail ($held -join '; ') }
        return New-WDResult -Status NotPresent -Message 'The uninstallers left nothing behind'
    }

    $mb    = [Math]::Round((($found | Measure-Object Bytes -Sum).Sum) / 1MB, 1)
    $detail = (($found | ForEach-Object { "$($_.Name) -> $($_.Path)" }) -join '; ') + $heldNote

    if ($Context.Preview) {
        return New-WDResult -Status Removed -Message "Would clear $($found.Count) leftover folder(s), about $mb MB" -Detail $detail
    }

    $gone = New-Object System.Collections.Generic.List[string]
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($f in $found) {
        # Remove-WDFileUndoable rather than the bin directly: as SYSTEM - every
        # re-apply guard - the bin is one nobody can open, so it parks instead.
        $why = Remove-WDFileUndoable -Path $f.Path -ItemId $Context.ItemId
        if ($why) { $kept.Add("$($f.Path) ($why)") } else { $gone.Add($f.Path) }
    }

    # A folder left because another program lives in it is the sweep being
    # right, not a refusal, so it is said in the detail and never counted as one.
    if ($gone.Count -and -not $kept.Count) {
        return New-WDResult -Status Removed -Message "$($gone.Count) leftover folder(s) cleared, about $mb MB" -Detail (($gone -join '; ') + $heldNote)
    }
    if ($gone.Count) {
        return New-WDResult -Status Partial -Message "$($gone.Count) cleared, $($kept.Count) left in place" -Detail (($kept -join '; ') + $heldNote)
    }
    New-WDResult -Status Blocked -Message 'The leftovers could not be cleared' -Detail (($kept -join '; ') + $heldNote)
}

function Get-WDResidueTokens {
    param([string]$Name)
    if (-not $Name) { return @() }

    $noise = @('the','and','for','inc','ltd','llc','corp','corporation','company','software',
               'technologies','technology','systems','solutions','group','version','edition',
               'x64','x86','win32','win64','bit','update','updater','installer','setup',
               'application','app','tool','tools','suite','client','service','runtime','free')

    $clean = $Name -replace '\(.*?\)', ' ' -replace '[^A-Za-z0-9]+', ' '
    @($clean -split '\s+' |
        Where-Object { $_ -and $_.Length -ge 5 -and $_ -notmatch '^\d' -and $_.ToLower() -notin $noise } |
        ForEach-Object { $_.ToLower() } | Select-Object -Unique)
}

function Get-WDResidueFlat {
    # A name with its punctuation, spacing, bracketed notes, and version numbers
    # taken out, so "Lenovo Now", "LenovoNow", and "Lenovo Now 2.1" compare equal.
    param([string]$Name)
    ($Name -replace '\(.*?\)', ' ' -replace '\bv?\d+(\.\d+)+\b', ' ' -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
}

function New-WDResidueMatcher {
    # What one uninstalled program's leftovers may be called. A folder or key
    # is a match only when its name IS the program - its whole name, or one of
    # its distinctive words standing alone - and never when it merely contains
    # one. It used to be "contains any word of five letters or more", which
    # made "Lenovo Now" a reason to recycle C:\Program Files\Lenovo and delete
    # HKLM\SOFTWARE\Lenovo, where Lenovo Vantage lives, and made Google Drive's
    # "drive" match C:\Program Files\Microsoft OneDrive.
    #
    # Two kinds of word never count: the program's own publisher (a vendor's
    # name is the name of everything that vendor makes) and any word still in
    # the name or publisher of something installed ($KeepWords).
    param($Program, $KeepWords)
    $own = @(Get-WDResidueTokens -Name ([string]$Program.Publisher))
    $words = @(Get-WDResidueTokens -Name ([string]$Program.Name) |
               Where-Object { $_ -notin $own -and -not ($KeepWords -and $KeepWords.Contains($_)) })
    [pscustomobject]@{ Whole = (Get-WDResidueFlat ([string]$Program.Name)); Words = $words }
}

function New-WDResidueKeep {
    # What still-installed programs claim: every word of their names and
    # publishers, and their install folders.
    param($Programs)
    $words = New-WDStringSet @()
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Programs)) {
        if (-not $p) { continue }
        foreach ($t in @(Get-WDResidueTokens -Name ([string]$p.DisplayName)) + @(Get-WDResidueTokens -Name ([string]$p.Publisher))) { $null = $words.Add($t) }
        foreach ($t in @((Get-WDResidueFlat ([string]$p.DisplayName)), (Get-WDResidueFlat ([string]$p.Publisher)))) { if ($t) { $null = $words.Add($t) } }
        $loc = ([string]$p.InstallLocation).Trim().Trim('"').TrimEnd([char]92)
        if ($loc) { $roots.Add($loc.ToLowerInvariant()) }
    }
    [pscustomobject]@{ Words = $words; Roots = $roots }
}

function Test-WDResidueName {
    # The reason a name is the program's, or '' when it is not.
    param([string]$Name, $Matcher, $KeepWords)
    $flat = Get-WDResidueFlat $Name
    if (-not $flat) { return '' }
    # Something still installed answers to this name: a vendor container.
    if ($KeepWords -and $KeepWords.Contains($flat)) { return '' }
    if ($Matcher.Whole.Length -ge 5 -and $flat -eq $Matcher.Whole) { return "named after the program itself" }
    if (@($Matcher.Words) -contains $flat) { return "named '$flat', a word of the program's name that nothing installed shares" }
    ''
}

Register-WDHandler 'RemoveUninstallResidue' {
    param($Action, $Context)

    # Assigned, never wrapped - see RemoveUninstallLeftovers above.
    $done = Get-WDUninstalledThisRun
    if (-not $done.Count) { return New-WDResult -Status NotPresent -Message 'Nothing was uninstalled this run' }

    # Read fresh, after this run's uninstalls: what is still installed decides
    # which names belong to somebody else, and which folders hold a program.
    Clear-WDProgramCache
    $keep      = New-WDResidueKeep -Programs @(Get-WDInstalledPrograms)
    $keepWords = $keep.Words
    $keepRoots = $keep.Roots

    # Only the containers where per-application residue accumulates. Anything
    # one level up would match half the machine.
    $roots = @(
        $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA,
        $env:ProgramFiles, ${env:ProgramFiles(x86)},
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path $env:ProgramFiles 'Common Files'),
        (Join-Path ${env:ProgramFiles(x86)} 'Common Files')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique

    $regRoots = @(
        'HKCU:\SOFTWARE', 'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node'
    ) | Where-Object { Test-Path -LiteralPath $_ }

    # Already-cleared install locations must not be reported a second time.
    $claimed = @($done | ForEach-Object { [string]$_.InstallLocation } |
                 Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() })

    $hits = New-Object System.Collections.Generic.List[psobject]
    foreach ($d in $done) {
        $m = New-WDResidueMatcher -Program $d -KeepWords $keepWords
        if (-not $m.Words.Count -and $m.Whole.Length -lt 5) { continue }

        foreach ($root in $roots) {
            foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
                $tok = Test-WDResidueName -Name $dir.Name -Matcher $m -KeepWords $keepWords
                if (-not $tok) { continue }
                $low = $dir.FullName.TrimEnd([char]92).ToLowerInvariant()
                if ($claimed -contains $low) { continue }
                # A folder that holds - or is - a program still installed is that
                # program's, whatever it is called.
                if (@($keepRoots | Where-Object { $_ -eq $low -or $_.StartsWith("$low\") }).Count) { continue }
                $bytes = 0
                try { $bytes = (Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                                Measure-Object Length -Sum).Sum } catch { }
                $hits.Add([pscustomobject]@{
                    Kind = 'folder'; Program = $d.Name; Path = $dir.FullName
                    Why  = "folder $tok"
                    Size = "$([Math]::Round(([double]$bytes) / 1MB, 1)) MB"
                })
            }
        }

        foreach ($root in $regRoots) {
            foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                $tok = Test-WDResidueName -Name $key.PSChildName -Matcher $m -KeepWords $keepWords
                if (-not $tok) { continue }
                $hits.Add([pscustomobject]@{
                    Kind = 'registry'; Program = $d.Name; Path = $key.Name
                    Why  = "key $tok"; Size = ''
                })
            }
        }
    }

    if (-not $hits.Count) { return New-WDResult -Status NotPresent -Message 'No residue matched anything uninstalled this run' }

    $hits = @($hits | Sort-Object Program, Kind, Path)

    if ($Context.Preview) {
        foreach ($h in $hits) {
            $size = $(if ($h.Size) { " ($($h.Size))" } else { '' })
            Write-WDFinding -Name "$($h.Program): $($h.Kind) left behind" `
                            -Detail "$($h.Path)$size - $($h.Why). Applying will send it to the Recycle Bin, or export and delete it if it is a key." `
                            -ItemId $Context.ItemId
        }
        $f = @($hits | Where-Object { $_.Kind -eq 'folder' }).Count
        $k = @($hits | Where-Object { $_.Kind -eq 'registry' }).Count
        return New-WDResult -Status Removed `
                            -Message "Would clear $($hits.Count) leftover(s) - $f folder(s), $k registry key(s)" `
                            -Detail 'Each one is listed above. Every folder goes to the Recycle Bin and every key is exported first, so the rollback script puts them all back.'
    }

    # A folder holding a running process is the one case where the name match is
    # demonstrably wrong about ownership, and also where deleting breaks
    # something in front of the operator.
    $live = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $path = ''
        try { $path = [string]$p.Path } catch { }
        if ($path) { $live[(Split-Path -Parent $path).ToLowerInvariant()] = $p.ProcessName }
    }

    $gone = New-Object System.Collections.Generic.List[string]
    $kept = New-Object System.Collections.Generic.List[string]

    foreach ($h in $hits) {
        if ($h.Kind -eq 'folder') {
            $low = ([string]$h.Path).ToLowerInvariant()
            $busy = @($live.Keys | Where-Object { $_ -eq $low -or $_.StartsWith("$low\") }) | Select-Object -First 1
            if ($busy) {
                $kept.Add("$($h.Path) (left alone: $($live[$busy]) is running from it)")
                continue
            }
            Write-WDLog "Leftover from $($h.Program): $($h.Path) - $($h.Why). Sending it to the Recycle Bin." -Level Info -Item $Context.ItemId
            if (-not (Test-WDRecycleAvailable -Path $h.Path)) {
                $kept.Add("$($h.Path) (no Recycle Bin on that volume)")
                continue
            }
            if (Remove-WDToRecycleBin -Path $h.Path) {
                $gone.Add($h.Path)
                Add-WDJournal -ItemId $Context.ItemId -Type 'file' -Target $h.Path -Status 'Removed' `
                              -Undo @{ method = 'recycle'; path = $h.Path }
            } else {
                $kept.Add("$($h.Path) (in use or locked)")
            }
            continue
        }

        # Get-ChildItem hands back the provider-qualified name; the cmdlets that
        # act on it want a PSDrive path.
        $key = ([string]$h.Path) -replace '^HKEY_CURRENT_USER', 'HKCU:' -replace '^HKEY_LOCAL_MACHINE', 'HKLM:'
        if (-not (Test-Path -LiteralPath $key)) { continue }
        Write-WDLog "Leftover from $($h.Program): $key - $($h.Why). Exporting it and deleting it." -Level Info -Item $Context.ItemId
        try {
            $backup = Backup-WDRegistryKey -Path $key
            Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
            $gone.Add($key)
            Add-WDJournal -ItemId $Context.ItemId -Type 'registry-key' -Target $key -Status 'Removed' `
                          -Undo @{ method = 'regfile'; file = $backup }
        } catch {
            $kept.Add("$key ($($_.Exception.Message))")
        }
    }

    if ($gone.Count -and -not $kept.Count) {
        return New-WDResult -Status Removed -Message "$($gone.Count) leftover(s) cleared" -Detail ($gone -join '; ')
    }
    if ($gone.Count) {
        return New-WDResult -Status Partial -Message "$($gone.Count) cleared, $($kept.Count) left in place" `
                            -Detail (($kept -join '; ') + ' | Cleared: ' + ($gone -join '; '))
    }
    New-WDResult -Status Blocked -Message 'The leftovers could not be cleared' -Detail ($kept -join '; ')
}

function Use-WDPowrProf {
    # The power-management API itself rather than powercfg's text. Compiled by
    # its first caller, like WDPriv and WDDisk: every Add-Type is a csc run, and
    # nothing on the launch path reads a power setting.
    #
    # It replaced parsing "powercfg /query", which was wrong three ways at once:
    # /query omits every setting Windows marks hidden (the network-in-standby
    # one is hidden by default everywhere, so that option found "nothing" and
    # never wrote anything); the parse matched the English labels, so on any
    # other display language every power option did nothing; and it could only
    # see the active plan.
    if ('WDPowrProf' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WDPowrProf {
    [DllImport("powrprof.dll")] static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr scheme);
    [DllImport("powrprof.dll")] static extern uint PowerSetActiveScheme(IntPtr root, ref Guid scheme);
    [DllImport("powrprof.dll")] static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid setting, out uint value);
    [DllImport("powrprof.dll")] static extern uint PowerReadDCValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid setting, out uint value);
    [DllImport("powrprof.dll")] static extern uint PowerWriteACValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid setting, uint value);
    [DllImport("powrprof.dll")] static extern uint PowerWriteDCValueIndex(IntPtr root, ref Guid scheme, ref Guid sub, ref Guid setting, uint value);
    [DllImport("powrprof.dll")] static extern uint PowerEnumerate(IntPtr root, IntPtr scheme, IntPtr sub, uint flags, uint index, byte[] buffer, ref uint size);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr mem);

    public static Guid Active() {
        IntPtr p;
        uint r = PowerGetActiveScheme(IntPtr.Zero, out p);
        if (r != 0) { throw new System.ComponentModel.Win32Exception((int)r); }
        try { return (Guid)Marshal.PtrToStructure(p, typeof(Guid)); } finally { LocalFree(p); }
    }
    // Every plan on the machine. 16 is ACCESS_SCHEME; the walk ends on
    // ERROR_NO_MORE_ITEMS.
    public static Guid[] Schemes() {
        var list = new System.Collections.Generic.List<Guid>();
        for (uint i = 0; i < 256; i++) {
            byte[] buf = new byte[16];
            uint size = 16;
            if (PowerEnumerate(IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 16, i, buf, ref size) != 0) { break; }
            list.Add(new Guid(buf));
        }
        return list.ToArray();
    }
    // -1 when the setting does not exist on this machine.
    public static long Read(Guid scheme, Guid sub, Guid setting, bool ac) {
        uint v = 0;
        uint r = ac ? PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref sub, ref setting, out v)
                    : PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref sub, ref setting, out v);
        if (r != 0) { return -1; }
        return v;
    }
    public static uint Write(Guid scheme, Guid sub, Guid setting, bool ac, uint value) {
        return ac ? PowerWriteACValueIndex(IntPtr.Zero, ref scheme, ref sub, ref setting, value)
                  : PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref sub, ref setting, value);
    }
    public static uint Apply(Guid scheme) { return PowerSetActiveScheme(IntPtr.Zero, ref scheme); }
}
'@
}

$script:PowerAliases = $null

function Resolve-WDPowerGuid {
    # A GUID as itself, an alias through "powercfg /aliases" - whose output is
    # GUIDs and fixed identifiers only, the same in every display language.
    param([string]$Name)
    $g = [guid]::Empty
    if ([guid]::TryParse($Name, [ref]$g)) { return $g }
    if ($null -eq $script:PowerAliases) {
        $script:PowerAliases = @{}
        try {
            foreach ($l in @(& "$env:SystemRoot\System32\powercfg.exe" /aliases 2>$null)) {
                if ([string]$l -match '^\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+(\S+)\s*$') {
                    $script:PowerAliases[$Matches[2]] = [guid]$Matches[1]
                }
            }
        } catch { }
    }
    if ($script:PowerAliases.ContainsKey($Name)) { return $script:PowerAliases[$Name] }
    $null
}

function Get-WDPowerSchemeNames {
    # Display only, so the localized names powercfg prints are exactly right.
    $names = @{}
    try {
        foreach ($l in @(& "$env:SystemRoot\System32\powercfg.exe" /list 2>$null)) {
            if ([string]$l -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\(([^)]+)\)') {
                $names[$Matches[1].ToLower()] = $Matches[2]
            }
        }
    } catch { }
    $names
}

function Get-WDPowerSettingRows {
    # One row per plan that has the setting: the plan, and its mains and
    # battery values. Empty when no plan on this machine has it.
    param([guid]$Sub, [guid]$Setting)
    Use-WDPowrProf
    $rows = New-Object System.Collections.Generic.List[psobject]
    foreach ($s in [WDPowrProf]::Schemes()) {
        $ac = [WDPowrProf]::Read($s, $Sub, $Setting, $true)
        $dc = [WDPowrProf]::Read($s, $Sub, $Setting, $false)
        if ($ac -lt 0 -and $dc -lt 0) { continue }
        $rows.Add([pscustomobject]@{ Scheme = $s; Ac = $ac; Dc = $dc })
    }
    ,$rows.ToArray()
}

Register-WDHandler 'SetPowerScheme' {
    # Every power plan on the machine, not only the active one: a setting that
    # comes undone the moment somebody picks another plan in Control Panel is
    # not the setting the row promised.
    param($Action, $Context)

    $subName = [string](Get-Prop $Action 'sub' '')
    $setName = [string](Get-Prop $Action 'setting' '')
    if (-not $subName -or -not $setName) {
        return New-WDResult -Status Failed -Message 'Power setting not specified' `
                            -Detail 'The action needs both a "sub" and a "setting".'
    }
    $sub = Resolve-WDPowerGuid $subName
    $set = Resolve-WDPowerGuid $setName
    if (-not $sub -or -not $set) {
        return New-WDResult -Status Failed -Message 'Unknown power setting name' `
                            -Detail "powercfg has no alias '$(if (-not $sub) { $subName } else { $setName })' on this machine."
    }
    $want = [uint32](Get-Prop $Action 'value' 0)

    $rows = @()
    try {
        # Assigned, never wrapped: the function ends in ,@(...).
        $rows = Get-WDPowerSettingRows -Sub $sub -Setting $set
    } catch {
        return New-WDResult -Status Failed -Message 'Could not read the power plans' -Detail (Format-WDException $_)
    }
    if (-not @($rows).Count) {
        return New-WDResult -Status NotPresent -Message 'This power setting is not on this machine' `
                            -Detail "No power plan here has $subName / $setName, which is normal on hardware that does not implement it."
    }

    $names  = Get-WDPowerSchemeNames
    $label  = { param($g) $k = ([string]$g).ToLower(); if ($names.ContainsKey($k)) { $names[$k] } else { $k } }
    $todo   = @($rows | Where-Object { ($_.Ac -ge 0 -and $_.Ac -ne $want) -or ($_.Dc -ge 0 -and $_.Dc -ne $want) })
    if (-not $todo.Count) {
        return New-WDResult -Status AlreadySet -Message "Already $want in every power plan" `
                            -Detail ((@($rows | ForEach-Object { & $label $_.Scheme }) -join ', ') + ' already hold it on mains and battery.')
    }
    $was = @($todo | ForEach-Object { "$(& $label $_.Scheme): mains $($_.Ac), battery $($_.Dc)" })
    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message "Would set it to $want in $($todo.Count) power plan(s)" `
                            -Detail ('Currently ' + ($was -join '; ') + '.')
    }

    $active = $null
    try { $active = [WDPowrProf]::Active() } catch { }
    $done   = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($r in $todo) {
        $name = & $label $r.Scheme
        $errAc = $(if ($r.Ac -ge 0) { [WDPowrProf]::Write($r.Scheme, $sub, $set, $true,  $want) } else { 0 })
        $errDc = $(if ($r.Dc -ge 0) { [WDPowrProf]::Write($r.Scheme, $sub, $set, $false, $want) } else { 0 })
        # Read back rather than trusting the return codes - a value a policy
        # owns can be accepted and not held.
        $nowAc = [WDPowrProf]::Read($r.Scheme, $sub, $set, $true)
        $nowDc = [WDPowrProf]::Read($r.Scheme, $sub, $set, $false)
        $okAc  = ($r.Ac -lt 0) -or ($nowAc -eq $want)
        $okDc  = ($r.Dc -lt 0) -or ($nowDc -eq $want)
        if ($okAc -or $okDc) {
            # The plan's own previous values, so undoing the run puts back the
            # numbers somebody had tuned rather than Microsoft's defaults - into
            # that plan, which is why the scheme is recorded.
            Add-WDJournal -ItemId $Context.ItemId -Type 'power' -Target "$($r.Scheme)\$sub\$set" -Status 'Changed' `
                          -Undo @{ method = 'powercfg'; scheme = ([string]$r.Scheme); sub = ([string]$sub); setting = ([string]$set)
                                   ac = $(if ($r.Ac -ge 0) { [int]$r.Ac } else { [int]$r.Dc })
                                   dc = $(if ($r.Dc -ge 0) { [int]$r.Dc } else { [int]$r.Ac }) }
        }
        if ($okAc -and $okDc) { $done.Add($name) }
        elseif ($errAc -eq 5 -or $errDc -eq 5) { $failed.Add("$name (needs administrator rights)") }
        else { $failed.Add("$name (Windows answered $errAc / $errDc and now holds mains $nowAc, battery $nowDc)") }
    }
    # A plan holds new numbers and the machine goes on behaving the old way
    # until the active one is applied again.
    if ($null -ne $active) { $null = [WDPowrProf]::Apply($active) }

    if ($failed.Count -and -not $done.Count) {
        return New-WDResult -Status Blocked -Message 'Windows did not keep the change' -Detail ($failed -join '; ')
    }
    if ($failed.Count) {
        return New-WDResult -Status Partial -Message "Set in $($done.Count) power plan(s), refused in $($failed.Count)" `
                            -Detail ("Set: $($done -join ', '). Refused: $($failed -join '; ')")
    }
    New-WDResult -Status Changed -Message "Set to $want in $($done.Count) power plan(s)" `
                 -Detail ('Was ' + ($was -join '; ') + '.')
}

Register-WDHandler 'SetTaskbarAutoHide' {
    # Auto-hide is one bit inside a blob, not a value: StuckRects3\Settings byte
    # 8, bit 0x01. The blob is 40 bytes on older builds and 48 on newer, and the
    # flag byte has not moved.
    param($Action, $Context)

    $rel  = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
    $done = New-Object System.Collections.Generic.List[string]
    $miss = 0

    # Per-user like any allusers registry action, so it honours the same choice.
    $roots = @(Select-WDAccountHives -Hives (Get-WDUserHives) -Default $Context.DefaultHive `
                                     -Accounts (Get-WDContextAccounts $Context))
    foreach ($root in $roots) {
        $path = Join-Path $root.Path $rel
        if (-not (Test-Path -LiteralPath $path)) { $miss++; continue }
        $cur = Get-ItemProperty -LiteralPath $path -Name 'Settings' -ErrorAction SilentlyContinue
        if (-not $cur -or -not $cur.Settings) { $miss++; continue }

        $bytes = [byte[]]$cur.Settings
        if ($bytes.Length -lt 9) { $miss++; continue }
        if (($bytes[8] -band 0x01) -eq 0x01) { $done.Add("$($root.Name) already hidden"); continue }
        if ($Context.Preview) { $done.Add("$($root.Name) would auto-hide"); continue }

        Backup-WDRegistryKey -Path $path
        # A copy of the real bytes. This used to record the text "@(48,0,4,...)"
        # because the emitter interpolated the previous value unquoted.
        $was = [byte[]]::new($bytes.Length)
        [Array]::Copy($bytes, $was, $bytes.Length)
        $bytes[8] = [byte]($bytes[8] -bor 0x01)
        try {
            Set-ItemProperty -LiteralPath $path -Name 'Settings' -Value $bytes -Type Binary -Force -ErrorAction Stop
            $done.Add($root.Name)
            Add-WDJournal -ItemId $Context.ItemId -Type 'registry' -Target "$path\Settings" -Status 'Changed' `
                          -Undo @{ method = 'registry'; path = $path; name = 'Settings'; kind = 'Binary'; previous = $was; raw = $true }
        } catch {
            return New-WDResult -Status Blocked -Message 'Could not write the taskbar layout' -Detail $_.Exception.Message
        }
    }

    if (-not $done.Count) {
        return New-WDResult -Status NotPresent -Message 'No taskbar layout to change' `
                            -Detail "$miss hive(s) had no StuckRects3 entry yet - Explorer writes it on first sign-in."
    }
    New-WDResult -Status Changed -Message "Taskbar set to auto-hide for $($done.Count) user(s)" `
                 -Detail (($done -join ', ') + '. Takes effect when Explorer restarts.')
}

Register-WDHandler 'CleanComponentStore' {
    # The component store and nothing else. It also used to hard-delete both
    # temp folders first, which the row it was attached to never mentioned and
    # which "Temporary files" already does properly, with its own text.
    param($Action, $Context)

    # DISM refuses with 0x800f0806 while servicing is pending, and removing a
    # Windows feature earlier in the same run makes it pending - so ticking both
    # made a refusal the expected outcome. Said plainly instead.
    if (Test-WDServicingPending) {
        return New-WDResult -Status Skipped -Message 'Run this again after restarting' `
                            -Detail 'Windows servicing is waiting on a restart (often from a feature this run removed), and the component store cannot be cleaned up until it has finished.'
    }
    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message 'Would compact the component store' `
                            -Detail 'Typically several gigabytes. Takes several minutes, and updates installed before it can no longer be uninstalled afterwards.'
    }

    $before = 0
    try { $before = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'").FreeSpace } catch { }

    $dism = Invoke-WDProcess -FilePath "$env:SystemRoot\System32\Dism.exe" `
                             -ArgumentList @('/Online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase', '/Quiet', '/NoRestart') `
                             -TimeoutSeconds 2400
    if ($dism.TimedOut) {
        return New-WDResult -Status Failed -Message 'The cleanup did not finish in 40 minutes' `
                            -Detail 'DISM was stopped. Nothing is damaged by that; run it again later.'
    }
    if ($dism.ExitCode -notin @(0, 3010)) {
        return New-WDResult -Status Blocked -Message 'Windows refused the component store cleanup' `
                            -Detail "DISM exit $($dism.ExitCode). This usually means a servicing operation is pending - run it again after a restart."
    }
    if ($dism.ExitCode -eq 3010) { Set-WDRebootNeeded }

    $freed = 0
    try {
        $after = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'").FreeSpace
        $freed = [Math]::Round((([double]$after - [double]$before)) / 1GB, 2)
    } catch { }

    $msg = if ($freed -gt 0) { "About $freed GB reclaimed" } else { 'Component store compacted' }
    New-WDResult -Status Removed -Message $msg -Detail 'Superseded component versions removed with DISM /StartComponentCleanup /ResetBase.'
}

Register-WDHandler 'EnableIrreversibleMode' {
    param($Action, $Context)

    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message 'Would delete outright and empty the Recycle Bin at the end' `
                            -Detail 'Every other item in this run loses its undo. The Recycle Bin is emptied completely, including anything already in it.'
    }
    Set-WDIrreversible
    Write-WDLog 'Irreversible mode on: deletions are permanent and the Recycle Bin is emptied at the end.' -Level Warn -Item $Context.ItemId
    New-WDResult -Status Changed -Message 'Deletions this run are permanent' `
                 -Detail 'The Recycle Bin is emptied when the run finishes.'
}

Register-WDHandler 'RestartExplorer' {
    param($Action, $Context)
    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message 'Would restart Explorer so shell changes take effect now' `
                            -Detail 'Open File Explorer windows close. Nothing else about the desktop changes, and this runs last.'
    }
    # This session's shell, not every session's. Get-Process answers for the
    # whole machine from an elevated process, so Stop-Process -Name explorer
    # took down the desktop of anybody else signed in.
    $mySession = 0
    try { $mySession = [Diagnostics.Process]::GetCurrentProcess().SessionId } catch { }
    $shells = { @(Get-Process -Name explorer -ErrorAction SilentlyContinue |
                  Where-Object { $_.SessionId -eq $mySession }) }
    $mine = & $shells
    if (-not $mine.Count) {
        return New-WDResult -Status NotPresent -Message 'Explorer was not running'
    }
    Write-WDLog 'Restarting Explorer so the shell picks up this run''s changes.' -Level Info -Item $Context.ItemId
    try {
        foreach ($p in $mine) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 1200
        # Windows restarts the shell itself on most machines (AutoRestartShell),
        # so this is normally already back.
        $back = & $shells
        if (-not $back.Count) {
            Start-Process explorer.exe -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 1500
            $back = & $shells
        }
        # Asked, not assumed: Start-Process with -ErrorAction SilentlyContinue
        # throws nothing when it fails, so success was reported over an empty
        # desktop.
        if (-not $back.Count) {
            return New-WDResult -Status Blocked -Message 'Explorer did not come back' `
                                -Detail ('The shell was closed so this run''s changes would take effect, and it ' +
                                         'did not restart. Press ctrl+shift+esc for Task Manager, then File > Run ' +
                                         'new task > explorer.exe - or sign out and back in, which also works.')
        }
        New-WDResult -Status Changed -Message 'Explorer restarted, so shell changes are live now' `
                     -Detail 'Anything this run wrote to the taskbar, the context menus, or File Explorer is in effect without signing out.'
    } catch {
        New-WDResult -Status Blocked -Message 'Could not restart Explorer' -Detail 'Sign out and back in to apply shell changes.'
    }
}

Register-WDHandler 'ClearStaleShortcuts' {
    param($Action, $Context)

    $dirs = @(
        [Environment]::GetFolderPath('CommonStartMenu'),
        [Environment]::GetFolderPath('StartMenu'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:PUBLIC 'Desktop')
    )
    # Every account's Start menu and desktop, not only the one running this: a
    # removal is machine-wide, and a shortcut left in another profile is the
    # same broken entry for whoever signs in next.
    try {
        foreach ($u in (Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction Stop)) {
            $dirs += (Join-Path $u.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu')
            $dirs += (Join-Path $u.FullName 'Desktop')
        }
    } catch { }
    $dirs = @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique)

    # Where programs live. A dead target under one of these is a removed
    # program; a dead target anywhere else is a file that happens not to be
    # there today.
    $programRoots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'),
        $env:windir
    )
    try {
        foreach ($u in (Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction Stop)) {
            $programRoots += (Join-Path $u.FullName 'AppData\Local\Programs')
        }
    } catch { }
    $programRoots = @($programRoots | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('\') + '\' } | Sort-Object -Unique)

    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell -ErrorAction Stop }
    catch {
        return New-WDResult -Status Blocked -Message 'Could not read shortcut targets' `
                            -Detail 'WScript.Shell is unavailable, so no shortcut could be resolved. Nothing was removed.'
    }

    $stale  = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $seen   = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($d in $dirs) {
        $hits = @()
        try {
            $hits = @(Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue |
                      Where-Object { $_.Extension -eq '.lnk' })
        } catch { continue }

        foreach ($h in $hits) {
            if (-not $seen.Add($h.FullName)) { continue }
            $target = ''
            try { $target = [string]$shell.CreateShortcut($h.FullName).TargetPath } catch { continue }
            if (-not $target) { continue }
            if ($target -notmatch '^[A-Za-z]:\\') { continue }
            $underProgram = $false
            foreach ($root in $programRoots) {
                if ($target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $underProgram = $true; break }
            }
            if (-not $underProgram) { continue }
            try { if (Test-Path -LiteralPath $target) { continue } } catch { continue }

            if ($Context.Preview) { $stale.Add($h.BaseName); continue }
            try {
                if (Test-WDIrreversible) {
                    Remove-Item -LiteralPath $h.FullName -Force -ErrorAction Stop
                } else {
                    # The bin, or parked in the run folder when this runs as
                    # SYSTEM - see Remove-WDFileUndoable.
                    $why = Remove-WDFileUndoable -Path $h.FullName -ItemId $Context.ItemId
                    if ($why) {
                        $errors.Add("$($h.FullName) : $why")
                        continue
                    }
                }
                Write-WDLog "Removed a Start menu or desktop shortcut pointing at '$target', which is gone." `
                            -Level Info -Item $Context.ItemId
                $stale.Add($h.BaseName)
            } catch {
                $errors.Add("$($h.FullName) : $($_.Exception.Message)")
            }
        }
    }

    try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { }

    $names = (($stale | Sort-Object -Unique) -join ', ')
    if ($Context.Preview) {
        if (-not $stale.Count) { return New-WDResult -Status NotPresent -Message 'No shortcuts point at anything missing' }
        return New-WDResult -Status Removed -Message "$($stale.Count) dead shortcut(s) would go" -Detail $names
    }
    if ($stale.Count -and $errors.Count) {
        return New-WDResult -Status Partial -Message "$($stale.Count) removed, $($errors.Count) left in place" `
                            -Detail ($names + ' | ' + ($errors -join '; '))
    }
    if ($stale.Count) { return New-WDResult -Status Removed -Message "$($stale.Count) dead shortcut(s)" -Detail $names }
    if ($errors.Count) { return New-WDResult -Status Blocked -Message 'Dead shortcuts could not be removed' -Detail ($errors -join '; ') }
    New-WDResult -Status NotPresent -Message 'No shortcuts point at anything missing'
}

# Tools that keep hardware working. The single place that decides what
# "load-bearing" means.
$script:PreservedVendorTools = @{
    hp      = @('HP Power Manager','HP Hotkey','HP Firmware','HP Thermal','HP System Event Utility','HP Programmable Key')
    dell    = @('Dell Power Manager','Dell Command | Update','Dell Optimizer','Dell Thermal')
    lenovo  = @('Lenovo Vantage','Lenovo Commercial Vantage','Lenovo System Interface','Lenovo Utility','Lenovo Hotkey')
    asus    = @('Armoury Crate','ASUS System Control Interface','MyASUS Service')
    acer    = @('Acer Quick Access','NitroSense','PredatorSense')
    msi     = @('MSI Center','Dragon Center')
    samsung = @('Samsung Settings')
    razer   = @('Razer Synapse')
}

Register-WDHandler 'ReportVendorProfile' {
    param($Action, $Context)
    $p = $Context.Profile
    $msg = "Detected $($p.Manufacturer) ($($p.Vendor) profile)"
    $detail = "$($p.Model), $(if ($p.IsPortable) { 'laptop' } else { 'desktop' })"
    if ($p.Vendor -eq 'generic') {
        $detail += '. No vendor-specific profile matched, so only the cross-vendor rules will run.'
    }
    # Reads the SMBIOS strings and says what it found. Its own handler note ends
    # "Changes nothing", and it reported Changed anyway.
    New-WDResult -Status AlreadySet -Message $msg -Detail $detail
}

Register-WDHandler 'ReportPreservedVendorTools' {
    param($Action, $Context)

    $vendor = $Context.Profile.Vendor
    if (-not $script:PreservedVendorTools.ContainsKey($vendor)) {
        return New-WDResult -Status NotPresent -Message 'No vendor-specific hardware tools to preserve'
    }

    $patterns = $script:PreservedVendorTools[$vendor]
    $present  = New-Object System.Collections.Generic.List[string]
    foreach ($prog in (Get-WDInstalledPrograms)) {
        foreach ($pat in $patterns) {
            if ($prog.DisplayName -like "$pat*") { $present.Add($prog.DisplayName); break }
        }
    }

    if (-not $present.Count) { return New-WDResult -Status NotPresent -Message 'None of the preserved tools are installed' }
    # What was deliberately not touched. Reporting that as a change is the
    # opposite of what the row says.
    New-WDResult -Status AlreadySet -Message "$($present.Count) hardware tool(s) preserved" `
                 -Detail ((($present | Sort-Object -Unique) -join ', ') + ' - kept because they control power, thermals or firmware. Remove manually if you do not want them.')
}

Register-WDHandler 'SetPowerPlan' {
    # Laptops keep Balanced: High performance pins clocks and costs battery life
    # for no real gain on portable hardware. Desktops get High performance.
    #
    # A plan is found by its PERSONALITY, the value every plan carries saying
    # which of the three kinds it is (0 power saver, 1 high performance, 2
    # balanced) - not by the built-in GUID, because OEM images ship their own
    # copies under new ones (this Lenovo's High performance is f4326b59..., and
    # 8c5e7fda... is not in its list at all, so the old fixed GUID failed on
    # exactly the machines most likely to want it). And not by name, which is
    # localized.
    param($Action, $Context)

    $portable = [bool]$Context.Profile.IsPortable
    $want     = $(if ($portable) { 2 } else { 1 })
    $builtIn  = $(if ($portable) { [guid]'381b4222-f694-41f0-9685-ff5bb260df2e' } else { [guid]'8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' })
    $kind     = $(if ($portable) { 'Balanced' } else { 'High performance' })
    $subNone  = [guid]'fea3413e-7e05-4911-9a71-700331f1c294'
    $persona  = [guid]'245d8541-3943-4422-b025-13a784f679b7'

    try { Use-WDPowrProf } catch {
        return New-WDResult -Status Failed -Message 'Could not read the power plans' -Detail (Format-WDException $_)
    }
    $names   = Get-WDPowerSchemeNames
    $nameOf  = { param($g) $k = ([string]$g).ToLower(); if ($names.ContainsKey($k)) { $names[$k] } else { $k } }
    $active  = $null
    try { $active = [WDPowrProf]::Active() } catch { }
    if ($null -ne $active -and [WDPowrProf]::Read($active, $subNone, $persona, $true) -eq $want) {
        return New-WDResult -Status AlreadySet -Message "Already on a $kind plan" -Detail "$(& $nameOf $active) is active."
    }

    $schemes = @([WDPowrProf]::Schemes())
    $target  = $null
    if ($schemes -contains $builtIn) { $target = $builtIn }
    if ($null -eq $target) {
        $target = @($schemes | Where-Object { [WDPowrProf]::Read($_, $subNone, $persona, $true) -eq $want }) | Select-Object -First 1
    }
    if ($Context.Preview) {
        if ($null -eq $target) {
            return New-WDResult -Status Changed -Message "Would add a $kind plan and switch to it" `
                                -Detail "This machine has no $kind plan, so one would be copied from Windows' own template."
        }
        return New-WDResult -Status Changed -Message "Would switch to $(& $nameOf $target)" -Detail "From $(& $nameOf $active)."
    }

    $created = ''
    if ($null -eq $target) {
        # Windows' own template, copied: it exists on every build even when the
        # plan list does not show it.
        $dup = Invoke-WDProcess -FilePath "$env:SystemRoot\System32\powercfg.exe" -ArgumentList @('/duplicatescheme', $builtIn) -TimeoutSeconds 60
        if ($dup.ExitCode -ne 0 -or [string]$dup.Output -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            return New-WDResult -Status Blocked -Message "Could not add a $kind plan" -Detail "powercfg exit $($dup.ExitCode). Some OEM images lock the plan list."
        }
        $target  = [guid]$Matches[1]
        $created = ([string]$target).ToLower()
        $names   = Get-WDPowerSchemeNames
    }

    $r = Invoke-WDProcess -FilePath "$env:SystemRoot\System32\powercfg.exe" -ArgumentList @('/setactive', $target) -TimeoutSeconds 60
    $now = $null
    try { $now = [WDPowrProf]::Active() } catch { }
    if ($r.ExitCode -ne 0 -or $now -ne $target) {
        return New-WDResult -Status Blocked -Message 'Could not set the power plan' `
                            -Detail "powercfg exit $($r.ExitCode). Some OEM images lock the plan list."
    }
    # The plan that was active, and the one this added if it added one - so the
    # undo switches back and takes the copy away again.
    Add-WDJournal -ItemId $Context.ItemId -Type 'power' -Target 'active power plan' -Status 'Changed' `
                  -Undo @{ method = 'power-scheme'; previous = $(if ($active) { ([string]$active).ToLower() } else { '381b4222-f694-41f0-9685-ff5bb260df2e' })
                           label = $(if ($active) { [string](& $nameOf $active) } else { 'Balanced' }); created = $created }
    $how = $(if ($created) { ' (added from Windows'' own template)' } else { '' })
    New-WDResult -Status Changed -Message "Power plan set to $(& $nameOf $target)$how" -Detail "Was $(& $nameOf $active)."
}

function Get-WDHibernateState {
    # $true on, $false off, $null unreadable. HibernateEnabled is absent until
    # something has switched it, and absent means the machine's default - which
    # HibernateEnabledDefault records. Reading only the first called every
    # untouched machine "not off", which happened to be right only where the
    # default is on.
    try {
        $pw = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop
        if ($pw.PSObject.Properties['HibernateEnabled'])        { return ([int]$pw.HibernateEnabled -ne 0) }
        if ($pw.PSObject.Properties['HibernateEnabledDefault']) { return ([int]$pw.HibernateEnabledDefault -ne 0) }
    } catch { }
    $null
}

Register-WDHandler 'DisableHibernation' {
    param($Action, $Context)
    if ($Context.Profile.HasBattery) {
        return New-WDResult -Status Skipped -Message 'Skipped on battery-powered hardware' -Detail 'Disabling hibernation on a laptop loses sleep-to-disk and hybrid sleep.'
    }
    $on = Get-WDHibernateState
    if ($on -eq $false) {
        return New-WDResult -Status AlreadySet -Message 'Hibernation is already off'
    }
    if ($Context.Preview) { return New-WDResult -Status Changed -Message 'Would disable hibernation and delete hiberfil.sys' -Detail 'Fast startup and hybrid sleep go with it.' }

    $r = Invoke-WDProcess -FilePath "$env:SystemRoot\System32\powercfg.exe" -ArgumentList @('/hibernate', 'off') -TimeoutSeconds 60
    if ($r.ExitCode -eq 0 -and (Get-WDHibernateState) -eq $false) {
        # It was journalled nowhere, so neither the rollback script nor the
        # Revert page could turn it back on while both said "partially".
        Add-WDJournal -ItemId $Context.ItemId -Type 'power' -Target 'hibernation' -Status 'Changed' `
                      -Undo @{ method = 'hibernate'; previous = 'on' }
        return New-WDResult -Status Changed -Message 'Hibernation disabled, hiberfil.sys reclaimed' -Detail 'Fast startup and hybrid sleep went with it.'
    }
    New-WDResult -Status Blocked -Message 'Could not disable hibernation' -Detail "powercfg exit $($r.ExitCode)"
}

Register-WDHandler 'DisableReservedStorage' {
    param($Action, $Context)
    try {
        $state = Get-WindowsReservedStorageState -ErrorAction Stop
        if ($state.ReservedStorageState -eq 'Disabled') {
            return New-WDResult -Status AlreadySet -Message 'Reserved storage is already disabled'
        }
        # Microsoft: "If reserved storage is in use, it may not be disabled ...
        # wait for any servicing operations to complete". Removing a Windows
        # feature earlier in the same run is one, so this is said plainly
        # rather than reported as a refusal nobody can read.
        if (Test-WDServicingPending) {
            return New-WDResult -Status Skipped -Message 'Run this again after restarting' `
                                -Detail 'Windows servicing is waiting on a restart (often from a feature this run removed), and Reserved Storage cannot be changed until it has finished.'
        }
        if ($Context.Preview) { return New-WDResult -Status Changed -Message 'Would disable reserved storage (~7 GB)' }

        Set-WindowsReservedStorageState -State Disabled -ErrorAction Stop
        Add-WDJournal -ItemId $Context.ItemId -Type 'storage' -Target 'reserved storage' -Status 'Changed' `
                      -Undo @{ method = 'reserved-storage'; previous = 'Enabled' }
        New-WDResult -Status Changed -Message 'Reserved storage disabled' -Detail 'Feature updates may now need free space staged manually.'
    } catch {
        # Windows refuses while an update is pending; that is expected, not a
        # failure.
        New-WDResult -Status Blocked -Message 'Reserved storage could not be changed' `
                     -Detail "$($_.Exception.Message) - usually means a Windows update is pending. Retry after a reboot."
    }
}

# Per-user JSON under %LOCALAPPDATA%\Microsoft\PowerToys: one settings.json with
# an enabled map keyed by module display name, and one per module holding its
# own properties. PowerToys writes defaults for anything absent, which is what
# makes writing these before it is installed work.

function Get-WDPowerToysRoot { Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys' }

function Write-WDJsonNoBom {
    # PowerToys reads its settings through Windows.Data.Json, which refuses a
    # byte order mark ("Invalid JSON string", 0x83750007) - and Set-Content
    # -Encoding UTF8 on PowerShell 5.1 always writes one. PowerToys then treats
    # the file as empty and starts from defaults, so every option written here
    # did nothing, while the toolkit's own check (PowerShell, which accepts a
    # BOM) read it back and said it had worked.
    param([string]$Path, $Object, [int]$Depth = 20)
    $text = $Object | ConvertTo-Json -Depth $Depth
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding $false))
}

function Test-WDFileHasBom {
    param([string]$Path)
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $b = New-Object byte[] 3
            $n = $fs.Read($b, 0, 3)
            ($n -eq 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        } finally { $fs.Dispose() }
    } catch { $false }
}

function Get-WDBackupPath {
    # One copy per run and per option. Every PowerToys option used to back up
    # to the same settings.json.wdbak, so the second option overwrote the first
    # option's copy of the original, and the rollback - which keeps the first
    # entry for a file - restored the state after the first option instead.
    param([string]$Path, $Context)
    $run = ''
    try { $run = [string]$Context.Session.Id } catch { }
    if (-not $run) { $run = (Get-Date).ToString('yyyyMMdd-HHmmss') }
    $item = ([string]$Context.ItemId) -replace '[^A-Za-z0-9\-]', '_'
    "$Path.$run.$item.wdbak"
}

function Set-WDPowerToysJson {
    param([string]$Path, [scriptblock]$Edit, $Context, [pscustomobject]$Seed)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

    $existed = Test-Path -LiteralPath $Path
    $json = $null
    $bak  = $null
    if ($existed) {
        $bak = Get-WDBackupPath -Path $Path -Context $Context
        Copy-Item -LiteralPath $Path -Destination $bak -Force -ErrorAction SilentlyContinue
        try { $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { $json = $null }
        if (-not $json) { throw "PowerToys config at $Path is not readable JSON - left untouched" }
    } else {
        $json = $Seed
    }

    & $Edit $json
    Write-WDJsonNoBom -Path $Path -Object $json -Depth 20
    Add-WDJournal -ItemId $Context.ItemId -Type 'powertoys' -Target $Path -Status 'Changed' `
                  -Undo @{ method = 'file-restore'; file = $bak; target = $Path }
}

# Compiled by Test-WDDiskNative on first use, not at import: it is a csc
# invocation, and the first thing to want it has a runspace of its own.
$script:WDDiskSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class WDDisk {
    // Set from the UI thread when the window closes. A whole-drive walk can
    // outlive the window that asked for it, and a runspace will not tear down
    // while a call into managed code is still running.
    //
    // Honoured only by callers that ask for it. A global flag that every
    // measurement obeyed would mean one closed window quietly turning every
    // later size in the process into a zero - and a zero here is not an error,
    // it is "nothing to free".
    public static volatile bool Stop = false;

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct SHQUERYRBINFO { public int cbSize; public long i64Size; public long i64NumItems; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHQueryRecycleBin(string pszRootPath, ref SHQUERYRBINFO info);

    // Bytes and item count without walking anything - the shell keeps a
    // running total. A null root asks about every drive at once.
    public static long[] RecycleBin(string root) {
        SHQUERYRBINFO info = new SHQUERYRBINFO();
        info.cbSize = Marshal.SizeOf(typeof(SHQUERYRBINFO));
        int rc = SHQueryRecycleBin(root, ref info);
        if (rc != 0) { return new long[] { -1, 0 }; }
        return new long[] { info.i64Size, info.i64NumItems };
    }

    // Returns { bytes, files, unreadable directories, stopped }.
    //
    // Reparse points are skipped rather than followed, and that is the whole
    // reason this is not a Get-ChildItem -Recurse: C:\Users\All Users is a
    // junction to C:\ProgramData and C:\Documents and Settings is a junction to
    // C:\Users, so following them counts the same bytes twice and can loop.
    //
    // A directory that refuses to be read is counted and skipped. Best effort
    // is the only available effort here: WindowsApps refuses administrators by
    // ACL, and the answer to that is to say so, not to seize it for a picture.
    public static long[] Size(string root) { return Size(root, false); }

    public static long[] Size(string root, bool cancellable) {
        long bytes = 0, files = 0, denied = 0;
        if (String.IsNullOrEmpty(root) || !Directory.Exists(root)) {
            return new long[] { 0, 0, 0, 0 };
        }
        Stack<string> stack = new Stack<string>();
        stack.Push(root);
        while (stack.Count > 0) {
            if (cancellable && Stop) { return new long[] { bytes, files, denied, 1 }; }
            DirectoryInfo dir = new DirectoryInfo(stack.Pop());
            try {
                // FileInfo from an enumeration carries the find data with it,
                // so Length and Attributes cost no extra call.
                foreach (FileInfo f in dir.EnumerateFiles()) {
                    if ((f.Attributes & FileAttributes.ReparsePoint) != 0) { continue; }
                    bytes += f.Length;
                    files++;
                }
            } catch { denied++; }
            try {
                foreach (DirectoryInfo d in dir.EnumerateDirectories()) {
                    if ((d.Attributes & FileAttributes.ReparsePoint) != 0) { continue; }
                    stack.Push(d.FullName);
                }
            } catch { denied++; }
        }
        return new long[] { bytes, files, denied, 0 };
    }
}
'@

$script:WDDiskTried = $false

function Test-WDDiskNative {
    if ('WDDisk' -as [type]) { return $true }
    if ($script:WDDiskTried)  { return $false }
    $script:WDDiskTried = $true
    try { Add-Type -ErrorAction SilentlyContinue -TypeDefinition $script:WDDiskSource } catch { }
    [bool]('WDDisk' -as [type])
}

function Measure-WDFolder {
    param([string]$Path)
    if (-not $Path) { return 0L }
    if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return 0L }
    try {
        if (Test-WDDiskNative) { return [int64]([WDDisk]::Size($Path))[0] }
        [int64](Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
    } catch { 0L }
}

function Measure-WDFolderDetail {
    # What could not be read is reported rather than folded into the total: "0
    # bytes" and "0 bytes I was allowed to see" are different answers.
    param([string]$Path, [switch]$Cancellable)
    $out = [pscustomobject]@{ Bytes = 0L; Files = 0L; Denied = 0; Present = $false; Stopped = $false }
    if (-not $Path) { return $out }
    if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return $out }
    $out.Present = $true
    if (-not (Test-WDDiskNative)) {
        $out.Bytes = Measure-WDFolder -Path $Path
        return $out
    }
    try {
        $r = [WDDisk]::Size($Path, [bool]$Cancellable)
        $out.Bytes   = [int64]$r[0]
        $out.Files   = [int64]$r[1]
        $out.Denied  = [int]$r[2]
        $out.Stopped = ([int]$r[3] -ne 0)
    } catch { }
    $out
}

function Format-WDBytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:n1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:n0} MB' -f ($Bytes / 1MB)) }
    ('{0:n0} KB' -f ($Bytes / 1KB))
}

function Stop-WDDiskWalk {
    # Opt-in per call, so one closed window cannot quietly turn every later
    # measurement in the process into a zero.
    param([switch]$Reset)
    if ('WDDisk' -as [type]) { [WDDisk]::Stop = (-not $Reset) }
}

function Get-WDStorageSources {
    # One table: each clean-up names the folders it acts on and which
    # descriptive bucket those bytes were already counted in. Two lists would
    # have the picture promising what the run does not deliver.
    $sys = [string]$env:SystemDrive
    if (-not $sys) { $sys = 'C:' }
    $win = [string]$env:SystemRoot
    if (-not $win) { $win = Join-Path $sys 'Windows' }

    # Windows' own two, then every account's - not just the temp folder of
    # whoever elevated. SystemTemp is where SYSTEM processes put theirs since
    # 24H2, and a run as SYSTEM has it as its own TEMP.
    $tempPaths = New-Object System.Collections.Generic.List[hashtable]
    $tempPaths.Add(@{ Path = (Join-Path $win 'Temp'); Bucket = 'windows' })
    $tempPaths.Add(@{ Path = (Join-Path $win 'SystemTemp'); Bucket = 'windows' })
    $tempList = Get-WDProfileTempPaths
    foreach ($t in $tempList) { $tempPaths.Add(@{ Path = $t; Bucket = 'users' }) }

    [ordered]@{
        # Only what has sat untouched for a day: anything newer may belong to a
        # program that is running, or an installer halfway through. Windows' own
        # Temporary Files clean-up waits a week for the same reason.
        'disk-temp' = @{
            Kind = 'folder'; What = 'temporary files'; MinAgeHours = 24
            Paths = $tempPaths.ToArray()
        }
        'disk-update-cache' = @{
            Kind = 'folder'; What = 'the Windows Update cache'
            Paths = @(
                @{ Path = (Join-Path $win 'SoftwareDistribution\Download'); Bucket = 'windows' }
            )
        }
        # The Cache folder, not the whole service folder: beside it sit the
        # service's own logs and state, which this has no business with.
        'disk-delivery-opt' = @{
            Kind = 'folder'; What = 'the Delivery Optimization cache'
            Paths = @(
                @{ Path = (Join-Path $win 'SoftwareDistribution\DeliveryOptimization'); Bucket = 'windows' }
                @{ Path = (Join-Path $win 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'); Bucket = 'windows' }
            )
        }
        # The cache databases only. The same folder holds Explorer's startup logs
        # and the Recommendations filter list, which are not caches.
        'disk-thumbnails' = @{
            Kind = 'folder'; What = 'the thumbnail and icon cache'
            Include = @('thumbcache_*.db', 'iconcache_*.db'); NoRecurse = $true; DelayLocked = $true
            Paths = @(
                @{ Path = (Join-Path ([string]$env:LOCALAPPDATA) 'Microsoft\Windows\Explorer'); Bucket = 'users' }
            )
        }
        'disk-recycle-bin' = @{
            Kind = 'recyclebin'; What = 'the Recycle Bin'
            Paths = @(
                @{ Path = (Join-Path $sys '$Recycle.Bin'); Bucket = 'other' }
            )
        }
        'disk-windows-old' = @{
            Kind = 'folder'; What = 'the previous Windows installation'
            Paths = @(
                @{ Path = (Join-Path $sys 'Windows.old'); Bucket = 'other' }
            )
        }
        'disk-component-store' = @{
            Kind = 'none'; What = 'superseded components'
            Paths = @()
        }
    }
}

function Get-WDProfileTempPaths {
    # Every real account's own temp folder. S-1-5-21 SIDs only, so the service
    # profiles under System32 are not swept as though they were people's.
    $out  = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) {
        if ([string]$k.PSChildName -notlike 'S-1-5-21-*') { continue }
        $dir = ''
        try { $dir = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -LiteralPath $k.PSPath -Name 'ProfileImagePath' -ErrorAction Stop).ProfileImagePath) } catch { }
        if (-not $dir) { continue }
        $t = Join-Path $dir 'AppData\Local\Temp'
        if ($seen.Add($t)) { $out.Add($t) }
    }
    ,$out.ToArray()
}

function Get-WDFilteredFiles {
    # The files a filtered clean-up takes: untouched for at least MinAgeHours,
    # and matching Include when it is given. One walk serves the sizing and the
    # deletion, so the row and the run cannot disagree. Never descends into a
    # junction or a symbolic link - this deletes file by file, and whatever is
    # behind a link is somewhere else entirely.
    param([string]$Path, [int]$MinAgeHours = 0, [string[]]$Include = @(), [switch]$NoRecurse)

    $out   = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $cut   = (Get-Date).AddHours(-$MinAgeHours)
    $stack = New-Object System.Collections.Generic.Stack[string]
    if (-not $Path) { return ,$out.ToArray() }
    $stack.Push($Path)
    while ($stack.Count) {
        $dir = $stack.Pop()
        $di = $null
        try { $di = New-Object System.IO.DirectoryInfo $dir } catch { continue }
        if (-not $di.Exists) { continue }
        try {
            foreach ($f in $di.EnumerateFiles()) {
                if ($Include.Count) {
                    $hit = $false
                    foreach ($p in $Include) { if ($f.Name -like $p) { $hit = $true; break } }
                    if (-not $hit) { continue }
                }
                if ($MinAgeHours -gt 0 -and ($f.LastWriteTime -ge $cut -or $f.CreationTime -ge $cut)) { continue }
                $out.Add($f)
            }
        } catch { }
        if ($NoRecurse) { continue }
        try {
            foreach ($s in $di.EnumerateDirectories()) {
                if ($s.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($s.FullName)
            }
        } catch { }
    }
    ,$out.ToArray()
}

function Measure-WDRecycleBin {
    # Both answers are wanted and they are not interchangeable: the bar draws
    # one drive, and Clear-WDRecycleBin empties every one.
    param([string]$Root, [switch]$All)
    if (-not (Test-WDDiskNative)) { return $null }
    $arg = $null
    if (-not $All) {
        if (-not $Root) {
            $Root = [string]$env:SystemDrive
            if (-not $Root) { $Root = 'C:' }
        }
        $arg = $Root.TrimEnd('\') + '\'
    }
    try {
        $r = [WDDisk]::RecycleBin($arg)
        if ([int64]$r[0] -lt 0) { return $null }
        [pscustomobject]@{ Bytes = [int64]$r[0]; Items = [int64]$r[1] }
    } catch { $null }
}

function Measure-WDReclaimable {
    param([switch]$Cancellable)
    $sources = Get-WDStorageSources
    $items   = @{}
    $unknown = New-Object System.Collections.Generic.List[string]
    $overlap = @{ windows = 0L; apps = 0L; users = 0L; other = 0L }

    foreach ($id in $sources.Keys) {
        $src = $sources[$id]
        if ([string]$src.Kind -eq 'none') { $unknown.Add([string]$id); continue }
        if ([string]$src.Kind -eq 'recyclebin') {
            $rb = Measure-WDRecycleBin
            if (-not $rb) { $unknown.Add([string]$id); continue }
            $items[[string]$id] = [int64]$rb.Bytes
            $overlap['other'] += [int64]$rb.Bytes
            continue
        }
        $sum = 0L; $blind = 0; $present = $false
        # A filtered clean-up is sized by the same walk that deletes, or the row
        # would promise the whole folder while the run took a part of it.
        # Keys, not Get-Prop: a source is a hashtable, and Get-Prop reads object
        # properties, so it would answer the defaults for every one of these.
        $minAge  = [int]$src['MinAgeHours']
        $include = @()
        if ($src['Include']) { $include = @($src['Include']) }
        $flat    = [bool]$src['NoRecurse']
        foreach ($p in @($src.Paths)) {
            if ($minAge -gt 0 -or $include.Count) {
                $here = Test-Path -LiteralPath ([string]$p.Path) -ErrorAction SilentlyContinue
                $b = 0L
                if ($here) {
                    $fs = Get-WDFilteredFiles -Path ([string]$p.Path) -MinAgeHours $minAge -Include $include -NoRecurse:$flat
                    foreach ($f in $fs) { $b += [int64]$f.Length }
                }
                $d = [pscustomobject]@{ Bytes = $b; Denied = 0; Present = [bool]$here }
            } else {
                $d = Measure-WDFolderDetail -Path ([string]$p.Path) -Cancellable:$Cancellable
            }
            $sum   += $d.Bytes
            $blind += $d.Denied
            if ($d.Present) { $present = $true }
            $k = [string]$p.Bucket
            if ($overlap.ContainsKey($k)) { $overlap[$k] += $d.Bytes }
        }
        # There but unreadable is not the same as empty, and only one of the two
        # may put "nothing to free" on the row.
        if ($sum -le 0 -and $present -and $blind -gt 0) { $unknown.Add([string]$id); continue }
        $items[[string]$id] = $sum
    }

    [pscustomobject]@{ Items = $items; Unmeasured = $unknown.ToArray(); Overlap = $overlap }
}

function Measure-WDDiskBuckets {
    param([switch]$Cancellable)
    $sys = [string]$env:SystemDrive
    if (-not $sys) { $sys = 'C:' }
    $win = [string]$env:SystemRoot
    if (-not $win) { $win = Join-Path $sys 'Windows' }

    $groups = [ordered]@{
        windows = @($win)
        apps    = @((Join-Path $sys 'Program Files'), (Join-Path $sys 'Program Files (x86)'),
                    (Join-Path $sys 'ProgramData'))
        users   = @((Join-Path $sys 'Users'))
    }

    $raw = @{}
    $denied = 0
    $stopped = $false
    foreach ($k in $groups.Keys) {
        $sum = 0L
        foreach ($p in $groups[$k]) {
            $d = Measure-WDFolderDetail -Path $p -Cancellable:$Cancellable
            $sum    += $d.Bytes
            $denied += $d.Denied
            if ($d.Stopped) { $stopped = $true }
        }
        $raw[[string]$k] = $sum
        if ($stopped) { break }
    }

    # The three files people are always surprised by. They sit at the root of
    # the drive, so naming them is the difference between Other meaning
    # something and Other meaning nothing.
    $reserve = [ordered]@{}
    foreach ($n in @('pagefile.sys', 'swapfile.sys', 'hiberfil.sys')) {
        $p = Join-Path ($sys + '\') $n
        try {
            $fi = New-Object System.IO.FileInfo $p
            if ($fi.Exists -and $fi.Length -gt 0) { $reserve[$n] = [int64]$fi.Length }
        } catch { }
    }

    [pscustomobject]@{ Raw = $raw; Reserve = $reserve; Denied = $denied; Stopped = $stopped }
}

function New-WDStorageSnapshot {
    param(
        [string]$Drive,
        [int64]$TotalBytes,
        [int64]$FreeBytes,
        [hashtable]$Items,
        [string[]]$Unmeasured,
        [hashtable]$Overlap,
        [hashtable]$Raw,
        $Reserve,
        [int]$Denied = 0,
        [switch]$Priced
    )
    if (-not $Drive) { $Drive = 'C:' }
    if (-not $Items) { $Items = @{} }
    if (-not $Overlap) { $Overlap = @{} }

    $used = [Math]::Max(0L, $TotalBytes - $FreeBytes)

    $reclaim = 0L
    foreach ($v in $Items.Values) { $reclaim += [int64]$v }
    # Cannot free more than is in use. Only reachable if a measurement went
    # stale, but a negative remainder renders as a bar running backwards.
    if ($reclaim -gt $used) { $reclaim = $used }
    $room = $used - $reclaim

    $labels = [ordered]@{ windows = 'Windows'; apps = 'Apps'; users = 'Your files'; other = 'Other' }
    $segments = New-Object System.Collections.Generic.List[psobject]
    $complete = $false
    $scaled   = $false

    $haveAll = $true
    foreach ($k in @('windows', 'apps', 'users')) {
        if (-not $Raw -or -not $Raw.ContainsKey($k)) { $haveAll = $false; break }
    }

    if ($haveAll) {
        $complete = $true
        $net = [ordered]@{}
        $known = 0L
        foreach ($k in @('windows', 'apps', 'users')) {
            $o = 0L
            if ($Overlap.ContainsKey($k)) { $o = [int64]$Overlap[$k] }
            $v = [Math]::Max(0L, [int64]$Raw[$k] - $o)
            $net[$k] = $v
            $known += $v
        }
        $other = 0L
        if ($known -gt $room -and $known -gt 0) {
            $scaled = $true
            $factor = [double]$room / [double]$known
            foreach ($k in @('windows', 'apps', 'users')) { $net[$k] = [int64]($net[$k] * $factor) }
        } else {
            $other = $room - $known
        }
        foreach ($k in @('windows', 'apps', 'users')) {
            $segments.Add([pscustomobject]@{ Key = $k; Label = $labels[$k]; Bytes = [int64]$net[$k] })
        }
        $segments.Add([pscustomobject]@{ Key = 'other'; Label = $labels['other']; Bytes = [int64]$other })
    } else {
        # Nothing walked yet: one block for everything in use rather than four
        # empty ones, because a segment drawn at zero reads as "you have no
        # files".
        $segments.Add([pscustomobject]@{ Key = 'unknown'; Label = 'In use'; Bytes = [int64]$room })
    }

    [pscustomobject]@{
        Drive       = $Drive
        TotalBytes  = [int64]$TotalBytes
        FreeBytes   = [int64]$FreeBytes
        UsedBytes   = [int64]$used
        UsedPercent = $(if ($TotalBytes -gt 0) { [int][Math]::Round(100 * $used / $TotalBytes) } else { 0 })
        Items       = $Items
        Unmeasured  = @($Unmeasured)
        Reclaimable = [int64]$reclaim
        Segments    = $segments.ToArray()
        Reserve     = $Reserve
        Denied      = $Denied
        # Two kinds of finished, and the interface needs both. Priced means a
        # row may say "nothing to free"; Complete means the bar may show a
        # split.
        Priced      = [bool]$Priced
        Complete    = $complete
        Scaled      = $scaled
    }
}

function Get-WDStorageReport {
    # -Quick skips the three drive walks and answers with the clean-up sizes
    # alone.
    param([switch]$Quick, $Buckets)

    $sys = [string]$env:SystemDrive
    if (-not $sys) { $sys = 'C:' }
    $total = 0L; $free = 0L
    try {
        $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sys'" -ErrorAction Stop
        if ($ld -and $ld.Size -gt 0) { $total = [int64]$ld.Size; $free = [int64]$ld.FreeSpace }
    } catch { }

    $rec = Measure-WDReclaimable
    if (-not $Buckets -and -not $Quick) { $Buckets = Measure-WDDiskBuckets }

    $raw = $null; $reserve = $null; $denied = 0
    if ($Buckets) {
        $raw     = $Buckets.Raw
        $reserve = $Buckets.Reserve
        $denied  = [int]$Buckets.Denied
    }

    New-WDStorageSnapshot -Drive $sys -TotalBytes $total -FreeBytes $free `
                          -Items $rec.Items -Unmeasured $rec.Unmeasured -Overlap $rec.Overlap `
                          -Raw $raw -Reserve $reserve -Denied $denied -Priced
}

function Get-WDDiskCapacity {
    $sys = [string]$env:SystemDrive
    if (-not $sys) { $sys = 'C:' }
    $total = 0L; $free = 0L
    try {
        $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sys'" -ErrorAction Stop
        if ($ld -and $ld.Size -gt 0) { $total = [int64]$ld.Size; $free = [int64]$ld.FreeSpace }
    } catch { }
    [pscustomobject]@{ Drive = $sys; TotalBytes = $total; FreeBytes = $free }
}

function Clear-WDFolderContents {
    param([string[]]$Paths, $Context, [string]$What,
          [int]$MinAgeHours = 0, [string[]]$Include = @(), [switch]$NoRecurse, [switch]$DelayLocked)

    # -ErrorAction on Test-Path, because some of these are owned by a service
    # account and answering "does it exist" throws Access denied rather than
    # returning false.
    $live = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue) })
    if (-not $live.Count) { return New-WDResult -Status NotPresent -Message "Nothing to clear in $What" }

    # Filtered: file by file, through the same walk that sized the row.
    if ($MinAgeHours -gt 0 -or $Include.Count) {
        $targets = New-Object System.Collections.Generic.List[System.IO.FileInfo]
        foreach ($p in $live) {
            foreach ($f in (Get-WDFilteredFiles -Path $p -MinAgeHours $MinAgeHours -Include $Include -NoRecurse:$NoRecurse)) { $targets.Add($f) }
        }
        $total = 0L
        foreach ($f in $targets) { $total += [int64]$f.Length }
        $aged = $(if ($MinAgeHours -gt 0) { ' that has sat untouched for a day or more' } else { '' })
        if ($total -le 0) { return New-WDResult -Status NotPresent -Message "Nothing in $What$aged to clear" }
        if ($Context.Preview) {
            return New-WDResult -Status Removed -Message "Would free about $(Format-WDBytes $total) from $What" -Detail ($live -join '; ')
        }
        $freed = 0L; $stuck = 0; $queued = 0
        $canQueue = $DelayLocked -and (Initialize-WDPendingDeleteType)
        foreach ($f in $targets) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $freed += [int64]$f.Length }
            catch {
                # 4 = MOVEFILE_DELAY_UNTIL_REBOOT: a real deletion, deferred to
                # the next restart, before anything has the file open again.
                if ($canQueue -and [WD.Pending]::MoveFileEx($f.FullName, $null, 4)) { $queued++ } else { $stuck++ }
            }
        }
        $notes = New-Object System.Collections.Generic.List[string]
        if ($queued) { $notes.Add("$queued file(s) in use are deleted at the next restart.") }
        if ($stuck)  { $notes.Add("$stuck file(s) were in use and were left alone.") }
        $status = $(if ($stuck -and -not $freed -and -not $queued) { 'Blocked' } elseif ($stuck) { 'Partial' } else { 'Removed' })
        return New-WDResult -Status $status -Message "Freed about $(Format-WDBytes $freed) from $What" -Detail ($notes -join ' ')
    }

    $bytes = 0L
    foreach ($p in $live) { $bytes += Measure-WDFolder -Path $p }
    $pretty = Format-WDBytes $bytes
    if ($bytes -le 0) { return New-WDResult -Status NotPresent -Message "$What is already empty" }
    if ($Context.Preview) {
        return New-WDResult -Status Removed -Message "Would free about $pretty from $What" -Detail ($live -join '; ')
    }

    $stuck = 0
    foreach ($p in $live) {
        foreach ($child in @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)) {
            try { Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop }
            catch { $stuck++ }
        }
    }
    $after = 0L
    foreach ($p in $live) { $after += Measure-WDFolder -Path $p }
    $freed = [Math]::Max(0L, $bytes - $after)
    if ($stuck) {
        return New-WDResult -Status Partial -Message "Freed about $(Format-WDBytes $freed) from $What" `
                            -Detail "$stuck item(s) were in use and were left alone."
    }
    New-WDResult -Status Removed -Message "Freed about $(Format-WDBytes $freed) from $What"
}

function Get-WDStoragePaths {
    param([Parameter(Mandatory)][string]$Id)
    $src = Get-WDStorageSources
    if (-not $src.Contains($Id)) { return @() }
    @($src[$Id].Paths | ForEach-Object { [string]$_.Path })
}

function Clear-WDStorageSource {
    # A clean-up straight off its row of the path table, filters and all, so
    # the handler cannot clear something other than what the row sized.
    param([Parameter(Mandatory)][string]$Id, $Context)
    $all = Get-WDStorageSources
    if (-not $all.Contains($Id)) { return New-WDResult -Status Failed -Message "No storage source '$Id'" }
    $src = $all[$Id]
    $inc = @()
    if ($src['Include']) { $inc = @($src['Include']) }
    Clear-WDFolderContents -Context $Context -What ([string]$src['What']) `
                           -Paths @($src['Paths'] | ForEach-Object { [string]$_.Path }) `
                           -MinAgeHours ([int]$src['MinAgeHours']) -Include $inc `
                           -NoRecurse:([bool]$src['NoRecurse']) -DelayLocked:([bool]$src['DelayLocked'])
}

Register-WDHandler 'ClearTempFiles' {
    param($Action, $Context)
    Clear-WDStorageSource -Id 'disk-temp' -Context $Context
}

Register-WDHandler 'ClearUpdateCache' {
    param($Action, $Context)

    $dl = @(Get-WDStoragePaths -Id 'disk-update-cache')[0]
    if (-not (Test-Path -LiteralPath $dl -ErrorAction SilentlyContinue)) {
        return New-WDResult -Status NotPresent -Message 'No update cache found'
    }
    if ($Context.Preview) {
        $b = Measure-WDFolder -Path $dl
        if ($b -le 0) { return New-WDResult -Status NotPresent -Message 'The update cache is already empty' }
        return New-WDResult -Status Removed -Message "Would free about $(Format-WDBytes $b) from the Windows Update cache" `
                            -Detail 'Windows downloads again anything it still needs.'
    }

    # Windows Update and BITS both, as Microsoft's own reset procedure does:
    # BITS is what downloads into this folder, so with it running a file can be
    # held open, or wuauserv restarted under the delete. Started again after,
    # whichever were running.
    $stopped = New-Object System.Collections.Generic.List[string]
    foreach ($n in @('wuauserv', 'bits')) {
        try {
            $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
                $stopped.Add($n)
            }
        } catch { }
    }
    if ($stopped.Count) { Start-Sleep -Milliseconds 500 }
    try {
        Clear-WDFolderContents -Context $Context -What 'the Windows Update cache' -Paths @($dl)
    } finally {
        foreach ($n in $stopped) { try { Start-Service -Name $n -ErrorAction SilentlyContinue } catch { } }
    }
}

Register-WDHandler 'ClearThumbnailCache' {
    param($Action, $Context)
    Clear-WDStorageSource -Id 'disk-thumbnails' -Context $Context
}

Register-WDHandler 'ClearDeliveryOptimization' {
    # Windows' own cmdlet where it exists: the cache belongs to a running
    # service, and Delete-DeliveryOptimizationCache is that service being asked
    # to drop it. Deleting files out from under it is the fallback for builds
    # without the cmdlet.
    param($Action, $Context)
    $cmd = Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue
    if (-not $cmd) { return Clear-WDStorageSource -Id 'disk-delivery-opt' -Context $Context }

    $paths = @(Get-WDStoragePaths -Id 'disk-delivery-opt' | Where-Object { $_ -and (Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue) })
    $before = 0L
    foreach ($p in $paths) { $before += Measure-WDFolder -Path $p }
    if ($before -le 0) { return New-WDResult -Status NotPresent -Message 'The Delivery Optimization cache is already empty' }
    if ($Context.Preview) {
        return New-WDResult -Status Removed -Message "Would free about $(Format-WDBytes $before) from the Delivery Optimization cache"
    }
    try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop }
    catch { return New-WDResult -Status Blocked -Message 'Delivery Optimization refused to clear its cache' -Detail $_.Exception.Message }
    $after = 0L
    foreach ($p in $paths) { $after += Measure-WDFolder -Path $p }
    New-WDResult -Status Removed -Message "Freed about $(Format-WDBytes ([Math]::Max(0L, $before - $after))) from the Delivery Optimization cache"
}

Register-WDHandler 'RemoveWindowsOld' {
    param($Action, $Context)

    $old = @(Get-WDStoragePaths -Id 'disk-windows-old')[0]
    if (-not (Test-Path -LiteralPath $old -ErrorAction SilentlyContinue)) {
        return New-WDResult -Status NotPresent -Message 'No previous Windows installation is being kept'
    }
    $b = Measure-WDFolder -Path $old
    if ($Context.Preview) {
        return New-WDResult -Status Removed -Message "Would free about $(Format-WDBytes $b) by deleting Windows.old" `
                            -Detail 'This is what "Go back to the previous version of Windows" restores from. Deleting it ends that option for good.'
    }
    # Owned by TrustedInstaller throughout, so the ACL has to be taken first.
    # Without following links: a profile inside Windows.old can carry absolute
    # links - All Users to C:\ProgramData among them - and takeown /R follows
    # them by default, which would re-own the live folders they point at.
    # /SKIPSL for takeown, /L for icacls, which then acts on the link itself.
    $null = & takeown.exe /F $old /R /A /D Y /SKIPSL 2>&1
    $null = & icacls.exe $old /grant "*S-1-5-32-544:F" /T /C /L /Q 2>&1
    try {
        Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction Stop
        New-WDResult -Status Removed -Message "Windows.old deleted, about $(Format-WDBytes $b) freed" `
                     -Detail 'Going back to the previous version of Windows is no longer possible.'
    } catch {
        $left = Measure-WDFolder -Path $old
        if ($left -lt $b) {
            New-WDResult -Status Partial -Message "Most of Windows.old deleted, about $(Format-WDBytes ($b - $left)) freed" `
                         -Detail $_.Exception.Message
        } else {
            New-WDResult -Status Blocked -Message 'Windows.old could not be deleted' -Detail $_.Exception.Message
        }
    }
}

Register-WDHandler 'EmptyRecycleBin' {
    # Clear-WDRecycleBin empties every drive's bin, so this is sized the same
    # way rather than by walking one.
    param($Action, $Context)

    $all = Measure-WDRecycleBin -All
    $here = Measure-WDRecycleBin
    if (-not $all) {
        return New-WDResult -Status Blocked -Message 'The Recycle Bin could not be measured'
    }
    $b = [int64]$all.Bytes
    if ($b -le 0) { return New-WDResult -Status NotPresent -Message 'The Recycle Bin is already empty' }

    $elsewhere = ''
    if ($here -and ($b - $here.Bytes) -gt 0) {
        $elsewhere = " $(Format-WDBytes ($b - $here.Bytes)) of that is on other drives."
    }
    if ($Context.Preview) {
        return New-WDResult -Status Removed -Message "Would free about $(Format-WDBytes $b) by emptying the Recycle Bin" `
                            -Detail ("$($all.Items) item(s) go for good, including anything an earlier run put there.$elsewhere")
    }
    if (Clear-WDRecycleBin) {
        New-WDResult -Status Removed -Message "Recycle Bin emptied, about $(Format-WDBytes $b) freed"
    } else {
        New-WDResult -Status Failed -Message 'The Recycle Bin could not be emptied'
    }
}

function Test-WDPowerToysModuleSet {
    param($Action)

    $module = [string](Get-Prop $Action 'module' '')
    if (-not $module) { return $false }
    $want = [bool](Get-Prop $Action 'enable' $true)
    $root = Get-WDPowerToysRoot

    $settings = Join-Path $root 'settings.json'
    if (-not (Test-Path -LiteralPath $settings)) { return $false }
    # A file PowerToys cannot read is not a setting that is set, however well
    # PowerShell reads it: an earlier version of this toolkit wrote these with a
    # byte order mark, which PowerToys' JSON parser refuses outright.
    if (Test-WDFileHasBom $settings) { return $false }
    $j = $null
    try { $j = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json } catch { return $false }
    if (-not $j -or -not $j.PSObject.Properties['enabled']) { return $false }
    $p = $j.enabled.PSObject.Properties[$module]
    # Absent means the module's own default, and this cannot know what that is.
    if (-not $p) { return $false }
    if ([bool]$p.Value -ne $want) { return $false }

    $hk = Get-Prop $Action 'hotkey' $null
    if ($hk -and $want) {
        $prop = [string](Get-Prop $hk 'property' '')
        $file = [string](Get-Prop $hk 'file' $module)
        if ($prop) {
            $own = Join-Path $root (Join-Path $file 'settings.json')
            if (-not (Test-Path -LiteralPath $own)) { return $false }
            if (Test-WDFileHasBom $own) { return $false }
            $k = $null
            try { $k = Get-Content -LiteralPath $own -Raw | ConvertFrom-Json } catch { return $false }
            $cur = $null
            if ($k -and $k.PSObject.Properties['properties']) { $cur = $k.properties.PSObject.Properties[$prop] }
            if (-not $cur -or -not $cur.Value) { return $false }
            $v = $cur.Value
            foreach ($mod in @('win', 'ctrl', 'alt', 'shift')) {
                if ([bool](Get-Prop $v $mod $false) -ne [bool](Get-Prop $hk $mod $false)) { return $false }
            }
            if ([int](Get-Prop $v 'code' -1) -ne [int](Get-Prop $hk 'code' 0)) { return $false }
        }
    }
    $true
}

# Handler name -> "is this already the case?". An item whose every action
# answers yes is already done. Only handlers that can answer cheaply and locally
# belong here: it runs for every action of every item while the window builds.
$script:StateTests = @{
    'SetPowerToysModule' = ${function:Test-WDPowerToysModuleSet}

    # The task is the hold; its active hours are the task's to move. In
    # WD.Persist, which every runspace that asks this imports.
    'HoldUpdateRestarts' = { param($Action) [bool](Test-WDRestartHoldTask) }

    # Both scrubs ask "is any of this vendor's software still installed", which
    # is the handler's own first line.
    'McAfeeScrub' = {
        param($Action)
        -not @(Get-WDInstalledPrograms | Where-Object {
            $_.DisplayName -like '*McAfee*' -or $_.Publisher -like '*McAfee*' }).Count
    }
    'NortonScrub' = {
        param($Action)
        -not @(Get-WDInstalledPrograms | Where-Object { $_.DisplayName -match 'Norton|Symantec' }).Count
    }

    # Asked exactly as RemoveEdge asks it. Done only when the browser is gone
    # and the updater that would bring it back is off, because half that job
    # is not the job. The updater is asked about rather than its policy, which
    # binds only a domain-joined machine.
    'RemoveEdge' = {
        param($Action)
        foreach ($d in @((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
                         (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'))) {
            if (Test-Path -LiteralPath $d -ErrorAction SilentlyContinue) { return $false }
        }
        try { if (@(Get-AppxPackage -Name 'Microsoft.MicrosoftEdge.Stable' -ErrorAction SilentlyContinue).Count) { return $false } } catch { }
        foreach ($s in @(Get-Service -Name 'edgeupdate', 'edgeupdatem' -ErrorAction SilentlyContinue)) {
            $st = ''
            try { $st = [string]$s.StartType } catch { }
            if ($st -ne 'Disabled') { return $false }
        }
        $true
    }

    # The handler's own question, asked through the same plan: done when one
    # press of Set default would move nothing. This read http and https alone
    # while the handler also saw .svg with Edge, so the row said "already
    # applied" over a step that reopened Settings at every run. Reads only.
    'SetDefaultBrowser' = {
        param($Action)
        if (-not (Get-Command Get-WDDefaultBrowserPlan -ErrorAction SilentlyContinue)) { return $false }
        try { return [bool](Get-WDDefaultBrowserPlan).Done } catch { return $false }
    }

    # OneDrive itself, not its in-box installer: System32\OneDriveSetup.exe is a
    # protected Windows file on every machine, so testing for it meant this
    # could never read as done and every guard ran the uninstall again.
    'RemoveOneDrive' = {
        param($Action)
        if (@(Get-WDInstalledPrograms | Where-Object { $_.DisplayName -like 'Microsoft OneDrive*' }).Count) { return $false }
        foreach ($p in @((Join-Path ([string]$env:ProgramFiles) 'Microsoft OneDrive'),
                         (Join-Path ([string]${env:ProgramFiles(x86)}) 'Microsoft OneDrive'),
                         (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'))) {
            if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { return $false }
        }
        $true
    }

    'RemoveWindowsOld' = {
        param($Action)
        -not (Test-Path -LiteralPath (Join-Path $env:SystemDrive 'Windows.old') -ErrorAction SilentlyContinue)
    }

    # Asked of the registry rather than by spawning powercfg, which this cannot
    # afford.
    'DisableHibernation' = {
        param($Action)
        (Get-WDHibernateState) -eq $false
    }

    # Through the power API, which is microseconds once loaded; the compile is
    # paid once, on the background scan that fills this answer in.
    'SetPowerScheme' = {
        param($Action)
        $sub = Resolve-WDPowerGuid ([string](Get-Prop $Action 'sub' ''))
        $set = Resolve-WDPowerGuid ([string](Get-Prop $Action 'setting' ''))
        if (-not $sub -or -not $set) { return $false }
        $rows = @()
        try { $rows = Get-WDPowerSettingRows -Sub $sub -Setting $set } catch { return $false }
        if (-not @($rows).Count) { return $false }
        $want = [long](Get-Prop $Action 'value' 0)
        foreach ($r in $rows) {
            if (($r.Ac -ge 0 -and $r.Ac -ne $want) -or ($r.Dc -ge 0 -and $r.Dc -ne $want)) { return $false }
        }
        $true
    }

    # One bit inside a blob, per account, which is why the handler exists at
    # all. Read the same byte back.
    # Off when Microsoft Update is not registered with Automatic Updates. An
    # agent that cannot be asked is no answer, which is not done.
    'DisableMicrosoftUpdateService' = {
        param($Action)
        $on = Test-WDMicrosoftUpdateOn
        ($null -ne $on) -and (-not $on)
    }

    # Done when every tray entry Windows knows is promoted. An account with no
    # entries yet has nothing outstanding, but a machine with none at all is not
    # "already set" - nothing has been looked at.
    'PromoteTrayIcons' = {
        param($Action)
        $keys = Get-WDTrayIconKeys
        if (-not $keys.Count) { return $false }
        foreach ($k in $keys) {
            $v = $null
            try { $v = (Get-ItemProperty -LiteralPath $k -Name 'IsPromoted' -ErrorAction Stop).IsPromoted } catch { return $false }
            if ([int]$v -ne 1) { return $false }
        }
        $true
    }

    'SetTaskbarAutoHide' = {
        param($Action)
        $rel  = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
        $seen = $false
        foreach ($root in @(Get-WDUserHives)) {
            $path = Join-Path $root.Path $rel
            $cur = $null
            try { $cur = Get-ItemProperty -LiteralPath $path -Name 'Settings' -ErrorAction SilentlyContinue } catch { }
            if (-not $cur -or -not $cur.Settings) { continue }
            $b = [byte[]]$cur.Settings
            if ($b.Length -lt 9) { continue }
            $seen = $true
            if (($b[8] -band 0x01) -ne 0x01) { return $false }
        }
        $seen
    }

    'SetNoSoundScheme' = {
        param($Action)
        $seen = $false
        foreach ($root in @(Get-WDUserHives)) {
            $k = Join-Path $root.Path 'AppEvents\Schemes'
            if (-not (Test-Path -LiteralPath $k -ErrorAction SilentlyContinue)) { continue }
            $seen = $true
            $v = ''
            try { $v = [string](Get-ItemProperty -LiteralPath $k -Name '(default)' -ErrorAction SilentlyContinue).'(default)' } catch { }
            if ($v -ne '.None') { return $false }
        }
        $seen
    }

    # The overlay value and the icon it points at: a value pointing at a file
    # somebody has since deleted is an overlay pointing at nothing.
    'SetShortcutArrow' = {
        param($Action)
        $ico = Join-Path (Join-Path $env:ProgramData 'WinSetupToolkit') 'blank-arrow.ico'
        if (-not (Test-Path -LiteralPath $ico -ErrorAction SilentlyContinue)) { return $false }
        $v = ''
        try {
            $v = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons' `
                                           -Name '29' -ErrorAction SilentlyContinue).'29'
        } catch { }
        $v -eq "$ico,0"
    }

    # Either layer counts as done - the native setting, or the PowerToys chord
    # remap. The point is that the key behaves as Right Ctrl, not which got it
    # there.
    'CopilotKeyToRightCtrl' = {
        param($Action)
        foreach ($c in @(
            @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Copilot\CopilotKey'; N = 'RemapTarget' }
            @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell\Copilot\CopilotKey';    N = 'RemapTarget' }
            @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell\Copilot\CopilotKey';    N = 'CopilotKeyMode' })) {
            $v = ''
            try { $v = [string](Get-ItemProperty -LiteralPath $c.P -Name $c.N -ErrorAction SilentlyContinue).$($c.N) } catch { }
            if ($v -eq 'RightControl') { return $true }
        }
        # The chord the handler writes, mapped to what the handler writes. It
        # matched any "162" anywhere in the file - Left Ctrl - while the handler
        # writes 163, so its own remap read as not applied and a Left Ctrl
        # mapping read as done. PowerToys installed is part of the answer: the
        # remap does nothing without it.
        if (-not (Test-WDPowerToys)) { return $false }
        $f = Join-Path (Get-WDPowerToysRoot) 'Keyboard Manager\default.json'
        if (-not (Test-Path -LiteralPath $f)) { return $false }
        try {
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            foreach ($g in @($j.remapShortcuts.global)) {
                $keys = [string]$g.originalKeys
                if (($keys -eq "$($script:VK.LWin);$($script:VK.LShift);$($script:VK.F23)" -or
                     $keys -eq "$($script:VK.LWin);$($script:VK.Shift);$($script:VK.F23)") -and
                    [string]$g.newRemapKeys -eq [string]$script:VK.RCtrl) { return $true }
            }
        } catch { }
        return $false
    }
}

function Test-WDActionSatisfied {
    param($Action, $Inventory)

    switch ([string](Get-Prop $Action 'type' '')) {
        'registry' { try { return [bool](Test-WDRegistryActionSatisfied -Action $Action) } catch { return $false } }
        # ServiceController already carries StartType, so a service costs
        # nothing to ask about. DISM costs seconds, which is why features and
        # capabilities are not asked.
        'service'  { try { return [bool](Test-WDServiceActionSatisfied -Action $Action) } catch { return $false } }
        'registryKey' {
            # Deleting a key that is not there is nothing to do, and cheap
            # enough to answer without an inventory.
            $paths = @(Get-Prop $Action 'paths' @())
            if (-not $paths.Count) { return $false }
            foreach ($p in $paths) {
                $x = [Environment]::ExpandEnvironmentVariables([string]$p)
                if ($x -and (Test-Path -LiteralPath $x -ErrorAction SilentlyContinue)) { return $false }
            }
            return $true
        }
        'file' {
            $paths = @(Get-Prop $Action 'paths' @())
            if (-not $paths.Count) { return $false }
            foreach ($p in $paths) {
                $x = [Environment]::ExpandEnvironmentVariables([string]$p)
                if ($x -and (Test-Path -LiteralPath $x -ErrorAction SilentlyContinue)) { return $false }
            }
            return $true
        }
    }

    if ($Inventory) {
        switch ([string](Get-Prop $Action 'type' '')) {
            'appx' {
                $pats = @(Get-Prop $Action 'names' @())
                if (-not $pats.Count) { return $false }
                foreach ($n in @($Inventory.Appx)) {
                    foreach ($p in $pats) { if ($p -and $n -like $p) { return $false } }
                }
                return $true
            }
            'appxPolicy' {
                $pats = @(Get-Prop $Action 'packages' @())
                if (-not $pats.Count) { return $false }
                foreach ($n in @($Inventory.Appx)) {
                    foreach ($p in $pats) { if ($p -and $n -like $p) { return $false } }
                }
                return $true
            }
            'uninstall' {
                $pats = @(Get-Prop $Action 'match' @())
                if (-not $pats.Count) { return $false }
                $skip = @(Get-Prop $Action 'exclude' @())
                foreach ($prog in @($Inventory.Programs)) {
                    $nm = [string]$prog.DisplayName
                    $hit = $false
                    foreach ($p in $pats) { if ($p -and $nm -like $p) { $hit = $true; break } }
                    if (-not $hit) { continue }
                    foreach ($p in $skip) { if ($p -and $nm -like $p) { $hit = $false; break } }
                    if ($hit) { return $false }
                }
                return $true
            }
            # A task the run disables rather than deletes is still registered
            # afterwards, so "gone" is the wrong test and Enabled is the right
            # one.
            'task' {
                $pats = @(Get-Prop $Action 'tasks' @())
                if (-not $pats.Count) { return $false }
                $del = [bool](Get-Prop $Action 'delete' $false)
                $off = @($Inventory.TasksOff)
                foreach ($n in @($Inventory.Tasks)) {
                    $hit = $false
                    foreach ($p in $pats) { if ($p -and $n -like $p) { $hit = $true; break } }
                    if (-not $hit) { continue }
                    if ($del) { return $false }
                    if ($off -notcontains $n) { return $false }
                }
                return $true
            }
        }
    }

    $h = [string](Get-Prop $Action 'handler' '')
    if (-not $h -or -not $script:StateTests.ContainsKey($h)) { return $false }
    try { [bool](& $script:StateTests[$h] $Action) } catch { $false }
}

function Get-WDStateTestNames {
    @($script:StateTests.Keys)
}

function Test-WDItemSatisfied {
    param($Item, $Inventory, $Profile)

    $acts = @(Get-Prop $Item 'actions' @())
    if (-not $acts.Count) { return $false }
    $asked = 0
    foreach ($a in $acts) {
        $g = @(Get-Prop $a 'guards' @())
        if ($g.Count -and $Profile -and -not (Test-WDGuard -Guards $g -Profile $Profile)) { continue }
        $asked++
        if (-not (Test-WDActionSatisfied -Action $a -Inventory $Inventory)) { return $false }
    }
    [bool]$asked
}

Register-WDHandler 'SetPowerToysModule' {
    param($Action, $Context)

    $module = [string](Get-Prop $Action 'module' '')
    if (-not $module) { return New-WDResult -Status Skipped -Message 'No PowerToys module named' }
    $on  = [bool](Get-Prop $Action 'enable' $true)
    $hk  = Get-Prop $Action 'hotkey' $null
    $lbl = [string](Get-Prop $Action 'label' $module)

    if ($Context.Preview) {
        $what = if ($on) { "Would enable $lbl" } else { "Would turn $lbl off" }
        if ($hk) { $what += " on $([string](Get-Prop $hk 'label' 'its shortcut'))" }
        $note = if (Test-WDPowerToys) { 'PowerToys is installed; it is restarted so the change takes effect.' }
                else { 'PowerToys is not installed yet - the setting is written now and read the first time it starts.' }
        return New-WDResult -Status Changed -Message $what -Detail $note
    }

    try {
        $root = Get-WDPowerToysRoot

        # 1. the enabled map, shared by every module
        $seed = [pscustomobject]@{ enabled = [pscustomobject]@{} }
        Set-WDPowerToysJson -Path (Join-Path $root 'settings.json') -Context $Context -Seed $seed -Edit {
            param($j)
            if (-not $j.PSObject.Properties['enabled'] -or $null -eq $j.enabled) {
                $j | Add-Member -NotePropertyName 'enabled' -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $j.enabled | Add-Member -NotePropertyName $module -NotePropertyValue $on -Force
        }

        # 2. that module's own file, when a hotkey was asked for
        if ($hk -and $on) {
            $prop = [string](Get-Prop $hk 'property' '')
            $file = [string](Get-Prop $hk 'file' $module)
            if ($prop) {
                $chord = [pscustomobject]@{
                    win   = [bool](Get-Prop $hk 'win' $false)
                    ctrl  = [bool](Get-Prop $hk 'ctrl' $false)
                    alt   = [bool](Get-Prop $hk 'alt' $false)
                    shift = [bool](Get-Prop $hk 'shift' $false)
                    code  = [int](Get-Prop $hk 'code' 0)
                    key   = [string](Get-Prop $hk 'key' '')
                }
                $seed2 = [pscustomobject]@{ name = $file; version = '1.0'; properties = [pscustomobject]@{} }
                Set-WDPowerToysJson -Path (Join-Path $root (Join-Path $file 'settings.json')) `
                                    -Context $Context -Seed $seed2 -Edit {
                    param($j)
                    if (-not $j.PSObject.Properties['properties'] -or $null -eq $j.properties) {
                        $j | Add-Member -NotePropertyName 'properties' -NotePropertyValue ([pscustomobject]@{}) -Force
                    }
                    $j.properties | Add-Member -NotePropertyName $prop -NotePropertyValue $chord -Force
                }
            }
        }

        # PowerToys reads all of this at start, so a running instance has to be
        # bounced or the change appears to have done nothing.
        $bounced = $false
        $running = Get-Process -Name 'PowerToys' -ErrorAction SilentlyContinue
        if ($running) {
            $exe = $running[0].Path
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
            if ($exe) { Start-Process -FilePath $exe -ErrorAction SilentlyContinue; $bounced = $true }
        }

        $msg = if ($on) { "$lbl enabled" } else { "$lbl turned off" }
        $detail = if (Test-WDPowerToys) {
            if ($bounced) { 'PowerToys was restarted to pick it up.' } else { 'Takes effect the next time PowerToys starts.' }
        } else {
            'Written ahead of the install - PowerToys reads it the first time it runs.'
        }
        New-WDResult -Status Changed -Message $msg -Detail $detail
    } catch {
        New-WDResult -Status Failed -Message "Could not configure $lbl" -Detail $_.Exception.Message
    }
}

function Get-WDTrayIconKeys {
    # Every app entry Windows keeps under Control Panel\NotifyIconSettings, per
    # account. Windows makes one the first time an app shows a tray icon, so the
    # default profile has none.
    param($Context)
    $accounts = $null
    if ($Context) { $accounts = Get-WDContextAccounts $Context }
    $roots = @(Select-WDAccountHives -Hives (Get-WDUserHives) -Default $null -Accounts $accounts)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        $base = Join-Path $root.Path 'Control Panel\NotifyIconSettings'
        if (-not (Test-Path -LiteralPath $base -ErrorAction SilentlyContinue)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
            $out.Add((Join-Path $base $k.PSChildName))
        }
    }
    ,$out.ToArray()
}

Register-WDHandler 'PromoteTrayIcons' {
    # Windows 11 22H2 and later ignore EnableAutoTray. What decides whether an
    # icon sits on the taskbar or behind the chevron is IsPromoted on that app's
    # entry - the value each switch under Settings > Personalization > Taskbar >
    # Other system tray icons writes. Handed to the registry executor, so every
    # value is backed up, journalled, and answered AlreadySet like a manifest
    # one. SystemTrayChevronVisibility was considered and left alone: the
    # sources disagree about whether 0 shows the hidden icons or hides them.
    param($Action, $Context)

    # Assigned, never wrapped: the function ends in ,@(...).
    $keys = Get-WDTrayIconKeys -Context $Context
    if (-not $keys.Count) { return New-WDResult -Status NotPresent -Message 'No app has shown a tray icon yet' }
    $values = foreach ($k in $keys) { [pscustomobject]@{ path = $k; name = 'IsPromoted'; kind = 'DWord'; value = 1 } }
    Invoke-WDRegistryAction -Action ([pscustomobject]@{ type = 'registry'; scope = 'machine'; values = @($values) }) -Context $Context
}

Register-WDHandler 'SetNoSoundScheme' {
    # "No Sounds" is not one value: the scheme name lives at the default of
    # AppEvents\Schemes, and every event under AppEvents\Schemes\Apps carries
    # its own.
    param($Action, $Context)

    $roots = @(Select-WDAccountHives -Hives (Get-WDUserHives) -Default $Context.DefaultHive `
                                     -Accounts (Get-WDContextAccounts $Context))
    if (-not $roots.Count) {
        return New-WDResult -Status Skipped -Message 'No accounts are selected for per-user settings'
    }

    $done = New-Object System.Collections.Generic.List[string]
    $errs = New-Object System.Collections.Generic.List[string]
    $any  = $false

    foreach ($root in $roots) {
        $schemes = Join-Path $root.Path 'AppEvents\Schemes'
        if (-not (Test-Path -LiteralPath $schemes -ErrorAction SilentlyContinue)) { continue }
        $any = $true
        if ($Context.Preview) { $done.Add($root.Name); continue }

        try {
            $backup = Backup-WDRegistryKey -Path $schemes
            $n = 0
            foreach ($app in @(Get-ChildItem -LiteralPath (Join-Path $schemes 'Apps') -ErrorAction SilentlyContinue)) {
                foreach ($ev in @(Get-ChildItem -LiteralPath $app.PSPath -ErrorAction SilentlyContinue)) {
                    $cur = Join-Path $ev.PSPath '.Current'
                    if (-not (Test-Path -LiteralPath $cur -ErrorAction SilentlyContinue)) { continue }
                    try { Set-ItemProperty -LiteralPath $cur -Name '(default)' -Value '' -Force -ErrorAction Stop; $n++ } catch { }
                }
            }
            Set-ItemProperty -LiteralPath $schemes -Name '(default)' -Value '.None' -Force -ErrorAction Stop
            $done.Add("$($root.Name) ($n sounds)")
            Add-WDJournal -ItemId $Context.ItemId -Type 'registry-key' -Target $schemes -Status 'Changed' `
                          -Undo @{ method = 'regfile'; file = $backup }
        } catch {
            $errs.Add("$($root.Name): $($_.Exception.Message)")
        }
    }

    if (-not $any) { return New-WDResult -Status NotPresent -Message 'No sound schemes found' }
    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message "Would silence every system sound for $($done.Count) account(s)" `
                            -Detail 'The whole AppEvents branch is exported first, so this reverses exactly.'
    }
    if ($done.Count -and -not $errs.Count) {
        return New-WDResult -Status Changed -Message "System sounds off for $($done.Count) account(s)" -Detail ($done -join ', ')
    }
    if ($done.Count) { return New-WDResult -Status Partial -Message "System sounds off for $($done.Count) account(s)" -Detail ($errs -join '; ') }
    New-WDResult -Status Failed -Message 'Could not change the sound scheme' -Detail ($errs -join '; ')
}

Register-WDHandler 'ClearActivityTraces' {
    param($Action, $Context)

    $roots = @(Select-WDAccountHives -Hives (Get-WDUserHives) -Default $Context.DefaultHive `
                                     -Accounts (Get-WDContextAccounts $Context))
    if (-not $roots.Count) {
        return New-WDResult -Status Skipped -Message 'No accounts are selected for per-user settings'
    }

    # Whole keys, deleted and recreated empty where Windows expects them to
    # exist.
    $keys = @(
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths'
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs'
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\OpenSavePidlMRU'
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\LastVisitedPidlMRU'
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\WordWheelQuery'
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Map Network Drive MRU'
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Applets\Regedit\Favorites'
    )
    # Values inside a key that has to stay.
    $values = @(
        @{ Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Applets\Regedit'; Name = 'LastKey' }
    )

    $cleared = 0; $errs = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        foreach ($rel in $keys) {
            $full = Join-Path $root.Path $rel
            if (-not (Test-Path -LiteralPath $full -ErrorAction SilentlyContinue)) { continue }
            if ($Context.Preview) { $cleared++; continue }
            try {
                $backup = Backup-WDRegistryKey -Path $full
                Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
                $null = New-Item -Path $full -Force -ErrorAction SilentlyContinue
                $cleared++
                Add-WDJournal -ItemId $Context.ItemId -Type 'registry-key' -Target $full -Status 'Removed' `
                              -Undo @{ method = 'regfile'; file = $backup }
            } catch { $errs.Add("$rel : $($_.Exception.Message)") }
        }
        foreach ($v in $values) {
            $full = Join-Path $root.Path $v.Path
            if (-not (Test-Path -LiteralPath $full -ErrorAction SilentlyContinue)) { continue }
            $existing = Get-ItemProperty -LiteralPath $full -Name $v.Name -ErrorAction SilentlyContinue
            if (-not ($existing -and $existing.PSObject.Properties[$v.Name])) { continue }
            if ($Context.Preview) { $cleared++; continue }
            try {
                $prev = [string]$existing.($v.Name)
                Remove-ItemProperty -LiteralPath $full -Name $v.Name -Force -ErrorAction Stop
                $cleared++
                Add-WDJournal -ItemId $Context.ItemId -Type 'registry' -Target "$full\$($v.Name)" -Status 'Changed' `
                              -Undo @{ method = 'registry'; path = $full; name = $v.Name; previous = $prev; kind = 'String'; raw = $true }
            } catch { $errs.Add("$($v.Name) : $($_.Exception.Message)") }
        }
    }

    # Jump lists and the Recent folder: per-application binaries and shortcuts
    # with no meaningful per-file undo, so they are deleted outright and the
    # risk note says so. For the same accounts as the registry half - this read
    # $env:APPDATA alone, so an elevated run from a separate admin account
    # cleared the admin's lists and left the person's own. The default profile
    # has no files of this kind to clear.
    $files = 0
    $profiles = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        if ([bool](Get-Prop $root 'Mounted' $false)) { continue }
        $dir = ''
        if ([string]$root.Name -eq 'CurrentUser') { $dir = [string]$env:USERPROFILE }
        else {
            try { $dir = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($root.Name)" -Name 'ProfileImagePath' -ErrorAction Stop).ProfileImagePath) } catch { }
        }
        if ($dir -and -not $profiles.Contains($dir)) { $profiles.Add($dir) }
    }
    foreach ($p in $profiles) {
        $recent = Join-Path $p 'AppData\Roaming\Microsoft\Windows\Recent'
        foreach ($dir in @((Join-Path $recent 'AutomaticDestinations'), (Join-Path $recent 'CustomDestinations'), $recent)) {
            if (-not (Test-Path -LiteralPath $dir -ErrorAction SilentlyContinue)) { continue }
            # No -Force on the listing: Recent carries a hidden desktop.ini that
            # names the folder, and that is not a record of anything.
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
                if ($Context.Preview) { $files++; continue }
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $files++ } catch { }
            }
        }
    }

    $what = "$cleared registry list(s) and $files recent-file record(s)"
    if ($Context.Preview) {
        return New-WDResult -Status Removed -Message "Would clear $what" `
                            -Detail 'Quick Access, the Run box history and every jump list go back to empty.'
    }
    if ($errs.Count -and -not $cleared) {
        return New-WDResult -Status Failed -Message 'Nothing could be cleared' -Detail ($errs -join '; ')
    }
    if ($errs.Count) { return New-WDResult -Status Partial -Message "Cleared $what" -Detail ($errs -join '; ') }
    New-WDResult -Status Removed -Message "Cleared $what" `
                 -Detail 'Explorer rebuilds these as you work. Sign out and back in to see the taskbar jump lists empty.'
}

# Explorer draws the overlay from whatever Shell Icons\29 points at, so the fix
# is a transparent icon rather than a value Windows understands as "off".
function New-WDBlankIcon {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue
        }
        $xor  = 16 * 16 * 4          # BGRA, every byte zero, so alpha is zero
        $and  = 16 * 4               # one bit per pixel, padded to 32 bits a row
        $img  = 40 + $xor + $and
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter $ms
        # ICONDIR
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)
        # ICONDIRENTRY
        $bw.Write([byte]16); $bw.Write([byte]16); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$img); $bw.Write([uint32]22)
        # BITMAPINFOHEADER. Height is doubled because the bitmap carries the
        # color rows and the AND mask rows one after the other.
        $bw.Write([uint32]40); $bw.Write([int32]16); $bw.Write([int32]32)
        $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]0)
        $bw.Write([uint32]($xor + $and))
        $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)
        $bw.Write((New-Object byte[] $xor))
        # AND mask all ones: transparent for anything that reads the mask rather
        # than the alpha channel.
        $mask = New-Object byte[] $and
        for ($i = 0; $i -lt $and; $i++) { $mask[$i] = 0xFF }
        $bw.Write($mask)
        $bw.Flush()
        [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
        $bw.Dispose(); $ms.Dispose()
        $Path
    } catch {
        Write-WDLog "Could not write the blank icon: $($_.Exception.Message)" -Level Warn
        ''
    }
}

Register-WDHandler 'SetShortcutArrow' {
    param($Action, $Context)

    $root = ''
    try { $root = [string]$Context.Session.Root } catch { }
    if (-not $root) { $root = Join-Path $env:ProgramData 'WinSetupToolkit' }
    $ico = Join-Path $root 'blank-arrow.ico'

    # Built once, so the preview and the apply cannot disagree about what
    # "already done" means.
    $act = [pscustomobject]@{
        type = 'registry'; scope = 'machine'
        values = @([pscustomobject]@{
            path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons'
            name = '29'; kind = 'String'; value = "$ico,0"
        })
    }
    # Idempotent, and it never said so: run twice, the second preview still
    # promised to point the overlay at an icon it already points at. The icon
    # file has to be there as well as the value.
    $done = (Test-Path -LiteralPath $ico) -and (Test-WDRegistryActionSatisfied -Action $act)
    if ($done) {
        return New-WDResult -Status AlreadySet -Message 'The shortcut overlay already points at the blank icon' `
                            -Detail "Shell Icons\29 is $ico,0"
    }
    # A blank overlay from an earlier build can point into a data folder this
    # toolkit no longer uses - C:\ProgramData\WinDebloat on machines that ran it
    # before the rename - and deleting that folder would leave the overlay
    # pointing at nothing. Moving it here is the change, and the message says so.
    $was = ''
    try {
        $was = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons' `
                                         -Name '29' -ErrorAction Stop).'29'
    } catch { }
    $moving = ($was -match '\\blank-arrow\.ico,0$') -and ($was -ne "$ico,0")
    if ($Context.Preview) {
        if ($moving) {
            return New-WDResult -Status Changed -Message 'Would move the blank overlay icon into the toolkit''s current folder' `
                                -Detail "Shell Icons\29 points at $was; writes $ico and points it there instead."
        }
        return New-WDResult -Status Changed -Message 'Would point the shortcut overlay at a blank icon' `
                            -Detail "Writes $ico and sets Shell Icons\29 to it."
    }
    $hadIcon = Test-Path -LiteralPath $ico
    if (-not (New-WDBlankIcon -Path $ico)) {
        return New-WDResult -Status Failed -Message 'Could not create the blank icon the overlay needs'
    }
    # The icon is this run's file, so undoing the run takes it away again rather
    # than leaving a stray .ico in the data folder.
    if (-not $hadIcon) {
        Add-WDJournal -ItemId $Context.ItemId -Type 'file' -Target $ico -Status 'Changed' `
                      -Undo @{ method = 'file-restore'; file = $null; target = $ico }
    }

    $res = Invoke-WDRegistryAction -Context $Context -Action $act
    if ([string]$res.Status -notin @('Changed','Removed')) { return $res }

    # Explorer caches the overlay, so the value alone changes nothing until the
    # cache is dropped.
    $cleared = 0
    foreach ($p in @(Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $p -Filter 'iconcache*' -File -ErrorAction SilentlyContinue)) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $cleared++ } catch { }
        }
    }
    New-WDResult -Status Changed -Message 'Shortcut overlay arrow removed' `
                 -Detail "Icon cache entries cleared: $cleared. Explorer restarts at the end of this run, which is when it takes effect."
}

# The GUI collects the figure and it crosses on run-options.json, as the browser
# choice does.
$script:WDDeferKinds = @{
    'feature' = @{ Flag = 'DeferFeatureUpdates'; Days = 'DeferFeatureUpdatesPeriodInDays'; Max = 365; Option = 'deferFeatureDays' }
    'quality' = @{ Flag = 'DeferQualityUpdates'; Days = 'DeferQualityUpdatesPeriodInDays'; Max = 30;  Option = 'deferQualityDays' }
}

Register-WDHandler 'SetUpdateDeferral' {
    param($Action, $Context)

    $kind = [string](Get-Prop $Action 'kind' 'feature')
    if (-not $script:WDDeferKinds.ContainsKey($kind)) {
        return New-WDResult -Status Failed -Message "Unknown deferral kind '$kind'"
    }
    $spec = $script:WDDeferKinds[$kind]
    $days = [int](Get-Prop $Action 'days' $spec.Max)

    $root = ''
    try { $root = [string]$Context.Session.Root } catch { }
    $chosen = Get-WDRunOption -Root $root -Name ([string]$spec.Option) -Default $null
    if ($null -ne $chosen) { $days = [int]$chosen }
    # Clamped rather than trusted: the file is editable, and Windows silently
    # ignores a period outside its range, which looks exactly like the policy
    # never being written.
    if ($days -lt 0) { $days = 0 }
    if ($days -gt [int]$spec.Max) { $days = [int]$spec.Max }

    $base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $vals = @(
        [pscustomobject]@{ path = $base; name = [string]$spec.Flag; kind = 'DWord'; value = 1 }
        [pscustomobject]@{ path = $base; name = [string]$spec.Days; kind = 'DWord'; value = $days }
    )
    # No BranchReadinessLevel. It used to be written as 20 ("Semi-Annual
    # Channel"), and on 25H2 it is no element of this policy at all: it moved to
    # Manage preview builds, whose list is 2, 4, 8, and 64 - 20 is not one of
    # them - and with that policy not configured Windows offers no preview
    # builds anyway, so general availability is already what is measured from.
    $res = Invoke-WDRegistryAction -Action ([pscustomobject]@{ type = 'registry'; scope = 'machine'; values = $vals }) -Context $Context
    if ([string]$res.Status -in @('Changed','Removed')) {
        $unit = $(if ($days -eq 1) { 'day' } else { 'days' })
        return New-WDResult -Status Changed -Message "$kind updates held back for $days $unit" `
                            -Detail 'Settings has no page for this - it is a policy. Undo this option from the toolkit to clear it.'
    }
    $res
}

# "Receive updates for other Microsoft products" is a service registration, not
# a value: Microsoft Update (this id) registered with Automatic Updates is what
# makes Windows Update scan for Office and the rest. The AllowMUUpdateService
# policy can only force it ON - Microsoft's Update CSP says setting it back to 0
# "doesn't revert the configuration" and names RemoveService as the way out - so
# the item used to write a 0 into a key the policy does not even live under, and
# did nothing either way.
$script:WDMicrosoftUpdateId = '7971f918-a847-4430-9279-4a52d1efe18d'

function Test-WDMicrosoftUpdateOn {
    # $null when the update agent cannot be asked.
    try {
        $sm = New-Object -ComObject 'Microsoft.Update.ServiceManager'
        foreach ($s in @($sm.Services)) {
            if ([string]$s.ServiceID -eq $script:WDMicrosoftUpdateId) { return [bool]$s.IsRegisteredWithAU }
        }
        return $false
    } catch { return $null }
}

Register-WDHandler 'DisableMicrosoftUpdateService' {
    param($Action, $Context)

    $on = Test-WDMicrosoftUpdateOn
    if ($null -eq $on) {
        return New-WDResult -Status Obstruction -Message 'The Windows Update agent could not be asked whether Microsoft Update is registered'
    }
    # The toggle's own record of the choice, through the executor so the
    # previous value is journalled. Written whichever way the registration was,
    # so the Settings page cannot read one answer while the service says another.
    $ux = [pscustomobject]@{ type = 'registry'; scope = 'machine'; values = @(
        [pscustomobject]@{ path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; name = 'AllowMUUpdateService'; kind = 'DWord'; value = 0 }) }
    # Off already is the answer whatever the record says; in an apply the record
    # is brought into line on the way past, journalled like any value.
    if (-not $on) {
        if (-not $Context.Preview) { $null = Invoke-WDRegistryAction -Action $ux -Context $Context }
        return New-WDResult -Status AlreadySet -Message 'Updates for other Microsoft products are already off'
    }
    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message 'Would turn off updates for other Microsoft products' `
                            -Detail 'Unregisters the Microsoft Update service from Automatic Updates, as the Settings switch does.'
    }
    try {
        $sm = New-Object -ComObject 'Microsoft.Update.ServiceManager'
        $sm.RemoveService($script:WDMicrosoftUpdateId)
    } catch {
        $why = $_.Exception.Message
        if (Test-WDElevationError -Message $why) { return New-WDResult -Status Blocked -Message 'Needs administrator rights' -Detail $why }
        return New-WDResult -Status Failed -Message 'Microsoft Update could not be unregistered' -Detail $why
    }
    Add-WDJournal -ItemId $Context.ItemId -Type 'update-service' -Target $script:WDMicrosoftUpdateId -Status 'Changed' `
                  -Undo @{ method = 'mu-service'; name = $script:WDMicrosoftUpdateId }
    $null = Invoke-WDRegistryAction -Action $ux -Context $Context
    if (Test-WDMicrosoftUpdateOn) {
        return New-WDResult -Status Failed -Message 'Microsoft Update is still registered after removing it'
    }
    New-WDResult -Status Changed -Message 'Updates for other Microsoft products turned off'
}

# Windows' own answer to "how long may a restart be put off": the quality-update
# deadline policy, which Microsoft names as the replacement for the
# no-auto-restart-with-users policy. Before the deadline Windows may restart
# only outside active hours, which is what the restart hold moves; once it
# passes, Windows restarts after a fifteen-minute warning, active hours or not.
# The quality half only: a feature-update deadline would force the annual
# upgrade the deferral option exists to hold back.
Register-WDHandler 'SetRestartDeadline' {
    param($Action, $Context)

    $days  = [int](Get-Prop $Action 'days' 7)
    $grace = [int](Get-Prop $Action 'grace' 2)
    $root = ''
    try { $root = [string]$Context.Session.Root } catch { }
    $chosen = Get-WDRunOption -Root $root -Name 'restartDeadlineDays' -Default $null
    if ($null -ne $chosen) { $days = [int]$chosen }
    # Windows' own ranges, and a value outside one is silently ignored.
    if ($days -lt 0)  { $days = 0 }
    if ($days -gt 30) { $days = 30 }
    if ($grace -lt 0) { $grace = 0 }
    if ($grace -gt 7) { $grace = 7 }

    $base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $vals = @(
        [pscustomobject]@{ path = $base; name = 'SetComplianceDeadlineForQU';         kind = 'DWord'; value = 1 }
        [pscustomobject]@{ path = $base; name = 'ConfigureDeadlineForQualityUpdates'; kind = 'DWord'; value = $days }
        [pscustomobject]@{ path = $base; name = 'ConfigureDeadlineGracePeriod';       kind = 'DWord'; value = $grace }
        # Off, so before the deadline Windows may still restart outside active
        # hours - which is when nobody is signed in, while the hold runs.
        [pscustomobject]@{ path = $base; name = 'ConfigureDeadlineNoAutoRebootForQualityUpdates'; kind = 'DWord'; value = 0 }
    )
    $res = Invoke-WDRegistryAction -Action ([pscustomobject]@{ type = 'registry'; scope = 'machine'; values = $vals }) -Context $Context
    if ([string]$res.Status -in @('Changed', 'Removed')) {
        $unit = $(if ($days -eq 1) { 'day' } else { 'days' })
        return New-WDResult -Status Changed -Message "Overdue security updates restart after $days $unit" `
                            -Detail ("Counted from when Windows Update first finds the update, and never sooner than $grace " +
                                     "day(s) after it is ready to restart. Windows warns fifteen minutes before. Undo this run to remove it.")
    }
    $res
}

Register-WDHandler 'WriteCommonIssues' {
    param($Action, $Context)

    $items = @()
    try { $items = @($Context.Plan) } catch { }
    # Its own row would be in the list and has nothing to go wrong with.
    $items = @($items | Where-Object { $_ -and [string]$_.Id -ne [string]$Context.ItemId })

    # The journal is where the previous values live, and they are the difference
    # between "set it to 0" and "set it back to 1".
    $undoBy = @{}
    try {
        $jf = [string](Get-Prop $Context.Session 'JournalFile' '')
        if ($jf -and (Test-Path -LiteralPath $jf)) {
            foreach ($line in (Get-Content -LiteralPath $jf -ErrorAction SilentlyContinue)) {
                if (-not $line.Trim()) { continue }
                try {
                    $e = $line | ConvertFrom-Json
                    $k = [string]$e.item
                    if (-not $k) { continue }
                    if (-not $undoBy.ContainsKey($k)) { $undoBy[$k] = New-Object System.Collections.Generic.List[psobject] }
                    $undoBy[$k].Add($e)
                } catch { }
            }
        }
    } catch { }

    $rows = New-Object System.Collections.Generic.List[psobject]
    foreach ($it in $items) {
        $seedPhrases = @(Get-Prop $it 'Symptoms' @())
        if (-not $seedPhrases.Count) { continue }
        $id = [string](Get-Prop $it 'Id' '')
        $mine = @()
        if ($undoBy.ContainsKey($id)) { $mine = @($undoBy[$id]) }
        $rows.Add([pscustomobject]@{
            Name    = [string](Get-Prop $it 'Name' $id)
            Id      = $id
            # Authored seeds first, then every other way each gets typed:
            # somebody searching "cant access account info" has to land here
            # too.
            Phrases = @(Expand-WDSymptoms -Phrases $seedPhrases)
            # Kept separately for the word index, which must be built from these
            # and not from the expansion - every generated variant is made of
            # the same words plus filler the generator supplied.
            Seeds   = $seedPhrases
            Routes  = @(Get-WDItemRevertRoutes -Item $it -JournalEntries $mine)
        })
    }

    # Into the run directory, always, under the name the session declares. It
    # used to ask a run option where to put it, which meant nothing else in the
    # toolkit could find what it had written.
    $path = ''
    try { $path = [string]$Context.Session.IssuesFile } catch { }
    if (-not $path) {
        $dir = ''
        try { $dir = [string](Get-Prop $Context.Session 'RunDir' '') } catch { }
        if (-not $dir) { $dir = [Environment]::GetFolderPath('Desktop') }
        $path = Join-Path $dir 'Common-issues.txt'
    }
    $dir = Split-Path -Parent $path

    if ($Context.Preview) {
        # The desktop copy - see the same block in WriteRollbackScript.
        $where = $null
        try { $where = Get-WDDesktopRunFolder -Session $Context.Session } catch { }
        if ($where -and $where.Ok) {
            return New-WDResult -Status Changed -Message "Would write a lookup file for $($rows.Count) option(s)" `
                                -Detail (Join-Path ([string]$where.Path) 'Common issues lookup and reversion instructions.txt')
        }
        return New-WDResult -Status Changed -Message "Would write a lookup file for $($rows.Count) option(s), but not to the desktop" `
                            -Detail "$(if ($where) { [string]$where.Why } else { 'The desktop folder could not be resolved.' }) It would go to $path"
    }

    $sb = New-Object System.Text.StringBuilder
    $w  = { param([string]$Line) $null = $sb.AppendLine($Line) }

    $bar = '---------------------------------------------------------------------------'

    & $w 'WINDOWS SETUP TOOLKIT - COMMON ISSUES, AND HOW TO UNDO ANY ONE OF THEM'
    & $w '========================================================================'
    & $w ''
    & $w 'HOW TO USE THIS FILE'
    & $w ''
    & $w 'Press ctrl+F and type what is wrong, in whatever words you would use: "no'
    & $w 'sound", "camera not working", "cant print", "search finds nothing". If one of'
    & $w 'the options below is the cause, you will land on it - each one lists the'
    & $w 'phrases people use for the problems it can cause, spelled several ways.'
    & $w ''
    & $w 'Under each option is every way to put that ONE thing back, step by step. They'
    & $w 'are listed narrowest first, so the earlier ones change nothing else. The very'
    & $w 'last one on every option undoes the whole run rather than just that option.'
    & $w ''
    & $w $bar
    & $w ''

    # A word index, for the reader whose problem is one word rather than a
    # phrase. Only words spanning two or more options earn a line.
    $wordMap = @{}
    $stop = New-WDStringSet @('the','and','not','for','with','from','this','that','have','has','are','was',
                              'cannot','cant','can','does','doesnt','dont','wont','isnt','will','all','any',
                              'app','apps','out','off','set','get','see','its','only','some','more','than',
                              'when','what','why','how','where','did','doing','done','been','being','into',
                              'after','before','still','just','very','now','new','old','one','two','back',
                              'about','again','also','anymore','longer','stopped','broken','missing','gone',
                              'working','work','works','error','slow','empty','blocked','denied','access',
                              'disappeared','showing','there','found','detected','disabled','turned',
                              'switched','enable','allowed','nothing','ages','slower','suddenly')
    foreach ($r in $rows) {
        $mine = New-WDStringSet @()
        # Seeds, never the expansion. Apostrophes are dropped rather than split
        # on, or "doesn't" arrives as the two tokens "doesn" and "t".
        foreach ($p in @($r.Seeds)) {
            foreach ($tok in ([regex]::Split((([string]$p).ToLower() -replace "'", ''), '[^a-z0-9]+'))) {
                if ($tok.Length -lt 4) { continue }
                if ($stop.Contains($tok)) { continue }
                $null = $mine.Add($tok)
            }
        }
        foreach ($tok in $mine) {
            if (-not $wordMap.ContainsKey($tok)) { $wordMap[$tok] = New-Object System.Collections.Generic.List[string] }
            $wordMap[$tok].Add($r.Name)
        }
    }
    $shared = @($wordMap.Keys | Where-Object { $wordMap[$_].Count -ge 2 } | Sort-Object)
    if ($shared.Count) {
        & $w 'ONE WORD AT A TIME'
        & $w ''
        & $w 'Words that more than one option below could be blamed for. Search the option'
        & $w 'name beside a word to jump to it.'
        & $w ''
        foreach ($tok in $shared) {
            $names = @($wordMap[$tok] | Sort-Object -Unique)
            & $w ("  {0}  {1}" -f $tok.PadRight(22), ($names -join '; '))
        }
        & $w ''
        & $w $bar
        & $w ''
    }

    foreach ($r in ($rows | Sort-Object Name)) {
        & $w ($r.Name.ToUpper())
        & $w ''
        foreach ($p in @($r.Phrases)) { & $w "  $p" }
        & $w ''
        & $w '  HOW TO PUT THIS BACK'
        $n = 0
        foreach ($route in @($r.Routes)) {
            $n++
            & $w ''
            & $w "    Option $n - $($route.Title)"
            $s = 0
            foreach ($step in @($route.Steps)) {
                $s++
                & $w "      $s. $step"
            }
        }
        if (-not $n) {
            & $w '    Open the toolkit, choose Revert past changes, and untick everything except this one.'
        }
        & $w ''
        & $w $bar
        & $w ''
    }

    if (-not $rows.Count) {
        & $w 'Nothing in this run has any known side effect worth looking up.'
        & $w ''
    }

    try {
        $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $path -Value $sb.ToString() -Encoding UTF8
    } catch {
        return New-WDResult -Status Failed -Message 'Could not write the common issues document' -Detail $_.Exception.Message
    }
    Write-WDLog "Common issues document written to $path" -Level Info -Item $Context.ItemId
    New-WDResult -Status Changed -Message "Lookup file written for $($rows.Count) option(s)" -Detail $path
}

# A row rather than something that simply happens: written unconditionally it
# was invisible, with no preview line and no way to confirm it was coming before
# Apply.
Register-WDHandler 'WriteRollbackScript' {
    param($Action, $Context)

    $path = $null
    try { $path = Join-Path $Context.Session.RunDir 'Undo-WinSetupToolkit.ps1' } catch { }
    if ($Context.Preview) {
        # The desktop copy, not the run directory: that is under %ProgramData%,
        # which Explorer hides, and this item's own description promises the
        # desktop.
        $where = $null
        try { $where = Get-WDDesktopRunFolder -Session $Context.Session } catch { }
        if ($where -and $where.Ok) {
            return New-WDResult -Status Changed -Message 'Would write the rollback script' `
                                -Detail (Join-Path ([string]$where.Path) 'Undo-WinSetupToolkit.ps1')
        }
        # Said, rather than quietly falling back to a path that contradicts the
        # description.
        return New-WDResult -Status Changed -Message 'Would write the rollback script, but not to the desktop' `
                            -Detail "$(if ($where) { [string]$where.Why } else { 'The desktop folder could not be resolved.' }) It would go to $path"
    }
    try {
        # The plan, so the window can group by option name and category. Nobody
        # can decide about a row labelled "perm-account-info".
        $null = Export-WDUndoScript -Items (Get-Prop $Context 'Plan' $null)
    } catch {
        return New-WDResult -Status Failed -Message 'Could not write the rollback script' -Detail $_.Exception.Message
    }
    if ($path -and -not (Test-Path -LiteralPath $path)) {
        return New-WDResult -Status Failed -Message 'The rollback script was not created' -Detail $path
    }
    Write-WDLog "Rollback script written to $path" -Level Info -Item $Context.ItemId
    New-WDResult -Status Changed -Message 'Rollback script written' -Detail $path
}

Export-ModuleMember -Function Register-WDHandler, Invoke-WDScriptAction, Get-WDHandlerNames,
                              Set-WDPowerToysRemap, Set-WDNativeCopilotKey, Get-WDResidueTokens,
                              Get-WDResidueFlat, New-WDResidueMatcher, New-WDResidueKeep, Test-WDResidueName,
                              Write-WDJsonNoBom, Test-WDFileHasBom,
                              Get-WDPowerToysRoot, Set-WDPowerToysJson, New-WDBlankIcon,
                              Test-WDPowerToysModuleSet, Test-WDActionSatisfied,
                              Test-WDItemSatisfied,
                              Get-WDStateTestNames,
                              Measure-WDFolder, Measure-WDFolderDetail, Format-WDBytes, Clear-WDFolderContents,
                              Get-WDStorageSources, Get-WDStoragePaths, Measure-WDRecycleBin,
                              Measure-WDReclaimable, Measure-WDDiskBuckets,
                              New-WDStorageSnapshot, Get-WDStorageReport, Get-WDDiskCapacity, Stop-WDDiskWalk
