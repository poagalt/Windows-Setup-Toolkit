<#
    WD.Custom - handlers for things a declarative manifest cannot express.

    Manifest entries reach these via {"type":"script","handler":"Name"}.
    Same contract as every other executor: never throw, always return a result.
#>

$script:Handlers = @{}

function Register-WDHandler {
    param([string]$Name, [scriptblock]$Body)
    $script:Handlers[$Name] = $Body
}

function Get-WDHandlerNames {
    <#  Lets the self test prove every handler a manifest references exists.  #>
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

# ============================================================ Copilot key ===
#
# The Copilot key does not emit one scancode. Firmware sends the chord
# Left Shift + Left Win + F23 (F23 is scancode 0x6E, virtual key 134). That is
# why the usual HKLM Scancode Map trick cannot fix it: remapping 0x6E leaves
# the Shift and Win presses intact, so you get a chord instead of a clean
# Right Ctrl. Two things actually work, tried in order of preference.

$script:VK = @{ LWin = 91; Shift = 16; LShift = 160; F23 = 134; RCtrl = 163 }

Register-WDHandler 'CopilotKeyToRightCtrl' {
    param($Action, $Context)

    # $machine, not $profile: that is an automatic variable holding the path to
    # the PowerShell profile script, and shadowing it reads as a bug.
    $machine = $Context.Profile
    if ($machine.CopilotKey -eq 'Absent') {
        return New-WDResult -Status NotPresent -Message 'No Copilot key on this keyboard'
    }

    # --- Preferred: the native setting Microsoft added in build 27500 -------
    if ($machine.Build -ge 27500) {
        $r = Set-WDNativeCopilotKey -Context $Context
        if ($r.Status -in @('Changed','Removed')) { return $r }
        Write-WDLog 'Native Copilot key setting unavailable, falling back to PowerToys.' -Level Info -Item $Context.ItemId
    }

    # --- Fallback that works on every current build: PowerToys -------------
    if (-not (Test-WDPowerToys)) {
        if ($Context.Preview) {
            return New-WDResult -Status Changed -Message 'Would install PowerToys and map Win+Shift+F23 to Right Ctrl'
        }
        if (-not $Context.Profile.HasWinget) {
            return New-WDResult -Status Skipped -Message 'PowerToys needed for the remap but winget is unavailable' `
                                -Detail 'Install PowerToys manually, then re-run this item.'
        }
        Write-WDLog 'Installing PowerToys (needed for the Copilot key remap)...' -Level Info -Item $Context.ItemId
        $res = Invoke-WDProcess -FilePath 'winget.exe' -TimeoutSeconds 900 -ArgumentList @(
            'install','--id','Microsoft.PowerToys','--exact','--silent',
            '--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
        if ($res.ExitCode -ne 0) {
            return New-WDResult -Status Failed -Message 'PowerToys install failed' -Detail "winget exit $($res.ExitCode)"
        }
    }

    Set-WDPowerToysRemap -Context $Context
}

function Set-WDNativeCopilotKey {
    <#
        Windows 11 build 27500+ exposes Settings > Bluetooth & devices >
        Keyboard > Copilot key > Right Ctrl. The backing value moved during
        flighting, so write every known location and verify by reading back.
        Returning anything other than Changed makes the caller use PowerToys.
    #>
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
    <#
        Writes the chord remap straight into Keyboard Manager's config so the
        user never has to open the GUI. Existing remaps are merged, not
        clobbered - people have their own mappings and losing them would be a
        nasty surprise from a debloat tool.
    #>
    param($Context)

    $ptRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys'
    $kbmDir = Join-Path $ptRoot 'Keyboard Manager'
    $cfg    = Join-Path $kbmDir 'default.json'

    # The chord as PowerToys records it. Windows reports the modifier as either
    # generic Shift or Left Shift depending on the keyboard driver, so map both.
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
        if (Test-Path -LiteralPath $cfg) {
            Copy-Item -LiteralPath $cfg -Destination "$cfg.wdbak" -Force -ErrorAction SilentlyContinue
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
        $json | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfg -Encoding UTF8

        # Make sure the module is actually switched on.
        $ptSettings = Join-Path $ptRoot 'settings.json'
        if (Test-Path -LiteralPath $ptSettings) {
            try {
                $s = Get-Content -LiteralPath $ptSettings -Raw | ConvertFrom-Json
                if ($s.PSObject.Properties['enabled']) {
                    $s.enabled | Add-Member -NotePropertyName 'Keyboard Manager' -NotePropertyValue $true -Force
                    $s | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ptSettings -Encoding UTF8
                }
            } catch { }
        }

        Add-WDJournal -ItemId $Context.ItemId -Type 'copilot-key' -Target $cfg -Status 'Changed' `
                      -Undo @{ method = 'file-restore'; file = "$cfg.wdbak"; target = $cfg }

        # PowerToys reads its config only at start, so bounce it if running.
        #
        # THE ENGINE IS A SEPARATE PROCESS AND IS THE ONE THAT MATTERS.
        # KeyboardManagerEngine loads default.json and does the remapping;
        # PowerToys.exe is only the launcher. Stopping the launcher alone leaves
        # the engine holding the old config, so the remap is on disk and has no
        # effect - and the symptom is the Copilot key behaving as before with
        # everything on disk looking correct.
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

        # Read back what is actually on disk rather than reporting the intent.
        # PowerToys owns this file and rewrites it in its own format when it
        # feels like it, so "we wrote it" and "it says what we wrote" are two
        # different claims and only the second is worth making.
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

        # Still not "the key now acts as Right Ctrl". That is a claim about what
        # happens when somebody presses it, and nothing here has pressed it -
        # the honest version names what was changed and what it depends on.
        New-WDResult -Status Changed `
            -Message 'Copilot key remapped to Right Ctrl in PowerToys' `
            -Detail "$added mapping(s) written to Keyboard Manager and confirmed in the config. PowerToys must stay installed and running at login for this to keep working."
    } catch {
        New-WDResult -Status Failed -Message 'Could not write PowerToys remap' -Detail $_.Exception.Message
    }
}

# ============================================================== OneDrive ====

Register-WDHandler 'RemoveOneDrive' {
    param($Action, $Context)

    $steps  = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]

    # ---- Known Folder Move, and this has to happen FIRST -------------------
    #
    # OneDrive's "back up your folders" repoints Documents, Pictures, and Desktop
    # at C:\Users\<me>\OneDrive\<name>. Uninstalling OneDrive does not put them
    # back - it removes what kept those paths populated, so the redirection names
    # a folder that is not there and GetFolderPath('MyDocuments') returns an
    # EMPTY STRING. Every program that saves to Documents asks the shell for that
    # path, and there is no longer an answer.
    #
    # It is also the most alarming way this can go wrong: "my Documents folder is
    # gone" reads as the debloat tool having deleted it. It did not - the files
    # are in the OneDrive account and no run touches user data.
    #
    # So, before the uninstaller: point any known folder inside OneDrive back at
    # the local profile, creating it if missing. Journalled, so a rollback
    # restores the redirection for anyone who wants OneDrive back.
    $kfmRoot = Join-Path $env:USERPROFILE 'OneDrive'
    $shellKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $kfm = @(
        @{ Name = 'Personal';    Local = (Join-Path $env:USERPROFILE 'Documents') },
        @{ Name = 'My Pictures'; Local = (Join-Path $env:USERPROFILE 'Pictures') },
        @{ Name = 'My Video';    Local = (Join-Path $env:USERPROFILE 'Videos') },
        @{ Name = 'My Music';    Local = (Join-Path $env:USERPROFILE 'Music') },
        @{ Name = 'Desktop';     Local = (Join-Path $env:USERPROFILE 'Desktop') }
    )
    $moved = New-Object System.Collections.Generic.List[string]
    foreach ($k in $kfm) {
        $cur = ''
        try { $cur = [string](Get-ItemProperty -LiteralPath $shellKey -Name $k.Name -ErrorAction Stop).$($k.Name) } catch { continue }
        if (-not $cur) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($cur)
        if (-not $expanded.StartsWith($kfmRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $moved.Add($k.Name)
        if ($Context.Preview) { continue }
        try {
            if (-not (Test-Path -LiteralPath $k.Local)) {
                $null = New-Item -ItemType Directory -Path $k.Local -Force -ErrorAction Stop
            }
            Add-WDJournal -ItemId $Context.ItemId -Type 'registry' -Target "$shellKey\$($k.Name)" -Status 'Changed' `
                          -Undo @{ method = 'registry'; path = $shellKey; name = $k.Name; kind = 'ExpandString'; previous = $cur; raw = $true }
            Set-ItemProperty -LiteralPath $shellKey -Name $k.Name -Value $k.Local -Type ExpandString -Force -ErrorAction Stop
            Write-WDLog "$($k.Name) was redirected into OneDrive; pointed back at $($k.Local) so it still resolves once OneDrive is gone. Anything stored in the OneDrive copy stays in your OneDrive account." `
                        -Level Warn -Item $Context.ItemId
        } catch {
            $failed.Add("could not point $($k.Name) back at the local profile: $($_.Exception.Message)")
        }
    }
    if ($moved.Count) {
        $steps.Add("$($moved.Count) folder(s) pointed back at this PC ($($moved -join ', '))")
    }

    if (-not $Context.Preview) {
        Get-Process -Name 'OneDrive','FileCoAuth','Microsoft.SharePoint' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }

    # OneDrive ships its own uninstaller in both bitnesses and both scopes.
    $setups = @(
        (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'),
        (Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDriveSetup.exe')
    )
    foreach ($dir in (Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive') -Directory -ErrorAction SilentlyContinue)) {
        $candidate = Join-Path $dir.FullName 'OneDriveSetup.exe'
        if (Test-Path -LiteralPath $candidate) { $setups += $candidate }
    }

    $ran = $false
    foreach ($s in ($setups | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $s)) { continue }
        $ran = $true
        if ($Context.Preview) { $steps.Add("uninstall via $(Split-Path $s -Leaf)"); continue }
        $r = Invoke-WDProcess -FilePath $s -ArgumentList @('/uninstall') -TimeoutSeconds 300
        if ($r.ExitCode -in @(0, 3010)) { $steps.Add('uninstaller ran') } else { $failed.Add("setup exit $($r.ExitCode)") }
    }

    if (-not $Context.Preview) {
        # Explorer navigation pane entries, both bitnesses.
        foreach ($clsid in @(
            'HKCR:\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
            'HKCR:\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}')) {
            $psPath = $clsid -replace '^HKCR:', 'Registry::HKEY_CLASSES_ROOT'
            if (Test-Path -LiteralPath $psPath) {
                try {
                    Set-ItemProperty -LiteralPath $psPath -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord -Force -EA Stop
                    $steps.Add('removed from Explorer sidebar')
                } catch { $failed.Add('Explorer sidebar entry') }
            }
        }
        # Startup entry for the current user.
        try {
            Remove-ItemProperty -LiteralPath 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
                                -Name 'OneDrive' -Force -EA SilentlyContinue
        } catch { }
        # Its own update task.
        Get-ScheduledTask -TaskName 'OneDrive*' -ErrorAction SilentlyContinue |
            Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
        $steps.Add('scheduled tasks removed')
    }

    if (-not $ran -and -not $steps.Count) { return New-WDResult -Status NotPresent -Message 'OneDrive not installed' }
    if ($failed.Count -and -not $steps.Count) { return New-WDResult -Status Failed -Message 'OneDrive removal failed' -Detail ($failed -join '; ') }
    New-WDResult -Status Removed -Message 'OneDrive removed' -Detail (($steps | Sort-Object -Unique) -join ', ')
}

# ========================================================= vendor scrubs ====

Register-WDHandler 'McAfeeScrub' {
    <#
        McAfee's own uninstallers routinely leave drivers, services and a
        filter driver behind. MCPR is the vendor's supported cleanup tool and
        is the only reliable way to finish the job - but it is a download, so
        it is offered rather than assumed.
    #>
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

    $url = 'https://download.mcafee.com/molbin/iss-loc/SupportTools/MCPR/MCPR.exe'
    $dst = Join-Path $Context.Session.RunDir 'MCPR.exe'
    try {
        Write-WDLog "Downloading McAfee MCPR from $url" -Level Info -Item $Context.ItemId
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -TimeoutSec 180
        $r = Invoke-WDProcess -FilePath $dst -TimeoutSeconds 1200
        Set-WDRebootNeeded
        New-WDResult -Status Removed -Message 'McAfee removed and scrubbed with MCPR' `
                     -Detail "MCPR exit $($r.ExitCode). Reboot required." -Reboot
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
    <#
        After third-party AV is removed, Defender should take back over. It
        sometimes needs a nudge, and silently having no AV is worse than any
        bloatware, so this is checked rather than assumed.
    #>
    param($Action, $Context)

    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        if ($status.AntivirusEnabled -and $status.RealTimeProtectionEnabled) {
            # A check that passed. Nothing was done and nothing needed to be,
            # which is what the grey status says - where Changed claimed this
            # row was one of the things about to alter the machine.
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

# ScanVendorApps was removed deliberately: it re-listed the discovered-software
# rows with every safety filter taken off - keep-listed vendor tools,
# manifest-covered products, and the SystemComponent sub-entries the scan exists
# to suppress - and wrote them to a text file.
#
# The only set the scan genuinely drops is uninstall entries with neither an
# UninstallString nor a QuietString, since there is nothing to run. If that list
# is ever wanted it needs a row that says so.

Register-WDHandler 'RemoveInstallShortcuts' {
    <#
        "Install without a desktop shortcut", after the fact. There is no
        portable winget switch for it, so the only honest way to offer the
        preference is to clear up behind the installers.

        NOT the same as `desktop-shortcuts`, which is tier 3 and takes every
        shortcut including ones the person made. This removes only what appeared
        during THIS run.

        Decided on "newer than the run's start" rather than a before-and-after
        snapshot: a snapshot needs a handler that runs twice with state in
        between, and the timestamp answers the same question with nothing to keep
        in sync. The cost is a shortcut made by hand mid-run, which does not
        really arise.

        order 94, after the installs at 88-93, so the files exist by then.
    #>
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
    # somebody's desktop and getting it wrong should cost a drag out of the bin,
    # not a reinstall.
    $gone = 0
    foreach ($f in $found) {
        if (Remove-WDToRecycleBin -Path $f.FullName) {
            $gone++
            Add-WDJournal -ItemId $Context.ItemId -Type 'file' -Target $f.FullName -Status 'Removed' `
                          -Undo @{ method = 'recycle'; path = $f.FullName }
        }
    }
    if (-not $gone) {
        return New-WDResult -Status Blocked -Message 'The new shortcuts could not be moved to the Recycle Bin'
    }
    New-WDResult -Status Removed -Message "$gone new desktop shortcut(s) removed" `
                 -Detail "$($names -join ', '). Only shortcuts created during this run were touched."
}

# Startup entries that must survive even though they are not "programs" in the
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

Register-WDHandler 'DisableStartupEntries' {
    <#
        Disables every login item that is not a system dependency.

        Run values are deleted and journalled with their previous data, so the
        generated rollback script restores them exactly. Startup-folder
        shortcuts are renamed rather than deleted, for the same reason.
    #>
    param($Action, $Context)

    $protected = Get-WDProtectedPrograms -Profile $Context.Profile
    $disabled  = New-Object System.Collections.Generic.List[string]
    $kept      = New-Object System.Collections.Generic.List[string]

    $isProtected = {
        param([string]$name, [string]$command)
        if (Test-WDPatternMatch $name $script:KeepStartup) { return $true }
        if (Test-WDPatternMatch $name $protected)          { return $true }
        foreach ($p in $protected) {
            # Match on the executable path too - Run value names are often
            # nothing like the product name in Add/Remove Programs.
            if ($command -and $command -like "*$($p.TrimEnd('*'))*") { return $true }
        }
        $false
    }

    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $props = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        if (-not $props) { continue }

        foreach ($prop in @($props.PSObject.Properties)) {
            if ($prop.Name -like 'PS*') { continue }
            $cmd = [string]$prop.Value

            if (& $isProtected $prop.Name $cmd) { $kept.Add($prop.Name); continue }
            if ($Context.Preview) { $disabled.Add($prop.Name); continue }

            try {
                Backup-WDRegistryKey -Path $k
                Remove-ItemProperty -LiteralPath $k -Name $prop.Name -Force -ErrorAction Stop
                $disabled.Add($prop.Name)
                Add-WDJournal -ItemId $Context.ItemId -Type 'registry' -Target "$k\$($prop.Name)" -Status 'Changed' `
                              -Undo @{ method = 'registry'; path = $k; name = $prop.Name; previous = $cmd; kind = 'String'; raw = $true }
            } catch {
                $kept.Add("$($prop.Name) (locked)")
            }
        }
    }

    foreach ($folder in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
            if ($f.Extension -eq '.disabled') { continue }
            if (& $isProtected $f.BaseName $f.FullName) { $kept.Add($f.BaseName); continue }
            if ($Context.Preview) { $disabled.Add($f.BaseName); continue }
            try {
                Rename-Item -LiteralPath $f.FullName -NewName "$($f.Name).disabled" -Force -ErrorAction Stop
                $disabled.Add($f.BaseName)
                Add-WDJournal -ItemId $Context.ItemId -Type 'file' -Target $f.FullName -Status 'Changed' `
                              -Undo @{ method = 'rename'; from = "$($f.FullName).disabled"; to = $f.FullName }
            } catch {
                $kept.Add("$($f.BaseName) (locked)")
            }
        }
    }

    if (-not $disabled.Count -and -not $kept.Count) {
        return New-WDResult -Status NotPresent -Message 'No startup entries found'
    }
    if (-not $disabled.Count) {
        return New-WDResult -Status Skipped -Message "All $($kept.Count) startup entries are system dependencies - none attempted" `
                            -Detail (($kept | Sort-Object -Unique) -join ', ')
    }
    New-WDResult -Status Changed -Message "$($disabled.Count) startup entries disabled" `
                 -Detail ("disabled: $((($disabled | Sort-Object -Unique) -join ', '))" +
                          $(if ($kept.Count) { " | kept as system dependencies: $((($kept | Sort-Object -Unique) -join ', '))" } else { '' }))
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
    <#
        Deletes previous run folders, keeping the one in progress.

        Worth being blunt about the trade: each folder holds that run's rollback
        script, journal and registry exports. Removing it makes those changes
        permanently irreversible from this tool.
    #>
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
    <#
        What the vendor uninstallers left behind, swept to the Recycle Bin.

        Deliberately not Revo's approach. Revo scans the registry and the file
        system for anything whose name resembles the product, which finds more
        and is only safe because a human reviews the list before it acts. There
        is no human in this loop, so this only touches a folder the program
        itself declared as its InstallLocation, recorded before its uninstall
        key was removed, and only when the uninstaller left it behind.

        That gives up the AppData and registry residue. It also means this
        cannot delete the wrong folder: every path came from the program.
    #>
    param($Action, $Context)

    # ASSIGNED, NEVER WRAPPED IN @(). Get-WDUninstalledThisRun ends in ,@(...)
    # so that assigning it does not unroll; @() around its pipeline output is
    # ONE element holding the whole list. The loop below then ran once with $d
    # bound to the array, and $d.InstallLocation member-enumerated into every
    # path space-joined into one string - so with two or more uninstalls this
    # swept nothing and reported "The uninstallers left nothing behind". With
    # exactly one it worked, which is why it survived every test it was given.
    $done = Get-WDUninstalledThisRun
    if (-not $done.Count) { return New-WDResult -Status NotPresent -Message 'Nothing was uninstalled this run' }

    # Never sweep a shared root. An installer that wrote "C:\Program Files" into
    # InstallLocation - and some do - would otherwise take everything with it.
    # The list itself lives in WD.Core as Test-WDSweepableRoot, because the
    # process kill before an uninstall has to refuse the same paths for the same
    # reason, and a safety list kept in two places is one list plus a bug waiting
    # for whoever extends the other copy. It also does the normalizing, so what
    # comes back is the path to act on rather than the raw property.
    $found = New-Object System.Collections.Generic.List[psobject]
    foreach ($d in $done) {
        $loc = Test-WDSweepableRoot -Path ([string]$d.InstallLocation)
        if (-not $loc) { continue }
        if (-not (Test-Path -LiteralPath $loc -PathType Container)) { continue }
        # An empty shell is the uninstaller tidying up asynchronously, not a
        # leftover worth reporting.
        $bytes = 0
        try { $bytes = (Get-ChildItem -LiteralPath $loc -Recurse -File -Force -ErrorAction SilentlyContinue |
                        Measure-Object Length -Sum).Sum } catch { }
        if (-not $bytes) { continue }
        $found.Add([pscustomobject]@{ Name = $d.Name; Path = $loc; Bytes = [long]$bytes })
    }

    if (-not $found.Count) { return New-WDResult -Status NotPresent -Message 'The uninstallers left nothing behind' }

    $mb    = [Math]::Round((($found | Measure-Object Bytes -Sum).Sum) / 1MB, 1)
    $detail = ($found | ForEach-Object { "$($_.Name) -> $($_.Path)" }) -join '; '

    if ($Context.Preview) {
        return New-WDResult -Status Removed -Message "Would clear $($found.Count) leftover folder(s), about $mb MB" -Detail $detail
    }

    $gone = New-Object System.Collections.Generic.List[string]
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($f in $found) {
        if (-not (Test-WDRecycleAvailable -Path $f.Path)) {
            $kept.Add("$($f.Path) (no Recycle Bin on that volume)")
            continue
        }
        if (Remove-WDToRecycleBin -Path $f.Path) {
            $gone.Add($f.Path)
            Add-WDJournal -ItemId $Context.ItemId -Type 'file' -Target $f.Path -Status 'Removed' `
                          -Undo @{ method = 'recycle'; path = $f.Path }
        } else {
            $kept.Add("$($f.Path) (in use or locked)")
        }
    }

    if ($gone.Count -and -not $kept.Count) {
        return New-WDResult -Status Removed -Message "$($gone.Count) leftover folder(s) sent to the Recycle Bin, about $mb MB" -Detail ($gone -join '; ')
    }
    if ($gone.Count) {
        return New-WDResult -Status Partial -Message "$($gone.Count) cleared, $($kept.Count) left in place" -Detail ($kept -join '; ')
    }
    New-WDResult -Status Blocked -Message 'The leftovers could not be cleared' -Detail ($kept -join '; ')
}

function Get-WDResidueTokens {
    <#
        The words worth searching for out of a program name. Version numbers,
        architecture markers and the filler that appears in every display name
        are dropped, because "Software" or "x64" matches half the disk.

        A token has to be five characters or more. Four-letter vendor names lose
        out, and that is the right trade: this decides what gets shown as
        suspicious, and a short token matches far too much.
    #>
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

Register-WDHandler 'RemoveUninstallResidue' {
    <#
        The wider sweep, the way Revo's works: search the usual residue locations
        by NAME, rather than only the folder the program declared.

        Revo is only safe because a human reviews the list first. There is no
        human in this loop, so the safety is bought back three other ways:

          - a token must be 5+ characters and not a generic word, so "Software"
            and "x64" match nothing
          - a folder holding a RUNNING executable is left alone - a live process
            is the one unambiguous sign the match was wrong
          - every removal is reversible: folders to the Recycle Bin, keys
            exported before deletion, so the rollback restores the lot

        Still the widest net here, which is why it is tier 3 and off by default.
    #>
    param($Action, $Context)

    # Assigned, never wrapped - see RemoveUninstallLeftovers above. Wrapped, the
    # loop ran once with $d bound to the whole list, so every finding was
    # attributed to all the uninstalled names joined together, and $claimed held
    # one joined non-path - which meant the folders the narrower sweep had
    # already recycled were reported and recycled a second time.
    $done = Get-WDUninstalledThisRun
    if (-not $done.Count) { return New-WDResult -Status NotPresent -Message 'Nothing was uninstalled this run' }

    # Only the containers where per-application residue actually accumulates.
    # Anything one level up would match half the machine.
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
        $tokens = @(Get-WDResidueTokens -Name $d.Name)
        if (-not $tokens.Count) { continue }

        foreach ($root in $roots) {
            foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
                $flat = ($dir.Name -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
                $tok  = @($tokens | Where-Object { $flat -like "*$_*" }) | Select-Object -First 1
                if (-not $tok) { continue }
                if ($claimed -contains $dir.FullName.ToLowerInvariant()) { continue }
                $bytes = 0
                try { $bytes = (Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                                Measure-Object Length -Sum).Sum } catch { }
                $hits.Add([pscustomobject]@{
                    Kind = 'folder'; Program = $d.Name; Path = $dir.FullName
                    Why  = "folder name matches '$tok'"
                    Size = "$([Math]::Round(([double]$bytes) / 1MB, 1)) MB"
                })
            }
        }

        foreach ($root in $regRoots) {
            foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                $flat = ($key.PSChildName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
                $tok  = @($tokens | Where-Object { $flat -like "*$_*" }) | Select-Object -First 1
                if (-not $tok) { continue }
                $hits.Add([pscustomobject]@{
                    Kind = 'registry'; Program = $d.Name; Path = $key.Name
                    Why  = "key name matches '$tok'"; Size = ''
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

    # A folder holding a process that is running right now is the one case where
    # the name match is demonstrably wrong about ownership, and it is also the
    # case where deleting would break something in front of the operator.
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

Register-WDHandler 'SetPowerScheme' {
    <#
        One value in the active power scheme, set for both AC and battery.

        POWERCFG, NOT THE REGISTRY, and that is not a preference: the keys under
        Control\Power\PowerSettings hold each setting's DEFAULT and allowed range,
        while the value in force belongs to the active scheme under a per-scheme
        GUID - writing the default does not move it. powercfg also re-applies the
        scheme, which is what makes the change take effect without a sign-out.

        The action names the subgroup and setting, so one handler covers every
        power item:

          { "type": "script", "handler": "SetPowerScheme",
            "sub": "SUB_SLEEP", "setting": "RTCWAKE", "value": 0 }

        Aliases and raw GUIDs are both accepted, and WHICH ONE TO USE HAS TO BE
        CHECKED against a real machine - there is no SUB_USB alias, and a wrong
        pairing reports NotPresent, which is indistinguishable from hardware that
        lacks the setting. Probe with `powercfg /query SCHEME_CURRENT` and
        `powercfg /aliases` first.

        Previous values are read from the SCHEME before the write, not from the
        documented default, so somebody who has already tuned their power plan
        gets their own numbers back.
    #>
    param($Action, $Context)

    $sub = [string](Get-Prop $Action 'sub' '')
    $set = [string](Get-Prop $Action 'setting' '')
    if (-not $sub -or -not $set) {
        return New-WDResult -Status Failed -Message 'Power setting not specified' `
                            -Detail 'The action needs both a "sub" and a "setting".'
    }
    $want = [int](Get-Prop $Action 'value' 0)

    # What it is now. /query prints the AC and DC index as hex on their own
    # lines; anything unparseable leaves the undo without a value, and an undo
    # that would restore a guess is worse than one that says it cannot.
    $acWas = $null; $dcWas = $null
    try {
        $q = @(& "$env:SystemRoot\System32\powercfg.exe" /query SCHEME_CURRENT $sub $set 2>&1)
        foreach ($line in $q) {
            if ($line -match 'AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $acWas = [Convert]::ToInt32($Matches[1], 16) }
            if ($line -match 'DC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $dcWas = [Convert]::ToInt32($Matches[1], 16) }
        }
    } catch { }

    if ($null -eq $acWas -and $null -eq $dcWas) {
        return New-WDResult -Status NotPresent -Message 'This power setting is not on this machine' `
                            -Detail "powercfg does not report $sub / $set here, which is normal on hardware that does not implement it."
    }
    if ([int]$acWas -eq $want -and [int]$dcWas -eq $want) {
        return New-WDResult -Status NotPresent -Message 'Already set' -Detail "$sub / $set is already $want on both AC and battery."
    }
    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message "Would set $set to $want" `
                            -Detail "Currently AC $acWas, battery $dcWas."
    }

    try {
        $exe = "$env:SystemRoot\System32\powercfg.exe"
        $null = & $exe /setacvalueindex SCHEME_CURRENT $sub $set $want 2>&1
        $null = & $exe /setdcvalueindex SCHEME_CURRENT $sub $set $want 2>&1
        # Without this the scheme holds the new numbers and the machine goes on
        # behaving the old way until something else re-applies it.
        $null = & $exe /setactive SCHEME_CURRENT 2>&1
    } catch {
        return New-WDResult -Status Blocked -Message 'powercfg refused the change' -Detail $_.Exception.Message
    }

    Add-WDJournal -ItemId $Context.ItemId -Type 'power' -Target "$sub\$set" -Status 'Changed' `
                  -Undo @{ method = 'powercfg'; sub = $sub; setting = $set
                           ac = $(if ($null -ne $acWas) { [int]$acWas } else { [int]$dcWas })
                           dc = $(if ($null -ne $dcWas) { [int]$dcWas } else { [int]$acWas }) }
    New-WDResult -Status Changed -Message "$set set to $want" `
                 -Detail "Was AC $acWas, battery $dcWas. Applied to the active power plan."
}

Register-WDHandler 'SetTaskbarAutoHide' {
    <#
        Auto-hide is one bit inside a binary blob, not a value of its own:
        StuckRects3\Settings byte 8, bit 0x01. So this is a read-modify-write
        per user hive rather than a manifest registry action.

        The blob is 40 bytes on older builds and 48 on newer ones, and the flag
        byte has not moved, so the length is checked but not assumed.
    #>
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
        # A copy of the real bytes. This used to record the TEXT "@(48,0,4,...)"
        # because the emitter interpolated the previous value unquoted, so a
        # PowerShell literal was the only thing that survived the trip. The
        # emitter renders values now, which means this can be a value.
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
    <#
        The superseded copies of every Windows update, plus the temp folders.

        This is the one big space win a debloat run can offer and nothing else
        here touches it - removing apps barely dents WinSxS. /ResetBase is what
        makes it worth running and also what makes it opt-in: it discards the
        backups Windows keeps to uninstall updates, so afterwards no installed
        update can be rolled back.

        Deliberately not cleanmgr /VERYLOWDISK, which winutil uses. That runs a
        UI-driven tool with a profile nobody here chose and it can clear the
        Recycle Bin and Downloads on some presets. DISM's scope is exactly the
        component store, which is where the space actually is.
    #>
    param($Action, $Context)

    $before = 0
    try { $before = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'").FreeSpace } catch { }

    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message 'Would compact the component store and clear temp files' `
                            -Detail 'Typically 3-8 GB. Takes several minutes, and installed updates can no longer be uninstalled afterwards.'
    }

    $notes = New-Object System.Collections.Generic.List[string]

    # Temp first: it is quick, and it is free space DISM does not need to work in.
    $tempBytes = 0
    foreach ($dir in @($env:TEMP, (Join-Path $env:SystemRoot 'Temp'))) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($e in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            try {
                if ($e.PSIsContainer) {
                    $tempBytes += (Get-ChildItem -LiteralPath $e.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                                   Measure-Object Length -Sum).Sum
                } else { $tempBytes += $e.Length }
                Remove-Item -LiteralPath $e.FullName -Recurse -Force -ErrorAction Stop
            } catch { }   # in-use temp files are the normal case, not a failure
        }
    }
    $notes.Add("temp files: about $([Math]::Round(([double]$tempBytes) / 1MB, 0)) MB")

    $dism = Invoke-WDProcess -FilePath "$env:SystemRoot\System32\Dism.exe" `
                             -ArgumentList @('/Online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase', '/Quiet', '/NoRestart') `
                             -TimeoutSeconds 2400
    if ($dism.TimedOut) {
        $notes.Add('component store cleanup did not finish in 40 minutes')
    } elseif ($dism.ExitCode -in @(0, 3010)) {
        if ($dism.ExitCode -eq 3010) { Set-WDRebootNeeded }
        $notes.Add('component store compacted')
    } else {
        return New-WDResult -Status Partial -Message 'Temp files cleared, component store cleanup refused' `
                            -Detail "DISM exit $($dism.ExitCode). This usually means a servicing operation is pending - retry after a restart. $($notes -join '; ')"
    }

    $freed = 0
    try {
        $after = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'").FreeSpace
        $freed = [Math]::Round((([double]$after - [double]$before)) / 1GB, 2)
    } catch { }

    $msg = if ($freed -gt 0) { "About $freed GB reclaimed" } else { 'Cleanup finished' }
    New-WDResult -Status Removed -Message $msg -Detail ($notes -join '; ')
}

Register-WDHandler 'EnableIrreversibleMode' {
    <#
        Turns off every way back for the rest of the run, and empties the
        Recycle Bin when it finishes.

        Ordered first in the plan on purpose: the flag has to be set before any
        file action runs, or the early ones still buy a way back that the later
        ones do not. The bin is emptied by the engine at the end rather than
        here, so that everything this run recycles is covered.
    #>
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
    <#
        Appended to every plan by Resolve-WDPlan rather than ticked. Taskbar,
        context-menu and Explorer settings are written to the registry the
        moment their item runs, but the shell only reads them at start-up, so
        without this the operator applies a change, looks at the taskbar, and
        sees nothing happen.
    #>
    param($Action, $Context)
    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message 'Would restart Explorer so shell changes take effect now' `
                            -Detail 'Open File Explorer windows close. Nothing else about the desktop changes, and this runs last.'
    }
    # THIS SESSION'S SHELL, NOT EVERY SESSION'S. Get-Process answers for the
    # whole machine when it is asked from an elevated process, and this was
    # `Stop-Process -Name explorer`, which on a machine with somebody else
    # signed in through fast user switching took their desktop down too. They
    # did not ask for a run and have no way to connect the two.
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
        # so this is normally already back and nothing below runs.
        $back = & $shells
        if (-not $back.Count) {
            Start-Process explorer.exe -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 1500
            $back = & $shells
        }
        # ASKED, NOT ASSUMED. Start-Process with -ErrorAction SilentlyContinue
        # throws nothing when it fails, so the success below was reported
        # unconditionally - and on an image with the shell watchdog switched off
        # that meant claiming "Explorer restarted" to somebody looking at an
        # empty desktop. Of everything this toolkit can get wrong, saying a
        # thing worked while the screen is black is the worst shape.
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
    <#
        Shortcuts left pointing at a program this run removed.

        Uninstallers routinely leave their Start entry behind, and Edge leaves
        one that survives every folder its own uninstaller deletes. It still
        comes up first when somebody searches the program by name, and clicking
        it gives a shell error rather than an explanation - so "it is still
        there" is the reasonable conclusion.

        Appended to any plan that removes something rather than ticked: it is the
        last part of a removal, not a choice about one.

        WHAT IT WILL NOT TOUCH, because a wrong deletion here takes away
        something somebody put on their own desktop:

          - an EMPTY target. Store apps activate through an AppUserModelID and
            have no target at all, so treating empty as stale would clear every
            Store app out of Start.
          - a target that is not a ROOTED path. Bare command names are resolved
            through PATH by the shell.
          - .url files: "does this exist on disk" is not a question about a URL.
          - anything whose target still exists.
          - ANYTHING OUTSIDE A PROGRAM DIRECTORY, which is the one that matters.
            A missing target does not mean uninstalled, it means not there right
            now: a game on an external drive, a tool in a synced folder. The
            first cut swept on "target is gone" alone and its first real find was
            an emulator shortcut pointing into OneDrive.

        Recycled and journalled, so the rollback puts every one back.
    #>
    param($Action, $Context)

    $dirs = @(
        [Environment]::GetFolderPath('CommonStartMenu'),
        [Environment]::GetFolderPath('StartMenu'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('Desktop'),
        (Join-Path $env:PUBLIC 'Desktop')
    )
    # Every account's own Start menu and desktop, not only the one running this.
    # A removal is machine-wide and a shortcut left in another profile is the
    # same broken entry for whoever signs in next.
    try {
        foreach ($u in (Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction Stop)) {
            $dirs += (Join-Path $u.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu')
            $dirs += (Join-Path $u.FullName 'Desktop')
        }
    } catch { }
    $dirs = @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique)

    # Where programs live. A dead target under one of these is a program that
    # has been removed; a dead target anywhere else is a file that happens not
    # to be there today, and is none of this sweep's business.
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
                    if (-not (Test-WDRecycleAvailable -Path $h.FullName)) {
                        $errors.Add("$($h.FullName) : no Recycle Bin on that volume, left in place")
                        continue
                    }
                    if (-not (Remove-WDToRecycleBin -Path $h.FullName)) {
                        $errors.Add("$($h.FullName) : could not be moved to the Recycle Bin")
                        continue
                    }
                    Add-WDJournal -ItemId $Context.ItemId -Type 'file' -Target $h.FullName -Status 'Removed' `
                                  -Undo @{ method = 'recycle'; path = $h.FullName }
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

Register-WDHandler 'VerifyShellHealth' {
    <#
        Guard for the CoreAI removal. If stripping the shell's AI package took
        Explorer or the Settings app with it, say so loudly and point at the
        rollback rather than letting the user find out after a reboot.
    #>
    param($Action, $Context)
    if ($Context.Preview) { return New-WDResult -Status Skipped -Message 'Health check runs during apply only' }

    Start-Sleep -Seconds 2
    $problems = New-Object System.Collections.Generic.List[string]

    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { $problems.Add('Explorer will not start') }
    }
    foreach ($pkg in @('Microsoft.Windows.ShellExperienceHost','Microsoft.Windows.StartMenuExperienceHost')) {
        if (-not (Get-AppxPackage -Name $pkg -ErrorAction SilentlyContinue)) { $problems.Add("$pkg missing") }
    }
    if (-not (Test-Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer')) { $problems.Add('Explorer settings key missing') }

    if ($problems.Count) {
        Write-WDLog "SHELL HEALTH CHECK FAILED: $($problems -join '; ')" -Level Error -Item $Context.ItemId
        return New-WDResult -Status Failed -Message 'Shell health check failed after AI package removal' `
            -Detail "$($problems -join '; '). Run the generated rollback script or use System Restore."
    }
    New-WDResult -Status AlreadySet -Message 'Shell health check passed'
}

# ================================================== vendor profile report ===

# Tools that keep hardware working. Every OEM removal list excludes these, and
# this table is the single place that decides what "load-bearing" means.
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
    # "Changes nothing", and it reported Changed anyway - so a preview listed it
    # under "will change" beside a hundred and fifty things that genuinely will.
    New-WDResult -Status AlreadySet -Message $msg -Detail $detail
}

Register-WDHandler 'ReportPreservedVendorTools' {
    <#
        Reports rather than removes. A debloat tool that silently strips the
        utility controlling a laptop's fan curve or battery charge limit has
        broken the machine, so those are excluded by construction and named
        here instead.
    #>
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
    # What was deliberately NOT touched. Reporting that as a change is the
    # opposite of what the row says.
    New-WDResult -Status AlreadySet -Message "$($present.Count) hardware tool(s) preserved" `
                 -Detail ((($present | Sort-Object -Unique) -join ', ') + ' - kept because they control power, thermals or firmware. Remove manually if you do not want them.')
}

# ========================================================== power tweaks ====

Register-WDHandler 'SetPowerPlan' {
    param($Action, $Context)

    # Laptops keep Balanced: High Performance pins clocks and destroys battery
    # life for no real-world gain on portable hardware.
    $guid = if ($Context.Profile.IsPortable) {
        '381b4222-f694-41f0-9685-ff5bb260df2e'   # Balanced
    } else {
        '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'   # High performance
    }
    $label = if ($Context.Profile.IsPortable) { 'Balanced (laptop)' } else { 'High performance (desktop)' }

    if ($Context.Preview) { return New-WDResult -Status Changed -Message "Would set power plan to $label" }

    $r = Invoke-WDProcess -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $guid) -TimeoutSeconds 60
    if ($r.ExitCode -eq 0) { return New-WDResult -Status Changed -Message "Power plan set to $label" }
    New-WDResult -Status Blocked -Message 'Could not set power plan' -Detail "powercfg exit $($r.ExitCode). Some OEM images lock the plan list."
}

Register-WDHandler 'DisableHibernation' {
    param($Action, $Context)
    if ($Context.Profile.HasBattery) {
        return New-WDResult -Status Skipped -Message 'Skipped on battery-powered hardware' -Detail 'Disabling hibernation on a laptop loses sleep-to-disk and hybrid sleep.'
    }
    if ($Context.Preview) { return New-WDResult -Status Changed -Message 'Would disable hibernation and delete hiberfil.sys' }

    $r = Invoke-WDProcess -FilePath 'powercfg.exe' -ArgumentList @('/hibernate', 'off') -TimeoutSeconds 60
    if ($r.ExitCode -eq 0) { return New-WDResult -Status Changed -Message 'Hibernation disabled, hiberfil.sys reclaimed' }
    New-WDResult -Status Blocked -Message 'Could not disable hibernation' -Detail "powercfg exit $($r.ExitCode)"
}

Register-WDHandler 'DisableReservedStorage' {
    param($Action, $Context)
    try {
        $state = Get-WindowsReservedStorageState -ErrorAction Stop
        if ($state.ReservedStorageState -eq 'Disabled') {
            return New-WDResult -Status NotPresent -Message 'Reserved storage is already disabled'
        }
        if ($Context.Preview) { return New-WDResult -Status Changed -Message 'Would disable reserved storage (~7 GB)' }

        Set-WindowsReservedStorageState -State Disabled -ErrorAction Stop
        New-WDResult -Status Changed -Message 'Reserved storage disabled' -Detail 'Feature updates may now need free space staged manually.'
    } catch {
        # Windows refuses while an update is pending; that is expected, not a failure.
        New-WDResult -Status Blocked -Message 'Reserved storage could not be changed' `
                     -Detail "$($_.Exception.Message) - usually means a Windows update is pending. Retry after a reboot."
    }
}

# --------------------------------------------------------- PowerToys ------
#
# Config is per-user JSON under %LOCALAPPDATA%\Microsoft\PowerToys: one
# settings.json with an "enabled" map keyed by module display name, plus one per
# module for its own properties. PowerToys reads them at start and writes
# defaults for anything absent, which is what makes writing them BEFORE it is
# installed work at all.
#
# Two rules. MERGE, NEVER REPLACE - a module absent from "enabled" falls back to
# its own default, so naming only what was asked for leaves the rest alone and
# somebody's existing config survives. And REFUSE WHAT IT CANNOT PARSE: these
# files are undocumented and PowerToys is free to migrate them, so an unrecognized
# shape is reported rather than overwritten.

function Get-WDPowerToysRoot { Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys' }

function Set-WDPowerToysJson {
    <#
        Reads a PowerToys JSON file, hands it to $Edit, writes it back, and
        journals enough to undo it. Backs an existing file up first; for one
        this run creates, the undo is to delete it again.
    #>
    param([string]$Path, [scriptblock]$Edit, $Context, [pscustomobject]$Seed)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

    $existed = Test-Path -LiteralPath $Path
    $json = $null
    $bak  = $null
    if ($existed) {
        $bak = "$Path.wdbak"
        Copy-Item -LiteralPath $Path -Destination $bak -Force -ErrorAction SilentlyContinue
        try { $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { $json = $null }
        if (-not $json) { throw "PowerToys config at $Path is not readable JSON - left untouched" }
    } else {
        $json = $Seed
    }

    & $Edit $json
    $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
    Add-WDJournal -ItemId $Context.ItemId -Type 'powertoys' -Target $Path -Status 'Changed' `
                  -Undo @{ method = 'file-restore'; file = $bak; target = $Path }
}

# ----------------------------------------------------------- storage ------
#
# Offered on every machine, not only a full one: a section that only appears once
# the drive is already full cannot be what stops it filling up.
#
# ONE PATH TABLE behind all three - the row's number, the bar's segment, and the
# bytes the run deletes all come from Get-WDStorageSources. Two path lists that
# drift would have the picture promising what the run does not deliver.

# Compiled by Test-WDDiskNative on first use, not at import. It is a csc
# invocation - about 400 ms - and on a normal launch the first thing to want it
# is the background storage measurement, which has a runspace of its own and a
# whole drive walk ahead of it. See the native note at the top of WD.Core.psm1.
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
    <#
        Is the fast walker available - compiling it if this is the first ask.

        Tried once per runspace and then remembered either way, so a machine
        that cannot compile falls back to Get-ChildItem rather than paying for
        the attempt on every folder. Two runspaces racing is harmless: the
        loser gets "type already exists", which the catch swallows, and the
        check below then finds the winner's type.
    #>
    if ('WDDisk' -as [type]) { return $true }
    if ($script:WDDiskTried)  { return $false }
    $script:WDDiskTried = $true
    try { Add-Type -ErrorAction SilentlyContinue -TypeDefinition $script:WDDiskSource } catch { }
    [bool]('WDDisk' -as [type])
}

function Measure-WDFolder {
    <#  Bytes under a path, best effort. Locked files are skipped, not fatal.  #>
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
    <#
        The same walk, with what it could not read reported rather than folded
        into the total. "0 bytes" and "0 bytes that I was allowed to see" are
        different answers, and the second one must not put "nothing to free" on
        a row - Windows.old is owned by TrustedInstaller and the clean-up seizes
        it before deleting, so a folder this cannot read is still a folder the
        run can empty.
    #>
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
    <#
        Abandons any walk in flight. Called when the window closes.

        Asks whether the type exists rather than going through
        Test-WDDiskNative: if nothing has compiled it then no walk has ever
        started, and compiling it here would be spending 400 ms on a closing
        window to set a flag with nobody to read it.
    #>
    param([switch]$Reset)
    if ('WDDisk' -as [type]) { [WDDisk]::Stop = (-not $Reset) }
}

function Get-WDStorageSources {
    <#
        The one table. Each clean-up names the folders it acts on and, for each
        of them, which descriptive bucket of the drive those bytes were already
        counted in - the temp folders live inside Windows and inside Users, so
        drawing them as their own segment without taking them back out of those
        two would draw the same gigabytes twice.

        'none' means there is no way to size it up front. That is the component
        store: only DISM knows what is reclaimable there, the analysis takes
        minutes, and it answers in whatever language Windows is installed in.
        An honest "not known until it runs" beats parsing that.
    #>
    $sys = [string]$env:SystemDrive
    if (-not $sys) { $sys = 'C:' }
    $win = [string]$env:SystemRoot
    if (-not $win) { $win = Join-Path $sys 'Windows' }

    [ordered]@{
        'disk-temp' = @{
            Kind = 'folder'; What = 'temporary files'
            Paths = @(
                @{ Path = (Join-Path $win 'Temp'); Bucket = 'windows' }
                @{ Path = [string]$env:TEMP;       Bucket = 'users'   }
            )
        }
        'disk-update-cache' = @{
            Kind = 'folder'; What = 'the Windows Update cache'
            Paths = @(
                @{ Path = (Join-Path $win 'SoftwareDistribution\Download'); Bucket = 'windows' }
            )
        }
        'disk-delivery-opt' = @{
            Kind = 'folder'; What = 'the Delivery Optimization cache'
            Paths = @(
                @{ Path = (Join-Path $win 'SoftwareDistribution\DeliveryOptimization'); Bucket = 'windows' }
                @{ Path = (Join-Path $win 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization'); Bucket = 'windows' }
            )
        }
        'disk-thumbnails' = @{
            Kind = 'folder'; What = 'the thumbnail and icon cache'
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

function Measure-WDRecycleBin {
    <#
        -Root of a drive asks about that drive; -All asks about every one. The
        two answers are both wanted and they are not interchangeable: the bar
        draws one drive, and the clean-up empties all of them.

        Returns $null when the shell refuses to answer, which reads as "no
        size" rather than as zero.
    #>
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
    <#
        Every clean-up, sized, plus the per-bucket total that has to be taken
        back out of the descriptive buckets so nothing is drawn twice.

        -Cancellable is for the background scan alone. In the foreground a
        closed window from ten minutes ago must not be able to answer this.
    #>
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
        foreach ($p in @($src.Paths)) {
            $d = Measure-WDFolderDetail -Path ([string]$p.Path) -Cancellable:$Cancellable
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
    <#
        The slow half: three walks of the drive, which is why this runs on a
        background runspace and its answer is cached between sessions.

        Sum-of-lengths, which is not the same as space on disk. WinSxS is a
        hardlink farm, so C:\Windows adds up to considerably more than it
        occupies, and a folder an administrator is not allowed to read adds up
        to nothing. New-WDStorageSnapshot is where that is reconciled; here the
        job is only to report what was counted and what was refused.
    #>
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
    # the drive, so they land in Other, and naming them is the difference
    # between Other meaning something and Other meaning nothing.
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
    <#
        Turns measurements into the segments the bar draws. Pure arithmetic and
        no I/O, which is what makes it testable without a disk to measure.

        Two rules do the work.

        The reclaimable sizes are never adjusted. They are what the run
        promises to free, so a scaled version of them would be a different
        promise. Only the descriptive buckets absorb the difference between
        what was counted and what the volume says is in use - they are the part
        of the picture that is allowed to be "about".

        Windows counts higher than it occupies because of hardlinks, and apps
        counts lower because WindowsApps refuses to be read. So the buckets are
        scaled down when they overflow the room available and Other takes the
        remainder when they do not. Either way the bar adds up to the drive.
    #>
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
    # stale between the walk and the capacity read, but a negative remainder
    # would render as a bar running backwards.
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
        # Nothing walked yet. One block for everything in use rather than four
        # empty ones - a segment drawn at zero reads as "you have no files".
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
        # Two different kinds of "finished", and the interface needs both. Priced
        # means the clean-up sizes are in, so a row may say "nothing to free";
        # Complete means the drive has been walked, so the bar may show a split.
        Priced      = [bool]$Priced
        Complete    = $complete
        Scaled      = $scaled
    }
}

function Get-WDStorageReport {
    <#
        The whole picture in one call. -Quick skips the three drive walks and
        answers with the clean-up sizes alone, which is what the interface shows
        while the slow half is still running.
    #>
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
    <#  Total and free on the system drive. One CIM call, no walking.  #>
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
    <#
        Empties a folder without removing the folder itself - Windows recreates
        several of these and expects them to exist. Whatever is in use is left
        alone: a cache file open right now is not worth failing a run over.
    #>
    param([string[]]$Paths, $Context, [string]$What)

    # -ErrorAction on Test-Path, because some of these are owned by a service
    # account and answering "does it exist" throws Access denied rather than
    # returning false. With the module's Stop preference that ends the handler.
    $live = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue) })
    if (-not $live.Count) { return New-WDResult -Status NotPresent -Message "Nothing to clear in $What" }

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
    <#  The folders one clean-up acts on, in the order the table lists them.  #>
    param([Parameter(Mandatory)][string]$Id)
    $src = Get-WDStorageSources
    if (-not $src.Contains($Id)) { return @() }
    @($src[$Id].Paths | ForEach-Object { [string]$_.Path })
}

Register-WDHandler 'ClearTempFiles' {
    param($Action, $Context)
    Clear-WDFolderContents -Context $Context -What 'temporary files' `
                           -Paths (Get-WDStoragePaths -Id 'disk-temp')
}

Register-WDHandler 'ClearUpdateCache' {
    <#
        The downloaded installers Windows Update keeps after installing them.
        Windows re-downloads anything it still needs, so this costs bandwidth
        rather than function - but it also means a partially downloaded update
        starts again, so the service is stopped first if it is running.
    #>
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

    $wasRunning = $false
    try {
        $svc = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            $wasRunning = $true
            Stop-Service -Name 'wuauserv' -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    } catch { }
    try {
        Clear-WDFolderContents -Context $Context -What 'the Windows Update cache' -Paths @($dl)
    } finally {
        if ($wasRunning) { try { Start-Service -Name 'wuauserv' -ErrorAction SilentlyContinue } catch { } }
    }
}

Register-WDHandler 'ClearThumbnailCache' {
    <#
        Explorer keeps a database per thumbnail size and per icon size, and
        never shrinks them. Explorer holds several of them open while it is
        running, so a partial result here is the normal one rather than a
        failure - Clear-WDFolderContents already says so.
    #>
    param($Action, $Context)
    Clear-WDFolderContents -Context $Context -What 'the thumbnail and icon cache' `
                           -Paths (Get-WDStoragePaths -Id 'disk-thumbnails')
}

Register-WDHandler 'ClearDeliveryOptimization' {
    param($Action, $Context)
    Clear-WDFolderContents -Context $Context -What 'the Delivery Optimization cache' `
                           -Paths (Get-WDStoragePaths -Id 'disk-delivery-opt')
}

Register-WDHandler 'RemoveWindowsOld' {
    <#
        The previous installation kept after an in-place upgrade. Windows
        deletes it on its own after ten days; until then it is the single
        largest thing on a drive that has just been upgraded.
    #>
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
    $null = & takeown.exe /F $old /R /A /D Y 2>&1
    $null = & icacls.exe $old /grant "*S-1-5-32-544:F" /T /C /Q 2>&1
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
    <#
        Clear-WDRecycleBin empties every drive's bin, so this is sized the same
        way. Walking C:\$Recycle.Bin - which is what this used to do - both
        under-reported the total and asked a different question from the one the
        deletion answers. The shell keeps a running total, so asking costs
        nothing either way.

        The bar upstairs is about the system drive alone and says so, which is
        why the two numbers are reported separately when they differ.
    #>
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
    <#
        Is this module already in the state the action would put it in?

        Reads the same two files the handler writes. A file that is missing or
        unreadable answers "no": the worst case is offering something that turns
        out to be a no-op, which the run reports honestly, and that is far better
        than hiding an option because a JSON parse failed.
    #>
    param($Action)

    $module = [string](Get-Prop $Action 'module' '')
    if (-not $module) { return $false }
    $want = [bool](Get-Prop $Action 'enable' $true)
    $root = Get-WDPowerToysRoot

    $settings = Join-Path $root 'settings.json'
    if (-not (Test-Path -LiteralPath $settings)) { return $false }
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

# Handler name -> "is this already the case?". An item whose every action answers
# yes is already done, and the GUI says so rather than offering it again.
#
# NO TEST MEANS NO OPINION, which must read as not-satisfied - an empty set of
# tests vacuously passing would quietly disable every item in the manifest.
#
# Deliberately absent: handlers whose work is a JOB rather than a STATE. Clearing
# a cache, emptying the bin, sweeping leftovers, writing a document - all worth
# doing again tomorrow, so "already done" is not a thing to say about them. Also
# SetPowerScheme, which would need a powercfg spawn per action.
#
# The rule for anything added: answer from the registry, the file system, or a
# list the scan already has, in milliseconds. This runs for every action of every
# item while the window is built.
$script:StateTests = @{
    'SetPowerToysModule' = ${function:Test-WDPowerToysModuleSet}

    # Both scrubs are "is any of this vendor's software still installed". The
    # handler's own first line asks the same question of the same list.
    'McAfeeScrub' = {
        param($Action)
        -not @(Get-WDInstalledPrograms | Where-Object {
            $_.DisplayName -like '*McAfee*' -or $_.Publisher -like '*McAfee*' }).Count
    }
    'NortonScrub' = {
        param($Action)
        -not @(Get-WDInstalledPrograms | Where-Object { $_.DisplayName -match 'Norton|Symantec' }).Count
    }

    # Edge, asked exactly as RemoveEdge asks it: the application directory in
    # either Program Files, and the Store package. Reported as done only when
    # the browser is gone AND the reinstall vectors are shut, because the
    # handler does both and half of it is not done.
    'RemoveEdge' = {
        param($Action)
        foreach ($d in @((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application'),
                         (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application'))) {
            if (Test-Path -LiteralPath $d -ErrorAction SilentlyContinue) { return $false }
        }
        try { if (@(Get-AppxPackage -Name 'Microsoft.MicrosoftEdge.Stable' -ErrorAction SilentlyContinue).Count) { return $false } } catch { }
        $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
        $v = $null
        try { $v = Get-ItemProperty -LiteralPath $pol -ErrorAction SilentlyContinue } catch { }
        if (-not $v) { return $false }
        foreach ($n in @('InstallDefault', 'UpdateDefault')) {
            if (-not $v.PSObject.Properties[$n] -or [int]$v.$n -ne 0) { return $false }
        }
        $true
    }

    # The web associations. Done when http and https point at something that is
    # not Edge - which is the whole of what this option is for, and is readable
    # without touching anything Windows protects.
    'SetDefaultBrowser' = {
        param($Action)
        foreach ($p in @('http', 'https')) {
            $k = "HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\$p\UserChoice"
            $id = ''
            try { $id = [string](Get-ItemProperty -LiteralPath $k -Name 'ProgId' -ErrorAction SilentlyContinue).ProgId } catch { }
            if (-not $id) { return $false }
            if ($id -like 'MSEdge*' -or $id -like 'AppX*Edge*') { return $false }
        }
        $true
    }

    'RemoveOneDrive' = {
        param($Action)
        foreach ($p in @((Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'),
                         (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'),
                         (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive'))) {
            if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { return $false }
        }
        $true
    }

    'RemoveWindowsOld' = {
        param($Action)
        -not (Test-Path -LiteralPath (Join-Path $env:SystemDrive 'Windows.old') -ErrorAction SilentlyContinue)
    }

    # hiberfil.sys is gone and the master switch is off. Asked of the registry
    # rather than by spawning powercfg, which this cannot afford to do.
    'DisableHibernation' = {
        param($Action)
        $v = $null
        try { $v = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled' -ErrorAction SilentlyContinue } catch { }
        if (-not $v -or -not $v.PSObject.Properties['HibernateEnabled']) { return $false }
        [int]$v.HibernateEnabled -eq 0
    }

    # One bit inside a blob, per account, which is why the handler exists at
    # all. Read the same byte back.
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

    # The overlay value AND the icon it points at, which is the same pair the
    # handler tests before reporting AlreadySet. A value pointing at a file
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

    # Either layer counts as done: the native setting where the build has it,
    # or the PowerToys chord remap where it does not. The item's whole point is
    # that the key behaves as Right Ctrl, not which of the two got it there.
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
        $f = Join-Path (Get-WDPowerToysRoot) 'Keyboard Manager\default.json'
        if (-not (Test-Path -LiteralPath $f)) { return $false }
        try { return ((Get-Content -LiteralPath $f -Raw) -match '"162"') } catch { return $false }
    }
}

function Test-WDActionSatisfied {
    <#
        Is there anything left for this one action to do on this machine?

        $true only when this can answer AND the answer is yes. No test means no
        opinion, which must read as "not satisfied" - otherwise an item silently
        disables itself because nobody wrote a check for it.

        Three kinds of answer:

          by VALUE    registry, service - does the setting already hold what the
                      action would write.
          by ABSENCE  appx, appxPolicy, uninstall, task, file, shortcut,
                      registryKey - the action removes something and there is
                      nothing to remove. Needs the startup scan's inventory;
                      without one it answers no, the careful direction.
          by HANDLER  a script action, through $script:StateTests.

        The absence arm is why "Copilot app and taskbar entry", "Cortana
        leftovers", and every other package-plus-policy item never reported
        itself done: the registry actions all answered yes, the appx action
        answered no because nothing answered it, and one no is enough.
        Get-WDItemPresence cannot cover for it - it has no opinion the moment an
        item carries a registry action, which is exactly these.
    #>
    param($Action, $Inventory)

    switch ([string](Get-Prop $Action 'type' '')) {
        'registry' { try { return [bool](Test-WDRegistryActionSatisfied -Action $Action) } catch { return $false } }
        # Services are the second-commonest thing a run turns off, and unlike
        # tasks and Windows features they can be asked about for nothing:
        # ServiceController already carries StartType. DISM costs seconds, which
        # is why features and capabilities are not here - a probe that runs for
        # every action of every item while the window is being built has to be
        # free or it does not belong.
        'service'  { try { return [bool](Test-WDServiceActionSatisfied -Action $Action) } catch { return $false } }
        'registryKey' {
            # Deleting a key that is not there is nothing to do. Cheap enough to
            # answer without an inventory.
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
            # one. The inventory carries both because the walk that builds it
            # reads them together.
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
    <#
        Which handlers can say whether they are already done. Exposed so the
        self test can check every one of them is a handler that exists, and
        report how many of the manifest's handlers deliberately answer nothing.

        Unrolled, not ",@(...)". Every caller wraps this in @() to count it, and
        the comma operator makes that one element holding an array - the trap
        this file has already paid for twice.
    #>
    @($script:StateTests.Keys)
}

function Test-WDItemSatisfied {
    <#
        Is there anything left for this whole item to do?

        Every action has to answer yes, and an action whose guards fail on this
        machine is not asked - it will never run here, so it can neither be
        outstanding nor make the item look outstanding. Ten items in the
        manifest carry a guarded action and every one of them was permanently
        unsatisfiable because of it: "Lock screen Spotlight ads" has an
        Enterprise-only pair of policy writes, so on Home and Pro the item asked
        about two values that would never be written and answered no, for ever.

        An item with no actions answers $false. There is nothing to be done and
        nothing to have been done, and "already applied" is a claim.
    #>
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
    <#
        Switches a PowerToys module on or off, and optionally sets one of its
        hotkeys, writing the config directly. Works whether PowerToys is
        installed yet or not - which is the point: the choice is made in this
        GUI, and the install item that precedes it in the run does the rest.
    #>
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

Register-WDHandler 'SetNoSoundScheme' {
    <#
        "No Sounds" is not one value. The scheme name lives at the default of
        AppEvents\Schemes, and every event under AppEvents\Schemes\Apps carries
        its own .Current pointing at a .wav - and Windows plays what .Current
        says, not what the scheme name says. Writing only the name changes the
        label in the Sound control panel and nothing else.

        So it walks them, which is fifty-odd values per account, and that is why
        it is a handler rather than a manifest action: fifty journal entries per
        account for one tick would drown the report. Instead the whole AppEvents
        branch is exported once per hive and undone as a single .reg import,
        which also restores custom sounds exactly - a per-value undo could only
        restore what it happened to overwrite.
    #>
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
    <#
        The lists Windows keeps of what you have opened, run and searched for.
        One item rather than a dozen, because nobody wants to decide about
        TypedPaths separately from RunMRU, and because half of them are only
        meaningful together - clearing RecentDocs while leaving the jump lists
        alone clears the menu and not the thing behind it.

        Two kinds of target with two different reversibility stories, and the
        risk note says so rather than the code pretending they are the same:
        registry keys are exported before deletion and the rollback script
        imports them back; the jump-list files are per-application binary caches
        with no backup, because restoring one to a different Windows build is
        not something to promise.
    #>
    param($Action, $Context)

    $roots = @(Select-WDAccountHives -Hives (Get-WDUserHives) -Default $Context.DefaultHive `
                                     -Accounts (Get-WDContextAccounts $Context))
    if (-not $roots.Count) {
        return New-WDResult -Status Skipped -Message 'No accounts are selected for per-user settings'
    }

    # Whole keys, deleted and recreated empty where Windows expects them to exist.
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

    # Jump lists: the recent and pinned lists behind every taskbar and Start
    # icon. Per-application binaries with no meaningful per-file undo, so they
    # go to the Recycle Bin when the run is reversible and are hard-deleted when
    # the operator has asked for a permanent run.
    $files = 0
    $jump = @(
        (Join-Path ([string]$env:APPDATA) 'Microsoft\Windows\Recent\AutomaticDestinations')
        (Join-Path ([string]$env:APPDATA) 'Microsoft\Windows\Recent\CustomDestinations')
        (Join-Path ([string]$env:APPDATA) 'Microsoft\Windows\Recent')
    )
    foreach ($dir in $jump) {
        if (-not (Test-Path -LiteralPath $dir -ErrorAction SilentlyContinue)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
            if ($Context.Preview) { $files++; continue }
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $files++ } catch { }
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

# ================================================== the shortcut arrow ======
#
# Explorer draws the overlay from whatever `Shell Icons\29` points at, so the fix
# is to point it at a blank one. Every published version of this names an index
# in imageres.dll (usually 197) and none is safe to copy: measured on 25H2, 197
# is NEARLY blank rather than blank, and the index moves between builds. So the
# icon is WRITTEN rather than found - deterministic, and checkable by reading the
# file back.
#
# Set through Invoke-WDRegistryAction, so it is backed up and journalled like any
# manifest action; deleting that one value is the whole undo.
function New-WDBlankIcon {
    <#  A 16x16 32bpp fully transparent .ico, written byte by byte. Returns the
        path, or empty on failure.  #>
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

    # The one value this writes, built once so the preview and the apply cannot
    # disagree about what "already done" means.
    $act = [pscustomobject]@{
        type = 'registry'; scope = 'machine'
        values = @([pscustomobject]@{
            path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons'
            name = '29'; kind = 'String'; value = "$ico,0"
        })
    }
    # Idempotent, and it never said so: run twice, and the second preview still
    # promised to point the overlay at an icon it is already pointing at. The
    # icon file has to be there as well as the value - deleting it and leaving
    # the value behind is a shortcut overlay pointing at nothing.
    $done = (Test-Path -LiteralPath $ico) -and (Test-WDRegistryActionSatisfied -Action $act)
    if ($done) {
        return New-WDResult -Status AlreadySet -Message 'The shortcut overlay already points at the blank icon' `
                            -Detail "Shell Icons\29 is $ico,0"
    }
    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message 'Would point the shortcut overlay at a blank icon' `
                            -Detail "Writes $ico and sets Shell Icons\29 to it."
    }
    if (-not (New-WDBlankIcon -Path $ico)) {
        return New-WDResult -Status Failed -Message 'Could not create the blank icon the overlay needs'
    }

    $res = Invoke-WDRegistryAction -Context $Context -Action $act
    if ([string]$res.Status -notin @('Changed','Removed')) { return $res }

    # Explorer caches the overlay, so the value alone changes nothing until the
    # cache is dropped. The run restarts Explorer at the end regardless, which
    # is the other half of this.
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

# ================================================ update deferral periods ===
#
# The GUI collects the figure and it crosses on run-options.json, as the browser
# choice does; the manifest number is the fallback for every caller with no GUI.
# The shipped 365 and 7 are not anybody's choice - a year is simply the longest
# Windows accepts, and a week is a guess at how long others take to find the bad
# ones.
#
# Through Invoke-WDRegistryAction rather than Set-ItemProperty, so it is backed
# up and journalled exactly as the plain registry action it replaced was.
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
    # Clamped rather than trusted. The file is editable, and Windows silently
    # ignores a period outside its own range - which looks exactly like the
    # policy not having been written at all.
    if ($days -lt 0) { $days = 0 }
    if ($days -gt [int]$spec.Max) { $days = [int]$spec.Max }

    $base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $vals = @(
        [pscustomobject]@{ path = $base; name = [string]$spec.Flag; kind = 'DWord'; value = 1 }
        [pscustomobject]@{ path = $base; name = [string]$spec.Days; kind = 'DWord'; value = $days }
    )
    if ($kind -eq 'feature') {
        # Semi-Annual Channel. Without it the period is measured from a release
        # ring the machine may not be on, and the deferral reads as ignored.
        $vals += [pscustomobject]@{ path = $base; name = 'BranchReadinessLevel'; kind = 'DWord'; value = 20 }
    }
    $res = Invoke-WDRegistryAction -Action ([pscustomobject]@{ type = 'registry'; scope = 'machine'; values = $vals }) -Context $Context
    if ([string]$res.Status -in @('Changed','Removed')) {
        $unit = $(if ($days -eq 1) { 'day' } else { 'days' })
        return New-WDResult -Status Changed -Message "$kind updates held back for $days $unit" `
                            -Detail "Change or clear it in Settings > Windows Update > Advanced options, or undo this run."
    }
    $res
}

# ================================================ common issues document ====
#
# The file somebody opens a fortnight later when something is wrong and does not
# yet know this run is the answer. Shaped by that moment:
#
#   - lookup phrases first, deliberately generic. Nobody types "a Store app
#     cannot find my camera"; they type "camera not working". Comprehensive beats
#     tidy - an unsearched phrase costs a line, a missing one costs the point.
#   - each phrase names its option AND how to undo that one option, because the
#     next thing wanted after "this is the cause" is "make it stop".
#   - searched, never read top to bottom, so no narrative and no summary.
Register-WDHandler 'WriteCommonIssues' {
    param($Action, $Context)

    $items = @()
    try { $items = @($Context.Plan) } catch { }
    # Its own row would be in the list and has nothing to go wrong with.
    $items = @($items | Where-Object { $_ -and [string]$_.Id -ne [string]$Context.ItemId })

    # The journal, read once and grouped by item. This is where the PREVIOUS
    # values live, and they are the difference between "set it to 0" and "set
    # it back to 1" - which is the difference between naming a setting and
    # telling somebody how to undo it. Best effort: no journal is a preview or
    # a run that changed nothing, and the routes below say so honestly rather
    # than inventing a value.
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
            # Authored seeds first, then every other way each one gets typed.
            # Somebody searching "cant access account info" has to land here
            # just as surely as somebody searching the phrase that was written.
            Phrases = @(Expand-WDSymptoms -Phrases $seedPhrases)
            # Kept separately for the word index below, which must be built
            # from these and not from the expansion. Every generated variant is
            # made of the same words plus filler the generator supplied - so
            # indexing them adds "application", "program" and "unable" as
            # though somebody had chosen them, and puts "doesn" in an
            # alphabetical list of things that might be wrong with a computer.
            Seeds   = $seedPhrases
            Routes  = @(Get-WDItemRevertRoutes -Item $it -JournalEntries $mine)
        })
    }

    # Into the run directory, always, under the name the session declares. It
    # used to ask a run option where to put it, and the operator chose a folder
    # beside the tick box - which meant the one file written for somebody to
    # find later could end up anywhere, and nothing else in the toolkit could
    # find it to copy or to point at. Every apply now leaves a folder on the
    # desktop holding this and the rollback script together, which is the same
    # want answered once for every file rather than once for this one.
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
        # The desktop copy - see the same block in WriteRollbackScript for why
        # the run directory is the wrong answer to give somebody here.
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
    # phrase. Searching "camera" without it lands on whichever option happens
    # to be first and gives no hint that three others mention it too. Only
    # words that span two or more options are worth a line: a word belonging to
    # one option leads straight there on its own.
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
        # Seeds, never the expansion - see the note where Seeds is set.
        # Apostrophes are dropped rather than split on, or "doesn't" arrives
        # here as the two tokens "doesn" and "t".
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

# The rollback script, as a ROW rather than as something that simply happens.
# Written unconditionally it was invisible: the one artefact this application's
# safety argument rests on had no row, no preview line, and no way to confirm it
# was coming before Apply was pressed.
#
# order 9995, after the common issues document, so the journal it reads is
# complete. Nothing to undo, and nothing to preview beyond its own existence.
Register-WDHandler 'WriteRollbackScript' {
    param($Action, $Context)

    $path = $null
    try { $path = Join-Path $Context.Session.RunDir 'Undo-WinSetupToolkit.ps1' } catch { }
    if ($Context.Preview) {
        # The desktop copy, not the run directory. Both exist and both are real,
        # but the run directory is under %ProgramData% - a folder Explorer hides
        # by default, on a path nobody will remember - and this item's own
        # description promises "the run folder left on your desktop". A preview
        # that names the other one is the card contradicting the option above it.
        $where = $null
        try { $where = Get-WDDesktopRunFolder -Session $Context.Session } catch { }
        if ($where -and $where.Ok) {
            return New-WDResult -Status Changed -Message 'Would write the rollback script' `
                                -Detail (Join-Path ([string]$where.Path) 'Undo-WinSetupToolkit.ps1')
        }
        # Said, rather than quietly falling back to a path that contradicts the
        # description. Somebody reading "your desktop" and getting ProgramData
        # deserves to be told which of the two happened and why.
        return New-WDResult -Status Changed -Message 'Would write the rollback script, but not to the desktop' `
                            -Detail "$(if ($where) { [string]$where.Why } else { 'The desktop folder could not be resolved.' }) It would go to $path"
    }
    try {
        # The plan, so the window can group by option name and category rather
        # than by raw id. Nobody can make a decision about a row labelled
        # "perm-account-info".
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
                              Get-WDPowerToysRoot, Set-WDPowerToysJson, New-WDBlankIcon,
                              Test-WDPowerToysModuleSet, Test-WDActionSatisfied,
                              Test-WDItemSatisfied,
                              Get-WDStateTestNames,
                              Measure-WDFolder, Measure-WDFolderDetail, Format-WDBytes, Clear-WDFolderContents,
                              Get-WDStorageSources, Get-WDStoragePaths, Measure-WDRecycleBin,
                              Measure-WDReclaimable, Measure-WDDiskBuckets,
                              New-WDStorageSnapshot, Get-WDStorageReport, Get-WDDiskCapacity, Stop-WDDiskWalk
