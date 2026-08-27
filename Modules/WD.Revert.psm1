<#
    WD.Revert - undoing what past runs did.

    Two separate jobs, deliberately kept apart because they fail in different
    ways:

      Recurring effects - things this toolkit installed that keep running or
      keep firing. These are always fully removable, and each carries an honest
      resource estimate so the cost is visible before you opt in.

      Removed software - reinstalling is best-effort and frequently impossible.
      Rather than pretend, every entry carries a feasibility class and a plain
      reason, so the answer to "why can't I get this back" is on screen instead
      of buried in a log.
#>

$script:GuardTaskName  = 'Windows Setup Toolkit Persistence Guard'
$script:UpdateTaskName = 'Windows Setup Toolkit Update Guard'
$script:NoticeTaskName = 'Windows Setup Toolkit Guard Notice'

$script:SchedSvc = $null

function Test-WDTaskPresent {
    <#
        Is a task registered in the root folder?

        Not Get-ScheduledTask: given a -TaskName alone it enumerates every task
        in every folder over CIM and filters afterwards, which measures at ~900
        ms per call on a normal machine. Three of those is most of the delay
        before the Revert page could open. The Task Scheduler COM object answers
        the same question directly, in single-digit milliseconds. All three
        toolkit tasks register without -TaskPath, so they are in the root.
    #>
    param([string]$Name)
    try {
        if (-not $script:SchedSvc) {
            $script:SchedSvc = New-Object -ComObject 'Schedule.Service'
            $script:SchedSvc.Connect()
        }
        $folder = $script:SchedSvc.GetFolder('\')
        # GetTask throws rather than returning null when the name is unknown.
        try { [bool]$folder.GetTask($Name) } catch { $false }
    } catch {
        # The service can be disabled outright, and COM is refused in some
        # locked-down images. Slow and correct beats fast and absent.
        $script:SchedSvc = $null
        try { [bool](Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) } catch { $false }
    }
}

function Remove-WDGuardLeftovers {
    <#
        Files and the shared notice task, cleaned up once the guard that needed
        them is gone. The notice is shared, so it only goes when neither guard
        is left - otherwise removing one guard would silently mute the other.
    #>
    param([string[]]$Files)
    $root = Join-Path $env:ProgramData 'WinSetupToolkit'
    foreach ($f in $Files) {
        $p = Join-Path $root $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
    if ((Test-WDTaskPresent $script:GuardTaskName) -or (Test-WDTaskPresent $script:UpdateTaskName)) { return $false }
    if (Test-WDTaskPresent $script:NoticeTaskName) {
        try { Unregister-ScheduledTask -TaskName $script:NoticeTaskName -Confirm:$false -ErrorAction Stop } catch { }
    }
    $p = Join-Path $root 'Show-WDGuardNotice.ps1'
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    # The copy of the toolkit the guards run from, which exists so a guard
    # survives the folder it was installed from going away. With neither guard
    # left there is nothing to run it, and a few megabytes of dormant copy under
    # ProgramData is exactly the kind of leftover this toolkit exists to remove.
    # A directory, so it needs -Recurse and cannot ride along in the file loop.
    $t = Join-Path $root 'toolkit'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
    $true
}

function Get-WDRecurringEffects {
    <#
        Lasting or repeating changes, with what they actually cost. Present is
        evaluated live, so this doubles as "what is currently installed".
    #>

    $effects = New-Object System.Collections.Generic.List[psobject]

    # --- logon task installed by persistence-guard -------------------------
    $task = Test-WDTaskPresent $script:GuardTaskName
    $effects.Add([pscustomobject]@{
        Id       = 'guard-task'
        Name     = 'Persistence guard logon task'
        Detail   = 'Re-applies your saved selection every time someone signs in.'
        Overhead = 'Runs at each logon: roughly 20-60 s of background work on a full selection, up to ~120 MB RAM while it runs, nothing at idle. Adds no measurable delay to sign-in because it runs detached.'
        Present  = [bool]$task
    })

    # --- boot task installed by update-guard -------------------------------
    $upd = Test-WDTaskPresent $script:UpdateTaskName
    $stampFile = Join-Path (Join-Path $env:ProgramData 'WinSetupToolkit') 'guard-build.txt'
    $stamped   = ''
    if (Test-Path -LiteralPath $stampFile) {
        try { $stamped = (Get-Content -LiteralPath $stampFile -Raw).Trim() } catch { }
    }
    $effects.Add([pscustomobject]@{
        Id       = 'update-task'
        Name     = 'Feature update guard'
        Detail   = ('Re-applies your saved selection after Windows upgrades itself, and only then.' +
                    $(if ($stamped) { " Last recorded build $stamped." } else { '' }))
        Overhead = 'Nothing on a normal boot - one registry read, well under a second. Only after the build changes does it do real work, roughly 20-60 s in the background five minutes after that boot.'
        Present  = [bool]$upd
    })

    # --- PowerToys, required by the Copilot key remap ----------------------
    $ptCfg = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\Keyboard Manager\default.json'
    $hasRemap = $false
    if (Test-Path -LiteralPath $ptCfg) {
        try {
            $j = Get-Content -LiteralPath $ptCfg -Raw | ConvertFrom-Json
            $hasRemap = @($j.remapShortcuts.global | Where-Object { $_.originalKeys -match '134' }).Count -gt 0
        } catch { }
    }
    $effects.Add([pscustomobject]@{
        Id       = 'copilot-remap'
        Name     = 'Copilot key remap via PowerToys'
        Detail   = 'Maps Win+Shift+F23 to Right Ctrl. Needs PowerToys running at login to work.'
        Overhead = 'PowerToys Keyboard Manager sits resident: roughly 60-90 MB RAM steady and about 1 s added to sign-in. Removing the mapping here does not uninstall PowerToys.'
        Present  = $hasRemap
    })

    # --- Edge reinstall block ---------------------------------------------
    $edgePol = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' `
                                 -Name 'InstallDefault' -ErrorAction SilentlyContinue).InstallDefault
    $effects.Add([pscustomobject]@{
        Id       = 'edge-block'
        Name     = 'Edge reinstall block'
        Detail   = 'Update policy, updater services, scheduled tasks and the parked EdgeUpdate folder.'
        Overhead = 'No runtime cost - it is policy and disabled services. Reverting lets Edge reinstall itself at the next update check.'
        Present  = ($edgePol -eq 0)
    })

    # --- consumer content suppression --------------------------------------
    $cc = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
                            -Name 'DisableWindowsConsumerFeatures' -ErrorAction SilentlyContinue).DisableWindowsConsumerFeatures
    $effects.Add([pscustomobject]@{
        Id       = 'cdm-block'
        Name     = 'Bundled app re-push block'
        Detail   = 'ContentDeliveryManager silent installs and the consumer features policy.'
        Overhead = 'No runtime cost. Reverting lets Windows start delivering suggested apps again.'
        Present  = ($cc -eq 1)
    })
    $effects.ToArray()
}

function Remove-WDRecurringEffect {
    <#  Undo one recurring effect. Returns a WD.Result.  #>
    param([Parameter(Mandatory)][string]$Id, [switch]$Preview)

    switch ($Id) {
        'guard-task' {
            if ($Preview) { return New-WDResult -Status Changed -Message 'Would unregister the persistence guard logon task' }
            try {
                Unregister-ScheduledTask -TaskName $script:GuardTaskName -Confirm:$false -ErrorAction Stop
                $quiet = Remove-WDGuardLeftovers -Files @('Invoke-WDLogonGuard.ps1')
                New-WDResult -Status Removed -Message 'Persistence guard logon task removed' `
                             -Detail $(if ($quiet) { 'Its notifications stopped with it.' }
                                       else { 'The feature update guard is still installed and still notifies you.' })
            } catch {
                New-WDResult -Status Failed -Message 'Could not remove the logon task' -Detail $_.Exception.Message
            }
        }
        'update-task' {
            if ($Preview) { return New-WDResult -Status Changed -Message 'Would unregister the feature update guard and delete its runner' }
            try {
                Unregister-ScheduledTask -TaskName $script:UpdateTaskName -Confirm:$false -ErrorAction Stop
                # The runner and the build stamp are only meaningful with the
                # task, so they go too rather than being left as litter.
                $quiet = Remove-WDGuardLeftovers -Files @('Invoke-WDUpdateGuard.ps1', 'guard-build.txt')
                New-WDResult -Status Removed -Message 'Feature update guard removed' `
                             -Detail $(if ($quiet) { 'Its notifications stopped with it.' }
                                       else { 'The logon guard is still installed and still notifies you.' })
            } catch {
                New-WDResult -Status Failed -Message 'Could not remove the update guard' -Detail $_.Exception.Message
            }
        }
        'copilot-remap' {
            if ($Preview) { return New-WDResult -Status Changed -Message 'Would remove the Copilot key mapping from PowerToys' }
            $cfg = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\Keyboard Manager\default.json'
            if (-not (Test-Path -LiteralPath $cfg)) { return New-WDResult -Status NotPresent -Message 'No PowerToys mapping found' }
            try {
                $j = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
                $j.remapShortcuts.global = @($j.remapShortcuts.global | Where-Object { $_.originalKeys -notmatch '134' })
                $j | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cfg -Encoding UTF8
                New-WDResult -Status Removed -Message 'Copilot key mapping removed' `
                             -Detail 'Restart PowerToys for it to take effect. PowerToys itself was left installed.'
            } catch {
                New-WDResult -Status Failed -Message 'Could not edit the PowerToys config' -Detail $_.Exception.Message
            }
        }
        'edge-block' {
            if ($Preview) { return New-WDResult -Status Changed -Message 'Would allow Edge to install again' }
            try {
                $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
                if (Test-Path $pol) { Remove-Item -LiteralPath $pol -Recurse -Force -ErrorAction Stop }
                foreach ($s in @('edgeupdate','edgeupdatem','MicrosoftEdgeElevationService')) {
                    Set-Service -Name $s -StartupType Manual -ErrorAction SilentlyContinue
                }
                $parked = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeUpdate.wd-disabled'
                if (Test-Path -LiteralPath $parked) {
                    Rename-Item -LiteralPath $parked -NewName 'EdgeUpdate' -Force -ErrorAction SilentlyContinue
                }
                New-WDResult -Status Changed -Message 'Edge block lifted' `
                             -Detail 'Edge will reinstall itself at the next update check, or install it manually.'
            } catch {
                New-WDResult -Status Failed -Message 'Could not lift the Edge block' -Detail $_.Exception.Message
            }
        }
        'cdm-block' {
            if ($Preview) { return New-WDResult -Status Changed -Message 'Would allow bundled apps to be delivered again' }
            try {
                foreach ($v in @('SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled','ContentDeliveryAllowed')) {
                    Set-ItemProperty -LiteralPath 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
                                     -Name $v -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                }
                Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
                                    -Name 'DisableWindowsConsumerFeatures' -Force -ErrorAction SilentlyContinue
                New-WDResult -Status Changed -Message 'Bundled app delivery re-enabled'
            } catch {
                New-WDResult -Status Failed -Message 'Could not re-enable app delivery' -Detail $_.Exception.Message
            }
        }
        default { New-WDResult -Status Failed -Message "Unknown effect '$Id' - this is a bug" }
    }
}

function Get-WDPastRuns {
    <#
        Every apply this machine has a record of, newest first.

        TWO SOURCES, merged on the bare run id (not the folder name - the session
        is 20260817-001047 and its folder is run-20260817-001047, so keying on
        the directory lists every run twice). Neither is complete alone: the run
        FOLDERS carry the journals, which are the only thing that can put
        anything back, and runs.jsonl at the root outlives "Delete old run logs"
        - so a run whose folder is gone still appears, named and dated, saying
        plainly that it can no longer be undone.

        RUNS FROM ANOTHER MACHINE ARE DROPPED. Export-WDRunFolder copies a run to
        the desktop precisely so it can be carried away, and one brought back
        here describes registry values that were never on this computer.

        SameMachine is three-valued and only an explicit $false excludes. Runs
        written before identities were recorded answer "cannot say", and calling
        those foreign would empty this page for everybody on an older build.
    #>
    param([string]$Root, [switch]$AllMachines)

    if (-not $Root) { $Root = Join-Path $env:ProgramData 'WinSetupToolkit' }
    if (-not (Test-Path -LiteralPath $Root)) { return @() }

    $byId = [ordered]@{}

    # --- the run folders: the only source that carries a journal ---
    foreach ($d in (Get-ChildItem -LiteralPath $Root -Directory -Filter 'run-*' -ErrorAction SilentlyContinue)) {
        $report  = Join-Path $d.FullName 'report.json'
        $journal = Join-Path $d.FullName 'journal.jsonl'
        $undo    = Join-Path $d.FullName 'Undo-WinSetupToolkit.ps1'
        $envf    = Join-Path $d.FullName 'environment.json'
        $preview = $true; $removed = 0; $changed = 0; $when = $d.CreationTime
        if (Test-Path -LiteralPath $report) {
            try {
                $r = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
                $preview = [bool]$r.preview
                $removed = [int]$r.counts.removed
                $changed = [int]$r.counts.changed
                if ($r.PSObject.Properties['started']) { $when = [datetime]$r.started }
            } catch { }
        }
        # A preview writes no journal, so those runs have nothing to revert.
        if ($preview) { continue }

        # Written by Write-WDRunEnvironment before anything was touched. Absent
        # on every run older than the identity block, which is a real state.
        $machine = $null
        if (Test-Path -LiteralPath $envf) {
            try {
                $e = Get-Content -LiteralPath $envf -Raw | ConvertFrom-Json
                if ($e.PSObject.Properties['machine']) { $machine = $e.machine }
            } catch { }
        }

        # Keyed on the bare stamp, not the folder name. The session calls itself
        # '20260817-001047' and its folder is 'run-20260817-001047', so keying
        # on the directory would never match an index entry and every run with
        # both would be listed twice - once revertible, once not.
        $byId[($d.Name -replace '^run-', '')] = [pscustomobject]@{
            Id          = ($d.Name -replace '^run-', '')
            Folder      = $d.Name
            Path        = $d.FullName
            When        = $when
            Removed     = $removed
            Changed     = $changed
            Journal     = $(if (Test-Path -LiteralPath $journal) { $journal } else { $null })
            UndoFile    = $(if (Test-Path -LiteralPath $undo) { $undo } else { $null })
            Machine     = $machine
            SameMachine = (Test-WDSameMachine $machine)
            LogPresent  = (Test-Path -LiteralPath $journal)
            Source      = 'folder'
        }
    }

    # --- the standing index: what survives the folders being deleted ---
    foreach ($rec in (Get-WDRunIndex -Root $Root)) {
        $id = [string]$rec.run
        if (-not $id) { continue }
        if ($byId.Contains($id)) {
            # The folder is here and is the better record. Take only the machine
            # identity from the index, and only where the run itself did not
            # write one - a run folder that predates environment.json's identity
            # block can still have been indexed by a later build.
            if (-not $byId[$id].Machine -and $rec.PSObject.Properties['machine'] -and $rec.machine) {
                $byId[$id].Machine     = $rec.machine
                $byId[$id].SameMachine = (Test-WDSameMachine $rec.machine)
            }
            continue
        }
        $when = Get-Date
        try { if ($rec.started) { $when = [datetime]$rec.started } } catch { }
        $mach = $(if ($rec.PSObject.Properties['machine']) { $rec.machine } else { $null })
        $byId[$id] = [pscustomobject]@{
            Id          = $id
            Folder      = "run-$id"
            Path        = [string]$rec.dir
            When        = $when
            Removed     = $(if ($rec.counts) { [int]$rec.counts.removed } else { 0 })
            Changed     = $(if ($rec.counts) { [int]$rec.counts.changed } else { 0 })
            Journal     = $null
            UndoFile    = $null
            Machine     = $mach
            SameMachine = (Test-WDSameMachine $mach)
            LogPresent  = $false
            Source      = 'index'
        }
    }

    $out = @($byId.Values)
    if (-not $AllMachines) { $out = @($out | Where-Object { $_.SameMachine -ne $false }) }
    @($out | Sort-Object When -Descending)
}

function Get-WDRemovedItems {
    <#
        Everything past runs uninstalled, each classified for reinstall.

        Feasibility is computed offline - no network, no winget queries - so the
        list renders instantly. The real answer only comes from attempting it,
        and Invoke-WDReinstall reports that.
    #>
    param($Runs, $Provisioned)

    # ContainsKey, not -not $Runs: an empty list means the caller already looked
    # and found nothing, and treating that as "not supplied" made the Revert
    # page walk every run folder twice for no result.
    if (-not $PSBoundParameters.ContainsKey('Runs')) { $Runs = Get-WDPastRuns }
    $items = New-Object System.Collections.Generic.List[psobject]
    $seen  = New-Object System.Collections.Generic.HashSet[string]

    # Provisioned packages can be re-registered offline; everything else can't.
    # Null until something actually asks: this is a DISM call, and it was being
    # paid on every visit to the Revert page including the common case of no
    # past runs at all, or none that uninstalled an Appx package.
    # Handed in when somebody has already paid for it on another thread - see
    # Start-WDRemovedScan. ContainsKey rather than a truth test, because an empty
    # provisioned list is a real answer and asking DISM again for it would be the
    # whole cost this exists to avoid.
    $provisioned = $null
    if ($PSBoundParameters.ContainsKey('Provisioned') -and $null -ne $Provisioned) {
        $provisioned = @($Provisioned)
    }

    # Installed packages, enumerated ONCE. A Get-AppxPackage -Name per removed
    # package is ~76 ms each and was the real cost here - 2,220 ms against 170 for
    # one enumeration. The DISM call above took the blame because it sounds
    # expensive; measured unelevated, where DISM refuses instantly, the 2.2
    # seconds did not move. Lazy, so a run that removed no package never pays it.
    $installed = $null

    foreach ($run in $Runs) {
        if (-not $run.Journal) { continue }
        foreach ($line in (Get-Content -LiteralPath $run.Journal -ErrorAction SilentlyContinue)) {
            if (-not $line.Trim()) { continue }
            $e = $null
            try { $e = $line | ConvertFrom-Json } catch { continue }
            if (-not $e.undo -or $e.undo.method -ne 'reinstall') { continue }
            $name = [string]$e.undo.name
            if (-not $name -or -not $seen.Add($name)) { continue }

            $kind = [string]$e.type
            $feas = 'manual'; $reason = ''
            switch -Wildcard ($kind) {
                'appx*' {
                    if ($null -eq $provisioned) {
                        $provisioned = @()
                        try { $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object { $_.DisplayName }) } catch { }
                    }
                    if ($null -eq $installed) {
                        $installed = New-WDStringSet
                        try {
                            foreach ($p in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
                                $null = $installed.Add([string]$p.Name)
                            }
                        } catch { }
                    }
                    if ($provisioned -contains $name) {
                        $feas = 'offline'
                        $reason = 'Still provisioned on this machine, so it can be re-registered without a download.'
                    } elseif ($installed.Contains($name)) {
                        $feas = 'done'
                        $reason = 'Already installed again.'
                    } else {
                        $feas = 'store'
                        $reason = 'Deprovisioned. In-box packages are not published for download, so this only returns through the Microsoft Store, if it is listed there, or a Windows feature update.'
                    }
                }
                'capability' {
                    $feas = 'dism'
                    $reason = 'A Windows capability - restorable with DISM if the feature source is reachable.'
                }
                'winget' {
                    $feas = 'winget'
                    $reason = 'Was installed through winget, so it can be reinstalled the same way.'
                }
                default {
                    $feas = 'winget'
                    $reason = 'A desktop program. The toolkit will try winget; if the package is not published there you will need the vendor installer.'
                }
            }
            $items.Add([pscustomobject]@{
                Name       = $name
                Kind       = $kind
                Run        = $run.Id
                When       = $run.When
                Feasibility= $feas
                Reason     = $reason
            })
        }
    }
    @($items | Sort-Object Name)
}

function Start-WDRemovedScan {
    <#
        Get-WDRemovedItems on a runspace of its own, started early and collected
        later.

        It is the single most expensive thing the Revert page does - measured at
        3,035 ms cold and 2,278 ms warm on this machine, against about 1,500 ms
        for everything else the page reads put together - and almost all of that
        is one Get-AppxProvisionedPackage, which is a DISM call and does not get
        cheaper for having been asked before.

        The list it answers with is plain data, so unlike a decoded bitmap there
        is nothing here with thread affinity. Same shape as Start-WDFeatureRead
        in the generated rollback script, and for the same reason: the work is
        known the moment the run list is known, and the page has a second and a
        half of other reading to do before anything wants the answer.

        Answers $null rather than throwing. A caller that gets one asks the
        ordinary way, which is what every caller did before this existed.
    #>
    param([string]$ModulePath, $Runs)
    # $ModulePath is not used and not Mandatory, and both are deliberate. It is
    # kept because every other scan starter here takes one and a caller should
    # not have to know which of them needs it; and nothing is Mandatory because
    # this runs inside the Revert page's build, under the busy overlay, where a
    # parameter binding failure would take the page down to save two seconds.
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        # ONLY THE DISM CALL CROSSES, not the whole function. Sending the function
        # over meant the runspace spent its first 600 ms importing four modules
        # before it could start the thing being waited for, and that came straight
        # off the overlap.
        #
        # No comma: EndInvoke hands back a collection of what the script emitted,
        # so ",@(...)" would be one element holding the whole array.
        $null = $ps.AddScript({
            @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                ForEach-Object { $_.DisplayName })
        })
        @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
    } catch {
        try { Write-WDLog "Could not start the uninstalled-software read: $($_.Exception.Message)" -Level Warn } catch { }
        $null
    }
}

function Receive-WDRemovedScan {
    <#
        The other half. Never throws and never returns nothing useful: a job that
        failed, was never started, or came back empty-handed falls through to
        reading it here, which is exactly what used to happen every time.
    #>
    param($Job, $Runs)
    if ($Job) {
        try {
            $out = @($Job.PS.EndInvoke($Job.Handle))
            $bad = @($Job.PS.Streams.Error)
            $Job.PS.Dispose(); $Job.RS.Dispose()
            # AN ERROR HERE IS AN ANSWER, NOT A TRANSPORT FAILURE. The commonest
            # one by far is "the requested operation requires elevation", which
            # is what an unelevated run gets and is exactly the state the inline
            # version ends in too - it initialises the list to empty and lets the
            # call fail into it. So the empty list is handed on, and the only
            # thing the log gets is a note. Falling back here instead meant an
            # unelevated Revert page did the whole read a second time.
            if ($bad.Count) {
                try { Write-WDLog "The provisioned-package read answered with an error, so nothing is offered for offline re-registration: $($bad[0])" -Level Info } catch { }
            }
            return @(Get-WDRemovedItems -Runs $Runs -Provisioned $out)
        } catch {
            try { Write-WDLog "Could not collect the uninstalled-software read: $($_.Exception.Message)" -Level Warn } catch { }
        }
    }
    @(Get-WDRemovedItems -Runs $Runs)
}

function Get-WDUndoStatus {
    <#
        How much of one run is still in place.

        Offering "Roll back 15 August, 22:30" over a run already rolled back - by
        this script, by hand, or by an MDM putting its policies back - is the same
        defect as a preview promising 121 changes where all 121 are already made.
        The journal holds what changed and what it was before, so the question is
        answerable: read each target and see which side of the change it is on.

        Three counts, and Unknown is a real answer:

          Outstanding  the change this run made is still in place
          Done         the machine is back at the previous value
          Unknown      could not be asked cheaply, or at all

        UNKNOWN IS MOSTLY THE DEFAULT PROFILE. allusers values go to
        HKU:\WD_DEFAULT too, and that hive is only mounted for the length of a run
        - about a third of a full run's registry entries, far too many to fold
        into either of the others. Features, capabilities, and winget packages are
        Unknown for cost.

        Changes nothing, and MOUNTS nothing: a status read that loads a registry
        hive is no longer a status read.
    #>
    param([Parameter(Mandatory)][string]$Journal)

    $out = [pscustomobject]@{ Total = 0; Outstanding = 0; Done = 0; Unknown = 0 }
    if (-not (Test-Path -LiteralPath $Journal)) { return $out }

    # THROUGH Get-WDUndoPlan, which is what the rollback script is generated from,
    # so the number on the page and the list in the script cannot disagree. Two
    # things come with it:
    #
    #   - previous values are normalised, so a string compares against a string.
    #     Holding a PowerShell literal ("'Allow'", quotes included) made all 75
    #     string values in a real run read as outstanding for ever, including
    #     right after a rollback that had restored every one.
    #   - duplicates are gone. Two options can write the same value, and only the
    #     first entry knows what was there before the run.
    $plan = Get-WDUndoPlan -Journal $Journal
    if (Get-Command Use-WDUserHiveDrive -ErrorAction SilentlyContinue) { Use-WDUserHiveDrive }

    foreach ($s in $plan.Steps) {
        $out.Total++
        switch (Get-WDUndoStepState -Step $s) {
            'done'  { $out.Done++ }
            'todo'  { $out.Outstanding++ }
            default { $out.Unknown++ }
        }
    }
    $out
}

function Get-WDUndoStepState {
    <#
        Which side of its change one step's target is on: 'done', 'todo', or
        'unknown'.

        Split out of Get-WDUndoStatus so the revert page can label a single
        option without a second copy of the rules. The counts and the row have
        to agree - a page saying an option is already back above a total that
        counts it as outstanding is worse than either number on its own - and
        the only way to guarantee that is one function.

        'unknown' is a real answer rather than a rounding error, and is mostly
        the default profile: values written with scope allusers go to
        HKU:\WD_DEFAULT as well, and that hive is only mounted for the length of
        a run. Reading nothing there is not evidence the change is undone.

        Nothing here changes anything and nothing here mounts anything - a
        status read that loads a registry hive is no longer a status read.
    #>
    param($Step)

    if (-not $Step) { return 'unknown' }
    switch ([string]$Step.Method) {
        'registry' {
            $path = [string]$Step.Path
            # "The key is not there" and "I was not allowed to look" are
            # different answers, and only the first means the change is undone.
            if ($path -like 'HKU:\*') {
                $hive = 'HKU:\' + (($path.Substring(5) -split '\\')[0])
                if (-not (Test-Path -LiteralPath $hive)) { return 'unknown' }
            }
            $back = $null
            try {
                $back = Test-WDRegistryValueSet -Full $path -Name ([string]$Step.Name) `
                                                -Data $Step.Previous -Kind ([string]$Step.Kind) -Delete ([bool]$Step.Gone)
            } catch { }
            if ($null -eq $back) { return 'unknown' }
            if ($back)           { return 'done' }
            return 'todo'
        }
        'service' {
            $svc = $null
            try { $svc = Get-Service -Name ([string]$Step.Name) -ErrorAction SilentlyContinue } catch { }
            if (-not $svc) { return 'unknown' }
            $cur = $null
            try { $cur = [string]$svc.StartType } catch { }
            if (-not $cur)                           { return 'unknown' }
            if ($cur -eq [string]$Step.Previous)     { return 'done' }
            return 'todo'
        }
        # Free, through the same COM interface Test-WDTaskPresent uses, so the
        # twenty-odd tasks a real run disables stopped being Unknown.
        'task' {
            $on = Get-WDTaskEnabledState -Path ([string]$Step.Path) -Name ([string]$Step.Name)
            if ($null -eq $on) { return 'unknown' }
            if ($on)           { return 'done' }
            return 'todo'
        }
        'unregister-task' {
            $on = Get-WDTaskEnabledState -Path '\' -Name ([string]$Step.Name)
            if ($null -eq $on) { return 'done' }
            return 'todo'
        }
        'rename' {
            if (Test-Path -LiteralPath ([string]$Step.To))   { return 'done' }
            if (Test-Path -LiteralPath ([string]$Step.From)) { return 'todo' }
            return 'unknown'
        }
        'recycle' {
            if (Test-Path -LiteralPath ([string]$Step.Path)) { return 'done' }
            return 'todo'
        }
        'file-restore' {
            if ($Step.File) {
                if (Test-Path -LiteralPath ([string]$Step.Target)) { return 'todo' }
                return 'unknown'
            }
            if (Test-Path -LiteralPath ([string]$Step.Target)) { return 'todo' }
            return 'done'
        }
        # Features and capabilities need DISM, a power setting needs a powercfg
        # query, a .reg import cannot be compared against a live key at all, and
        # a winget package needs winget. Every one of those is seconds, and this
        # runs per step with somebody waiting on a page.
        default { return 'unknown' }
    }
}

function Get-WDTaskEnabledState {
    <#
        $true, $false, or $null for a task that cannot be found or asked about.

        Test-WDTaskPresent answers for the root folder, which is where the three
        toolkit tasks live. Everything a RUN disables is several folders down
        under \Microsoft\Windows, so this takes the path as well.
    #>
    param([string]$Path, [string]$Name)

    try {
        if (-not $script:SchedSvc) {
            $script:SchedSvc = New-Object -ComObject 'Schedule.Service'
            $script:SchedSvc.Connect()
        }
        $p = [string]$Path
        if ($p) { $p = $p.TrimEnd('\') }
        if (-not $p) { $p = '\' }
        $f = $script:SchedSvc.GetFolder($p)
        if (-not $f) { return $null }
        $t = $f.GetTask($Name)
        if (-not $t) { return $null }
        return [bool]$t.Enabled
    } catch {
        $script:SchedSvc = $null
        return $null
    }
}

function Invoke-WDReinstall {
    <#  Best-effort reinstall of one previously removed item.  #>
    param([Parameter(Mandatory)]$Item, [switch]$Preview)

    if ($Preview) { return New-WDResult -Status Changed -Message "Would attempt to reinstall $($Item.Name)" -Detail $Item.Reason }

    switch ($Item.Feasibility) {
        'done' { return New-WDResult -Status NotPresent -Message 'Already installed' }

        'offline' {
            try {
                $prov = Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                        Where-Object { $_.DisplayName -eq $Item.Name } | Select-Object -First 1
                if (-not $prov) { return New-WDResult -Status Failed -Message 'No longer provisioned' -Detail 'Try the Microsoft Store instead.' }
                $manifest = Join-Path (Split-Path $prov.InstallLocation -Parent) 'AppxManifest.xml'
                if (Test-Path -LiteralPath $manifest) {
                    Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ErrorAction Stop
                } else {
                    Add-AppxPackage -Path $prov.InstallLocation -ErrorAction Stop
                }
                New-WDResult -Status Changed -Message "$($Item.Name) reinstalled from the local provisioned copy"
            } catch {
                New-WDResult -Status Failed -Message "Could not re-register $($Item.Name)" -Detail $_.Exception.Message
            }
        }

        'dism' {
            try {
                $cap = Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { $_.Name -like "$($Item.Name)*" } | Select-Object -First 1
                if (-not $cap) { return New-WDResult -Status Failed -Message 'Capability not offered by this build' }
                $null = Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop
                New-WDResult -Status Changed -Message "$($Item.Name) restored"
            } catch {
                New-WDResult -Status Failed -Message "Could not restore $($Item.Name)" `
                             -Detail "$($_.Exception.Message) - usually means Windows Update is unreachable, since capability sources are downloaded on demand."
            }
        }

        'store' {
            New-WDResult -Status Blocked -Message "$($Item.Name) cannot be reinstalled automatically" -Detail $Item.Reason
        }

        default {
            if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
                return New-WDResult -Status Blocked -Message 'winget is not available on this machine' -Detail $Item.Reason
            }
            $r = Invoke-WDProcess -FilePath 'winget.exe' -TimeoutSeconds 900 -ArgumentList @(
                'install', '--name', "`"$($Item.Name)`"", '--silent',
                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
            if ($r.ExitCode -eq 0) {
                New-WDResult -Status Changed -Message "$($Item.Name) reinstalled via winget"
            } else {
                # 0x8A15002B / no applicable package is the common, expected miss.
                New-WDResult -Status Blocked -Message "$($Item.Name) is not available through winget" `
                             -Detail "winget exit $($r.ExitCode). Download it from the vendor if you still want it."
            }
        }
    }
}

function Invoke-WDRevertPlan {
    <#
        Runs a list of revert operations, emitting the same progress events as
        Invoke-WDPlan so the existing run page renders them without changes.

        Each op is @{ Kind = 'effect' | 'reinstall' | 'rollback'; Name = ...; ... }
    #>
    param(
        [Parameter(Mandatory)]$Ops,
        [Parameter(Mandatory)]$Session,
        [scriptblock]$Progress,
        [switch]$Preview,
        $CancelToken
    )

    $ops     = @($Ops)
    $total   = $ops.Count
    $results = New-Object System.Collections.Generic.List[psobject]
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $report  = { param($p) if ($Progress) { try { & $Progress $p | Out-Null } catch { } } }

    & $report @{ Phase = 'Start'; Index = 0; Total = $total; Elapsed = $sw.Elapsed }

    $i = 0
    foreach ($op in $ops) {
        if ($CancelToken -and $CancelToken.Cancel) { break }
        $i++
        $label = [pscustomobject]@{ Name = $op.Name }
        & $report @{ Phase = 'Item'; Index = $i; Total = $total; Item = $label; Result = $null; Elapsed = $sw.Elapsed }
        Write-WDLog "[$i/$total] $($op.Name)" -Level Info -Item 'revert'

        $r = $null
        try {
            switch ($op.Kind) {
                'effect'    { $r = Remove-WDRecurringEffect -Id $op.Id -Preview:$Preview }
                'reinstall' { $r = Invoke-WDReinstall -Item $op.Item -Preview:$Preview }
                'rollback'  {
                    # The script's own -Only, not a second executor here: that
                    # script is the tested one, and a copy means two answers to
                    # "how is a step put back".
                    #
                    # The caller orders these NEWEST FIRST, which is what gets a
                    # value several runs wrote right: June's script restores
                    # pre-June, then March's restores pre-March, and the last
                    # write stands. Oldest first leaves June's value standing.
                    $only = @(@($op.Only) | Where-Object { $_ })
                    $cmdArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($op.Path)`"", '-Console')
                    if ($only.Count) { $cmdArgs += @('-Only', ($only -join ',')) }
                    if ($Preview) {
                        $r = New-WDResult -Status Changed -Message $(if ($only.Count) {
                                "Would put back $($only.Count) option(s) from $($op.Path)"
                            } else { "Would run $($op.Path)" })
                    } else {
                        $res = Invoke-WDProcess -FilePath 'powershell.exe' -TimeoutSeconds 900 -ArgumentList $cmdArgs
                        $r = if ($res.ExitCode -eq 0) {
                            New-WDResult -Status Changed -Message 'Rollback script completed' -Detail $op.Path
                        } else {
                            New-WDResult -Status Partial -Message "Rollback finished with exit $($res.ExitCode)" `
                                         -Detail 'Registry and service changes are reversed on a best-effort basis; check the log.'
                        }
                    }
                }
                default { $r = New-WDResult -Status Failed -Message "Unknown revert operation '$($op.Kind)' - this is a bug" }
            }
        } catch {
            $r = New-WDResult -Status Failed -Message "Revert step failed" -Detail $_.Exception.Message
        }
        if (-not $r) { $r = New-WDResult -Status Failed -Message 'No result returned' }

        $record = [pscustomobject]@{
            Id = $op.Kind; Name = $op.Name; Category = 'Revert'; Risk = 0
            Status = $r.Status; Message = $r.Message; Detail = $r.Detail
        }
        $results.Add($record)
        & $report @{ Phase = 'Item'; Index = $i; Total = $total; Item = $label; Result = $record; Elapsed = $sw.Elapsed }
    }

    $sw.Stop()
    & $report @{ Phase = 'Done'; Index = $i; Total = $total; Elapsed = $sw.Elapsed; Results = $results }
    ,$results
}

# ================================================== the rollback script =====
#
# Here rather than WD.Core because this is the third thing in this module that
# undoes a past run, and Core is what a rollback READS rather than what reads it.
#
# The generator's one job is to hand the emitted script REAL VALUES. Quoting,
# escaping, and rendering all belong on this side: the script imports nothing,
# and a mistake in it is only ever discovered by somebody running a rollback.

function ConvertTo-WDPsLiteral {
    <#
        A value as PowerShell source, for pasting into the generated script.

        This exists because the journal used to be written the other way round:
        Invoke-WDRegistryAction wrapped a previous string value in quotes before
        recording it, so the journal held a PowerShell literal rather than a
        value, and Export-WDUndoScript interpolated that literal unquoted. It
        worked, and it put the escaping in the one place that could not test it -
        a previous value containing an apostrophe produced a script that stopped
        parsing at that line, and a MultiString previous value came out as the
        text "System.String[]".

        It also broke reading. Get-WDUndoStatus compared the journalled
        "'Allow'" against the machine's Allow and found them different, so all
        75 of the string values in a real run's journal read as outstanding
        forever, including immediately after a successful rollback.
    #>
    param($Value)

    if ($null -eq $Value)     { return '$null' }
    if ($Value -is [bool])    { return $(if ($Value) { '$true' } else { '$false' }) }
    # Before the general array case: a byte array IS an array, and rendering it
    # as one loses the type the registry needs.
    if ($Value -is [byte[]])  { return '[byte[]]@(' + ((@($Value) | ForEach-Object { [int]$_ }) -join ',') + ')' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [uint32]) { return [string]$Value }
    if ($Value -is [Array]) {
        if (-not @($Value).Count) { return '@()' }
        return '@(' + ((@($Value) | ForEach-Object { ConvertTo-WDPsLiteral $_ }) -join ',') + ')'
    }
    "'" + ([string]$Value -replace "'", "''") + "'"
}

function ConvertFrom-WDUndoPrevious {
    <#
        The value a registry entry held before the run, whatever shape the
        journal recorded it in.

        Two shapes, because journals outlive builds. A modern entry carries
        raw = $true and the value itself. An older one carries a PowerShell
        literal: a string wrapped in single quotes, or - for the taskbar
        auto-hide blob, which is a handler rather than a manifest action - the
        text "@(48,0,4,...)". Both are unwrapped here so that everything
        downstream, the emitted script and the status read alike, only ever
        sees a value.

        '__ABSENT__' is not a value and stays the sentinel it is: it means the
        name did not exist before the run, so putting it back is a delete.
    #>
    param($Value, [string]$Kind = 'DWord', [bool]$Raw = $false)

    if ($null -eq $Value) { return $null }
    if (($Value -is [string]) -and ([string]$Value -eq '__ABSENT__')) { return '__ABSENT__' }

    if (-not $Raw -and ($Value -is [string])) {
        $t = [string]$Value
        if ($Kind -eq 'Binary' -and $t -match '^@\(\s*([0-9\s,]*)\s*\)$') {
            $nums = @($matches[1] -split ',' | Where-Object { $_.Trim() } | ForEach-Object { [byte][int]$_.Trim() })
            return ,([byte[]]$nums)
        }
        if ($t.Length -ge 2 -and $t.StartsWith("'") -and $t.EndsWith("'")) {
            return ($t.Substring(1, $t.Length - 2) -replace "''", "'")
        }
    }

    switch ($Kind) {
        'Binary'      { return ,([byte[]]@(@($Value) | ForEach-Object { [byte][int]$_ })) }
        'MultiString' { return ,([string[]]@(@($Value) | ForEach-Object { [string]$_ })) }
        'DWord'       { try { return [int]$Value }   catch { return $Value } }
        'QWord'       { try { return [int64]$Value } catch { return $Value } }
        default       { return [string]$Value }
    }
}

function Get-WDUndoStepKey {
    <#
        What this step ACTS ON, as one string.

        The dedup rule - keep the first entry for a target and drop the rest,
        because only the first knows what was there before - has to be applied
        twice now: within a journal, and again across journals when several runs
        are being undone together. Two copies of "what counts as the same
        target" is one copy plus a way for them to disagree, so it is written
        once here and both callers ask.

        The four strings that used to be inline in Get-WDUndoPlan are reproduced
        exactly, because a journal read by an older build and this one must
        dedup to the same set. The methods that had no key have one now, which
        means two items disabling the same feature in one run collapse to one
        step - correct, and previously an accident of nobody having written the
        line.
    #>
    param($Step)

    if (-not $Step) { return '' }
    switch ([string]$Step.Method) {
        'registry'        { "reg|$([string]$Step.Path)|$([string]$Step.Name)" }
        'service'         { "svc|$([string]$Step.Name)" }
        'task'            { "task|$([string]$Step.Path)|$([string]$Step.Name)" }
        'recycle'         { "bin|$([string]$Step.Path)" }
        'powercfg'        { "pwr|$([string]$Step.Sub)|$([string]$Step.Setting)" }
        'unregister-task' { "untask|$([string]$Step.Name)" }
        'feature'         { "feat|$([string]$Step.Name)" }
        'feature-off'     { "featoff|$([string]$Step.Name)" }
        'capability-off'  { "capoff|$([string]$Step.Name)" }
        'regfile'         { "regfile|$([string]$Step.Target)" }
        'file-restore'    { "file|$([string]$Step.Target)" }
        'rename'          { "rename|$([string]$Step.To)" }
        'uninstall'       { "uninst|$([string]$Step.Name)" }
        default           { '' }
    }
}

function Get-WDUndoPlan {
    <#
        The journal, normalised into the steps a rollback would take.

        Three things happen here that the emitter used to do inline or not at
        all, and all three are correctness rather than tidiness:

        DEDUPLICATION, and it is the one that silently produced a wrong result.
        Two options can write the same value, and the second one's "previous" is
        what the first one wrote. Replaying both in order restores the original
        and then puts the first option's value straight back on top of it, so
        the machine ends up holding a value nobody asked for. The FIRST entry
        for a target is the only one that knows what was there before the run,
        so that is the one kept and the rest are dropped.

        NORMALISATION of the previous value - see ConvertFrom-WDUndoPrevious.

        NAMES. The journal records an option's id, and 'perm-account-info' is
        not something to show anybody. The plan the run executed carries the
        name and the category, so it is handed in and each step is labelled
        with it; a step whose id is not in the plan keeps the id, which is what
        happens for a journal read back on its own.
    #>
    param(
        [Parameter(Mandatory)][string]$Journal,
        # The resolved plan, for names and categories. Optional: without it the
        # steps carry their raw ids, which is still a working script.
        $Items
    )

    $names = @{}
    $cats  = @{}
    # And the one-line description, in the tense a page about what has already
    # happened is written in - see Get-WDRevertDescription. Collected here
    # because it comes off the same items the names do, and keyed by option
    # rather than by step: a description belongs to the option, and repeating it
    # on each of a hundred steps would put the same paragraph a hundred times
    # into a file whose whole premise is that somebody can read it.
    $descs = @{}
    foreach ($it in @($Items)) {
        if (-not $it) { continue }
        $id = [string](Get-Prop $it 'Id' '')
        if (-not $id) { continue }
        $names[$id] = [string](Get-Prop $it 'Name' $id)
        $cats[$id]  = [string](Get-Prop $it 'Category' 'Other')
        $d = [string](Get-Prop $it 'Desc' '')
        if ($d) { $descs[$id] = [string](Get-WDRevertDescription -Desc $d) }
    }

    $steps     = New-Object System.Collections.Generic.List[psobject]
    $reinstall = New-Object System.Collections.Generic.List[string]
    $owners    = New-Object System.Collections.Generic.List[string]
    $seen      = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $dropped   = 0

    if (-not (Test-Path -LiteralPath $Journal)) {
        return [pscustomobject]@{ Steps = @(); Reinstall = @(); Owners = @(); Dropped = 0
                                  WantsHku = $false; WantsDefault = 0; Descs = @{} }
    }

    foreach ($line in (Get-Content -LiteralPath $Journal -ErrorAction SilentlyContinue)) {
        if (-not $line.Trim()) { continue }
        $e = $null
        try { $e = $line | ConvertFrom-Json } catch { continue }
        if (-not $e -or -not $e.undo) { continue }

        $id     = [string]$e.item
        $method = [string]$e.undo.method
        $step   = $null

        switch ($method) {
            'registry' {
                $path = [string]$e.undo.path
                $name = [string]$e.undo.name
                $kind = [string]$e.undo.kind
                if (-not $kind) { $kind = 'DWord' }
                $prev = ConvertFrom-WDUndoPrevious -Value $e.undo.previous -Kind $kind `
                                                   -Raw ([bool](Get-Prop $e.undo 'raw' $false))
                $step = [pscustomobject]@{
                    Method = 'registry'; Path = $path; Name = $name; Kind = $kind
                    Previous = $prev
                    # Absent before the run, so putting it back is a delete.
                    Gone = ($null -eq $prev -or (($prev -is [string]) -and $prev -eq '__ABSENT__'))
                }
            }
            'service' {
                $name = [string]$e.undo.name
                $step = [pscustomobject]@{ Method = 'service'; Name = $name; Previous = [string]$e.undo.previous }
            }
            'powercfg' {
                $step = [pscustomobject]@{ Method = 'powercfg'; Sub = [string]$e.undo.sub; Setting = [string]$e.undo.setting
                                           Ac = [int]$e.undo.ac; Dc = [int]$e.undo.dc }
            }
            'task' {
                $p = [string]$e.undo.path; $n = [string]$e.undo.name
                $step = [pscustomobject]@{ Method = 'task'; Path = $p; Name = $n }
            }
            # Registered BY the run, so undoing it means taking it off again.
            # This had no case in the emitter at all, which meant a run that
            # installed a persistence guard offered no way to remove it.
            'unregister-task' {
                $step = [pscustomobject]@{ Method = 'unregister-task'; Name = [string]$e.undo.name }
            }
            'feature'        { $step = [pscustomobject]@{ Method = 'feature';        Name = [string]$e.undo.name } }
            'feature-off'    { $step = [pscustomobject]@{ Method = 'feature-off';    Name = [string]$e.undo.name } }
            'capability-off' { $step = [pscustomobject]@{ Method = 'capability-off'; Name = [string]$e.undo.name } }
            # A whole key branch exported to a .reg file before it was deleted.
            # Also had no case: SetNoSoundScheme is the one that uses it, and
            # its undo - every custom sound anybody had - was being dropped.
            'regfile' {
                $step = [pscustomobject]@{ Method = 'regfile'; File = [string]$e.undo.file; Target = [string]$e.target }
            }
            'file-restore' {
                $step = [pscustomobject]@{ Method = 'file-restore'; Target = [string]$e.undo.target; File = [string]$e.undo.file }
            }
            'rename' {
                $step = [pscustomobject]@{ Method = 'rename'; From = [string]$e.undo.from; To = [string]$e.undo.to }
            }
            'recycle' {
                $p = [string]$e.undo.path
                $step = [pscustomobject]@{ Method = 'recycle'; Path = $p }
            }
            # Installed by the run rather than removed by it - a winget package
            # from the Add section. Undoing an install is an uninstall, and this
            # is the third method the emitter never had a case for.
            'uninstall' {
                $step = [pscustomobject]@{ Method = 'uninstall'; Name = [string]$e.undo.name }
            }
            'reinstall' { $reinstall.Add([string]$e.undo.name) }
            'owner'     { $owners.Add("$([string]$e.undo.path)  (was owned by $([string]$e.undo.previous))") }
        }

        if (-not $step) { continue }

        # One dedup, after the step exists, rather than four spellings of the
        # rule inside the branches. The first entry for a target is the only one
        # that knows what was there before the run, so it is the one kept.
        $key = Get-WDUndoStepKey $step
        if ($key -and -not $seen.Add($key)) { $dropped++; continue }

        Add-Member -InputObject $step -NotePropertyName 'Key'      -NotePropertyValue $key
        Add-Member -InputObject $step -NotePropertyName 'Id'       -NotePropertyValue $id
        Add-Member -InputObject $step -NotePropertyName 'ItemName' -NotePropertyValue $(if ($names.ContainsKey($id)) { $names[$id] } else { $id })
        Add-Member -InputObject $step -NotePropertyName 'Category' -NotePropertyValue $(if ($cats.ContainsKey($id)) { $cats[$id] } else { 'Other' })
        $steps.Add($step)
    }

    $hku = @($steps | Where-Object { $_.Method -eq 'registry' -and [string]$_.Path -like 'HKU:\*' }).Count
    $def = @($steps | Where-Object { $_.Method -eq 'registry' -and [string]$_.Path -like 'HKU:\WD_DEFAULT\*' }).Count

    $kept = @{}
    foreach ($s in $steps) {
        $sid = [string]$s.Id
        if ($descs.ContainsKey($sid)) { $kept[$sid] = $descs[$sid] }
    }

    [pscustomobject]@{
        Steps        = $steps.ToArray()
        Reinstall    = @($reinstall | Sort-Object -Unique)
        Owners       = @($owners | Sort-Object -Unique)
        Dropped      = $dropped
        WantsHku     = [bool]$hku
        WantsDefault = $def
        # Only for the options this journal actually names. Every description in
        # the manifest would put two hundred paragraphs into a script that has
        # twenty options to show.
        Descs        = $kept
    }
}

function Get-WDUndoStepKind {
    <#
        Which kind of thing this step puts back, as a heading somebody reads.

        A second copy of what the generated script's Get-WDUndoKind answers, and
        deliberately so: that script imports nothing by design, so the two
        cannot share code and never could. The strings match exactly, because
        the toolkit's revert page and the standalone window are meant to look
        like one interface and a heading that differed between them would say
        they are not.
    #>
    param($Step)

    switch ([string]$Step.Method) {
        'registry'        { 'Registry values' }
        'regfile'         { 'Registry values' }
        'service'         { 'Services' }
        'task'            { 'Scheduled tasks' }
        'unregister-task' { 'Scheduled tasks' }
        'feature'         { 'Windows features' }
        'feature-off'     { 'Windows features' }
        'capability-off'  { 'Windows features' }
        'file-restore'    { 'Files and folders' }
        'rename'          { 'Files and folders' }
        'recycle'         { 'Files and folders' }
        'powercfg'        { 'Power settings' }
        'uninstall'       { 'Installed programs' }
        default           { 'Other' }
    }
}

# The verbs item descriptions actually open with, past-tensed. HARVESTED from the
# manifest, not imagined: ~107 of 266 begin with one of these and the rest begin
# with a noun ("The taskbar search box...", "Windows sends...") which describes
# the SUBJECT and reads correctly on either page, so those are left alone.
#
# A table rather than a rule because the irregulars break "add -ed": Takes/Took,
# Goes/Went, Hides/Hid, Leaves/Left, Makes/Made, Runs/Ran, Holds/Held, Sets/Set.
$script:WDPastVerbs = @{
    'adds' = 'Added'; 'blocks' = 'Blocked'; 'brings' = 'Brought'; 'checks' = 'Checked'
    'clears' = 'Cleared'; 'compacts' = 'Compacted'; 'confirms' = 'Confirmed'
    'delays' = 'Delayed'; 'deletes' = 'Deleted'; 'denies' = 'Denied'
    'disables' = 'Disabled'; 'gives' = 'Gave'; 'goes' = 'Went'; 'hands' = 'Handed'
    'hides' = 'Hid'; 'holds' = 'Held'; 'includes' = 'Included'; 'installs' = 'Installed'
    'keeps' = 'Kept'; 'leaves' = 'Left'; 'lets' = 'Let'; 'lifts' = 'Lifted'
    'makes' = 'Made'; 'puts' = 'Put'; 'reads' = 'Read'; 'registers' = 'Registered'
    'releases' = 'Released'; 'removes' = 'Removed'; 'replaces' = 'Replaced'
    'runs' = 'Ran'; 'searches' = 'Searched'; 'sets' = 'Set'; 'shows' = 'Showed'
    'stops' = 'Stopped'; 'switches' = 'Switched'
    'takes' = 'Took'; 'turns' = 'Turned'; 'uninstalls' = 'Uninstalled'
    'uses' = 'Used'; 'writes' = 'Wrote'
    # Never 'steps'. The one description that opens with it is "Steps Recorder,
    # Math Recognizer, Windows Fax and Scan..." - a list of Windows features, and
    # Steps Recorder is the name of one of them. "Stepped Recorder" is what a
    # table that cannot tell a verb from a product name produces, and it is the
    # reason every entry here was checked against the rewritten output rather
    # than reasoned about.
}

# Verbs that only ever get rewritten in a LATER clause, never at the start. A
# description opening with one of these is usually naming a thing - "Sponsored
# links...", "Sync..." - but "..., and drops the ads" can only be a verb, because
# the sentence has already been established as being in this voice.
$script:WDPastVerbsTail = @{
    'drops' = 'Dropped'; 'points' = 'Pointed'; 'sends' = 'Sent'; 'moves' = 'Moved'
    'opens' = 'Opened'; 'forces' = 'Forced'; 'allows' = 'Allowed'
    'prevents' = 'Prevented'; 'restores' = 'Restored'; 'redirects' = 'Redirected'
    'silences' = 'Silenced'; 'suppresses' = 'Suppressed'; 'skips' = 'Skipped'
    're-runs' = 'Re-ran'; 'finds' = 'Found'
    # Deliberately NOT here: re-installs, re-applies, watches, refuses, installs.
    # Every one of those turns up inside a relative clause describing something
    # that is still true - "the policy that stops Windows checking", "It never
    # re-installs anything" - and a relative clause stays in the present after a
    # past-tense main verb. Rewriting them is the one way this can produce a
    # sentence that is grammatical and false.
}

function Get-WDRevertDescription {
    <#
        An item's own description, in the tense the Revert page is written in.

        The page lists what a machine has ALREADY had done to it, so "Stops
        Windows sending diagnostic data" describes something that already happened
        as though it were about to.

        PAST TENSE RATHER THAN REVERSAL VOICE. Turning "Stops X" into "Allows X"
        needs the object rearranged - "Allows Windows sending diagnostic data"
        wants "to send" - and every rule that fixes one description breaks
        another. Past tense touches one word and cannot produce a sentence that
        does not parse.

        THE WHOLE SENTENCE MOVES OR NONE OF IT DOES. "Removes the Copilot app and
        blocks its return" must become "Removed ... and blocked ...", or the
        second half claims a removal is still being enforced by the run you are
        undoing. But a description OPENING with a noun is not in this voice at
        all, so a later clause is only touched when the first word was.
    #>
    param([string]$Desc)
    $Desc = [string]$Desc
    if (-not $Desc.Trim()) { return '' }

    $first = ($Desc -split ' ')[0]
    $key   = $first.ToLower().TrimEnd(',', '.', ':', ';')
    if (-not $script:WDPastVerbs.ContainsKey($key)) { return $Desc }

    # The tail of the first word, so "Stops," keeps its comma.
    $tail = $first.Substring($key.Length)
    $out  = $script:WDPastVerbs[$key] + $tail + $Desc.Substring($first.Length)

    # The later clauses, now that the sentence is known to be in this voice.
    # Case-insensitive on the boundary word and lower-case on the way out: a verb
    # after "and" is not the start of a sentence.
    $tails = @{}
    foreach ($k in $script:WDPastVerbs.Keys)     { $tails[$k] = $script:WDPastVerbs[$k] }
    foreach ($k in $script:WDPastVerbsTail.Keys) { $tails[$k] = $script:WDPastVerbsTail[$k] }
    foreach ($lead in @(' and ', ' then ', ' otherwise ', ' but ', ' or ', ', ', '; ', '. ')) {
        foreach ($v in @($tails.Keys)) {
            $find = $lead + $v + ' '
            if ($out.IndexOf($find, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $past = [string]$tails[$v]
                # After a full stop it is a new sentence and keeps its capital.
                $rep = $lead + $(if ($lead -eq '. ') { $past } else { $past.ToLower() }) + ' '
                $out = $out -replace [regex]::Escape($find), $rep
            }
        }
    }
    $out
}

function Get-WDUndoStepText {
    <#
        One line saying exactly what putting this step back would do.

        The other half of the pair above, and the same argument applies. It is
        what the Details panel under a row shows, and what the search box looks
        inside - so a registry path typed into the box finds the option that
        wrote it.
    #>
    param($Step)

    switch ([string]$Step.Method) {
        'registry' {
            if ($Step.Gone) { return "Delete $($Step.Name) under $($Step.Path) - it did not exist before the run" }
            $v = $Step.Previous
            $s = [string]$v
            if ($v -is [byte[]])            { $s = "$(@($v).Count) bytes" }
            elseif ($v -is [string[]])      { $s = (@($v) -join ', ') }
            elseif ($s -eq '')              { $s = '(an empty value)' }
            elseif ($s.Length -gt 60)       { $s = $s.Substring(0, 57) + '...' }
            return "Set $($Step.Name) under $($Step.Path) back to $s"
        }
        'service'         { return "Set the $($Step.Name) service back to $($Step.Previous) startup" }
        'task'            { return "Re-enable the scheduled task $($Step.Path)$($Step.Name)" }
        'unregister-task' { return "Remove the scheduled task $($Step.Name), which this run registered" }
        'feature'         { return "Turn the Windows feature $($Step.Name) back on" }
        'feature-off'     { return "Turn the Windows feature $($Step.Name) back off" }
        'capability-off'  { return "Remove the Windows capability $($Step.Name), which this run added" }
        'powercfg'        { return "Put the power setting $($Step.Sub)\$($Step.Setting) back to $($Step.Ac) on mains, and $($Step.Dc) on battery" }
        'regfile'         { return "Import $($Step.File), which is the whole of $($Step.Target) as it was before the run" }
        'file-restore'    { if ($Step.File) { return "Restore $($Step.Target) from the copy taken before the run" }
                            return "Delete $($Step.Target), which this run created" }
        'rename'          { return "Move $($Step.From) back to $($Step.To)" }
        'recycle'         { return "Take $($Step.Path) back out of the Recycle Bin" }
        'uninstall'       { return "Uninstall $($Step.Name), which this run installed" }
        default           { return "$($Step.Method) $($Step.Name)" }
    }
}

function Get-WDCombinedUndoPlan {
    <#
        One plan over several runs, oldest first.

        THE DEDUP RULE HAS TO CROSS RUNS, and that is the whole reason this
        exists rather than the page calling Get-WDUndoPlan per run and
        concatenating the results. If March's run moved a value from 1 to 0 and
        June's moved it from 0 to 2, the value to put back is 1 - and only
        March's entry knows it. So: oldest first, and the first entry for a
        target wins, which is exactly the rule applied inside a single journal
        and for exactly the same reason.

        Concatenating without this is not a cosmetic fault. It would replay
        June's entry as well, putting 0 back over the 1 that had just been
        restored, and leaving the machine holding a value nobody ever chose -
        with a journal saying it had been returned to its original state.

        Each step is stamped with the run that contributed it, so the page can
        show one run's share without reading anything again. That is NOT the
        same list as reverting that run on its own, which is its own journal's
        plan with its own previous values - a step superseded here still belongs
        to the earlier run. The two answer different questions and the page asks
        whichever one the picker is on.

        A run whose folder has been deleted carries no journal and contributes
        nothing; it is still counted in Runs so the page can say so rather than
        leave it out and look complete.
    #>
    param($Runs, $Items)

    $ordered = @(@($Runs) | Where-Object { $_ } | Sort-Object When)
    $steps     = New-Object System.Collections.Generic.List[psobject]
    $reinstall = New-Object System.Collections.Generic.List[string]
    $owners    = New-Object System.Collections.Generic.List[string]
    $seen      = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $per       = New-Object System.Collections.Generic.List[psobject]
    $dropped   = 0
    # THE SAME SHAPE Get-WDUndoPlan RETURNS. A description belongs to the option
    # rather than to the run, so the merge is a union rather than a first-wins:
    # what would differ between two runs is nothing, since both read it from the
    # same manifest. It is here because two functions answering the same question
    # with different shapes is a caller reaching for a field that exists on one
    # of them - which is how this was found.
    $descs     = @{}
    foreach ($run in $ordered) {
        $mine = 0
        if ($run.Journal) {
            $plan = Get-WDUndoPlan -Journal $run.Journal -Items $Items
            $dropped += [int]$plan.Dropped
            foreach ($dk in @($plan.Descs.Keys)) { $descs[$dk] = [string]$plan.Descs[$dk] }
            foreach ($s in @($plan.Steps)) {
                $k = [string]$s.Key
                if ($k -and -not $seen.Add($k)) { $dropped++; continue }
                Add-Member -InputObject $s -NotePropertyName 'Run'     -NotePropertyValue ([string]$run.Id) -Force
                Add-Member -InputObject $s -NotePropertyName 'RunWhen' -NotePropertyValue $run.When -Force
                $steps.Add($s); $mine++
            }
            foreach ($r in @($plan.Reinstall)) { $reinstall.Add([string]$r) }
            foreach ($o in @($plan.Owners))    { $owners.Add([string]$o) }
        }
        $per.Add([pscustomobject]@{
            Id = [string]$run.Id; When = $run.When; Steps = $mine
            LogPresent = [bool]$run.LogPresent; Run = $run
        })
    }

    $hku = @($steps | Where-Object { $_.Method -eq 'registry' -and [string]$_.Path -like 'HKU:\*' }).Count
    $def = @($steps | Where-Object { $_.Method -eq 'registry' -and [string]$_.Path -like 'HKU:\WD_DEFAULT\*' }).Count

    [pscustomobject]@{
        Steps        = $steps.ToArray()
        Reinstall    = @($reinstall | Sort-Object -Unique)
        Owners       = @($owners | Sort-Object -Unique)
        Dropped      = $dropped
        WantsHku     = [bool]$hku
        WantsDefault = $def
        Descs        = $descs
        # Newest first, which is the order a picker reads in - the oldest-first
        # pass above is about correctness, not about presentation.
        Runs         = @($per | Sort-Object When -Descending)
    }
}

# The whole of the generated script that is not data. Kept as one literal
# here-string rather than assembled line by line, for two reasons: it is
# ordinary PowerShell that can be read as PowerShell, and a single-quoted
# here-string interpolates nothing, so the hundred-odd dollar signs in it are
# the emitted script's variables rather than this module's.
#
# Everything above it in the emitted file is data. Everything in it is fixed.
# That split is what makes the script testable at all - the body is the same
# bytes on every run, so a self test that exercises one exercises them all.
$script:WDUndoBody = @'

$ErrorActionPreference = 'Continue'

# A window needs a single-threaded apartment and "Run with PowerShell" does not
# always give one. Relaunch once, marked so a failure cannot loop.
if (-not $Console -and -not $env:WD_UNDO_STA -and
    [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $env:WD_UNDO_STA = '1'
    $me = $PSCommandPath
    if ($me) {
        & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $me @PSBoundParameters
        exit $LASTEXITCODE
    }
}

# ------------------------------------------------------------ reading -----
#
# Nothing below changes anything. Every step is asked which side of the change
# its target is on before the operator is offered the choice, because a page
# offering to put back what is already back is the same defect as a preview
# promising changes that are already made.

$global:WDRegCache   = @{}
$global:WDSched      = $null
$global:WDFeatures   = $null
$global:WDFeatureJob = $null

function global:Get-WDRegNow {
    <#  Every value under one key, read once and kept.  #>
    param([string]$Path, [string]$Name)

    $out = @{ Key = $false; Has = $false; Value = $null }
    if (-not $global:WDRegCache.ContainsKey($Path)) {
        $v = $null
        try {
            if (Test-Path -LiteralPath $Path) { $v = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue }
        } catch { }
        $global:WDRegCache[$Path] = $v
    }
    $p = $global:WDRegCache[$Path]
    if ($null -eq $p) { return $out }
    $out.Key = $true
    if ($p.PSObject.Properties[$Name]) { $out.Has = $true; $out.Value = $p.$Name }
    $out
}

function global:Test-WDPathReachable {
    <#
        Can this path be read at all right now?

        The one case that matters is HKU:. Its hives are not mounted outside a
        run, and "the key is not there" and "I was not allowed to look" are
        different answers - only the first of them means the change is already
        undone. Getting that wrong would report every per-account value as
        already back and hide the row that puts it back.
    #>
    param([string]$Path)

    if ($Path -notlike 'HKU:\*') { return $true }
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) { return $false }
    $hive = (($Path.Substring(5)) -split '\\')[0]
    if (-not $hive) { return $false }
    try { return [bool](Test-Path -LiteralPath ('HKU:\' + $hive)) } catch { return $false }
}

function global:Test-WDSameValue {
    param($A, $B, [string]$Kind)

    switch ($Kind) {
        'Binary' {
            if ($null -eq $A -or $null -eq $B) { return $false }
            $x = @($A); $y = @($B)
            if ($x.Count -ne $y.Count) { return $false }
            for ($i = 0; $i -lt $x.Count; $i++) { if ([int]$x[$i] -ne [int]$y[$i]) { return $false } }
            return $true
        }
        'MultiString' {
            $x = @($A); $y = @($B)
            if ($x.Count -ne $y.Count) { return $false }
            for ($i = 0; $i -lt $x.Count; $i++) { if ([string]$x[$i] -ne [string]$y[$i]) { return $false } }
            return $true
        }
        'DWord' { try { return ([int64]$A -eq [int64]$B) } catch { return $false } }
        'QWord' { try { return ([int64]$A -eq [int64]$B) } catch { return $false } }
        default { return ([string]$A -eq [string]$B) }
    }
}

function global:Get-WDTaskEnabled {
    <#
        Enabled, disabled, or $null for "could not ask".

        The COM interface rather than Get-ScheduledTask: given a name that one
        enumerates every task in every folder and filters afterwards, which is
        about a second each. Twenty-two of those is most of a minute in front of
        somebody waiting for a window.
    #>
    param([string]$Path, [string]$Name)

    try {
        if (-not $global:WDSched) {
            $global:WDSched = New-Object -ComObject 'Schedule.Service'
            $global:WDSched.Connect()
        }
        $p = [string]$Path
        if ($p) { $p = $p.TrimEnd('\') }
        if (-not $p) { $p = '\' }
        $f = $global:WDSched.GetFolder($p)
        if (-not $f) { return $null }
        $t = $f.GetTask($Name)
        if (-not $t) { return $null }
        return [bool]$t.Enabled
    } catch { return $null }
}

function global:Read-WDFeatureTable {
    <#
        Every optional feature Windows knows about, as name -> state.

        Win32_OptionalFeature rather than Get-WindowsOptionalFeature, and the
        gap between them is not a detail: measured elevated on the machine this
        was written against, the DISM enumeration is 12,072 ms and this class is
        1,043, for an answer that agreed on every one of the 135 names the two
        share. The whole distinction anything here draws is enabled against not
        enabled, which is InstallState 1 against everything else.

        This body is also what runs inside the warming runspace, handed over as
        its own text rather than copied - four lines kept in two places is four
        lines that will disagree.
    #>
    $t = @{}
    try {
        foreach ($f in @(Get-CimInstance -ClassName Win32_OptionalFeature -ErrorAction Stop)) {
            if ([int]$f.InstallState -eq 1) { $t[[string]$f.Name] = 'Enabled' }
            else                            { $t[[string]$f.Name] = 'Disabled' }
        }
    } catch { }
    $t
}

function global:Start-WDFeatureRead {
    <#
        Warm the feature table on a runspace of its own.

        Whichever option happens to hold the first feature change pays for the
        whole enumeration, and the splash sits on that one option's name while
        it does - which is the whole of "Legacy optional features takes much
        longer than any other option". It was option 101 of 136 on the run this
        was written against, so started before the first option the answer is
        already in hand by the time anything asks for it.

        A hashtable of strings is all that crosses back, so there is nothing
        thread-affine about it. Nothing happens at all unless this run actually
        touched a feature - a runspace and a second of somebody's processor for
        a question no step is going to ask is worse than the wait.
    #>
    if ($global:WDFeatureJob -or $null -ne $global:WDFeatures) { return }
    $wanted = $false
    foreach ($s in @($global:WDSteps)) {
        if ($s.M -eq 'feature' -or $s.M -eq 'feature-off') { $wanted = $true; break }
    }
    if (-not $wanted) { return }
    try {
        $rs = [RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [PowerShell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript((Get-Command Read-WDFeatureTable).Definition)
        $global:WDFeatureJob = @{ PS = $ps; RS = $rs; H = $ps.BeginInvoke() }
    } catch {
        $global:WDFeatureJob = $null
    }
}

function global:Get-WDFeatureState {
    <#
        One table for every feature this run touched - collected off-thread when
        somebody thought to start it, and here otherwise.
    #>
    param([string]$Name)

    if ($null -eq $global:WDFeatures) {
        $j = $global:WDFeatureJob
        $global:WDFeatureJob = $null
        if ($j) {
            try {
                $r = @($j.PS.EndInvoke($j.H))
                if ($r.Count) { $global:WDFeatures = $r[0] }
            } catch { }
            try { $j.PS.Dispose() } catch { }
            try { $j.RS.Dispose() } catch { }
        }
        if ($null -eq $global:WDFeatures) { $global:WDFeatures = Read-WDFeatureTable }
    }
    if ($global:WDFeatures.ContainsKey($Name)) { return $global:WDFeatures[$Name] }

    # A name that class does not carry - Recall and the Remote Desktop client
    # are the two on this build. DISM answers for one name in 377 ms against
    # twelve seconds for the lot, so the fallback is per name, and the answer
    # goes into the same table whether or not there was one: a name nobody can
    # answer for must not be asked twice.
    $st = ''
    try { $st = [string](Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop).State } catch { }
    $global:WDFeatures[$Name] = $st
    if ($st) { return $st }
    $null
}

function global:Get-WDStepState {
    <#
        'todo'    the change this run made is still in place
        'done'    the machine is already back where it was
        'unknown' could not be established, so it is offered rather than hidden
    #>
    param($S)

    switch ($S.M) {
        'registry' {
            if (-not (Test-WDPathReachable $S.P)) { return 'unknown' }
            $now = Get-WDRegNow -Path $S.P -Name $S.N
            if ($S.Gone) { if ($now.Has) { return 'todo' } else { return 'done' } }
            if (-not $now.Has) { return 'todo' }
            if (Test-WDSameValue $now.Value $S.V $S.K) { return 'done' }
            return 'todo'
        }
        'service' {
            $svc = $null
            try { $svc = Get-Service -Name $S.N -ErrorAction SilentlyContinue } catch { }
            if (-not $svc) { return 'unknown' }
            $cur = ''
            try { $cur = [string]$svc.StartType } catch { }
            if (-not $cur) { return 'unknown' }
            if ($cur -eq [string]$S.V) { return 'done' }
            return 'todo'
        }
        'task' {
            $on = Get-WDTaskEnabled -Path $S.P -Name $S.N
            if ($null -eq $on) { return 'unknown' }
            if ($on) { return 'done' }
            return 'todo'
        }
        'unregister-task' {
            $on = Get-WDTaskEnabled -Path '\' -Name $S.N
            if ($null -eq $on) { return 'done' }
            return 'todo'
        }
        'feature' {
            $st = Get-WDFeatureState $S.N
            if (-not $st) { return 'unknown' }
            if ($st -eq 'Enabled') { return 'done' }
            return 'todo'
        }
        'feature-off' {
            $st = Get-WDFeatureState $S.N
            if (-not $st) { return 'unknown' }
            if ($st -eq 'Disabled') { return 'done' }
            return 'todo'
        }
        'rename' {
            if (Test-Path -LiteralPath $S.To)   { return 'done' }
            if (Test-Path -LiteralPath $S.From) { return 'todo' }
            return 'unknown'
        }
        'file-restore' {
            if ($S.F) {
                if (Test-Path -LiteralPath $S.T) { return 'todo' }
                return 'unknown'
            }
            if (Test-Path -LiteralPath $S.T) { return 'todo' }
            return 'done'
        }
        'recycle' {
            if (Test-Path -LiteralPath $S.P) { return 'done' }
            return 'todo'
        }
        'uninstall' {
            # Installed by the run. Undoing it is an uninstall, and winget is
            # the only thing that can say whether it is still here.
            return 'unknown'
        }
        default { return 'unknown' }
    }
}

function global:Get-WDStepText {
    <#  One line saying exactly what this step would do.  #>
    param($S)

    switch ($S.M) {
        'registry' {
            if ($S.Gone) { return "Delete $($S.N) under $($S.P) - it did not exist before the run" }
            return "Set $($S.N) under $($S.P) back to $(Format-WDShort $S.V)"
        }
        'service'         { return "Set the $($S.N) service back to $($S.V) startup" }
        'task'            { return "Re-enable the scheduled task $($S.P)$($S.N)" }
        'unregister-task' { return "Remove the scheduled task $($S.N), which this run registered" }
        'feature'         { return "Turn the Windows feature $($S.N) back on" }
        'feature-off'     { return "Turn the Windows feature $($S.N) back off" }
        'capability-off'  { return "Remove the Windows capability $($S.N), which this run added" }
        'powercfg'        { return "Put the power setting $($S.Sub)\$($S.Set) back to $($S.Ac) on mains, and $($S.Dc) on battery" }
        'regfile'         { return "Import $($S.F), which is the whole of $($S.T) as it was before the run" }
        'file-restore'    { if ($S.F) { return "Restore $($S.T) from the copy taken before the run" }
                            return "Delete $($S.T), which this run created" }
        'rename'          { return "Move $($S.From) back to $($S.To)" }
        'recycle'         { return "Take $($S.P) back out of the Recycle Bin" }
        'uninstall'       { return "Uninstall $($S.N), which this run installed" }
        default           { return "$($S.M) $($S.N)" }
    }
}

function global:Format-WDShort {
    param($V)
    if ($null -eq $V) { return '(nothing)' }
    if ($V -is [Array]) {
        $n = @($V).Count
        if ($n -gt 8) { return "$n bytes" }
        return (@($V) -join ', ')
    }
    $s = [string]$V
    if ($s.Length -gt 60) { return $s.Substring(0, 57) + '...' }
    if ($s -eq '') { return '(an empty value)' }
    $s
}

# ------------------------------------------------------------ writing -----

function global:Open-WDRegKeyForWrite {
    <#
        One key, opened writable, straight from .NET.

        Only the default value needs this and everything else goes through the
        provider, so it is deliberately small: it answers $null for a path it
        does not recognise rather than throwing, and the caller reports that as
        a refusal like any other.
    #>
    param([string]$Path)

    $root = $null; $rest = ''
    if     ($Path -match '^HKLM:\\(.*)$') { $root = [Microsoft.Win32.Registry]::LocalMachine; $rest = $Matches[1] }
    elseif ($Path -match '^HKCU:\\(.*)$') { $root = [Microsoft.Win32.Registry]::CurrentUser;  $rest = $Matches[1] }
    elseif ($Path -match '^HKCR:\\(.*)$') { $root = [Microsoft.Win32.Registry]::ClassesRoot;  $rest = $Matches[1] }
    elseif ($Path -match '^HKU:\\(.*)$')  { $root = [Microsoft.Win32.Registry]::Users;        $rest = $Matches[1] }
    if (-not $root) { return $null }
    try { return $root.OpenSubKey($rest, $true) } catch { return $null }
}

function global:Invoke-WDStep {
    <#
        Do one step. Answers @{ Ok; Note } and never throws: a rollback that
        stops at the first refusal leaves the machine in a state nobody chose.
    #>
    param($S)

    try {
        switch ($S.M) {
            'registry' {
                if (-not (Test-WDPathReachable $S.P)) {
                    return @{ Ok = $false; Note = 'that part of the registry is not mounted' }
                }
                if ($S.Gone) {
                    # A key's default value cannot be deleted through the
                    # provider. Remove-ItemProperty -Name '(default)' answers
                    # "Property (default) does not exist" however plainly it is
                    # there, and -Name '' refuses to bind at all - so a run that
                    # created one would journal an undo nothing could perform.
                    # .NET does it, and wants the empty name rather than the
                    # label the provider prints.
                    if ($S.N -eq '(default)') {
                        $k = Open-WDRegKeyForWrite $S.P
                        if (-not $k) { return @{ Ok = $false; Note = 'that key could not be opened for writing' } }
                        try { $k.DeleteValue('', $false) } finally { $k.Close() }
                    } else {
                        Remove-ItemProperty -LiteralPath $S.P -Name $S.N -Force -ErrorAction Stop
                    }
                } else {
                    if (-not (Test-Path -LiteralPath $S.P)) {
                        $null = New-Item -Path ([Management.Automation.WildcardPattern]::Escape($S.P)) -Force -ErrorAction Stop
                    }
                    Set-ItemProperty -LiteralPath $S.P -Name $S.N -Value $S.V -Type $S.K -Force -ErrorAction Stop
                }
                $global:WDRegCache.Remove($S.P) | Out-Null
                return @{ Ok = $true; Note = '' }
            }
            'service' {
                Set-Service -Name $S.N -StartupType $S.V -ErrorAction Stop
                return @{ Ok = $true; Note = '' }
            }
            'task' {
                $null = Enable-ScheduledTask -TaskPath $S.P -TaskName $S.N -ErrorAction Stop
                return @{ Ok = $true; Note = '' }
            }
            'unregister-task' {
                Unregister-ScheduledTask -TaskName $S.N -Confirm:$false -ErrorAction Stop
                return @{ Ok = $true; Note = '' }
            }
            'feature' {
                if ($global:WDDismBlocked) { return @{ Ok = $false; Note = 'a restart is pending, so Windows will not service features yet' } }
                $null = Enable-WindowsOptionalFeature -Online -FeatureName $S.N -NoRestart -ErrorAction Stop
                return @{ Ok = $true; Note = 'a restart finishes this' }
            }
            'feature-off' {
                if ($global:WDDismBlocked) { return @{ Ok = $false; Note = 'a restart is pending, so Windows will not service features yet' } }
                $null = Disable-WindowsOptionalFeature -Online -FeatureName $S.N -NoRestart -ErrorAction Stop
                return @{ Ok = $true; Note = 'a restart finishes this' }
            }
            'capability-off' {
                if ($global:WDDismBlocked) { return @{ Ok = $false; Note = 'a restart is pending, so Windows will not service capabilities yet' } }
                $null = Remove-WindowsCapability -Online -Name $S.N -ErrorAction Stop
                return @{ Ok = $true; Note = '' }
            }
            'powercfg' {
                $null = & powercfg.exe /setacvalueindex SCHEME_CURRENT $S.Sub $S.Set $S.Ac
                $null = & powercfg.exe /setdcvalueindex SCHEME_CURRENT $S.Sub $S.Set $S.Dc
                $null = & powercfg.exe /setactive SCHEME_CURRENT
                return @{ Ok = $true; Note = '' }
            }
            'regfile' {
                if (-not (Test-Path -LiteralPath $S.F)) {
                    return @{ Ok = $false; Note = 'the backup file this needs is no longer there' }
                }
                $null = & reg.exe import "$($S.F)"
                if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Note = "reg import exit $LASTEXITCODE" } }
                return @{ Ok = $true; Note = '' }
            }
            'file-restore' {
                if ($S.F) {
                    if (-not (Test-Path -LiteralPath $S.F)) {
                        return @{ Ok = $false; Note = 'the copy taken before the run is no longer there' }
                    }
                    Copy-Item -LiteralPath $S.F -Destination $S.T -Force -ErrorAction Stop
                } else {
                    Remove-Item -LiteralPath $S.T -Force -ErrorAction Stop
                }
                return @{ Ok = $true; Note = '' }
            }
            'rename' {
                if (-not (Test-Path -LiteralPath $S.From)) { return @{ Ok = $false; Note = 'the parked folder is no longer there' } }
                if (Test-Path -LiteralPath $S.To)          { return @{ Ok = $false; Note = 'something is already at that name' } }
                Rename-Item -LiteralPath $S.From -NewName (Split-Path $S.To -Leaf) -Force -ErrorAction Stop
                return @{ Ok = $true; Note = '' }
            }
            'recycle'   { return (Restore-WDFromBin -Path $S.P) }
            'uninstall' {
                if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
                    return @{ Ok = $false; Note = 'winget is not available on this machine' }
                }
                $null = & winget.exe uninstall --id $S.N --exact --silent --disable-interactivity --accept-source-agreements
                if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Note = "winget exit $LASTEXITCODE" } }
                return @{ Ok = $true; Note = '' }
            }
        }
        return @{ Ok = $false; Note = "nothing here knows how to undo '$($S.M)'" }
    } catch {
        return @{ Ok = $false; Note = $_.Exception.Message }
    }
}

$global:WDBin = $null
function global:Restore-WDFromBin {
    <#
        Out of the Recycle Bin by moving the item, not by invoking the Restore
        verb - verb names are localised and MoveHere is not. The bin is
        enumerated once: it can hold thousands of items and this used to walk
        the whole of it per path.
    #>
    param([string]$Path)

    try {
        if ($null -eq $global:WDBin) {
            $global:WDBin = @{}
            $ns = (New-Object -ComObject Shell.Application).NameSpace(0xA)
            foreach ($it in @($ns.Items())) {
                try {
                    $from = $it.ExtendedProperty('System.Recycle.DeletedFrom')
                    if ($from) { $global:WDBin[[string](Join-Path $from $it.Name)] = $it }
                } catch { }
            }
        }
        if (-not $global:WDBin.ContainsKey($Path)) { return @{ Ok = $false; Note = 'not in the Recycle Bin any more' } }
        $parent = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop }
        # 0x14 is no confirmation dialog and no progress window. Without it the
        # shell can raise UI, and this may be running with nobody at the screen.
        (New-Object -ComObject Shell.Application).NameSpace($parent).MoveHere($global:WDBin[$Path], 0x14)
        return @{ Ok = $true; Note = '' }
    } catch {
        return @{ Ok = $false; Note = $_.Exception.Message }
    }
}

# ----------------------------------------------------- hives and DISM -----

$global:WDDismBlocked  = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                         (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
$global:WDDefaultOurs  = $false
$global:WDDefaultOk    = $true

function global:Enter-WDUndoSingleInstance {
    <#
        One copy of anything that changes this machine, at a time.

        THE MUTEX NAME IS THE TOOLKIT'S, so the two are mutually exclusive rather
        than one of each - a rollback is precisely the thing that must not run
        while the Revert page is open. Two at once each read the other's changes as
        the "previous value" they restore from.

        A HANDLE, NOT OWNERSHIP. WaitOne/ReleaseMutex is thread-affine and has the
        abandoned-mutex case to get right; a named mutex lives as long as any
        handle is open and Windows closes handles however a process dies, so "did
        I create it" is the whole question.

        Spelled out again rather than imported, like every helper here: the premise
        of this script is that the toolkit may be gone.

        NEVER REFUSES ON ITS OWN FAILURE - if the interlock cannot be built, the
        answer is yes. Blocking a rollback over a guard that would not build is
        worse than the thing guarded against.
    #>
    $createdNew = $false
    try {
        $sec  = New-Object System.Security.AccessControl.MutexSecurity
        $rule = New-Object System.Security.AccessControl.MutexAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'),
                    [System.Security.AccessControl.MutexRights]::FullControl,
                    [System.Security.AccessControl.AccessControlType]::Allow)
        $sec.AddAccessRule($rule)
        $global:WDInstanceMutex = New-Object System.Threading.Mutex(
                                      $false, 'Global\WinSetupToolkit.Toolkit.1', [ref]$createdNew, $sec)
    } catch {
        try {
            $global:WDInstanceMutex = New-Object System.Threading.Mutex(
                                          $false, 'Global\WinSetupToolkit.Toolkit.1', [ref]$createdNew)
        } catch { return $true }
    }
    if ($createdNew) { return $true }
    try { $global:WDInstanceMutex.Dispose() } catch { }
    $global:WDInstanceMutex = $null

    # Who, for the message only - the mutex has already decided. Matched on the
    # script rather than the word: 'WinSetupToolkit' alone matches any shell whose
    # command line merely mentions the folder.
    $who = @()
    try {
        $who = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
                 Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'WinSetupToolkit\.ps1' } |
                 ForEach-Object {
                     $kind = 'the toolkit'
                     if ($_.CommandLine -match 'Undo-WinSetupToolkit\.ps1') { $kind = 'another rollback script' }
                     "Already running: $kind, process $($_.ProcessId)"
                 })
    } catch { }

    # Word for word what the toolkit says, because it is the same refusal and
    # somebody may meet it from either side.
    Write-Host ''
    Write-Host 'For your own safety, having two instances of the Windows Setup Toolkit or its reversion script open is not allowed. There is no reason why you should need two instances, and it can only do harm. Close the other instance to open a new one, or just use the existing one.' -ForegroundColor Yellow
    if ($who.Count) {
        Write-Host ''
        foreach ($line in $who) { Write-Host $line -ForegroundColor Yellow }
    }
    Write-Host ''
    $false
}

function global:Open-WDHives {
    <#
        HKU: is not one of PowerShell's default drives, and HKU:\WD_DEFAULT is
        not a hive at all - it is C:\Users\Default\NTUSER.DAT, mounted for the
        length of a run and unmounted afterwards. Without both of these every
        per-account line in this script throws DriveNotFoundException, and they
        used to be written with -EA SilentlyContinue, so the script restored
        nothing, said nothing, and finished with "Rollback complete".
    #>
    if (-not $global:WDWantsHku) { return }
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        $null = New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -Scope Global -ErrorAction SilentlyContinue
    }
    if (-not $global:WDWantsDefault) { return }
    if (Test-Path 'HKU:\WD_DEFAULT') { return }
    $dat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $dat)) { $global:WDDefaultOk = $false; return }
    $null = & reg.exe load "HKU\WD_DEFAULT" "$dat" 2>&1
    $global:WDDefaultOurs = [bool](Test-Path 'HKU:\WD_DEFAULT')
    $global:WDDefaultOk   = $global:WDDefaultOurs
}

function global:Close-WDHives {
    <#
        Unload what this script loaded, and only that.

        The collect is not decoration and one of them is not enough. Reading a
        value under HKU:\WD_DEFAULT goes through PowerShell's registry provider,
        which keeps the key handle alive until it is collected - and a hive with
        an open handle will not unload. This script reads a hundred and
        twenty-five of them before anybody presses anything, so by the time the
        window closes the provider is holding the whole branch.

        Removing the PSDrive first is what actually releases them: collecting
        alone left the mount standing on a real machine, which is precisely the
        stranded mount this is here to prevent - it rides along in every later
        boot, and nothing afterwards says why.

        Verified rather than assumed. The first version fired the unload,
        assigned $false, and reported nothing, so a failure was indistinguishable
        from success.
    #>
    if (-not $global:WDDefaultOurs) { return }
    $global:WDRegCache.Clear()

    for ($try = 1; $try -le 3; $try++) {
        Remove-PSDrive -Name HKU -Force -ErrorAction SilentlyContinue
        [gc]::Collect(); [gc]::WaitForPendingFinalizers(); [gc]::Collect()
        $out = & reg.exe unload "HKU\WD_DEFAULT" 2>&1
        $null = New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -Scope Global -ErrorAction SilentlyContinue
        if (-not (Test-Path 'HKU:\WD_DEFAULT')) {
            $global:WDDefaultOurs = $false
            return
        }
        if ($try -eq 3) {
            Write-Host ''
            Write-Host 'The default user profile could not be unmounted again, so it is still loaded.' -ForegroundColor Yellow
            Write-Host 'Nothing is broken by that, but it should not be left behind. From an administrator' -ForegroundColor Yellow
            Write-Host 'prompt, run:  reg unload HKU\WD_DEFAULT' -ForegroundColor Yellow
            Write-Host "  ($($out -join ' '))" -ForegroundColor DarkGray
        }
        Start-Sleep -Milliseconds 250
    }
    $global:WDDefaultOurs = $false
}

# ------------------------------------------------------------- the run ----

function global:Invoke-WDUndo {
    <#
        Run a set of steps and report each one. $Say is how a line reaches
        whoever is watching - Write-Host on the console, a row on the page -
        so the two surfaces cannot drift into describing the run differently.
    #>
    param($Steps, [scriptblock]$Say)

    $out = [pscustomobject]@{ Restored = 0; Already = 0; Failed = 0; Notes = (New-Object System.Collections.Generic.List[string]) }
    $n = 0
    foreach ($s in @($Steps)) {
        $n++
        $state = Get-WDStepState $s
        if ($state -eq 'done') {
            $out.Already++
            & $Say @{ Level = 'skip'; Index = $n; Text = "Already back: $(Get-WDStepText $s)" }
            continue
        }
        $r = Invoke-WDStep $s
        if ($r.Ok) {
            $out.Restored++
            $t = Get-WDStepText $s
            if ($r.Note) { $t = "$t - $($r.Note)" }
            & $Say @{ Level = 'ok'; Index = $n; Text = $t }
        } else {
            $out.Failed++
            $msg = "Could not: $(Get-WDStepText $s) - $($r.Note)"
            $out.Notes.Add($msg)
            & $Say @{ Level = 'bad'; Index = $n; Text = $msg }
        }
    }
    $out
}

function global:Get-WDSelectedSteps {
    param($Ids)
    if (-not @($Ids).Count) { return @($global:WDSteps) }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($i in @($Ids)) { $null = $set.Add([string]$i) }
    @($global:WDSteps | Where-Object { $set.Contains([string]$_.Id) })
}

# ============================================================== console ====

function global:Invoke-WDUndoConsole {
    # Taken as parameters rather than read off the script's own scope. Every
    # function in here is global so that a WPF callback can find it whatever
    # session state it arrives in, and a global function reading an unqualified
    # script variable is reading whatever the CALLER can see.
    param([string[]]$Only = @(), [switch]$ListOnly)

    Write-Host ''
    Write-Host "Undoing Windows Setup Toolkit run $global:WDRun" -ForegroundColor Cyan
    if ($global:WDWhen) { Write-Host "  applied $global:WDWhen" -ForegroundColor DarkGray }
    Write-Host ''

    Start-WDFeatureRead
    Open-WDHives
    if ($global:WDWantsDefault -and -not $global:WDDefaultOk) {
        Write-Host "The default user profile could not be loaded, so $global:WDWantsDefault value(s) that only affect accounts created later cannot be restored." -ForegroundColor Yellow
        Write-Host 'Everything that affects accounts on this machine now is restored regardless.' -ForegroundColor Yellow
        Write-Host ''
    }
    if ($global:WDDismBlocked) {
        Write-Host 'A restart is pending, so Windows features and capabilities cannot be changed yet.' -ForegroundColor Yellow
        Write-Host 'Everything else is restored now. Restart, then run this again to finish those.' -ForegroundColor Yellow
        Write-Host ''
    }

    $steps = Get-WDSelectedSteps $Only

    if ($ListOnly) {
        Write-Host ''
        $todo = 0; $done = 0; $huh = 0
        foreach ($s in $steps) {
            switch (Get-WDStepState $s) {
                'todo'    { $todo++; Write-Host "  still in place : $(Get-WDStepText $s)" }
                'done'    { $done++ }
                'unknown' { $huh++;  Write-Host "  cannot tell    : $(Get-WDStepText $s)" -ForegroundColor DarkGray }
            }
        }
        Write-Host ''
        Write-Host "$todo of $(@($steps).Count) change(s) are still in place, $done already back, $huh not checkable from here."
        Close-WDHives
        return 0
    }

    $say = {
        param($L)
        switch ($L.Level) {
            'ok'   { Write-Host "  $($L.Text)" -ForegroundColor Green }
            'bad'  { Write-Host "  $($L.Text)" -ForegroundColor Red }
            default { }
        }
    }
    $r = Invoke-WDUndo -Steps $steps -Say $say
    Close-WDHives

    Write-Host ''
    Write-Host "$($r.Restored) change(s) put back, $($r.Already) were already back, $($r.Failed) could not be done." -ForegroundColor Cyan
    if ($global:WDReinstall.Count) {
        Write-Host ''
        Write-Host "$($global:WDReinstall.Count) program(s) were uninstalled by that run. Nothing can put those back automatically:" -ForegroundColor Yellow
        foreach ($x in $global:WDReinstall) { Write-Host "    $x" -ForegroundColor Yellow }
    }
    if ($global:WDOwners.Count) {
        Write-Host ''
        Write-Host 'Registry keys whose owner was changed to Administrators (restore with takeown or icacls if you want to):' -ForegroundColor DarkGray
        foreach ($x in $global:WDOwners) { Write-Host "    $x" -ForegroundColor DarkGray }
    }
    Write-Host ''
    if ($r.Failed) {
        Write-Host 'Finished, but not completely - see the lines above. A restart is recommended.' -ForegroundColor Yellow
        return 1
    }
    Write-Host 'Finished. A restart is recommended.' -ForegroundColor Green
    0
}
'@

# The window. Split from the body above only so the two read apart: everything
# here is interface, everything above works with no screen.
#
# DELIBERATELY THE SAME PAGE as the toolkit's Advanced list - heading, rule, a row
# per option with a tick and a tag, an index of counts down the side. Somebody who
# has used the toolkit has already learnt this page, and this is the screen they
# see when something has gone wrong.
#
# It is NOT the toolkit's Revert page. That lists recurring effects and removed
# software across every run, from a machine that still has the toolkit. This is
# one run, on a machine that may not.
$script:WDUndoWindow = @'

# ============================================================= the window ===
#
# The toolkit's Advanced page, as closely as a file importing nothing can carry
# it: both palettes, the retemplated controls, the thin scrollbars, the index rail
# with its scroll spy, Group by and Sort by, the filter, and the same splash.
#
# IT IS A COPY AND IT HAS TO BE ONE. The premise of this file is that it runs
# where the toolkit does not - on a machine somebody has just changed, possibly
# badly, possibly with the folder it came from already thrown away. A rollback
# that depends on the thing under test is not a rollback.

function global:Get-WDUndoThemeKey {
    <#  Whatever the caller said, reduced to 'dark' or 'light'. One place, so
        the palette, the icon and the splash cannot disagree about what an
        empty string means.  #>
    param([string]$Theme = '')
    if ($Theme -eq 'dark' -or $Theme -eq 'light') { return $Theme }
    try {
        $v = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        if ($v.AppsUseLightTheme -eq 0) { return 'dark' }
    } catch { }
    'light'
}

function global:Get-WDUndoPalette {
    <#  The toolkit's own two palettes, value for value. Flat is the one
        addition: a transparent key, so a hover that comes and goes can be a
        resource reference like everything else rather than a literal brush a
        theme switch would leave standing.  #>
    param([string]$Theme)

    if ((Get-WDUndoThemeKey $Theme) -eq 'dark') {
        @{ Dark='1'; Bg='#FF1F1F1F'; Panel='#FF2B2B2B'; Card='#FF303030'; CardSel='#FF37475A'
           Text='#FFBABABA'; Sub='#FF9A9A9A'; Line='#FF454545'; Accent='#FF4CA6FF'
           Ok='#FF5FD07F'; Warn='#FFE8B44A'; Bad='#FFF06C6C'; Muted='#FF9E9E9E'
           RowHover='#FF3A3A3A'; ScrollThumb='#FF5A5A5A'; ScrollThumbHover='#FF8C8C8C'
           BtnBg='#FF3C3C3C'; BtnBorder='#FF5E5E5E'; BtnTint='#26FFFFFF'; FieldBg='#FF262626'
           Flat='#00000000' }
    } else {
        @{ Dark='0'; Bg='#FFF5F5F5'; Panel='#FFFFFFFF'; Card='#FFFAFAFA'; CardSel='#FFE4EEF8'
           Text='#FF141414'; Sub='#FF555555'; Line='#FFD8D8D8'; Accent='#FF0F6CBD'
           Ok='#FF1A7F37'; Warn='#FF8A5A00'; Bad='#FFC03030'; Muted='#FF6B6B6B'
           RowHover='#FFEDEDED'; ScrollThumb='#FFBFBFBF'; ScrollThumbHover='#FF8A8A8A'
           BtnBg='#FFF0F0F0'; BtnBorder='#FFACACAC'; BtnTint='#1A000000'; FieldBg='#FFFFFFFF'
           Flat='#00000000' }
    }
}

function global:Get-WDUndoPaletteKeys {
    ,@('Bg','Panel','Card','CardSel','Text','Sub','Line','Accent','Ok','Warn','Bad','Muted',
       'RowHover','ScrollThumb','ScrollThumbHover','BtnBg','BtnBorder','BtnTint','FieldBg','Flat')
}

function global:Set-WDUndoBrushes {
    <#  One frozen brush per palette entry, under the key everything on the page
        points at with a DynamicResource. Switching theme is this function again
        with the other palette: about two hundred elements repaint and not one
        of them is re-created, re-parented or re-measured, so the page keeps its
        scroll position, its filters and its ticks because nothing touched them.  #>
    param($Window, $Pal)
    foreach ($k in (Get-WDUndoPaletteKeys)) {
        $b = (New-Object Windows.Media.BrushConverter).ConvertFromString($Pal[$k])
        $b.Freeze()
        $Window.Resources['Wd' + $k] = $b
    }
}

function global:Use-WDUndoNative {
    <#
        ONE csc INVOCATION FOR EVERY P/INVOKE THIS SCRIPT NEEDS.

        Add-Type is a compiler run: the first one in a process costs 400-500ms
        because it loads the compiler, and each one after it still costs 150-200.
        Three separate types - the title bar, the taskbar id, and the console -
        were three of those on the way to a window, all of them before anything
        was on screen. One type is one compile.

        Answers true or false rather than throwing. None of the three is worth
        failing a rollback over.
    #>
    if ('WDUndo.Native' -as [type]) { return $true }
    try {
        Add-Type -Namespace 'WDUndo' -Name 'Native' -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@ -ErrorAction Stop
        return $true
    } catch { return $false }
}

function global:Set-WDUndoConsole {
    <#
        Hide the console this script is running in, or put it back.

        The launcher keeps its console for as long as the elevation prompt is up
        - a UAC dialog over nothing gives no clue what asked for it - and that is
        the right behaviour and is not this. The console this hides is the one
        the ELEVATED copy runs in afterwards, which otherwise sits behind the
        window for the whole session with nothing on it.

        Put back rather than left hidden on any path that goes on to print:
        falling through to the console version with the console hidden is a
        program that has stopped responding as far as anybody can see.
    #>
    param([switch]$Show)
    try {
        if (-not (Use-WDUndoNative)) { return }
        $h = [WDUndo.Native]::GetConsoleWindow()
        if ($h -eq [IntPtr]::Zero) { return }
        # SW_HIDE is 0, SW_SHOWNA is 8 - shown without taking the foreground,
        # because whatever is being reported is not worth stealing focus for.
        $null = [WDUndo.Native]::ShowWindow($h, $(if ($Show) { 8 } else { 0 }))
    } catch { }
}

function global:Set-WDUndoDarkTitleBar {
    <#
        A white caption over a dark page is the one part of a window that never
        follows the theme, and it is the part that is always on screen.
        Attribute 20 only - not the Mica backdrop, which on a plain window is a
        translucent sheet over whatever is behind it.
    #>
    param($Window, [bool]$Dark)
    try {
        if (-not (Use-WDUndoNative)) { return }
        $h = (New-Object Windows.Interop.WindowInteropHelper $Window).EnsureHandle()
        $on = [int]$Dark
        $null = [WDUndo.Native]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)
    } catch { }
}

function global:Set-WDUndoTaskbarIdentity {
    <#
        A taskbar button is grouped by AppUserModelID, and a process that sets
        no explicit one is given an id derived from its executable - so the
        shell finds the Start menu shortcut whose target is powershell.exe and
        draws THAT shortcut's icon. Window.Icon is never consulted, which reads
        as the icon half-working: the title bar is right and the taskbar is not.

        An explicit id nothing has a shortcut for leaves the shell nothing to
        match and it falls back to the window icon. Must run before the first
        window exists, which here means before the splash.
    #>
    try {
        if (-not (Use-WDUndoNative)) { return }
        $null = [WDUndo.Native]::SetCurrentProcessExplicitAppUserModelID('WinSetupToolkit.Rollback')
    } catch { }
}

function global:Get-WDUndoIcon {
    <#  The toolkit's own application icon, decoded on the calling thread.

        BYTES CROSS THREADS AND DECODED FRAMES DO NOT. A BitmapFrame keeps a
        reference to the decoder that produced it, a decoder is a
        DispatcherObject owned by one thread, and Freeze() on the frame does not
        freeze the decoder. WPF reads .Decoder.Frames when a window's handle is
        created, so a foreign frame assigns cleanly and then throws inside
        Show(). The splash therefore takes the base64 and does this for itself
        over there.

        Null when no icon was embedded, which is the case for a run started from
        the command line: the drawing lives in the toolkit's interface module
        and a console run never loads it. An icon is not worth failing over.  #>
    param([string]$Theme = '')
    $b64 = $global:WDIconLight
    if ((Get-WDUndoThemeKey $Theme) -eq 'dark') { $b64 = $global:WDIconDark }
    if (-not $b64) { return $null }
    try {
        $ms = New-Object System.IO.MemoryStream (,[byte[]][Convert]::FromBase64String($b64))
        $dec = New-Object Windows.Media.Imaging.IconBitmapDecoder `
                   $ms, ([Windows.Media.Imaging.BitmapCreateOptions]::None),
                   ([Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $pick = $dec.Frames[0]
        foreach ($f in $dec.Frames) { if ($f.PixelWidth -eq 32) { $pick = $f } }
        if ($pick.CanFreeze) { $pick.Freeze() }
        return $pick
    } catch { return $null }
}

function global:New-WDUndoSplash {
    <#
        The toolkit's splash, on a UI thread of its own, because reading the
        machine is the slowest thing this script does and a console line behind
        a window that has not appeared yet is not an answer to "is it working".

        THE SEPARATE THREAD IS THE POINT AND IS NOT AN OPTIMISATION. WPF runs
        its animation clock on the dispatcher that owns the element, so a
        storyboard on the main thread advances only while the main thread is
        idle - and the main thread spends this whole window reading several
        hundred registry values and then building the list. The sweep would
        stutter in exactly the places the work does not slice.

        The cost is thread affinity: nothing outside that runspace may touch the
        window, which is why the handles below write to a synchronised hashtable
        and a timer inside the runspace reads it.
    #>
    param([string]$Theme = '', [string]$Caption = '')

    $sync = [hashtable]::Synchronized(@{
        Status = 'Starting up'; Note = ''; Close = $false; Ready = $false; Error = $null
    })

    $xaml = @(
    '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"'
    '        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
    '        WindowStyle="None" AllowsTransparency="True" Background="Transparent"'
    '        WindowStartupLocation="CenterScreen" ShowInTaskbar="True"'
    '        SizeToContent="Manual" Width="470" Height="230" Topmost="True"'
    '        Title="Windows Setup Toolkit">'
    '  <Window.Triggers>'
    '    <EventTrigger RoutedEvent="FrameworkElement.Loaded">'
    '      <BeginStoryboard>'
    '        <Storyboard RepeatBehavior="Forever" AutoReverse="True">'
    '          <DoubleAnimation Storyboard.TargetName="Shift" Storyboard.TargetProperty="X"'
    '                           From="0" To="290" Duration="0:0:1.1">'
    '            <DoubleAnimation.EasingFunction><SineEase EasingMode="EaseInOut"/></DoubleAnimation.EasingFunction>'
    '          </DoubleAnimation>'
    '          <DoubleAnimation Storyboard.TargetName="Shuttle" Storyboard.TargetProperty="Opacity"'
    '                           From="0.55" To="1.0" Duration="0:0:1.1"/>'
    '        </Storyboard>'
    '      </BeginStoryboard>'
    '    </EventTrigger>'
    '  </Window.Triggers>'
    '  <Border Name="Card" CornerRadius="10" BorderThickness="1" Padding="30,26,30,24">'
    '    <StackPanel>'
    '      <TextBlock Name="Title" Text="Windows Setup Toolkit" FontSize="21" FontWeight="SemiBold"/>'
    '      <TextBlock Name="Machine" FontSize="12.5" Margin="0,5,0,0" TextTrimming="CharacterEllipsis"/>'
    '      <Border Name="Track" Height="4" CornerRadius="2" Margin="0,26,0,0" ClipToBounds="True"'
    '              HorizontalAlignment="Stretch">'
    '        <Border Name="Shuttle" Height="4" Width="120" CornerRadius="2" HorizontalAlignment="Left">'
    '          <Border.RenderTransform><TranslateTransform x:Name="Shift" X="0"/></Border.RenderTransform>'
    '        </Border>'
    '      </Border>'
    '      <TextBlock Name="Status" FontSize="13.5" Margin="0,16,0,0" TextWrapping="NoWrap"'
    '                 TextTrimming="CharacterEllipsis"/>'
    '      <TextBlock Name="Detail" FontSize="11.5" Margin="0,4,0,0" TextWrapping="NoWrap"'
    '                 TextTrimming="CharacterEllipsis"/>'
    '    </StackPanel>'
    '  </Border>'
    '</Window>'
    ) -join [Environment]::NewLine

    $key = Get-WDUndoThemeKey $Theme
    $ico = $global:WDIconLight
    if ($key -eq 'dark') { $ico = $global:WDIconDark }

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'          # WPF refuses to start on an MTA thread
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        # Plain data only. The runspace runs none of the functions in this file.
        $rs.SessionStateProxy.SetVariable('Sync',    $sync)
        $rs.SessionStateProxy.SetVariable('Xaml',    $xaml)
        $rs.SessionStateProxy.SetVariable('Pal',     (Get-WDUndoPalette -Theme $key))
        $rs.SessionStateProxy.SetVariable('IconB64', [string]$ico)
        $rs.SessionStateProxy.SetVariable('Caption', [string]$Caption)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript({
            try {
                Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
                $box = $Sync
                $Brush = { param($hex) (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }
                $win = [Windows.Markup.XamlReader]::Parse($Xaml)
                # In a try of its own, which is the lesson rather than the
                # decoration: the splash must not be able to fail over an icon.
                if ($IconB64) {
                    try {
                        $ims = New-Object System.IO.MemoryStream (,[byte[]][Convert]::FromBase64String($IconB64))
                        $idc = New-Object Windows.Media.Imaging.IconBitmapDecoder `
                                   $ims, ([Windows.Media.Imaging.BitmapCreateOptions]::None),
                                   ([Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                        $pick = $idc.Frames[0]
                        foreach ($fr in $idc.Frames) { if ($fr.PixelWidth -eq 32) { $pick = $fr } }
                        if ($pick.CanFreeze) { $pick.Freeze() }
                        $win.Icon = $pick
                    } catch { }
                }
                $get = { param([string]$n) $win.FindName($n) }
                $card = & $get 'Card'
                $card.Background  = & $Brush $Pal.Panel
                $card.BorderBrush = & $Brush $Pal.Line
                (& $get 'Title').Foreground   = & $Brush $Pal.Text
                (& $get 'Track').Background   = & $Brush $Pal.Line
                (& $get 'Shuttle').Background = & $Brush $Pal.Accent
                $status = & $get 'Status'; $status.Foreground = & $Brush $Pal.Text
                $detail = & $get 'Detail'; $detail.Foreground = & $Brush $Pal.Muted
                $machine = & $get 'Machine'
                $machine.Foreground = & $Brush $Pal.Sub
                $machine.Text = [string]$Caption
                $status.Text  = [string]$box.Status
                $win.Add_MouseLeftButtonDown({ try { $this.DragMove() } catch { } })
                $win.Show()

                # The only thing that ever writes to these elements. Polling at
                # 60ms rather than marshalling each update across: the caller
                # must never block on the splash.
                $tick = New-Object Windows.Threading.DispatcherTimer
                $tick.Interval = [TimeSpan]::FromMilliseconds(60)
                $tick.Add_Tick({
                    try {
                        $s = [string]$box.Status
                        if ($s -and $status.Text -ne $s) { $status.Text = $s }
                        $n = [string]$box.Note
                        if ($detail.Text -ne $n) { $detail.Text = $n }
                        if ($box.Close) {
                            $tick.Stop(); $win.Close()
                            [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
                        }
                    } catch { }
                }.GetNewClosure())
                $tick.Start()
                $box.Ready = $true
                [Windows.Threading.Dispatcher]::Run()
            } catch {
                $Sync.Error = $_.Exception.Message
                $Sync.Ready = $true      # or the caller waits out the whole timeout
            }
        })
        $handle = $ps.BeginInvoke()
    } catch {
        return $null
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $sync.Ready -and $sw.ElapsedMilliseconds -lt 6000) { Start-Sleep -Milliseconds 15 }

    @{
        State  = $sync
        Status = { param([string]$Text, [string]$Note)
                   if ($Text) { $sync.Status = $Text }
                   $sync.Note = [string]$Note }.GetNewClosure()
        Close  = { $sync.Close = $true
                   $w = [Diagnostics.Stopwatch]::StartNew()
                   while (-not $handle.IsCompleted -and $w.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 10 }
                   try { $ps.Dispose(); $rs.Dispose() } catch { } }.GetNewClosure()
    }
}

function global:Get-WDUndoKind {
    <#  Which of eight buckets a change belongs to. Used to group and to filter,
        never to decide anything about what happens.  #>
    param($S)
    switch ([string]$S.M) {
        'registry'        { 'Registry values' }
        'regfile'         { 'Registry values' }
        'service'         { 'Services' }
        'task'            { 'Scheduled tasks' }
        'unregister-task' { 'Scheduled tasks' }
        'feature'         { 'Windows features' }
        'feature-off'     { 'Windows features' }
        'capability-off'  { 'Windows features' }
        'file-restore'    { 'Files and folders' }
        'rename'          { 'Files and folders' }
        'recycle'         { 'Files and folders' }
        'powercfg'        { 'Power settings' }
        'uninstall'       { 'Installed programs' }
        default           { 'Other' }
    }
}

function global:Show-WDUndoWindow {
    param([string]$Theme = '', [switch]$BuildOnly)

    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    } catch {
        Write-Host 'A window could not be opened on this machine, so this is the console version.' -ForegroundColor Yellow
        return (Invoke-WDUndoConsole)
    }

    $themeKey = Get-WDUndoThemeKey $Theme
    $pal      = Get-WDUndoPalette -Theme $themeKey
    $title    = "Revert changes from Windows Setup Toolkit run $global:WDRun"
    if ($global:WDWhen) { $title += " applied on $global:WDWhen" }

    # The splash gets its own shorter wording. Its subtitle is a single 410px
    # line that does not wrap, and the title above measures 506px at 12.5px, so
    # it arrived ellipsised on every launch - the run id cut off mid-way, which
    # is the one part of it worth reading. The title bar and the page heading
    # both have room for the long form, so the fix is a second string for the
    # one surface that does not rather than cutting all three back to fit the
    # smallest. Measured against a long-month locale too, since the date is
    # culture-formatted: 382px worst case.
    $caption = "Reverting run $global:WDRun"
    if ($global:WDWhen) { $caption += ", applied $global:WDWhen" }

    # Both before the first window exists: the taskbar id because the button is
    # given its icon when it is created, and the console because from here on
    # there is a window to look at instead. Not under -BuildOnly, which prints
    # what the page says and needs somewhere to print it.
    if (-not $BuildOnly) {
        Set-WDUndoTaskbarIdentity
        Set-WDUndoConsole
    }

    # -BuildOnly shows nothing at all, splash included: it exists so a headless
    # check can ask what the page says without drawing anything over whatever
    # somebody is doing.
    $splash = $null
    if (-not $BuildOnly) { $splash = New-WDUndoSplash -Theme $themeKey -Caption $caption }
    $tell = {
        param([string]$Text, [string]$Note)
        if ($splash) { & $splash.Status $Text $Note }
    }.GetNewClosure()

    # Where the wait goes, recorded rather than guessed at. Three numbers, and
    # each one has a different answer if it grows: the read is the machine, the
    # rows are WPF element construction, and the layout is this file's own
    # arranging. -BuildOnly prints them and the log line at the end says them,
    # so "it takes a while to open" is answerable without a profiler.
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $ms = @{ Read = 0; Rows = 0; Shell = 0; Layout = 0 }

    & $tell 'Reading what is still in place' ''
    Start-WDFeatureRead
    Open-WDHives

    # One entry per option, in the order the run touched them, each carrying its
    # own steps and one state derived from them. An option is outstanding if any
    # one of its changes is still in place: a half-undone option is not undone.
    $order = New-Object System.Collections.Generic.List[string]
    $byId  = @{}
    foreach ($s in @($global:WDSteps)) {
        $id = [string]$s.Id
        if (-not $byId.ContainsKey($id)) {
            $order.Add($id)
            $byId[$id] = [pscustomobject]@{
                Id = $id; Name = [string]$s.Nm; Cat = [string]$s.Cat
                # What the option did, past tense, from the table the generator
                # emitted. Empty for a script written with no plan in hand, and
                # for the three steps Resolve-WDPlan appends, which are not
                # manifest items and have no description to carry.
                Desc = [string]$(if ($global:WDDesc -and $global:WDDesc.ContainsKey($id)) { $global:WDDesc[$id] } else { '' })
                Steps = (New-Object System.Collections.Generic.List[psobject])
                Kinds = (New-Object System.Collections.Generic.List[string])
                Todo = 0; Done = 0; Unknown = 0; State = 'done'
            }
        }
        $byId[$id].Steps.Add($s)
        $k = Get-WDUndoKind $s
        if (-not $byId[$id].Kinds.Contains($k)) { $byId[$id].Kinds.Add($k) }
    }
    $seen = 0
    foreach ($id in $order) {
        $o = $byId[$id]
        $seen++
        & $tell '' "$seen of $($order.Count) - $($o.Name)"
        foreach ($s in $o.Steps) {
            switch (Get-WDStepState $s) {
                'todo'    { $o.Todo++ }
                'done'    { $o.Done++ }
                default   { $o.Unknown++ }
            }
        }
        if ($o.Todo)         { $o.State = 'todo' }
        elseif ($o.Unknown)  { $o.State = 'unknown' }
        else                 { $o.State = 'done' }
        # What pressing the button would actually do for this option, counted
        # once here. The footer used to work it out by asking the machine again
        # for every change of every ticked option, inside the click handler,
        # before the tick could be drawn.
        $o | Add-Member -NotePropertyName Pending -NotePropertyValue ($o.Todo + $o.Unknown) -Force
        # The two strings the row shows, built here beside the counts rather than
        # inside the row builder - the same arrangement the Revert page has, so
        # the two builders can be read against each other line by line.
        $o | Add-Member -NotePropertyName Count -NotePropertyValue (@($o.Steps).Count) -Force
        $o | Add-Member -NotePropertyName CountText `
                        -NotePropertyValue (@($o.Steps).Count.ToString() + $(if (@($o.Steps).Count -eq 1) { ' change' } else { ' changes' })) -Force
        $dl = New-Object System.Collections.Generic.List[string]
        foreach ($s in $o.Steps) { $dl.Add('- ' + (Get-WDStepText $s)) }
        $o | Add-Member -NotePropertyName DetailText -NotePropertyValue ($dl -join [Environment]::NewLine) -Force
    }
    $opts = @($order | ForEach-Object { $byId[$_] })

    $totalSteps = @($global:WDSteps).Count
    $totalTodo  = 0; $totalDone = 0; $totalHuh = 0
    foreach ($o in $opts) { $totalTodo += $o.Todo; $totalDone += $o.Done; $totalHuh += $o.Unknown }

    $ms.Read = [int]$clock.ElapsedMilliseconds; $clock.Restart()
    & $tell 'Building the list' ''

    # ------------------------------------------------------------ shell ----
    #
    # Every colour is a DynamicResource pointing at a key this script fills in
    # after the parse, which is what makes the theme button a repaint rather
    # than a rebuild. Nothing below may carry a literal brush.
    $x = @(
    '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"'
    '        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
    '        Title="@Title@" Width="1120" Height="760"'
    '        MinWidth="900" MinHeight="600" WindowStartupLocation="CenterScreen"'
    '        Background="{DynamicResource WdBg}" UseLayoutRounding="True"'
    '        TextOptions.TextFormattingMode="Display">'
    '  <Window.Resources>'
    # Scrollbars. Always set the Min of whichever dimension is narrowed: the
    # default theme style sets both, and Min beats the plain property in layout,
    # so a bare Width reads back 5 while the bar arranges at the system's 17.
    '    <ControlTemplate x:Key="WdVBarTemplate" TargetType="ScrollBar">'
    '      <Grid Background="Transparent">'
    '        <Track Name="PART_Track" IsDirectionReversed="True">'
    '          <Track.Thumb>'
    '            <Thumb Name="WdThumb" Background="{DynamicResource WdScrollThumb}">'
    '              <Thumb.Template>'
    '                <ControlTemplate TargetType="Thumb">'
    # The transparent Grid is the draggable part. A Thumb with no Background of
    # its own is not hit-testable, so only the inset mark was - and the pixels
    # between it and the window edge fell through to the track and PAGED instead
    # of grabbing, which is the whole of "I shoved the pointer at the edge and
    # could not drag the bar". Same fix as the toolkit's own template.
    '                  <Grid Background="Transparent">'
    '                    <Border CornerRadius="3" Width="5.5" Margin="0,0,3,0" HorizontalAlignment="Right"'
    '                            Background="{Binding Background, RelativeSource={RelativeSource TemplatedParent}}"/>'
    '                  </Grid>'
    '                </ControlTemplate>'
    '              </Thumb.Template>'
    '            </Thumb>'
    '          </Track.Thumb>'
    '          <Track.IncreaseRepeatButton>'
    '            <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>'
    '          </Track.IncreaseRepeatButton>'
    '          <Track.DecreaseRepeatButton>'
    '            <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>'
    '          </Track.DecreaseRepeatButton>'
    '        </Track>'
    '      </Grid>'
    '      <ControlTemplate.Triggers>'
    '        <Trigger Property="IsMouseOver" Value="True">'
    '          <Setter TargetName="WdThumb" Property="Background" Value="{DynamicResource WdScrollThumbHover}"/>'
    '        </Trigger>'
    '      </ControlTemplate.Triggers>'
    '    </ControlTemplate>'
    '    <ControlTemplate x:Key="WdHBarTemplate" TargetType="ScrollBar">'
    '      <Grid Background="Transparent">'
    '        <Track Name="PART_Track" Orientation="Horizontal">'
    '          <Track.Thumb>'
    '            <Thumb Name="WdThumb" Background="{DynamicResource WdScrollThumb}">'
    '              <Thumb.Template>'
    '                <ControlTemplate TargetType="Thumb">'
    '                  <Grid Background="Transparent">'
    '                    <Border CornerRadius="2" Margin="0,1.5"'
    '                            Background="{Binding Background, RelativeSource={RelativeSource TemplatedParent}}"/>'
    '                  </Grid>'
    '                </ControlTemplate>'
    '              </Thumb.Template>'
    '            </Thumb>'
    '          </Track.Thumb>'
    '          <Track.IncreaseRepeatButton>'
    '            <RepeatButton Command="ScrollBar.PageRightCommand" Opacity="0" Focusable="False"/>'
    '          </Track.IncreaseRepeatButton>'
    '          <Track.DecreaseRepeatButton>'
    '            <RepeatButton Command="ScrollBar.PageLeftCommand" Opacity="0" Focusable="False"/>'
    '          </Track.DecreaseRepeatButton>'
    '        </Track>'
    '      </Grid>'
    '      <ControlTemplate.Triggers>'
    '        <Trigger Property="IsMouseOver" Value="True">'
    '          <Setter TargetName="WdThumb" Property="Background" Value="{DynamicResource WdScrollThumbHover}"/>'
    '        </Trigger>'
    '      </ControlTemplate.Triggers>'
    '    </ControlTemplate>'
    '    <Style x:Key="WdSlimBar" TargetType="ScrollBar">'
    '      <Setter Property="Background" Value="Transparent"/>'
    '      <Style.Triggers>'
    '        <Trigger Property="Orientation" Value="Vertical">'
    '          <Setter Property="Template" Value="{StaticResource WdVBarTemplate}"/>'
    # 16 of hit area carrying a 5.5 mark, as the toolkit's is. Both Width and
    # MinWidth: the theme style sets Min too, and Min beats the plain property in
    # layout - so a bare Width reads back correctly while the bar arranges at the
    # system's 17.33.
    '          <Setter Property="Width" Value="16"/><Setter Property="MinWidth" Value="16"/>'
    '          <Setter Property="Height" Value="Auto"/>'
    '        </Trigger>'
    '        <Trigger Property="Orientation" Value="Horizontal">'
    '          <Setter Property="Template" Value="{StaticResource WdHBarTemplate}"/>'
    '          <Setter Property="Height" Value="7"/><Setter Property="MinHeight" Value="7"/>'
    '          <Setter Property="Width" Value="Auto"/>'
    '        </Trigger>'
    '      </Style.Triggers>'
    '    </Style>'
    '    <Style TargetType="ScrollBar" BasedOn="{StaticResource WdSlimBar}"/>'
    # The rail wants something narrower still - 5px beside a 196px column, where
    # 11.5 would read as a second column. An implicit style has to live in the
    # ScrollViewer's own resources to reach the bar inside its template, but the
    # definition does not, so it is here and pulled in with a one-line BasedOn.
    '    <ControlTemplate x:Key="WdRailBarTemplate" TargetType="ScrollBar">'
    '      <Grid Background="Transparent">'
    '        <Track Name="PART_Track" IsDirectionReversed="True">'
    '          <Track.Thumb>'
    '            <Thumb Name="WdRailThumb" Background="{DynamicResource WdScrollThumb}">'
    '              <Thumb.Template>'
    '                <ControlTemplate TargetType="Thumb">'
    '                  <Grid Background="Transparent">'
    '                    <Border CornerRadius="2.5"'
    '                            Background="{Binding Background, RelativeSource={RelativeSource TemplatedParent}}"/>'
    '                  </Grid>'
    '                </ControlTemplate>'
    '              </Thumb.Template>'
    '            </Thumb>'
    '          </Track.Thumb>'
    '          <Track.IncreaseRepeatButton>'
    '            <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>'
    '          </Track.IncreaseRepeatButton>'
    '          <Track.DecreaseRepeatButton>'
    '            <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>'
    '          </Track.DecreaseRepeatButton>'
    '        </Track>'
    '      </Grid>'
    '      <ControlTemplate.Triggers>'
    '        <Trigger Property="IsMouseOver" Value="True">'
    '          <Setter TargetName="WdRailThumb" Property="Background" Value="{DynamicResource WdScrollThumbHover}"/>'
    '        </Trigger>'
    '      </ControlTemplate.Triggers>'
    '    </ControlTemplate>'
    '    <Style x:Key="WdRailBar" TargetType="ScrollBar">'
    '      <Setter Property="Width" Value="5"/><Setter Property="MinWidth" Value="5"/>'
    '      <Setter Property="Background" Value="Transparent"/>'
    '      <Setter Property="Template" Value="{StaticResource WdRailBarTemplate}"/>'
    '    </Style>'
    # Button, ToggleButton, TextBox and ComboBox all keep the system chrome
    # unless they are retemplated, and that chrome is light in BOTH palettes.
    # The hover state is a translucent OVERLAY rather than a Background setter,
    # so a button carrying a colour of its own composites rather than being
    # replaced.
    '    <Style x:Key="WdButton" TargetType="Button">'
    '      <Setter Property="Background" Value="{DynamicResource WdBtnBg}"/>'
    '      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>'
    '      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>'
    '      <Setter Property="BorderThickness" Value="1"/>'
    '      <Setter Property="Padding" Value="10,4"/>'
    '      <Setter Property="SnapsToDevicePixels" Value="True"/>'
    '      <Setter Property="Template">'
    '        <Setter.Value>'
    '          <ControlTemplate TargetType="Button">'
    '            <Grid>'
    '              <Border Name="WdBtnFace" CornerRadius="4" Background="{TemplateBinding Background}"'
    '                      BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"'
    '                      SnapsToDevicePixels="True"/>'
    '              <Border Name="WdBtnTint" CornerRadius="4" Opacity="0" Background="{DynamicResource WdBtnTint}"/>'
    '              <ContentPresenter Margin="{TemplateBinding Padding}"'
    '                                HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"'
    '                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"'
    '                                RecognizesAccessKey="True"'
    '                                TextElement.Foreground="{TemplateBinding Foreground}"/>'
    '            </Grid>'
    '            <ControlTemplate.Triggers>'
    '              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="WdBtnTint" Property="Opacity" Value="0.55"/></Trigger>'
    '              <Trigger Property="IsPressed" Value="True"><Setter TargetName="WdBtnTint" Property="Opacity" Value="1"/></Trigger>'
    '              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="WdBtnFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/></Trigger>'
    '              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>'
    '            </ControlTemplate.Triggers>'
    '          </ControlTemplate>'
    '        </Setter.Value>'
    '      </Setter>'
    '    </Style>'
    '    <Style TargetType="Button" BasedOn="{StaticResource WdButton}"/>'
    # NOT BasedOn WdButton. A style's BasedOn target has to be its own type or a
    # base of it, and Button and ToggleButton are siblings under ButtonBase - it
    # parses and then throws on the first element that uses it, naming
    # FrameworkElement.Style and nothing whatever about why.
    '    <Style x:Key="WdToggle" TargetType="ToggleButton">'
    '      <Setter Property="Background" Value="{DynamicResource WdBtnBg}"/>'
    '      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>'
    '      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>'
    '      <Setter Property="BorderThickness" Value="1"/>'
    '      <Setter Property="SnapsToDevicePixels" Value="True"/>'
    '      <Setter Property="Template">'
    '        <Setter.Value>'
    '          <ControlTemplate TargetType="ToggleButton">'
    '            <Grid>'
    '              <Border Name="WdTgFace" CornerRadius="4" Background="{TemplateBinding Background}"'
    '                      BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"'
    '                      SnapsToDevicePixels="True"/>'
    '              <Border Name="WdTgTint" CornerRadius="4" Opacity="0" Background="{DynamicResource WdBtnTint}"/>'
    '              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center"'
    '                                VerticalAlignment="Center" RecognizesAccessKey="True"'
    '                                TextElement.Foreground="{TemplateBinding Foreground}"/>'
    '            </Grid>'
    '            <ControlTemplate.Triggers>'
    '              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="WdTgTint" Property="Opacity" Value="0.55"/></Trigger>'
    '              <Trigger Property="IsChecked" Value="True">'
    '                <Setter TargetName="WdTgTint" Property="Opacity" Value="1"/>'
    '                <Setter TargetName="WdTgFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>'
    '              </Trigger>'
    '              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>'
    '            </ControlTemplate.Triggers>'
    '          </ControlTemplate>'
    '        </Setter.Value>'
    '      </Setter>'
    '    </Style>'
    '    <Style x:Key="WdTextBox" TargetType="TextBox">'
    '      <Setter Property="Background" Value="{DynamicResource WdFieldBg}"/>'
    '      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>'
    '      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>'
    '      <Setter Property="CaretBrush" Value="{DynamicResource WdText}"/>'
    '      <Setter Property="SelectionBrush" Value="{DynamicResource WdAccent}"/>'
    '      <Setter Property="BorderThickness" Value="1"/>'
    '      <Setter Property="Template">'
    '        <Setter.Value>'
    '          <ControlTemplate TargetType="TextBox">'
    '            <Border Name="WdTbFace" CornerRadius="4" Background="{TemplateBinding Background}"'
    '                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"'
    '                    SnapsToDevicePixels="True">'
    '              <ScrollViewer Name="PART_ContentHost" Focusable="False" Margin="{TemplateBinding Padding}"'
    '                            HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>'
    '            </Border>'
    '            <ControlTemplate.Triggers>'
    '              <Trigger Property="IsKeyboardFocusWithin" Value="True">'
    '                <Setter TargetName="WdTbFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>'
    '              </Trigger>'
    '            </ControlTemplate.Triggers>'
    '          </ControlTemplate>'
    '        </Setter.Value>'
    '      </Setter>'
    '    </Style>'
    '    <Style TargetType="TextBox" BasedOn="{StaticResource WdTextBox}"/>'
    # A ComboBox draws its closed bar from SelectionBoxItem in the ComboBox's
    # OWN foreground and its popup on the system window brush, which is white in
    # both themes. Painting the items is the wrong fix and makes it worse; the
    # popup has to be a surface this file owns before anything on it can be read.
    '    <ControlTemplate x:Key="WdComboToggle" TargetType="ToggleButton">'
    '      <Border Name="WdCbFace" CornerRadius="4" Background="{DynamicResource WdFieldBg}"'
    '              BorderBrush="{DynamicResource WdBtnBorder}" BorderThickness="1" SnapsToDevicePixels="True">'
    '        <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,1,9,0"'
    '              Data="M 0 0 L 8 0 L 4 4 Z" Fill="{DynamicResource WdSub}"/>'
    '      </Border>'
    '      <ControlTemplate.Triggers>'
    '        <Trigger Property="IsMouseOver" Value="True">'
    '          <Setter TargetName="WdCbFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>'
    '        </Trigger>'
    '      </ControlTemplate.Triggers>'
    '    </ControlTemplate>'
    '    <Style x:Key="WdCombo" TargetType="ComboBox">'
    '      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>'
    '      <Setter Property="Background" Value="{DynamicResource WdFieldBg}"/>'
    '      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>'
    '      <Setter Property="Padding" Value="8,4,24,4"/>'
    '      <Setter Property="Template">'
    '        <Setter.Value>'
    '          <ControlTemplate TargetType="ComboBox">'
    '            <Grid>'
    '              <ToggleButton Name="WdCbToggle" Focusable="False" ClickMode="Press"'
    '                            Template="{StaticResource WdComboToggle}"'
    '                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>'
    '              <ContentPresenter Name="WdCbText" IsHitTestVisible="False"'
    '                                Content="{TemplateBinding SelectionBoxItem}"'
    '                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"'
    '                                Margin="{TemplateBinding Padding}" HorizontalAlignment="Left"'
    '                                VerticalAlignment="Center" TextElement.Foreground="{TemplateBinding Foreground}"/>'
    '              <Popup Name="PART_Popup" Placement="Bottom" Focusable="False" AllowsTransparency="True"'
    '                     IsOpen="{TemplateBinding IsDropDownOpen}">'
    '                <Border Name="WdCbList" CornerRadius="4" BorderThickness="1"'
    '                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"'
    '                        MaxHeight="{TemplateBinding MaxDropDownHeight}"'
    '                        Background="{DynamicResource WdPanel}" BorderBrush="{DynamicResource WdLine}">'
    '                  <ScrollViewer><StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>'
    '                </Border>'
    '              </Popup>'
    '            </Grid>'
    '          </ControlTemplate>'
    '        </Setter.Value>'
    '      </Setter>'
    '    </Style>'
    '    <Style TargetType="ComboBox" BasedOn="{StaticResource WdCombo}"/>'
    '    <Style x:Key="WdComboItem" TargetType="ComboBoxItem">'
    '      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>'
    '      <Setter Property="Background" Value="Transparent"/>'
    '      <Setter Property="Padding" Value="9,5"/>'
    '      <Setter Property="Template">'
    '        <Setter.Value>'
    '          <ControlTemplate TargetType="ComboBoxItem">'
    '            <Border Name="WdItemFace" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">'
    '              <ContentPresenter TextElement.Foreground="{TemplateBinding Foreground}"/>'
    '            </Border>'
    '            <ControlTemplate.Triggers>'
    '              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="WdItemFace" Property="Background" Value="{DynamicResource WdRowHover}"/></Trigger>'
    '              <Trigger Property="IsSelected" Value="True"><Setter TargetName="WdItemFace" Property="Background" Value="{DynamicResource WdCardSel}"/></Trigger>'
    '            </ControlTemplate.Triggers>'
    '          </ControlTemplate>'
    '        </Setter.Value>'
    '      </Setter>'
    '    </Style>'
    '    <Style TargetType="ComboBoxItem" BasedOn="{StaticResource WdComboItem}"/>'
    '    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="{DynamicResource WdText}"/></Style>'
    '  </Window.Resources>'
    '  <Grid Margin="18,14,0,14">'
    '    <Grid.RowDefinitions>'
    '      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>'
    '      <RowDefinition Height="*"/><RowDefinition Height="Auto"/>'
    '    </Grid.RowDefinitions>'
    '    <DockPanel Grid.Row="0" Margin="0,0,18,12">'
    '      <Button x:Name="BtnTheme" DockPanel.Dock="Right" VerticalAlignment="Top" Margin="12,0,0,0"'
    '              Padding="12,4" FontSize="12.5" MinWidth="106"/>'
    # Non-verbose is the default here as it is in the application: the standing
    # description is the same on every visit, which is what somebody who has read
    # the list once reads past, and Details still carries the whole of it for the
    # one option being asked about. This is the App Options tick, in the one place
    # a window with no options page can put it - beside the theme button, because
    # both are about how the page reads rather than about what to put back.
    '      <ToggleButton x:Name="BtnVerbose" DockPanel.Dock="Right" VerticalAlignment="Top" Margin="12,0,0,0"'
    '                    Content="Verbose" Padding="12,4" FontSize="12.5" MinWidth="92"'
    '                    Style="{StaticResource WdToggle}"'
    '                    ToolTip="Show the one-line description under every option. Off by default - Details still shows it for one option at a time."/>'
    '      <StackPanel>'
    '        <TextBlock x:Name="Head" FontSize="20" FontWeight="SemiBold" TextWrapping="Wrap"'
    '                   Foreground="{DynamicResource WdText}"/>'
    '        <TextBlock x:Name="Sub1" FontSize="12.5" Margin="0,4,0,0" TextWrapping="Wrap"'
    '                   Foreground="{DynamicResource WdSub}"/>'
    '        <TextBlock x:Name="Sub2" FontSize="12.5" Margin="0,4,0,0" TextWrapping="Wrap"'
    '                   Foreground="{DynamicResource WdSub}"/>'
    '      </StackPanel>'
    '    </DockPanel>'
    '    <Border x:Name="Bar" Grid.Row="1" Background="{DynamicResource WdPanel}"'
    '            BorderBrush="{DynamicResource WdLine}" BorderThickness="1"'
    '            CornerRadius="4" Padding="12,9,12,10" Margin="0,0,18,10">'
    '      <StackPanel>'
    '        <DockPanel LastChildFill="True">'
    '          <ToggleButton x:Name="BtnFilter" Content="Filter" Padding="12,3" FontSize="12.5"'
    '                        Style="{StaticResource WdToggle}" Margin="0,0,12,0" MinWidth="118"/>'
    '          <TextBlock Text="Group by" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="12.5"'
    '                     Foreground="{DynamicResource WdText}"/>'
    '          <ComboBox x:Name="CmbOrder" Width="160" FontSize="12.5" Margin="0,0,12,0"/>'
    '          <TextBlock Text="Sort by" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="12.5"'
    '                     Foreground="{DynamicResource WdText}"/>'
    '          <ComboBox x:Name="CmbSort" Width="152" FontSize="12.5" Margin="0,0,16,0"/>'
    '          <Button x:Name="BtnSelectAll" Content="Select all" Padding="10,3" FontSize="12.5"'
    '                  Margin="0,0,16,0" MinWidth="90"'
    '                  ToolTip="Selects every option on screen that can be reverted. Press again to clear them."/>'
    '          <TextBlock Text="Collapse all" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="12.5"'
    '                     Foreground="{DynamicResource WdText}"/>'
    '          <Button x:Name="BtnCollapseAll" Content="-" Width="26" Padding="0,1" FontSize="13"'
    '                  FontWeight="Bold" Margin="0,0,4,0" ToolTip="Collapse every group on the page"/>'
    '          <Button x:Name="BtnExpandAll" Content="+" Width="26" Padding="0,1" FontSize="13"'
    '                  FontWeight="Bold" Margin="0,0,16,0" ToolTip="Expand every group on the page"/>'
    # This page is a READING of the machine, taken when it was built, and
    # somebody may have put something back by hand since - with regedit, or with
    # this script open beside the toolkit. Refresh asks again.
    '          <Button x:Name="BtnRefresh" Content="Refresh" Padding="10,3" FontSize="12.5" Margin="0,0,16,0"'
    '                  ToolTip="Reads this machine again and rebuilds the page, so anything put back by hand since it was opened is accounted for."/>'
    '          <TextBlock x:Name="TxtCount" VerticalAlignment="Center" Margin="0,0,16,0" FontSize="12.5"'
    '                     Foreground="{DynamicResource WdSub}"/>'
    '          <TextBlock Text="Search" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="12.5"'
    '                     Foreground="{DynamicResource WdText}"/>'
    '          <TextBox x:Name="Find" Padding="7,3" FontSize="12.5" MinWidth="140"/>'
    '        </DockPanel>'
    '        <WrapPanel x:Name="FilterChips" Margin="0,9,0,0" Visibility="Collapsed"/>'
    '      </StackPanel>'
    '    </Border>'
    '    <Popup x:Name="FilterPopup" PlacementTarget="{Binding ElementName=BtnFilter}" Placement="Bottom"'
    '           StaysOpen="False" AllowsTransparency="True" VerticalOffset="4"'
    '           IsOpen="{Binding IsChecked, ElementName=BtnFilter, Mode=TwoWay}">'
    '      <Border Background="{DynamicResource WdPanel}" BorderBrush="{DynamicResource WdLine}"'
    '              BorderThickness="1" CornerRadius="6" Padding="16,12" MinWidth="300">'
    '        <StackPanel>'
    '          <ScrollViewer MaxHeight="430" VerticalScrollBarVisibility="Auto">'
    '            <StackPanel x:Name="FilterPanel"/>'
    '          </ScrollViewer>'
    '          <DockPanel LastChildFill="False" Margin="0,12,0,0">'
    '            <Button x:Name="BtnFilterClear" Content="Clear all" Padding="12,4" FontSize="12.5"/>'
    '            <Button x:Name="BtnFilterDone" DockPanel.Dock="Right" Content="Done" Padding="16,4" FontSize="12.5" Margin="0"/>'
    '          </DockPanel>'
    '        </StackPanel>'
    '      </Border>'
    '    </Popup>'
    # Three columns and the middle one is a splitter, because where the rail
    # should stop is a matter of which names are in it - which the operator can
    # see and this cannot. No right margin on the grid: the list's own
    # ScrollViewer carries the inset as Padding, which insets the CONTENT and
    # not the bar, so the bar lands hard against the window edge where every
    # other application puts one.
    '    <Grid x:Name="ListPage" Grid.Row="2">'
    '      <Grid.ColumnDefinitions>'
    '        <ColumnDefinition x:Name="IndexCol" Width="196" MinWidth="120" MaxWidth="420"/>'
    '        <ColumnDefinition Width="Auto"/>'
    '        <ColumnDefinition Width="*"/>'
    '      </Grid.ColumnDefinitions>'
    '      <ScrollViewer x:Name="RailScroll" Grid.Column="0" VerticalScrollBarVisibility="Auto"'
    '                    HorizontalScrollBarVisibility="Disabled">'
    '        <ScrollViewer.Resources>'
    '          <Style TargetType="ScrollBar" BasedOn="{StaticResource WdRailBar}"/>'
    '        </ScrollViewer.Resources>'
    '        <StackPanel x:Name="Rail" Margin="0,0,6,0"/>'
    '      </ScrollViewer>'
    '      <Border Grid.Column="1" Width="1" Margin="9,0,0,0" HorizontalAlignment="Left"'
    '              IsHitTestVisible="False" Background="{DynamicResource WdLine}"/>'
    '      <GridSplitter Grid.Column="1" Width="10" HorizontalAlignment="Center"'
    '                    VerticalAlignment="Stretch" Background="Transparent" ShowsPreview="False"/>'
    '      <ScrollViewer x:Name="Scroll" Grid.Column="2" Padding="14,0,14,0"'
    '                    VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">'
    '        <StackPanel x:Name="List"/>'
    '      </ScrollViewer>'
    '    </Grid>'
    '    <Grid x:Name="RunPage" Grid.Row="2" Margin="0,0,18,0" Visibility="Collapsed">'
    '      <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>'
    '      <Border Grid.Row="0" Background="{DynamicResource WdPanel}" BorderBrush="{DynamicResource WdLine}"'
    '              BorderThickness="1" CornerRadius="4">'
    '        <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto" Padding="10">'
    '          <StackPanel x:Name="Log"/>'
    '        </ScrollViewer>'
    '      </Border>'
    '      <TextBlock x:Name="RunNote" Grid.Row="1" Margin="2,10,0,0" FontSize="12.5" TextWrapping="Wrap"'
    '                 Foreground="{DynamicResource WdSub}"/>'
    '    </Grid>'
    '    <DockPanel Grid.Row="3" Margin="0,12,18,0">'
    '      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">'
    '        <Button x:Name="BtnGo" Content="Revert selected" Padding="14,5" Margin="0,0,8,0"/>'
    '        <Button x:Name="BtnClose" Content="Close" Padding="14,5" Margin="0"/>'
    '      </StackPanel>'
    '      <TextBlock x:Name="Tally" VerticalAlignment="Center" FontSize="12.5" TextWrapping="Wrap"'
    '                 Foreground="{DynamicResource WdSub}"/>'
    '    </DockPanel>'
    '  </Grid>'
    '</Window>'
    ) -join [Environment]::NewLine

    $esc = ([string]$title).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    $x = $x.Replace('@Title@', $esc)

    $win = $null
    try {
        $win = [Windows.Markup.XamlReader]::Parse($x)
    } catch {
        if ($splash) { & $splash.Close }
        # The console was hidden on the way in. Anything that falls through to
        # printing has to put it back, or this reads as a program that started
        # and then stopped existing.
        Set-WDUndoConsole -Show
        Write-Host "The window could not be built ($($_.Exception.Message)), so this is the console version." -ForegroundColor Yellow
        Close-WDHives
        return (Invoke-WDUndoConsole)
    }
    Set-WDUndoBrushes -Window $win -Pal $pal

    $ui = @{}
    foreach ($n in @('Head','Sub1','Sub2','Bar','Find','BtnTheme','BtnVerbose','BtnFilter','FilterPopup','FilterPanel',
                     'FilterChips','BtnFilterClear','BtnFilterDone','CmbOrder','CmbSort','BtnSelectAll','BtnCollapseAll',
                     'BtnExpandAll','BtnRefresh','TxtCount','IndexCol','RailScroll','Rail','Scroll','List','ListPage',
                     'RunPage','Log','LogScroll','RunNote','BtnGo','BtnClose','Tally')) {
        $ui[$n] = $win.FindName($n)
    }

    # A resource reference rather than a brush, everywhere, because that is what
    # makes the theme button a repaint. The property identifier has to come from
    # the type that declares it - a TextBlock's Foreground is TextBlock's, a
    # Control's is Control's - and the wrong one throws.
    #
    # Cached per type and property name. This runs about sixteen hundred times
    # while the page is built, and the answer for a given pair never changes;
    # the four -is tests were being paid on every one of them.
    $dpCache = @{}
    $Ref = {
        param($El, [string]$Prop, [string]$Key)
        $ck = $El.GetType().Name + '|' + $Prop
        if (-not $dpCache.ContainsKey($ck)) {
            $dp = $null
            switch ($Prop) {
                'Foreground' {
                    if ($El -is [Windows.Controls.TextBlock]) { $dp = [Windows.Controls.TextBlock]::ForegroundProperty }
                    else { $dp = [Windows.Controls.Control]::ForegroundProperty }
                }
                'Background' {
                    if     ($El -is [Windows.Controls.Border])    { $dp = [Windows.Controls.Border]::BackgroundProperty }
                    elseif ($El -is [Windows.Controls.Panel])     { $dp = [Windows.Controls.Panel]::BackgroundProperty }
                    elseif ($El -is [Windows.Controls.TextBlock]) { $dp = [Windows.Controls.TextBlock]::BackgroundProperty }
                    else { $dp = [Windows.Controls.Control]::BackgroundProperty }
                }
                'BorderBrush' {
                    if ($El -is [Windows.Controls.Border]) { $dp = [Windows.Controls.Border]::BorderBrushProperty }
                    else { $dp = [Windows.Controls.Control]::BorderBrushProperty }
                }
            }
            $dpCache[$ck] = $dp
        }
        $dp = $dpCache[$ck]
        if ($dp) { $El.SetResourceReference($dp, 'Wd' + $Key) }
    }.GetNewClosure()

    $palBox = @{ Key = $themeKey; Cur = $pal }
    $applyTheme = {
        param([string]$Key)
        $p = Get-WDUndoPalette -Theme $Key
        $palBox.Key = $Key
        $palBox.Cur = $p
        Set-WDUndoBrushes -Window $win -Pal $p
        Set-WDUndoDarkTitleBar -Window $win -Dark ($p.Dark -eq '1')
        $ui.BtnTheme.Content = $(if ($p.Dark -eq '1') { 'Light theme' } else { 'Dark theme' })
        $ic = Get-WDUndoIcon -Theme $Key
        if ($ic) { $win.Icon = $ic }
    }.GetNewClosure()

    $ui.BtnTheme.Content = $(if ($pal.Dark -eq '1') { 'Light theme' } else { 'Dark theme' })
    $ui.BtnTheme.ToolTip = 'Switch between the dark and light palettes.'
    $ico = Get-WDUndoIcon -Theme $themeKey
    if ($ico) { $win.Icon = $ico }
    if (-not $BuildOnly) { Set-WDUndoDarkTitleBar -Window $win -Dark ($pal.Dark -eq '1') }

    $win.Title    = $title
    $ui.Head.Text = $title

    # ONE PLACE THAT COUNTS THE HEADING, because Refresh reads the machine again
    # and the two numbers under the title are the answer it changes. Counted off
    # $opts rather than handed the totals: a second copy of the arithmetic is how
    # the heading and the rows come to disagree about what a run left behind.
    $saySummary = {
        param([string]$Extra)
        $tTodo = 0; $tDone = 0; $tHuh = 0; $tSteps = 0
        foreach ($o in $opts) {
            $tSteps += [int]@($o.Steps).Count
            $tTodo  += [int]$o.Todo; $tDone += [int]$o.Done; $tHuh += [int]$o.Unknown
        }
        $ui.Sub1.Text = 'Nothing here happens until you press Revert selected.'
        $bits = New-Object System.Collections.Generic.List[string]
        $bits.Add("$tTodo of $tSteps changes are still in place")
        if ($tDone) { $bits.Add("$tDone already back") }
        if ($tHuh)  { $bits.Add("$tHuh could not be checked from here") }
        $txt = ($bits -join ', ') + '.'
        if ($global:WDWantsDefault -and -not $global:WDDefaultOk) {
            $txt += " The default user profile could not be loaded, so $global:WDWantsDefault value(s) affecting accounts created later cannot be read or restored."
        }
        if ($global:WDDismBlocked) {
            $txt += ' A restart is pending, so Windows features cannot be changed until this machine has restarted.'
        }
        if ($Extra) { $txt += ' ' + $Extra }
        $ui.Sub2.Text = $txt
    }.GetNewClosure()
    & $saySummary ''

    # --------------------------------------------------------- the rows ----
    #
    # Built once, and re-parented by every change of grouping.
    #
    # ONLY WHAT HAS ALREADY BEEN PUT BACK WEARS A TAG. Still in place is what
    # every row on this page is unless it says otherwise, so a "still in place"
    # marker on a hundred and twenty rows is the page's own premise printed a
    # hundred and twenty times. "Cannot tell from here" stays, because that one
    # is not the assumption - it is this script admitting it could not ask.
    $ms.Shell = [int]$clock.ElapsedMilliseconds; $clock.Restart()

    $rows = New-Object System.Collections.Generic.List[psobject]
    $tag  = @{ done = 'already back'; unknown = 'cannot tell from here' }
    $col  = @{ done = 'Ok';           unknown = 'Muted' }

    # DECLARED BEFORE THE ROW LOOP, and that placement is load-bearing: $makeRow
    # resolves $state when it runs, which is in the loop below. Declared after it,
    # every row read $null.Terse - falsy - and descriptions came up showing
    # whatever the option said to hide.
    #
    # Terse is Non-verbose and is the DEFAULT, as in the application. The one way
    # this cannot match: a script that stands alone has nowhere to remember the
    # choice between launches.
    $state = @{ Group = 'category'; Sort = 'name'; Booting = $true; Terse = $true }

    # Reports progress like the machine read does: the splash animates on its own
    # thread, but a line that does not move for three seconds says the same thing
    # a frozen one does.
    #
    # THE ROW BUILDER IS ITS OWN BLOCK, and that is a cost decision.
    # GetNewClosure copies the LOCALS of the scope it is written in, and there are
    # five closures per row - written inline, six hundred of them each copy every
    # local this function has, and it has a lot. Written in a block of its own,
    # they copy that block's dozen.
    #
    # AND THE BUILDER ITSELF IS A CLOSURE, which is a different question.
    # Everything arrives as a parameter except $state, and Refresh calls this
    # again - a bare block would resolve $state against whoever invoked it. From a
    # WPF handler that is this function's live frame and works; through the
    # -BuildOnly diagnostic, after it has returned, it is $null.
    $makeRow = {
        param($O, $RefFn, $TagText, $TagInk)
        $Ref = $RefFn
        $card = New-Object Windows.Controls.Border
        $card.CornerRadius = 3; $card.Padding = '8,5,8,6'; $card.Margin = '0,0,0,3'
        & $Ref $card 'Background' 'Flat'

        # THE SAME SHAPE AS THE TOOLKIT'S OWN ROW, which is the point of this
        # whole file: somebody who has used one has used the other. The tick box
        # is docked to the left of a stack that fills, so everything under the
        # name starts at the name's own left edge rather than being pushed there
        # by a hand-measured margin.
        $panel = New-Object Windows.Controls.DockPanel
        $panel.LastChildFill = $true

        $cb = New-Object Windows.Controls.CheckBox
        $cb.VerticalAlignment = 'Top'; $cb.Margin = '0,4,8,0'
        $cb.IsChecked = ($O.State -ne 'done')
        $cb.IsEnabled = ($O.State -ne 'done')
        [Windows.Controls.DockPanel]::SetDock($cb, 'Left')
        $null = $panel.Children.Add($cb)

        $stack = New-Object Windows.Controls.StackPanel

        # A name, then some chips, is a WrapPanel and never a horizontal
        # StackPanel: that one measures its children with infinite width, so
        # nothing wraps and the last chip is drawn off the edge of the card.
        $line = New-Object Windows.Controls.WrapPanel

        $nm = New-Object Windows.Controls.TextBlock
        # 15 and SemiBold, as an Advanced row's name is. It was 13.5 and normal
        # weight here and on the Revert page, and against the toolkit's own list
        # the same option looked like two different kinds of thing.
        $nm.Text = $O.Name; $nm.FontSize = 15; $nm.FontWeight = 'SemiBold'
        # Wrap, as the toolkit's own row does. A WrapPanel arranges a child at
        # its DESIRED width, and a TextBlock with no wrapping desires the whole
        # of its text however narrow the column is - so a long name is simply
        # drawn past the edge of the card. It never showed while the list was one
        # column wide; halving that width is what brought it out.
        $nm.TextWrapping = 'Wrap'
        # The key in a variable rather than an if-expression in the argument: the
        # toolkit's closure check reads the literals handed to $Ref to confirm
        # each is a real theme key, and a condition comparing against 'done'
        # inside the argument looks exactly like a key being passed.
        $nmInk = 'Text'
        if ($O.State -eq 'done') {
            $nmInk = 'Muted'
            # STRUCK THROUGH, and dimmed below, exactly as an Advanced row is
            # when its target is not on this machine. The two states are the same
            # kind of thing - a row that is here to tell you there is nothing left
            # to do - and this one said it in two ways where that one says it in
            # four. A line through a name is the one mark that cannot be mistaken
            # for a style choice.
            $nm.TextDecorations = [Windows.TextDecorations]::Strikethrough
        }
        & $Ref $nm 'Foreground' $nmInk
        $null = $line.Children.Add($nm)

        $tagEl = $null
        if ($TagText.ContainsKey($O.State)) {
            $tagEl = New-Object Windows.Controls.TextBlock
            # 11 at '6,4,0,0', as every tag on an Advanced row is.
            $tagEl.Text = '  ' + $TagText[$O.State]; $tagEl.FontSize = 11; $tagEl.Margin = '6,4,0,0'
            & $Ref $tagEl 'Foreground' $TagInk[$O.State]
            $null = $line.Children.Add($tagEl)
        }

        $cnt = New-Object Windows.Controls.TextBlock
        $cnt.Text = '  ' + $O.CountText
        $cnt.FontSize = 11; $cnt.Margin = '6,4,0,0'
        & $Ref $cnt 'Foreground' 'Muted'
        $null = $line.Children.Add($cnt)

        # A real face and the button border, so it reads as a control at rest
        # rather than as a bordered label whose only tell is a hover tint nobody
        # sees until they are already on it. Same values as the toolkit's own.
        $chip = New-Object Windows.Controls.Border
        $chip.CornerRadius = 4; $chip.Padding = '9,2,9,3'; $chip.Margin = '8,2,0,0'
        $chip.BorderThickness = New-Object Windows.Thickness 1
        $chip.VerticalAlignment = 'Center'
        & $Ref $chip 'BorderBrush' 'BtnBorder'
        & $Ref $chip 'Background' 'BtnBg'
        $chip.Cursor = 'Hand'
        $ct = New-Object Windows.Controls.TextBlock
        $ct.Text = 'Details'; $ct.FontSize = 11
        & $Ref $ct 'Foreground' 'Text'
        $chip.Child = $ct
        $null = $line.Children.Add($chip)
        $null = $stack.Children.Add($line)

        # The always-on description, exactly as an Advanced row carries one, and
        # in the tense this page is written in - see Get-WDRevertDescription. The
        # page used to name an option and count its changes without ever saying
        # what the option was, so "Office telemetry - 4 changes" was the whole of
        # what a row told somebody deciding whether to put it back.
        #
        # 13 at '0,2,0,0', which is an Advanced description exactly. No indent:
        # the stack this sits in already begins at the name's left edge, because
        # the tick box is docked outside it.
        $dsc = [string]$O.Desc
        $dscEl = $null
        if ($dsc) {
            $dt = New-Object Windows.Controls.TextBlock
            $dt.Text = $dsc; $dt.FontSize = 13; $dt.TextWrapping = 'Wrap'
            $dt.Margin = '0,2,0,0'
            & $Ref $dt 'Foreground' 'Sub'
            # Built collapsed under Non-verbose rather than skipped, so turning
            # the option back off does not need the page rebuilt.
            if ($state.Terse) { $dt.Visibility = 'Collapsed' }
            $null = $stack.Children.Add($dt)
            $dscEl = $dt
        }

        # WHAT AN UNTICKED ROW MEANS, SAID ON THE ROW. Every option arrives ticked,
        # so clearing one is an edit - marked like an edit on the Advanced page,
        # name in Bad and bold. The words are the half a colour cannot carry: there
        # a tick is what a run will DO, here it is what a run will UNDO, and red
        # alone could as easily read as the dangerous half.
        #
        # Built empty and collapsed on EVERY row: a notice that exists only where
        # somebody remembered to build one is a rule that does half its job.
        $skip = New-Object Windows.Controls.TextBlock
        $skip.Text = 'Option will not be reverted'
        $skip.FontSize = 12.5; $skip.TextWrapping = 'Wrap'; $skip.Margin = '0,4,0,0'
        $skip.Visibility = 'Collapsed'
        & $Ref $skip 'Foreground' 'Bad'
        $null = $stack.Children.Add($skip)

        $null = $panel.Children.Add($stack)
        $card.Child = $panel

        # Under the row rather than in a dialog. Everything about this page is
        # "what exactly is about to happen to my machine", and an answer that
        # covers the question while you read it is the wrong shape.
        #
        # THE ELEMENT IS BUILT ON FIRST OPEN. The text is not: the search box
        # looks inside it, so a registry path finds the option that wrote it,
        # and that has to be true of a row nobody has expanded. What is deferred
        # is a hundred and twenty-one TextBlocks nobody may ever look at, on a
        # page whose whole cost is element creation.
        $detText = [string]$O.DetailText

        # GetNewClosure snapshots this block's locals, so each row's handlers
        # hold their own elements. Hover is a resource reference like everything
        # else, or a theme switch would leave the last hovered row wearing the
        # other palette's grey.
        $refL = $RefFn
        # A local of this invocation, never a reach up the chain for $state: this
        # block is invoked with &, so a closure built in it copies THESE locals
        # and nothing of the function's. The hashtable itself, so Non-verbose
        # toggled later reads live.
        $stateHere = $state
        $hold = @{ Det = $null }
        $chip.Add_MouseLeftButtonUp({
            if ($hold.Det -and $hold.Det.Visibility -eq 'Visible') {
                $hold.Det.Visibility = 'Collapsed'
                return
            }
            if (-not $hold.Det) {
                # 12 at LineHeight 18, as the Advanced panel is. No left indent:
                # the stack begins at the name, because the tick box is docked
                # outside it.
                $d = New-Object Windows.Controls.TextBlock
                $d.FontSize = 12; $d.Margin = '0,4,8,7'
                $d.TextWrapping = 'Wrap'; $d.LineHeight = 18
                $d.LineStackingStrategy = 'BlockLineHeight'
                & $refL $d 'Foreground' 'Sub'
                $null = $stack.Children.Add($d)
                $hold.Det = $d
            }
            # Set on every open, not once: under Non-verbose the row is not
            # showing its description, so the panel carries it - and the option
            # can be switched off between two presses of this chip.
            $body = $detText
            if ($stateHere.Terse -and $dsc) { $body = $dsc + [Environment]::NewLine + [Environment]::NewLine + $detText }
            $hold.Det.Text = $body
            $hold.Det.Visibility = 'Visible'
        }.GetNewClosure())
        $chip.Add_MouseEnter({ & $refL $ct 'Foreground' 'Accent' }.GetNewClosure())
        $chip.Add_MouseLeave({ & $refL $ct 'Foreground' 'Text' }.GetNewClosure())

        # A ROW WITH NOTHING LEFT TO DECIDE IS INERT, exactly as an Advanced row
        # is when its target is not on this machine: no hand cursor, and no hover
        # tint. The tint is this application's own signal for "you can act on
        # this", which makes it the loudest part of the invitation - and the row
        # already refuses the click that signal promises.
        if ($O.State -eq 'done') {
            $card.Cursor  = 'Arrow'
            $card.Opacity = 0.6
        } else {
            $card.Cursor = 'Hand'
            $card.Add_MouseEnter({ & $refL $card 'Background' 'RowHover' }.GetNewClosure())
            $card.Add_MouseLeave({ & $refL $card 'Background' 'Flat'     }.GetNewClosure())
        }

        # CLICKING THE ROW TICKS IT. A tick box is a 13px target on a row 40px tall
        # and a column wide. Two things it must honour: a Button marks its click
        # handled before it bubbles, so the Details chip does not also toggle the
        # row it sits on; and IsEnabled does not block a PROGRAMMATIC set, so the
        # row has to test it or an already-back option ticks from a click on its
        # name.
        #
        # It also repaints the counts itself - the box is wired on Add_Click, which
        # does not fire for a programmatic set.
        $card.Add_MouseLeftButtonUp({
            if (-not $args[1].Handled -and $this.Tag.Box.IsEnabled) {
                $this.Tag.Box.IsChecked = -not [bool]$this.Tag.Box.IsChecked
                if ($this.Tag.After) { & $this.Tag.After }
            }
        }.GetNewClosure())
        $card.Tag = @{ Box = $cb; After = $null }

        [pscustomobject]@{
            Opt = $O; Card = $card; Check = $cb; Tag = $tagEl
            # The name line, and the two elements $paintCounts writes to. Handed
            # out rather than walked to: reaching the name as Card.Child.Children[0]
            # is a description of the layout rather than of the row, and the tick
            # box moving into a DockPanel outside the stack silently turned "the
            # first child" into the check box.
            Line = $line
            NameEl = $nm; Skip = $skip
            Detail = $hold; DetailText = $detText; Desc = $dsc; DescEl = $dscEl
            Cat = [string]$O.Cat; Name = [string]$O.Name
            Kinds = @($O.Kinds); Count = [int]$O.Count
            # Stamped by $applyOrder with the group this row is in under the
            # grouping now on screen. Declared here rather than added later: a
            # pscustomobject takes a new property only through Add-Member.
            GKey = ''
        }
    }.GetNewClosure()

    $made = 0
    foreach ($o in $opts) {
        $made++
        & $tell 'Building the list' "$made of $($opts.Count) - $($o.Name)"
        $rows.Add((& $makeRow $o $Ref $tag $col))
    }

    $ms.Rows = [int]$clock.ElapsedMilliseconds; $clock.Restart()

    # ------------------------------------------------- grouping and sort ----
    #
    # Two controls, not one, and every pairing of them means something - which
    # is why there is nothing to gray out. Group by decides what the page is
    # divided into; Sort by decides the order inside a division.
    $GROUPS = @(
        @{ Key = 'category'; Label = 'Category' }
        @{ Key = 'status';   Label = 'What is left' }
        @{ Key = 'kind';     Label = 'Kind of change' }
        @{ Key = 'alpha';    Label = 'Name (A-Z)' }
    )
    $SORTS = @(
        @{ Key = 'name';     Label = 'Name (A-Z)' }
        @{ Key = 'selected'; Label = 'Selected first' }
        @{ Key = 'most';     Label = 'Most changes first' }
    )
    $STATE_LABEL = @{ todo = 'Still in place'; unknown = 'Cannot tell from here'; done = 'Already back' }
    $STATE_RANK  = @{ todo = 0;                unknown = 1;                       done = 2 }
    # The Revert page's table, entry for entry - including 'Recurring effects',
    # which nothing here produces: this script reads one journal and that page
    # also lists what the toolkit left running. A rank for a kind that never
    # appears costs nothing and keeps the two tables comparable at a glance,
    # which a missing line does not.
    $KIND_RANK   = @{ 'Registry values' = 0; 'Services' = 1; 'Scheduled tasks' = 2
                      'Windows features' = 3; 'Files and folders' = 4; 'Power settings' = 5
                      'Installed programs' = 6; 'Recurring effects' = 7; 'Other' = 8 }

    $catOrder = @{}
    $catSeen = 0
    foreach ($r in $rows) { if (-not $catOrder.ContainsKey($r.Cat)) { $catOrder[$r.Cat] = $catSeen; $catSeen++ } }

    $alphaOf = {
        param([string]$Name)
        if (-not $Name.Length) { return @{ Key = 'zz'; Label = 'Other' } }
        $c = ([string]$Name.Substring(0, 1)).ToUpper()
        if ($c -notmatch '^[A-Z]$') { return @{ Key = 'zz'; Label = 'Other' } }
        foreach ($b in @(@('A','E'), @('F','J'), @('K','O'), @('P','T'), @('U','Z'))) {
            if ($c -ge $b[0] -and $c -le $b[1]) { return @{ Key = $b[0]; Label = "$($b[0]) - $($b[1])" } }
        }
        @{ Key = 'zz'; Label = 'Other' }
    }

    $groupsFor = {
        param([string]$Mode)
        $out   = New-Object System.Collections.Generic.List[psobject]
        $index = @{}
        $add = {
            param([string]$Key, [string]$Label, [int]$Rank, $Row)
            if (-not $index.ContainsKey($Key)) {
                $g = [pscustomobject]@{
                    Key = $Key; Label = $Label; Rank = $Rank
                    Members = (New-Object System.Collections.Generic.List[psobject])
                }
                $index[$Key] = $g
                $out.Add($g)
            }
            $index[$Key].Members.Add($Row)
        }
        foreach ($r in $rows) {
            switch ($Mode) {
                'status' { & $add $r.Opt.State $STATE_LABEL[$r.Opt.State] $STATE_RANK[$r.Opt.State] $r }
                'kind'   {
                    # An option can touch more than one kind, so it is filed
                    # under its first. Filing it under all of them would list
                    # the same tick twice and let somebody clear one copy.
                    $k = [string]@($r.Kinds)[0]
                    & $add $k $k ([int]$KIND_RANK[$k]) $r
                }
                'alpha'  { $a = & $alphaOf $r.Name; & $add $a.Key $a.Label 0 $r }
                default  { & $add $r.Cat $r.Cat ([int]$catOrder[$r.Cat]) $r }
            }
        }
        if ($Mode -eq 'alpha') { return ,@($out | Sort-Object @{ E = { $_.Key } }) }
        ,@($out | Sort-Object @{ E = { $_.Rank } }, @{ E = { $_.Label } })
    }.GetNewClosure()

    $sortMembers = {
        param($Members, [string]$Mode)
        switch ($Mode) {
            'selected' { ,@($Members | Sort-Object @{ E = { if ($_.Check.IsChecked) { 0 } else { 1 } } }, @{ E = { $_.Name } }) }
            'most'     { ,@($Members | Sort-Object @{ E = { -1 * $_.Count } }, @{ E = { $_.Name } }) }
            default    { ,@($Members | Sort-Object @{ E = { $_.Name } }) }
        }
    }

    # ------------------------------------------------------- the filter ----
    #
    # OR within a group and AND across groups, which is what makes "still in
    # place, registry or services" read the way people say it. An empty set
    # means that group imposes no constraint.
    $FILTER_GROUPS = @('State', 'View', 'Kind', 'Cat')
    $filterSel = @{}
    foreach ($fg in $FILTER_GROUPS) { $filterSel[$fg] = New-Object System.Collections.Generic.List[string] }
    $filterBoxes = New-Object System.Collections.Generic.List[psobject]
    # Selected only / Unselected only are a SNAPSHOT. A live query deletes the
    # row you just clicked out from under the pointer, which makes the list
    # unusable.
    $viewSnap = @{ Ids = $null }
    # The holder that breaks the cycle: a chip has to un-tick a box, drop the
    # facet and re-filter, and it is built by the filter pass it has to call.
    $fx = @{ Filter = $null; Pairs = $null }

    $blocks    = New-Object System.Collections.Generic.List[psobject]
    $railCards = New-Object System.Collections.Generic.List[psobject]
    $spy       = @{ Offsets = $null; On = '' }

    # On $state rather than in a local, because Refresh rebuilds the rows and
    # $paintCounts is a closure: a captured int keeps the number it was given for
    # the life of the window, and the footer would go on quoting a denominator
    # from before the machine was read again. Mutate, never assign - the same
    # rule every collection on this page follows.
    $state.Tickable = @($rows | Where-Object { $_.Check.IsEnabled }).Count

    # ------------------------------------------------------ the painters ---
    # Whatever the person just did shows immediately; the expensive consequence
    # catches up. Render priority rather than a DispatcherFrame: it flushes
    # layout and drawing and stops, so nothing at Input priority runs and a
    # second click cannot re-enter the handler that is still in the first.
    $showNow = { [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, 'Render') }

    # ONE PASS OVER THE ROWS, and that is the whole of why a tick used to take a
    # second to appear.
    #
    # This asked each of sixteen rail cards for its own members and each of
    # sixteen blocks again - the same hundred and twenty rows walked thirty-two
    # times - and then, for every ticked option, called Get-WDStepState on every
    # one of its changes. That last part is four hundred and thirty-five
    # registry reads, done inside a click handler, before the tick the person
    # just made could be drawn. The machine had already been read once at build
    # time and the answer had not moved: Pending is that answer, counted then.
    $paintCounts = {
        $on = @{}; $can = @{}; $free = @{}; $all = @{}
        $pickedCount = 0
        $chg = 0
        $pageLive = 0; $pageFree = 0
        foreach ($r in $rows) {
            $ticked = [bool]$r.Check.IsChecked
            if ($ticked) { $pickedCount++; $chg += [int]$r.Opt.Pending }

            # MARK WHAT WAS UNTICKED, in the pass that is already walking every
            # row. Two property sets, and only on the rows whose answer moved.
            #
            # The enabled test is what separates the two ways a box can be clear.
            # An already-back row is unticked and always was; it is not an edit,
            # and its name is Muted and struck through - which the reset branch
            # must not undo, so that branch is gated on the notice being up
            # rather than on the tick.
            if (-not $ticked -and $r.Check.IsEnabled) {
                & $Ref $r.NameEl 'Foreground' 'Bad'; $r.NameEl.FontWeight = 'Bold'
                $r.Skip.Visibility = 'Visible'
            } elseif ($r.Skip.Visibility -eq 'Visible') {
                & $Ref $r.NameEl 'Foreground' 'Text'; $r.NameEl.FontWeight = 'SemiBold'
                $r.Skip.Visibility = 'Collapsed'
            }

            if ($r.Check.IsEnabled -and $r.Card.Visibility -eq 'Visible') {
                $pageLive++
                if (-not $ticked) { $pageFree++ }
            }
            $k = [string]$r.GKey
            if (-not $k) { continue }
            if (-not $on.ContainsKey($k)) { $on[$k] = 0; $can[$k] = 0; $free[$k] = 0; $all[$k] = 0 }
            # Counted before the enabled test, because a group can be entirely
            # made of rows that refuse a tick and it still has that many rows in
            # it - see the rail loop below.
            $all[$k]++
            if (-not $r.Check.IsEnabled) { continue }
            $can[$k]++
            if ($ticked) { $on[$k]++ }
            elseif ($r.Card.Visibility -eq 'Visible') { $free[$k]++ }
        }
        foreach ($rc in $railCards) {
            $k = [string]$rc.Key
            $rcOn  = 0; if ($on.ContainsKey($k))  { $rcOn  = $on[$k] }
            $rcCan = 0; if ($can.ContainsKey($k)) { $rcCan = $can[$k] }
            $rcAll = 0; if ($all.ContainsKey($k)) { $rcAll = $all[$k] }
            # A FRACTION IS ABOUT WHAT IS LEFT TO DECIDE, and there are groups
            # here with nothing left to decide and plenty in them. Grouped by
            # What is left, "Already back" is every option this run has finished
            # with: none of them takes a tick, so the denominator was zero and
            # the card read 0/0 - which is what a group emptied by the search box
            # reads, and says nothing about a dozen options sitting under it.
            #
            # Three states, then, not two. A bare count in Ok for a group that is
            # settled, the fraction for one with decisions in it, and 0/0 only
            # when there is genuinely nothing there. Ok rather than Accent
            # because Accent is what this application paints things you can act
            # on, and a blue number on an inert card reads as "click me".
            if ($rcAll -gt 0 -and $rcCan -eq 0) {
                $rc.Num.Text = "$rcAll"
                & $Ref $rc.Num 'Foreground' 'Ok'
            } else {
                $rc.Num.Text = "$rcOn/$rcCan"
                if     ($rcCan -eq 0)     { & $Ref $rc.Num 'Foreground' 'Muted' }
                elseif ($rcOn -eq $rcCan) { & $Ref $rc.Num 'Foreground' 'Ok' }
                else                      { & $Ref $rc.Num 'Foreground' 'Accent' }
            }
            $rc.Card.Opacity = $(if ($rc.Live) { 1.0 } else { 0.45 })
        }
        foreach ($b in $blocks) {
            $k = [string]$b.Key
            $anyFree = $false; if ($free.ContainsKey($k)) { $anyFree = ($free[$k] -gt 0) }
            # A group with nothing to take reads "Select all" rather than
            # offering to clear a selection that is not there. It is disabled
            # either way; the label still has to be the true one.
            $b.SelAll.Content   = $(if ($anyFree -or -not $b.VisEnabled) { 'Select all' } else { 'Select none' })
            $b.SelAll.IsEnabled = [bool]$b.VisEnabled
        }
        # The page-wide twin of that button, on exactly the same rule and worded
        # the same way: it offers to select while anything selectable is
        # untouched, and to clear once nothing is. Counted over VISIBLE rows, so
        # it agrees with the filter rather than quietly reaching past it.
        $ui.BtnSelectAll.Content   = $(if ($pageFree -or -not $pageLive) { 'Select all' } else { 'Select none' })
        $ui.BtnSelectAll.IsEnabled = [bool]$pageLive
        $ui.Tally.Text = "$pickedCount of $($state.Tickable) options selected, $chg change(s) to put back."
        $ui.BtnGo.IsEnabled = [bool]$pickedCount
    }.GetNewClosure()

    # The rail's highlight follows the scroll. Offsets are measured once into a
    # table and thrown away by anything that moves a heading - a filter pass, a
    # re-order, a fold, a resize - because transforming every heading on every
    # scroll tick is how this ships janky.
    #
    # Never measured against a page that is not on screen: a collapsed element
    # has no layout, so every heading transforms to Y=0, and a table of zeros is
    # still a table.
    #
    # NOR AGAINST A PAGE THAT HAS JUST BEEN REBUILT AND NOT YET ARRANGED, which
    # is the same trap wearing a different hat and is what broke the rail every
    # time somebody changed Group by. $applyOrder tears the list down, builds new
    # blocks, and asks for a measurement in the same breath - so every one of
    # them transformed to Y=0, the table of zeros was cached, and the highlight
    # named the first entry for the rest of the session. UpdateLayout goes inside
    # the invalidation branch, so it is paid once per re-order rather than once
    # per scroll tick.
    $spyRun = {
        if (-not $blocks.Count) { return }
        if ($ui.ListPage.Visibility -ne 'Visible') { return }
        if ($ui.Scroll.ActualHeight -le 0) { return }
        if (-not $spy.Offsets) {
            $ui.Scroll.UpdateLayout()
            $t = @{}
            foreach ($b in $blocks) {
                try {
                    $p = $b.Block.TransformToAncestor($ui.Scroll.Content).Transform((New-Object Windows.Point 0, 0))
                    $t[$b.Key] = [double]$p.Y
                } catch { $t[$b.Key] = 0.0 }
            }
            $spy.Offsets = $t
        }
        $y = [double]$ui.Scroll.VerticalOffset + 12
        $best = ''
        foreach ($b in $blocks) {
            if ($b.Block.Visibility -ne 'Visible') { continue }
            if ($spy.Offsets[$b.Key] -le $y) { $best = $b.Key }
        }
        if (-not $best) {
            foreach ($b in $blocks) { if ($b.Block.Visibility -eq 'Visible') { $best = $b.Key; break } }
        }
        if ($best -eq $spy.On) { return }
        $spy.On = $best
        foreach ($rc in $railCards) {
            $lit = ($rc.Key -eq $best)
            $rc.Lit = $lit
            & $Ref $rc.Card 'Background' $(if ($lit) { 'CardSel' } else { 'Flat' })
            & $Ref $rc.Label 'Foreground' $(if ($lit) { 'Text' } else { 'Sub' })
        }
    }.GetNewClosure()

    # What is actually narrowing the list, and the one thing the button could
    # never say: "Filter (3)" tells you how many, never which. Everything the
    # handler needs travels on the Tag, because a closure built inside another
    # closure captures that closure's LOCALS and nothing it was handed.
    $chipFor = {
        param([string]$Group, [string]$Value, [string]$Text, $Ctx)
        $b = New-Object Windows.Controls.Border
        $b.CornerRadius = 9; $b.Padding = '9,1,8,2'; $b.Margin = '0,0,6,0'
        $b.BorderThickness = New-Object Windows.Thickness 1
        & $Ref $b 'BorderBrush' 'Line'
        & $Ref $b 'Background' 'Card'
        $b.Cursor = 'Hand'
        $b.ToolTip = 'Drop this filter'
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = "$Text  x"; $t.FontSize = 11.5
        & $Ref $t 'Foreground' 'Sub'
        $b.Child = $t
        $b.Tag = @{ G = $Group; V = $Value; Ctx = $Ctx }
        $b.Add_MouseLeftButtonUp({
            $t2 = $this.Tag
            $c  = $t2.Ctx
            foreach ($fb in $c.Boxes) {
                if ($fb.Group -eq $t2.G -and $fb.Value -eq $t2.V) { $fb.Box.IsChecked = $false }
            }
            $null = $c.Sel[$t2.G].Remove($t2.V)
            if ($t2.G -eq 'View' -and -not $c.Sel['View'].Count) { $c.Snap.Ids = $null }
            if ($c.Fx.Pairs)  { & $c.Fx.Pairs }
            if ($c.Fx.Filter) { & $c.Fx.Filter }
        }.GetNewClosure())
        $b
    }.GetNewClosure()

    $chipCtx = @{ Boxes = $filterBoxes; Sel = $filterSel; Snap = $viewSnap; Fx = $fx }

    # Two columns inside a full-width block, exactly as the Advanced page lays a
    # category out, and re-filled with what is VISIBLE rather than with
    # everything. Filling with everything and hiding half of it is how a search
    # ends up with six rows down the left and an empty column beside them.
    #
    # Below four rows it stays one column and the right half gives its width
    # back, gutter included: two columns of one row apiece is not a layout, and
    # a lot of these groups are that size.
    $fillBlock = {
        param($B, $Members)
        $B.ColL.Children.Clear()
        $B.ColR.Children.Clear()
        $list = @($Members)
        $one = ($list.Count -lt 4)
        $gap  = $(if ($one) { 0 } else { 30 })
        $B.Grid.ColumnDefinitions[1].Width = New-Object System.Windows.GridLength -ArgumentList $gap, ([System.Windows.GridUnitType]::Pixel)
        if ($one) {
            $B.Grid.ColumnDefinitions[2].Width = New-Object System.Windows.GridLength -ArgumentList 0, ([System.Windows.GridUnitType]::Pixel)
        } else {
            $B.Grid.ColumnDefinitions[2].Width = New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)
        }
        $half = [Math]::Ceiling($list.Count / 2)
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ($one -or $i -lt $half) { $null = $B.ColL.Children.Add($list[$i].Card) }
            else                       { $null = $B.ColR.Children.Add($list[$i].Card) }
        }
        $B.VisEnabled = @($list | Where-Object { $_.Check.IsEnabled }).Count
    }

    $applyFilter = {
        $needle = ([string]$ui.Find.Text).Trim()
        foreach ($r in $rows) {
            $ok = $true
            if ($ok -and $filterSel['State'].Count) { $ok = $filterSel['State'].Contains([string]$r.Opt.State) }
            if ($ok -and $filterSel['Cat'].Count)   { $ok = $filterSel['Cat'].Contains([string]$r.Cat) }
            if ($ok -and $filterSel['Kind'].Count) {
                $hit = $false
                foreach ($k in $r.Kinds) { if ($filterSel['Kind'].Contains([string]$k)) { $hit = $true } }
                $ok = $hit
            }
            if ($ok -and $filterSel['View'].Count) {
                $was = $false
                if ($viewSnap.Ids) { $was = $viewSnap.Ids.Contains([string]$r.Opt.Id) }
                $hit = $false
                if ($filterSel['View'].Contains('ticked')   -and $was)        { $hit = $true }
                if ($filterSel['View'].Contains('unticked') -and (-not $was)) { $hit = $true }
                $ok = $hit
            }
            if ($ok -and $needle) {
                $ok = ($r.Name -like "*$needle*") -or ($r.Cat -like "*$needle*") -or
                      ($r.Desc -like "*$needle*") -or ($r.DetailText -like "*$needle*")
            }
            $r.Card.Visibility = $(if ($ok) { 'Visible' } else { 'Collapsed' })
        }
        # One pass for the per-group tallies rather than one per block and again
        # per rail card, for the reason written above $paintCounts.
        $visBy = @{}
        $shown = 0
        foreach ($r in $rows) {
            if ($r.Card.Visibility -ne 'Visible') { continue }
            $shown++
            $k = [string]$r.GKey
            if (-not $k) { continue }
            if (-not $visBy.ContainsKey($k)) { $visBy[$k] = 0 }
            $visBy[$k]++
        }
        foreach ($b in $blocks) {
            $n = 0; if ($visBy.ContainsKey([string]$b.Key)) { $n = $visBy[[string]$b.Key] }
            $b.Block.Visibility = $(if ($n) { 'Visible' } else { 'Collapsed' })
            & $fillBlock $b @($b.Ordered | Where-Object { $_.Card.Visibility -eq 'Visible' })
        }
        # A rail entry the filter has emptied is dimmed, never removed: a rail
        # whose entries come and go as you type reads as broken, and the thing
        # you were about to click moving out from under the pointer is worse
        # than a dim label.
        foreach ($rc in $railCards) {
            $rc.Live = [bool]($visBy.ContainsKey([string]$rc.Key) -and $visBy[[string]$rc.Key])
        }
        $ui.TxtCount.Text = $(if ($shown -eq $rows.Count) { "$($rows.Count) options" } else { "$shown of $($rows.Count) options" })

        $ui.FilterChips.Children.Clear()
        $facets = 0
        foreach ($fg in $FILTER_GROUPS) {
            foreach ($v in @($filterSel[$fg])) {
                $facets++
                $lbl = $v
                if ($fg -eq 'State') { $lbl = $STATE_LABEL[$v] }
                if ($fg -eq 'View')  { $lbl = $(if ($v -eq 'ticked') { 'Selected only' } else { 'Unselected only' }) }
                $null = $ui.FilterChips.Children.Add((& $chipFor $fg $v $lbl $chipCtx))
            }
        }
        $ui.FilterChips.Visibility = $(if ($facets) { 'Visible' } else { 'Collapsed' })
        $ui.BtnFilter.Content = $(if ($facets) { "Filter ($facets)" } else { 'Filter' })

        & $paintCounts
        $spy.Offsets = $null
        $spy.On = ''
        & $spyRun
    }.GetNewClosure()
    $fx.Filter = $applyFilter

    # Folding one group open or shut. Shared, because Collapse all has to do
    # exactly the same thing to every one of them and a second copy of "what
    # collapsed looks like" is how the sign and the visibility come to disagree.
    # Folding shuts the Details panels underneath it; unfolding deliberately does
    # not open them. Collapse all means "put this away and let me see the shape
    # of it", and a group that comes back with six paragraphs standing open has
    # not been put away - while an expansion is something somebody opened on
    # purpose, one row at a time.
    $setGroupOpen = {
        param($Body, $Btn, [bool]$Open, $GroupRows)
        $Body.Visibility = $(if ($Open) { 'Visible' } else { 'Collapsed' })
        $Btn.Content = $(if ($Open) { '-' } else { '+' })
        $Btn.ToolTip = $(if ($Open) { 'Collapse this group' } else { 'Expand this group' })
        if (-not $Open -and $GroupRows) {
            foreach ($r in @($GroupRows)) {
                if ($r.Detail -and $r.Detail.Det) { $r.Detail.Det.Visibility = 'Collapsed' }
            }
        }
    }

    $applyOrder = {
        # A child of a panel cannot be added to another one - WPF refuses the
        # reparent with "already the logical child of another element" - and
        # Children.Clear() on the list does not touch what its blocks are
        # holding, so every card is detached explicitly first.
        foreach ($r in $rows) {
            if ($r.Card.Parent -is [Windows.Controls.Panel]) { $r.Card.Parent.Children.Remove($r.Card) }
        }
        $ui.List.Children.Clear()
        $ui.Rail.Children.Clear()
        $blocks.Clear()
        $railCards.Clear()

        foreach ($g in (& $groupsFor $state.Group)) {
            $block = New-Object Windows.Controls.StackPanel
            $block.Margin = '0,0,0,10'

            # A name then some buttons is a WrapPanel, for the same reason a row
            # is: a horizontal StackPanel measures with infinite width and draws
            # the last button off the edge.
            $hp = New-Object Windows.Controls.WrapPanel
            # 16 SemiBold over '0,18,0,6', which is what a category heading on
            # the toolkit's Advanced page is. This was 15 over '0,12,0,6'.
            $hp.Margin = '0,18,0,6'
            $ht = New-Object Windows.Controls.TextBlock
            $ht.Text = [string]$g.Label; $ht.FontSize = 16; $ht.FontWeight = 'SemiBold'
            $ht.VerticalAlignment = 'Center'; $ht.TextWrapping = 'Wrap'
            & $Ref $ht 'Foreground' 'Text'
            $null = $hp.Children.Add($ht)

            # Two columns and a gutter, filled by $fillBlock. The block itself
            # stays full width and the blocks stack straight down, which is what
            # keeps the page's order, the group order, and the rail's order the
            # same list.
            $body = New-Object Windows.Controls.Grid
            foreach ($w in @((New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)),
                             (New-Object System.Windows.GridLength -ArgumentList 30, ([System.Windows.GridUnitType]::Pixel)),
                             (New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)))) {
                $cd = New-Object Windows.Controls.ColumnDefinition
                $cd.Width = $w
                $body.ColumnDefinitions.Add($cd)
            }
            $colL = New-Object Windows.Controls.StackPanel
            $colR = New-Object Windows.Controls.StackPanel
            [Windows.Controls.Grid]::SetColumn($colL, 0)
            [Windows.Controls.Grid]::SetColumn($colR, 2)
            $null = $body.Children.Add($colL)
            $null = $body.Children.Add($colR)

            # The heading itself is inert. With a collapse control on the same
            # line, clicking the name of a group is as likely to mean "fold this
            # away" as "take all of it", and a target whose meaning has to be
            # guessed is worse than two controls that each say what they do.
            $tg = New-Object Windows.Controls.Button
            $tg.Content = '-'; $tg.Width = 24; $tg.Padding = '0,1'; $tg.FontSize = 13
            $tg.FontWeight = 'Bold'; $tg.Margin = '10,0,0,0'; $tg.VerticalAlignment = 'Center'
            $tg.ToolTip = 'Collapse this group'
            $tg.Tag = @{ Body = $body; Set = $setGroupOpen; Spy = $spy; Run = $spyRun }
            $tg.Add_Click({
                $t = $this.Tag
                & $t.Set $t.Body $this (-not ($t.Body.Visibility -eq 'Visible')) $t.Rows
                # Folding moves every heading below it, so the measured offsets
                # are stale for exactly the reason a filter pass makes them stale.
                $t.Spy.Offsets = $null
                $t.Spy.On = ''
                & $t.Run
            }.GetNewClosure())
            $null = $hp.Children.Add($tg)

            # Takes the whole group and takes it back, acting on what is VISIBLE
            # so it respects the filter rather than quietly selecting rows that
            # are not on screen.
            $sa = New-Object Windows.Controls.Button
            $sa.Content = 'Select all'; $sa.FontSize = 11.5; $sa.Padding = '8,2'
            $sa.Margin = '8,0,0,0'; $sa.VerticalAlignment = 'Center'; $sa.MinWidth = 84
            $sa.ToolTip = 'Selects every option in this group that is on screen and can be reverted. Press again to clear them.'
            $sa.Tag = @{ Members = $g.Members; Paint = $paintCounts; Show = $showNow }
            $sa.Add_Click({
                $t = $this.Tag
                $vis = @($t.Members | Where-Object { $_.Card.Visibility -eq 'Visible' -and $_.Check.IsEnabled })
                if (-not $vis.Count) { return }
                $want = @($vis | Where-Object { -not $_.Check.IsChecked }).Count -gt 0
                foreach ($r in $vis) { $r.Check.IsChecked = $want }
                # The ticks are what the person asked for; the counts under them
                # are the consequence. Draw the first before doing the second.
                & $t.Show
                & $t.Paint
            }.GetNewClosure())
            $null = $hp.Children.Add($sa)
            $null = $block.Children.Add($hp)

            $rule = New-Object Windows.Controls.Border
            $rule.Height = 1; $rule.Margin = '0,0,0,4'; $rule.Opacity = 0.55
            & $Ref $rule 'Background' 'Line'
            $null = $block.Children.Add($rule)

            $null = $block.Children.Add($body)
            $null = $ui.List.Children.Add($block)
            # Plain assignment, never @(...). $sortMembers ends in ,@(...) so
            # that a caller who assigns gets the array rather than its elements
            # one at a time - and wrapping that in @() gives a one-element array
            # holding the whole list, which then reads as a single row with no
            # properties on it. The same comma this repo has been bitten by from
            # both ends.
            $sorted = & $sortMembers $g.Members $state.Sort
            $rec = [pscustomobject]@{
                Key = $g.Key; Group = $g; Block = $block; Body = $body
                Grid = $body; ColL = $colL; ColR = $colR
                Ordered = $sorted
                VisEnabled = 0; Toggle = $tg; SelAll = $sa
            }
            # Which group a row is in under THIS grouping, stamped on the row so
            # every count is one pass over the rows rather than one pass per
            # block and another per rail card.
            foreach ($m in $rec.Ordered) { $m.GKey = [string]$g.Key }
            # No fill here. $applyFilter runs at the foot of this function and
            # fills every block with what is visible, so doing it now as well is
            # a second re-parent of every card on the page for nothing.
            # After $sorted exists, not where the button was built: folding has
            # to reach this group's rows to shut their Details panels.
            $tg.Tag.Rows = $sorted
            $blocks.Add($rec)

            # ---- the rail -------------------------------------------------
            #
            # An index INTO the list, never a router. Clicking scrolls; the
            # highlight follows the scroll. What it buys is the two things a
            # long page lacks: somewhere to jump to, and a sense that the work
            # in front of somebody is finite - which is what the counts are for.
            $c = New-Object Windows.Controls.Border
            $c.CornerRadius = 3; $c.Padding = '8,4,8,5'; $c.Margin = '0,0,0,2'; $c.Cursor = 'Hand'
            & $Ref $c 'Background' 'Flat'
            $dp = New-Object Windows.Controls.DockPanel
            $num = New-Object Windows.Controls.TextBlock
            $num.FontSize = 11.5; $num.Margin = '6,0,0,0'
            & $Ref $num 'Foreground' 'Accent'
            [Windows.Controls.DockPanel]::SetDock($num, 'Right')
            $null = $dp.Children.Add($num)
            $lbl = New-Object Windows.Controls.TextBlock
            $lbl.Text = [string]$g.Label; $lbl.FontSize = 12.5; $lbl.TextTrimming = 'CharacterEllipsis'
            & $Ref $lbl 'Foreground' 'Sub'
            $null = $dp.Children.Add($lbl)
            $c.Child = $dp
            $null = $ui.Rail.Children.Add($c)
            $entry = [pscustomobject]@{ Key = $g.Key; Group = $g; Card = $c; Num = $num; Label = $lbl
                                        Block = $block; Live = $true; Lit = $false }
            $railCards.Add($entry)

            $refL = $Ref
            $scr  = $ui.Scroll
            $blk  = $block
            $ent  = $entry
            $c.Add_MouseLeftButtonUp({
                try {
                    $p = $blk.TransformToAncestor($scr.Content).Transform((New-Object Windows.Point 0, 0))
                    $scr.ScrollToVerticalOffset($p.Y)
                } catch { }
            }.GetNewClosure())
            # The highlighted card keeps its highlight rather than dimming to a
            # hover tint as the pointer crosses it.
            $c.Add_MouseEnter({ if (-not $ent.Lit) { & $refL $ent.Card 'Background' 'RowHover' } }.GetNewClosure())
            $c.Add_MouseLeave({ if (-not $ent.Lit) { & $refL $ent.Card 'Background' 'Flat' } }.GetNewClosure())
        }

        # Back to the top. The old offset was a position in an arrangement that
        # no longer exists, and leaving it there drops somebody into the middle
        # of a page they have not seen the top of.
        $ui.Scroll.ScrollToVerticalOffset(0)
        $spy.Offsets = $null
        $spy.On = ''
        & $applyFilter
    }.GetNewClosure()

    # ------------------------------------------------- the filter panel ----
    $addFilterSection = {
        param([string]$Group, [string]$Heading, $Entries)
        if (-not @($Entries).Count) { return }
        $h = New-Object Windows.Controls.TextBlock
        $h.Text = $Heading.ToUpper(); $h.FontSize = 11; $h.FontWeight = 'SemiBold'
        $h.Margin = '0,10,0,4'
        & $Ref $h 'Foreground' 'Muted'
        $null = $ui.FilterPanel.Children.Add($h)
        foreach ($e in @($Entries)) {
            $box = New-Object Windows.Controls.CheckBox
            $box.Content = $e.Label; $box.FontSize = 12.5; $box.Margin = '0,2,0,2'
            # WPF's default CheckBox foreground is the system control-text brush,
            # which is BLACK whatever the Windows theme says - so a box with no
            # Foreground of its own is an invisible label on the dark palette and
            # a mismatched one on the light. There is no implicit CheckBox style
            # in this window; every box paints itself, which is what the Revert
            # page's filter does. This is the exact defect that once shipped
            # "Selected first" unreadable on the Advanced toolbar.
            & $Ref $box 'Foreground' 'Text'
            $box.Tag = @{ G = $Group; V = [string]$e.Key; Sel = $filterSel; Fx = $fx
                          Snap = $viewSnap; Rows = $rows }
            $box.Add_Click({
                $t = $this.Tag
                if ($this.IsChecked) {
                    if (-not $t.Sel[$t.G].Contains($t.V)) { $t.Sel[$t.G].Add($t.V) }
                    if ($t.G -eq 'View') {
                        $ids = New-Object System.Collections.Generic.List[string]
                        foreach ($r in $t.Rows) { if ($r.Check.IsChecked) { $ids.Add([string]$r.Opt.Id) } }
                        $t.Snap.Ids = $ids
                    }
                } else {
                    $null = $t.Sel[$t.G].Remove($t.V)
                    if ($t.G -eq 'View' -and -not $t.Sel['View'].Count) { $t.Snap.Ids = $null }
                }
                if ($t.Fx.Pairs)  { & $t.Fx.Pairs }
                if ($t.Fx.Filter) { & $t.Fx.Filter }
            }.GetNewClosure())
            $null = $ui.FilterPanel.Children.Add($box)
            $filterBoxes.Add([pscustomobject]@{ Group = $Group; Value = [string]$e.Key; Box = $box })
        }
    }.GetNewClosure()

    # A BLOCK RATHER THAN FOUR CALLS IN LINE, because Refresh has to build this
    # again: What is left is derived from the rows, and a machine somebody has
    # been putting things back on by hand can lose a whole band of it. Panel and
    # box list are emptied here rather than by the caller, so the two cannot get
    # out of step - a stale entry in $filterBoxes is a box the Clear all button
    # would try to untick after it had been thrown away.
    $buildFilterPanel = {
        $ui.FilterPanel.Children.Clear()
        $filterBoxes.Clear()
        $stateEntries = New-Object System.Collections.Generic.List[psobject]
        foreach ($k in @('todo', 'unknown', 'done')) {
            if (@($rows | Where-Object { $_.Opt.State -eq $k }).Count) {
                $stateEntries.Add([pscustomobject]@{ Key = $k; Label = $STATE_LABEL[$k] })
            }
        }
        & $addFilterSection 'State' 'What is left' $stateEntries
        & $addFilterSection 'View' 'View' @(
            [pscustomobject]@{ Key = 'ticked';   Label = 'Selected only' }
            [pscustomobject]@{ Key = 'unticked'; Label = 'Unselected only' }
        )
        $kindEntries = New-Object System.Collections.Generic.List[psobject]
        foreach ($k in (@($rows | ForEach-Object { $_.Kinds } | Select-Object -Unique) | Sort-Object @{ E = { [int]$KIND_RANK[$_] } })) {
            $kindEntries.Add([pscustomobject]@{ Key = [string]$k; Label = [string]$k })
        }
        & $addFilterSection 'Kind' 'Kind of change' $kindEntries
        $catEntries = New-Object System.Collections.Generic.List[psobject]
        foreach ($k in (@($rows | ForEach-Object { $_.Cat } | Select-Object -Unique) | Sort-Object @{ E = { [int]$catOrder[$_] } })) {
            $catEntries.Add([pscustomobject]@{ Key = [string]$k; Label = [string]$k })
        }
        & $addFilterSection 'Cat' 'Category' $catEntries
    }.GetNewClosure()
    & $buildFilterPanel

    # Selected only and Unselected only together are every row, which is what no
    # filter already says; whichever is ticked disables the other rather than
    # being quietly ignored.
    $syncPairs = {
        $a = $null; $b = $null
        foreach ($fb in $filterBoxes) {
            if ($fb.Group -eq 'View' -and $fb.Value -eq 'ticked')   { $a = $fb.Box }
            if ($fb.Group -eq 'View' -and $fb.Value -eq 'unticked') { $b = $fb.Box }
        }
        if ($a -and $b) {
            $a.IsEnabled = -not [bool]$b.IsChecked
            $b.IsEnabled = -not [bool]$a.IsChecked
        }
    }.GetNewClosure()
    $fx.Pairs = $syncPairs

    # ----------------------------------------------------- the handlers ----
    foreach ($g in $GROUPS) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = $g.Label; $it.Tag = $g.Key
        $null = $ui.CmbOrder.Items.Add($it)
        if ($g.Key -eq $state.Group) { $ui.CmbOrder.SelectedItem = $it }
    }
    foreach ($s in $SORTS) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = $s.Label; $it.Tag = $s.Key
        $null = $ui.CmbSort.Items.Add($it)
        if ($s.Key -eq $state.Sort) { $ui.CmbSort.SelectedItem = $it }
    }

    $ui.CmbOrder.Add_SelectionChanged({
        if ($state.Booting) { return }
        if (-not $ui.CmbOrder.SelectedItem) { return }
        $state.Group = [string]$ui.CmbOrder.SelectedItem.Tag
        & $applyOrder
    }.GetNewClosure())
    $ui.CmbSort.Add_SelectionChanged({
        if ($state.Booting) { return }
        if (-not $ui.CmbSort.SelectedItem) { return }
        $state.Sort = [string]$ui.CmbSort.SelectedItem.Tag
        & $applyOrder
    }.GetNewClosure())

    # The tick is what the person asked for and the counts are the consequence,
    # so the tick is drawn first. $paintCounts is two passes over the rows now
    # rather than thirty-two plus four hundred registry reads, but the order is
    # the rule whatever the cost: whatever was just done shows immediately.
    # One block, handed to the box and to the row it sits on, so a click anywhere
    # does the whole gesture rather than half of it. Add_Click does not fire for
    # a programmatic set, which is why the row has to run this itself.
    $afterTick = { & $showNow; & $paintCounts }.GetNewClosure()
    foreach ($r in $rows) {
        $r.Check.Add_Click($afterTick)
        if ($r.Card.Tag) { $r.Card.Tag.After = $afterTick }
    }

    # The whole page at once, and the same rule the per-group button follows:
    # visible rows only, so a search narrowing the page narrows what this takes,
    # and one press either way rather than a pair of buttons of which exactly one
    # is ever the useful one.
    $ui.BtnSelectAll.Add_Click({
        $vis = @($rows | Where-Object { $_.Card.Visibility -eq 'Visible' -and $_.Check.IsEnabled })
        if (-not $vis.Count) { return }
        $want = @($vis | Where-Object { -not $_.Check.IsChecked }).Count -gt 0
        foreach ($r in $vis) { $r.Check.IsChecked = $want }
        # The ticks are what the person asked for; the counts under them are the
        # consequence. Draw the first before doing the second.
        & $showNow
        & $paintCounts
    }.GetNewClosure())

    $ui.BtnCollapseAll.Add_Click({
        foreach ($b in $blocks) { & $setGroupOpen $b.Body $b.Toggle $false $b.Ordered }
        $spy.Offsets = $null; $spy.On = ''
        & $spyRun
    }.GetNewClosure())

    # ---- Non-verbose ------------------------------------------------------
    #
    # Off as shipped: the standing description is the same on every visit, and
    # Details still carries the whole of it for the one option being asked about.
    # COLLAPSED, NOT SKIPPED, so turning it back on needs no rebuild.
    #
    # A CLOSURE, NOT A BARE BLOCK. A bare block resolves against whatever scope
    # invokes it, which is fine from a WPF handler - this function is still on the
    # stack in ShowDialog. -BuildOnly reaches it after the frame is gone, where it
    # sees no $rows and no $state, sets nothing, and REPORTS NO ERROR.
    $applyTerse = {
        $vis = $(if ($state.Terse) { 'Collapsed' } else { 'Visible' })
        foreach ($r in $rows) {
            if ($r.DescEl) { $r.DescEl.Visibility = $vis }
        }
    }.GetNewClosure()
    $ui.BtnVerbose.IsChecked = (-not $state.Terse)
    $ui.BtnVerbose.Add_Click({
        $state.Terse = -not [bool]$this.IsChecked
        & $applyTerse
        # A description appearing or going takes every card below it with it, so
        # the measured heading offsets describe a page that no longer exists.
        $spy.Offsets = $null
        & $spyRun
    }.GetNewClosure())
    $ui.BtnExpandAll.Add_Click({
        foreach ($b in $blocks) { & $setGroupOpen $b.Body $b.Toggle $true }
        $spy.Offsets = $null; $spy.On = ''
        & $spyRun
    }.GetNewClosure())

    $ui.BtnFilterClear.Add_Click({
        foreach ($fb in $filterBoxes) { $fb.Box.IsChecked = $false; $fb.Box.IsEnabled = $true }
        foreach ($fg in $FILTER_GROUPS) { $filterSel[$fg].Clear() }
        $viewSnap.Ids = $null
        & $applyFilter
    }.GetNewClosure())
    $ui.BtnFilterDone.Add_Click({ $ui.BtnFilter.IsChecked = $false }.GetNewClosure())

    # A TextChanged handler runs synchronously inside the input event, so a pass
    # over every row is time during which the character just typed is not on
    # screen and the next keystroke is queued behind it. Restart, not start, so
    # the pass runs once at the end rather than once per letter.
    $findTimer = New-Object Windows.Threading.DispatcherTimer
    $findTimer.Interval = [TimeSpan]::FromMilliseconds(180)
    $findTimer.Add_Tick({ $findTimer.Stop(); & $applyFilter }.GetNewClosure())
    $ui.Find.Add_TextChanged({ $findTimer.Stop(); $findTimer.Start() }.GetNewClosure())

    $ui.Scroll.Add_ScrollChanged({ & $spyRun }.GetNewClosure())
    # A narrower list re-wraps every card, so the measured offsets go with it.
    # This handler changes no layout of its own, which is what keeps it from
    # feeding itself.
    $ui.ListPage.Add_SizeChanged({ $spy.Offsets = $null; & $spyRun }.GetNewClosure())

    $ui.BtnTheme.Add_Click({
        & $applyTheme $(if ($palBox.Key -eq 'dark') { 'light' } else { 'dark' })
    }.GetNewClosure())
    $ui.BtnClose.Add_Click({ $win.Close() }.GetNewClosure())

    # ---- Refresh ----------------------------------------------------------
    #
    # The page is a READING of the machine taken when the window opened, and
    # somebody may have put something back since - in regedit, or with the toolkit
    # open beside this.
    #
    # A REBUILD, not a repaint: an option's state decides whether its box takes a
    # tick, whether its name is struck through, whether the row answers the
    # pointer, and which band it is filed under. Repainting that in place would
    # mean unwiring hover handlers, which WPF does not offer.
    #
    # The ticks cannot survive it - a rebuild makes new boxes - which is why the
    # tooltip says so rather than only that it refreshes.
    $ui.BtnRefresh.Add_Click({
        # Paint first. The read is seconds of a blocked UI thread, so the button
        # goes dead and the line above says what is happening before any of it
        # starts - a control that does not move reads as a click that missed.
        $ui.BtnRefresh.IsEnabled = $false
        $ui.Sub1.Text = 'Reading this machine again...'
        & $showNow
        try {
            $wasRows = $rows.Count
            $wasTodo = @($rows | Where-Object { $_.Opt.State -eq 'todo' }).Count
            $wasPend = 0
            foreach ($r in $rows) { $wasPend += [int]$r.Opt.Pending }

            # The machine, rather than what it looked like when this opened.
            # Get-WDRegNow keeps every key it has read for the life of the
            # process and Get-WDFeatureState keeps the whole feature table, so
            # without this the answer could not move.
            $global:WDRegCache.Clear()
            $global:WDFeatures   = $null
            $global:WDFeatureJob = $null

            foreach ($o in $opts) {
                $o.Todo = 0; $o.Done = 0; $o.Unknown = 0
                foreach ($s in $o.Steps) {
                    switch (Get-WDStepState $s) {
                        'todo'  { $o.Todo++ }
                        'done'  { $o.Done++ }
                        default { $o.Unknown++ }
                    }
                }
                if ($o.Todo)        { $o.State = 'todo' }
                elseif ($o.Unknown) { $o.State = 'unknown' }
                else                { $o.State = 'done' }
                $o.Pending = $o.Todo + $o.Unknown
            }

            # MUTATE, NEVER ASSIGN. Every closure on this page captured these
            # collections; a fresh assignment would leave all of them reading the
            # old one for ever.
            $rows.Clear()
            foreach ($o in $opts) { $rows.Add((& $makeRow $o $Ref $tag $col)) }
            foreach ($r in $rows) {
                $r.Check.Add_Click($afterTick)
                if ($r.Card.Tag) { $r.Card.Tag.After = $afterTick }
            }
            $state.Tickable = @($rows | Where-Object { $_.Check.IsEnabled }).Count

            # The panel too, since What is left is derived from the rows and a
            # band can empty entirely. Every facet is cleared with it: keeping a
            # selection whose box has just been thrown away and rebuilt unticked
            # is exactly the kind of disagreement between a control and its state
            # that this page is careful not to have.
            foreach ($fg in $FILTER_GROUPS) { $filterSel[$fg].Clear() }
            $viewSnap.Ids = $null
            & $buildFilterPanel
            $ui.Find.Text = ''

            $spy.Offsets = $null; $spy.On = ''
            & $applyOrder

            $nowTodo = @($rows | Where-Object { $_.Opt.State -eq 'todo' }).Count
            $nowPend = 0
            foreach ($r in $rows) { $nowPend += [int]$r.Opt.Pending }
            # Said, rather than left for somebody to spot. A Refresh that changed
            # nothing looks exactly like one that did not run.
            $moved = ''
            if ($wasRows -eq $rows.Count -and $wasTodo -eq $nowTodo -and $wasPend -eq $nowPend) {
                $moved = 'Read again just now - nothing has changed since this window opened.'
            } else {
                $moved = "Read again just now: still in place $wasTodo to $nowTodo option(s), $wasPend to $nowPend change(s)."
            }
            & $saySummary $moved
        } finally {
            $ui.BtnRefresh.IsEnabled = $true
        }
    }.GetNewClosure())

    # ------------------------------------------------------------- go ------
    $done = @{ Ran = $false; Failed = 0 }
    $ui.BtnGo.Add_Click({
        $picked = @($rows | Where-Object { $_.Check.IsChecked })
        if (-not $picked.Count) { return }
        $steps = New-Object System.Collections.Generic.List[psobject]
        foreach ($p in $picked) { foreach ($s in $p.Opt.Steps) { $steps.Add($s) } }

        $ui.ListPage.Visibility = 'Collapsed'
        $ui.Bar.Visibility = 'Collapsed'
        $ui.RunPage.Visibility = 'Visible'
        $ui.BtnGo.IsEnabled = $false
        $ui.Head.Text = 'Putting it back'
        $ui.Sub1.Text = "$($steps.Count) change(s) from $($picked.Count) option(s)."
        $ui.Sub2.Text = 'Windows features can take a minute each, and the window does not answer while one is running.'
        $ui.RunNote.Text = ''

        $pump = { [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, 'Render') }
        $say = {
            param($L)
            $t = New-Object Windows.Controls.TextBlock
            $t.Text = $L.Text; $t.FontSize = 12.5; $t.TextWrapping = 'Wrap'; $t.Margin = '0,0,0,2'
            & $Ref $t 'Foreground' $(switch ($L.Level) { 'ok' { 'Ok' } 'bad' { 'Bad' } default { 'Muted' } })
            $null = $ui.Log.Children.Add($t)
            $ui.LogScroll.ScrollToEnd()
            $ui.Tally.Text = "$($L.Index) of $($steps.Count)..."
            & $pump
        }.GetNewClosure()

        $r = Invoke-WDUndo -Steps $steps -Say $say
        $done.Ran = $true
        $done.Failed = $r.Failed

        $ui.Head.Text = 'Finished'
        $ui.Sub1.Text = "$($r.Restored) change(s) put back, $($r.Already) were already back, $($r.Failed) could not be done."
        $ui.Sub2.Text = 'A restart is recommended.'
        $ui.Tally.Text = ''
        $note = New-Object System.Collections.Generic.List[string]
        if ($global:WDReinstall.Count) {
            $note.Add("$($global:WDReinstall.Count) program(s) were uninstalled by that run and nothing can put those back automatically: " + (($global:WDReinstall | Select-Object -First 12) -join ', ') + $(if ($global:WDReinstall.Count -gt 12) { ', and more.' } else { '.' }))
        }
        if ($global:WDOwners.Count) {
            $note.Add("$($global:WDOwners.Count) registry key(s) had their owner changed to Administrators. Restoring an owner needs takeown or icacls and is not done here.")
        }
        $ui.RunNote.Text = ($note -join ' ')
        $ui.BtnClose.Content = 'Close'
    }.GetNewClosure())

    $state.Booting = $false
    & $tell 'Arranging the page' "$($rows.Count) options"
    & $applyOrder
    $ms.Layout = [int]$clock.ElapsedMilliseconds

    # The seam. ShowDialog blocks the dispatcher with nobody to dismiss it, so
    # the only thing a headless check can ask is whether the page assembles and
    # what it says - which is exactly the half that can be wrong while every
    # structural check passes. It also means the window is never drawn over
    # whatever somebody is doing in order to test it.
    if ($BuildOnly) {
        Close-WDHives
        return [pscustomobject]@{
            Options   = @($rows).Count
            Groups    = @($blocks).Count
            Rail      = @($railCards).Count
            Ticked    = @($rows | Where-Object { $_.Check.IsChecked }).Count
            Locked    = @($rows | Where-Object { -not $_.Check.IsEnabled }).Count
            Todo      = $totalTodo
            Done      = $totalDone
            Unknown   = $totalHuh
            Steps     = $totalSteps
            Theme     = $palBox.Key
            Icon      = [bool]$ico
            Ms        = $ms
            Tagged    = @($rows | Where-Object { $_.Tag }).Count
            # Must be zero. Still in place is what every row is unless it says
            # otherwise, so a marker for it is the page's premise repeated once
            # per row.
            Mistagged = @($rows | Where-Object { $_.Opt.State -eq 'todo' -and $_.Tag }).Count
            Tally     = [string]$ui.Tally.Text
            Summary   = [string]$ui.Sub2.Text
            Title     = [string]$win.Title
            Window    = $win
            Rows      = $rows
            Blocks    = $blocks
            RailCards = $railCards
            Order     = $applyOrder
            Filter    = $applyFilter
            Theming   = $applyTheme
            Boxes     = $filterBoxes
            State     = $state
            Ui        = $ui
            # How many rows carry the one-line description. Zero on a journal read
            # back with no plan in hand, which is a real state and not a fault -
            # so what the self test asserts is that a script written WITH one has
            # them, and that the row's element is there to hold it either way.
            Described = @($rows | Where-Object { [string]$_.Desc }).Count
            # The two passes a headless check has to be able to drive: repainting
            # after a tick, and turning the descriptions on. Both are reached by a
            # click in the window, and a click is what -BuildOnly cannot make.
            Paint     = $paintCounts
            Terse     = $applyTerse
        }
    }

    # Closed here rather than at the end of the read: building the list is the
    # other half of the wait, and a splash that goes away over an empty screen
    # is worse than one that stays until there is something to look at.
    if ($splash) { & $splash.Close }

    $win.Add_ContentRendered({ $this.Activate() | Out-Null })
    $null = $win.ShowDialog()
    Close-WDHives

    if ($done.Ran -and $done.Failed) {
        # The launcher prints what the exit code means and holds for twenty
        # seconds, and it does that in the console this hid. Put it back for
        # exactly the case that has something to say - on a clean run cmd.exe
        # exits straight away, and a console reappearing for that moment is a
        # flash of nothing.
        Set-WDUndoConsole -Show
        return 1
    }
    0
}
'@

# Double-clicking a .ps1 opens a text editor - Windows' own association, which
# nothing in a .ps1 can change. So the run folder's "double-click it" was wrong on
# every machine, and the script ships with a launcher beside it.
#
# Same three rules as Run-WinSetupToolkit.cmd: NO BOM (cmd.exe does not strip one,
# so the first line reads as "<BOM>@echo", fails, and leaves echo on for the whole
# file), CRLF (labels and parenthesised blocks are unreliable with bare LF), and
# `reg query HKU\S-1-5-19` for the admin probe (net session needs the Server
# service, openfiles needs a flag most machines lack).
$script:WDUndoLauncher = @'
@echo off
setlocal
set "PS1=%~dp0Undo-WinSetupToolkit.ps1"
if not exist "%PS1%" (
    echo Undo-WinSetupToolkit.ps1 is not in this folder, so there is nothing to run.
    echo Keep the two files together.
    pause
    exit /b 1
)
reg query HKU\S-1-5-19 >nul 2>&1
if not errorlevel 1 goto :run
echo Requesting administrator rights...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b 0
:run
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%PS1%" %*
set RC=%ERRORLEVEL%
if "%RC%"=="0" goto :done
echo.
echo Finished with errors ^(exit %RC%^). The lines above say which.
%SystemRoot%\System32\timeout.exe /t 20 >nul 2>&1 || ping -n 21 127.0.0.1 >nul 2>&1
:done
endlocal & exit /b %RC%
'@

function Export-WDUndoLauncher {
    <#
        Writes Undo-WinSetupToolkit.cmd beside the script and answers with its path.
        Separate from the script's own generation so a run that could not write
        one still gets the other.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        $text = ($script:WDUndoLauncher -split "`r?`n") -join "`r`n"
        # No BOM. Not a preference - see the note above.
        [IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding $false))
        return $Path
    } catch {
        Write-WDLog "Could not write the rollback launcher: $($_.Exception.Message)" -Level Warn
        return ''
    }
}

function Get-WDIcoSubset {
    <#
        The same .ico with only the frames at or under $MaxSize.

        The toolkit's icon carries eight frames up to 256, and the 128 and 256
        ones are 130 KB of the 158 - which becomes 173 KB of base64 in a script
        somebody is meant to be able to read. A window icon is asked for at 16
        for the title bar and 24 to 48 for the taskbar; nothing here ever draws
        it at 256, so those two frames are 173 KB buying nothing.

        A directory entry is sixteen bytes and only the last four - the offset -
        change when frames are dropped, so the entries are copied through and
        re-pointed rather than rebuilt.
    #>
    param([byte[]]$Bytes, [int]$MaxSize = 64)

    if (-not $Bytes -or $Bytes.Length -lt 22) { return $Bytes }
    $n = [BitConverter]::ToUInt16($Bytes, 4)
    $keep = New-Object System.Collections.Generic.List[psobject]
    for ($i = 0; $i -lt $n; $i++) {
        $o = 6 + 16 * $i
        $w = [int]$Bytes[$o]
        if ($w -eq 0) { $w = 256 }          # 256 is recorded as zero
        if ($w -gt $MaxSize) { continue }
        $keep.Add([pscustomobject]@{
            Dir = [byte[]]$Bytes[$o..($o + 15)]
            Len = [int][BitConverter]::ToUInt32($Bytes, $o + 8)
            Off = [int][BitConverter]::ToUInt32($Bytes, $o + 12)
        })
    }
    if (-not $keep.Count) { return $Bytes }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$keep.Count)
    $cur = 6 + 16 * $keep.Count
    foreach ($k in $keep) {
        $bw.Write($k.Dir, 0, 12)            # width, height, planes, bpp, length
        $bw.Write([uint32]$cur)
        $cur += $k.Len
    }
    foreach ($k in $keep) { $bw.Write($Bytes, $k.Off, $k.Len) }
    $bw.Flush()
    ,$ms.ToArray()
}

function Get-WDUndoIconData {
    <#
        The toolkit's own application icon as base64, for embedding.

        Embedded rather than written beside the script, because the whole
        premise of that file is that it stands alone - somebody who copies only
        the .ps1 somewhere else should still get a window with the right mark on
        it.

        Answers the empty string when the icon cannot be built, which is a real
        state rather than a failure: the drawing lives in the interface module
        and a run started from the command line never loads it. The window falls
        back to the host icon, which is what it had before.
    #>
    param([string]$Theme = '')

    if (-not (Get-Command Get-WDAppIconBytes -ErrorAction SilentlyContinue)) { return '' }
    try {
        $full = Get-WDAppIconBytes -Theme $Theme
        if (-not $full) { return '' }
        [Convert]::ToBase64String((Get-WDIcoSubset -Bytes $full -MaxSize 64))
    } catch {
        Write-WDLog "Could not embed the application icon in the rollback script: $($_.Exception.Message)" -Level Warn
        ''
    }
}

function Export-WDUndoScript {
    <#
        Turn the journal into a runnable rollback script with a window on the
        front of it.

        Registry values, service start-types, tasks, features, power settings
        and parked folders reverse exactly. Uninstalled programs cannot be put
        back by anything and are listed as such rather than pretended at.

        The script imports nothing and calls nothing from this toolkit, which is
        deliberate and is the whole reason it exists: it is read on a machine
        somebody has just changed, possibly badly, possibly with the toolkit
        already deleted off the stick it came on.
    #>
    param(
        # The plan that ran, for option names and categories. Optional - without
        # it the page groups by raw id, which works and reads badly.
        $Items
    )

    # Get-WDSession, never $script:Session. Each module has a script scope of
    # its own, so the variable that meant the live session while this function
    # lived in WD.Core is $null from here - and the guard below reads as "there
    # is no session", so the function would answer nothing and every caller
    # would report the script as simply not written.
    $sess = Get-WDSession
    if (-not $sess -or -not (Test-Path $sess.JournalFile)) { return }

    $plan = Get-WDUndoPlan -Journal $sess.JournalFile -Items $Items
    $when = ''
    try { $when = ([datetime]$sess.Started).ToString('d MMMM yyyy') + ' at ' + ([datetime]$sess.Started).ToString('HH:mm') } catch { }

    $q = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('<#')
    $null = $sb.AppendLine("    Revert changes from the Windows Setup Toolkit run of $when.")
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('    Double-click Undo-WinSetupToolkit.cmd beside this file - Windows opens a')
    $null = $sb.AppendLine('    .ps1 in a text editor, which is its own association and not something')
    $null = $sb.AppendLine('    a .ps1 can change. A window opens listing everything that run changed,')
    $null = $sb.AppendLine('    with what has already been put back marked as such. Tick what you want')
    $null = $sb.AppendLine('    reversed and press Revert selected.')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('      -Console      no window: put everything back, printing as it goes')
    $null = $sb.AppendLine('      -ListOnly     change nothing, just report what is still in place')
    $null = $sb.AppendLine('      -Only a,b     restrict to these option ids')
    $null = $sb.AppendLine('      -Theme dark   open in one palette rather than following Windows')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('    Programs the run uninstalled cannot be reinstalled from a journal.')
    $null = $sb.AppendLine('    They are listed at the end so you know what they were.')
    $null = $sb.AppendLine('#>')
    $null = $sb.AppendLine('#Requires -RunAsAdministrator')
    $null = $sb.AppendLine('[CmdletBinding()]')
    $null = $sb.AppendLine('param(')
    $null = $sb.AppendLine('    [switch]$Console,')
    $null = $sb.AppendLine('    [switch]$ListOnly,')
    $null = $sb.AppendLine('    [string[]]$Only = @(),')
    $null = $sb.AppendLine('    [ValidateSet('''', ''dark'', ''light'')][string]$Theme = '''',')
    $null = $sb.AppendLine('    # Build the window and report what it says, without showing it. The')
    $null = $sb.AppendLine('    # toolkit self test drives this; nothing else has a use for it.')
    $null = $sb.AppendLine('    [switch]$BuildOnly')
    $null = $sb.AppendLine(')')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("`$global:WDRun          = $(& $q $sess.Id)")
    $null = $sb.AppendLine("`$global:WDWhen         = $(& $q $when)")
    $null = $sb.AppendLine("`$global:WDWantsHku     = `$$([string]$plan.WantsHku.ToString().ToLower())")
    $null = $sb.AppendLine("`$global:WDWantsDefault = $([int]$plan.WantsDefault)")
    $null = $sb.AppendLine('')

    # The toolkit's own application icon, so the window and its taskbar button
    # wear the mark somebody recognises rather than PowerShell's. Two of them,
    # because the icon follows the palette and the window has a theme button.
    #
    # Embedded rather than written beside the script: this file has to stand
    # alone. Trimmed to the frames a window is actually asked for - see
    # Get-WDIcoSubset - and empty on a run with no interface loaded to draw one,
    # in which case the window simply keeps the host icon.
    $null = $sb.AppendLine('# The application icon, one per palette, as base64. Empty if this run had')
    $null = $sb.AppendLine('# no interface loaded to draw one; the window then keeps the host icon.')
    foreach ($pair in @(@('WDIconDark', 'dark'), @('WDIconLight', 'light'))) {
        $b64 = Get-WDUndoIconData -Theme $pair[1]
        if (-not $b64) {
            $null = $sb.AppendLine("`$global:$($pair[0]) = ''")
            continue
        }
        # Long lines rather than short ones. Nobody reads base64 either way, and
        # every line of it is a string literal the parser has to build before
        # anything at all is on screen.
        $null = $sb.AppendLine("`$global:$($pair[0]) = @(")
        for ($p = 0; $p -lt $b64.Length; $p += 1000) {
            $len = [Math]::Min(1000, $b64.Length - $p)
            $null = $sb.AppendLine("'" + $b64.Substring($p, $len) + "'")
        }
        $null = $sb.AppendLine(") -join ''")
    }
    $null = $sb.AppendLine('')

    # One line per step, in the order they happened. Readable on purpose: this
    # is the part somebody checks before running it, and a blob of JSON is not
    # something anybody checks.
    $null = $sb.AppendLine('# Every change that run recorded, with what it was before.')
    $null = $sb.AppendLine('$global:WDSteps = @(')
    foreach ($s in $plan.Steps) {
        $f = New-Object System.Collections.Generic.List[string]
        $f.Add("Id=$(& $q $s.Id)")
        $f.Add("Nm=$(& $q $s.ItemName)")
        $f.Add("Cat=$(& $q $s.Category)")
        $f.Add("M=$(& $q $s.Method)")
        switch ($s.Method) {
            'registry' {
                $f.Add("P=$(& $q $s.Path)"); $f.Add("N=$(& $q $s.Name)"); $f.Add("K=$(& $q $s.Kind)")
                $f.Add("V=$(ConvertTo-WDPsLiteral $s.Previous)")
                $f.Add("Gone=`$$([string]$s.Gone.ToString().ToLower())")
            }
            'service'         { $f.Add("N=$(& $q $s.Name)"); $f.Add("V=$(& $q $s.Previous)") }
            'task'            { $f.Add("P=$(& $q $s.Path)"); $f.Add("N=$(& $q $s.Name)") }
            'unregister-task' { $f.Add("N=$(& $q $s.Name)") }
            'feature'         { $f.Add("N=$(& $q $s.Name)") }
            'feature-off'     { $f.Add("N=$(& $q $s.Name)") }
            'capability-off'  { $f.Add("N=$(& $q $s.Name)") }
            'powercfg'        { $f.Add("Sub=$(& $q $s.Sub)"); $f.Add("Set=$(& $q $s.Setting)")
                                $f.Add("Ac=$([int]$s.Ac)"); $f.Add("Dc=$([int]$s.Dc)") }
            'regfile'         { $f.Add("F=$(& $q $s.File)"); $f.Add("T=$(& $q $s.Target)") }
            'file-restore'    { $f.Add("T=$(& $q $s.Target)"); $f.Add("F=$(& $q $s.File)") }
            'rename'          { $f.Add("From=$(& $q $s.From)"); $f.Add("To=$(& $q $s.To)") }
            'recycle'         { $f.Add("P=$(& $q $s.Path)") }
            'uninstall'       { $f.Add("N=$(& $q $s.Name)") }
        }
        $null = $sb.AppendLine('    @{ ' + ($f -join '; ') + ' }')
    }
    $null = $sb.AppendLine(')')
    $null = $sb.AppendLine('')

    $null = $sb.AppendLine('# Uninstalled by that run. Listed, never attempted: nothing puts a removed')
    $null = $sb.AppendLine('# program back from a journal, and a script that pretended otherwise would')
    $null = $sb.AppendLine('# be worse than one that says so.')
    $null = $sb.AppendLine('$global:WDReinstall = @(')
    foreach ($r in $plan.Reinstall) { $null = $sb.AppendLine('    ' + (& $q $r)) }
    $null = $sb.AppendLine(')')
    $null = $sb.AppendLine('$global:WDOwners = @(')
    foreach ($o in $plan.Owners) { $null = $sb.AppendLine('    ' + (& $q $o)) }
    $null = $sb.AppendLine(')')

    # WHAT EACH OPTION DID, past-tensed. Without it the page named an option and
    # counted its changes and never said what it was - "Office telemetry, 4
    # changes" was all somebody deciding had to go on.
    #
    # KEYED BY OPTION AND EMITTED ONCE EACH, not per step: a hundred steps of one
    # option would repeat one paragraph a hundred times in a file whose premise is
    # that it can be read. Absent when the journal is read with no plan in hand,
    # where the rows simply carry no description.
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('# What each option did, in the past tense - the same line the Revert page')
    $null = $sb.AppendLine('# shows. Empty if this script was written without the plan in hand.')
    $null = $sb.AppendLine('$global:WDDesc = @{')
    foreach ($k in @($plan.Descs.Keys | Sort-Object)) {
        $null = $sb.AppendLine('    ' + (& $q $k) + ' = ' + (& $q $plan.Descs[$k]))
    }
    $null = $sb.AppendLine('}')

    $null = $sb.Append($script:WDUndoBody)
    $null = $sb.AppendLine($script:WDUndoWindow)
    $null = $sb.AppendLine('')
    # Before anything reads the machine or draws a window, and NOT for -ListOnly
    # or -BuildOnly: the first changes nothing and is the obvious thing to run
    # while the toolkit is open to see what a run left behind, and the second is
    # the self test's seam. The interlock exists to stop two things WRITING at
    # once, and refusing a read would only teach people to work around it.
    $null = $sb.AppendLine('if (-not $ListOnly -and -not $BuildOnly) {')
    $null = $sb.AppendLine('    if (-not (Enter-WDUndoSingleInstance)) { exit 4 }')
    $null = $sb.AppendLine('}')
    $null = $sb.AppendLine('if ($Console -or $ListOnly) { exit (Invoke-WDUndoConsole -Only $Only -ListOnly:$ListOnly) }')
    # Printed rather than emitted. The diagnostic object holds the Window and
    # every row in it, and letting that reach the pipeline means PowerShell's
    # formatter walking a live WPF element tree - which does not come back.
    $null = $sb.AppendLine('if ($BuildOnly) {')
    $null = $sb.AppendLine('    $d = Show-WDUndoWindow -Theme $Theme -BuildOnly')
    $null = $sb.AppendLine('    Write-Host ("options={0} groups={1} rail={2} ticked={3} locked={4}" -f $d.Options, $d.Groups, $d.Rail, $d.Ticked, $d.Locked)')
    $null = $sb.AppendLine('    Write-Host ("steps={0} todo={1} done={2} unknown={3}" -f $d.Steps, $d.Todo, $d.Done, $d.Unknown)')
    $null = $sb.AppendLine('    Write-Host ("theme={0} icon={1} tagged={2} mistagged={3} boxes={4}" -f $d.Theme, $d.Icon, $d.Tagged, $d.Mistagged, @($d.Boxes).Count)')
    $null = $sb.AppendLine('    Write-Host ("ms read={0} shell={1} rows={2} layout={3}" -f $d.Ms.Read, $d.Ms.Shell, $d.Ms.Rows, $d.Ms.Layout)')
    $null = $sb.AppendLine('    Write-Host ("title=" + $d.Title)')
    $null = $sb.AppendLine('    Write-Host ("tally=" + $d.Tally)')
    $null = $sb.AppendLine('    Write-Host ("summary=" + $d.Summary)')
    # Every grouping laid out for real, because a grouping nothing exercises is
    # a grouping that throws the first time somebody picks it.
    $null = $sb.AppendLine('    foreach ($g in @(''status'', ''kind'', ''alpha'', ''category'')) {')
    $null = $sb.AppendLine('        $d.State.Group = $g')
    $null = $sb.AppendLine('        & $d.Order')
    $null = $sb.AppendLine('        Write-Host ("group[{0}] blocks={1} rail={2}" -f $g, @($d.Blocks).Count, @($d.RailCards).Count)')
    $null = $sb.AppendLine('    }')
    $null = $sb.AppendLine('    foreach ($s in @(''selected'', ''most'', ''name'')) {')
    $null = $sb.AppendLine('        $d.State.Sort = $s; & $d.Order')
    $null = $sb.AppendLine('    }')
    $null = $sb.AppendLine('    Write-Host ("sorted=ok")')
    # The page-wide Select all, pressed for real in both directions. A button one
    # press from "revert nothing" has to be checked on what it SAYS as well as on
    # what it does, so the label is reported beside the count either side of it.
    $null = $sb.AppendLine('    $saSay = { "{0}/{1}" -f [string]$d.Ui.BtnSelectAll.Content, @($d.Rows | Where-Object { $_.Check.IsChecked }).Count }')
    $null = $sb.AppendLine('    $saHit = { $d.Ui.BtnSelectAll.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }')
    $null = $sb.AppendLine('    $sa0 = & $saSay')
    $null = $sb.AppendLine('    & $saHit; $sa1 = & $saSay')
    $null = $sb.AppendLine('    & $saHit; $sa2 = & $saSay')
    $null = $sb.AppendLine('    Write-Host ("selectall={0} -> {1} -> {2}" -f $sa0, $sa1, $sa2)')
    # WHAT AN UNTICKED ROW SAYS, driven for real. Every option here arrives
    # ticked, so a clear box is an edit, and the row marks it the way the
    # Advanced page marks a row a preset selected and the operator cleared: the
    # name in Bad and bold, with a line under it saying what that means. Read
    # off the RESOURCE KEY rather than the brush, because the two palettes give
    # different colours for the same answer.
    $null = $sb.AppendLine('    $rkOf = {')
    $null = $sb.AppendLine('        param($El, $Dp)')
    $null = $sb.AppendLine('        $v = $El.ReadLocalValue($Dp)')
    $null = $sb.AppendLine('        if ($null -eq $v -or $v -eq [Windows.DependencyProperty]::UnsetValue) { return '''' }')
    $null = $sb.AppendLine('        $pi = $v.GetType().GetProperty(''ResourceKey'', [Reflection.BindingFlags]''Instance,Public,NonPublic'')')
    $null = $sb.AppendLine('        if (-not $pi) { return "$v" }')
    $null = $sb.AppendLine('        [string]$pi.GetValue($v)')
    $null = $sb.AppendLine('    }')
    $null = $sb.AppendLine('    $fgDp = [Windows.Controls.TextBlock]::ForegroundProperty')
    $null = $sb.AppendLine('    $bgDp = [Windows.Controls.Border]::BackgroundProperty')
    $null = $sb.AppendLine('    $liveR = @($d.Rows | Where-Object { $_.Check.IsEnabled })')
    $null = $sb.AppendLine('    $deadR = @($d.Rows | Where-Object { -not $_.Check.IsEnabled })')
    $null = $sb.AppendLine('    if ($liveR.Count) {')
    $null = $sb.AppendLine('        $lr = $liveR[0]')
    $null = $sb.AppendLine('        $lr.Check.IsChecked = $true;  & $d.Paint')
    $null = $sb.AppendLine('        $u0 = "{0}/{1}" -f (& $rkOf $lr.NameEl $fgDp), $lr.Skip.Visibility')
    $null = $sb.AppendLine('        $lr.Check.IsChecked = $false; & $d.Paint')
    $null = $sb.AppendLine('        $u1 = "{0}/{1}/{2}" -f (& $rkOf $lr.NameEl $fgDp), $lr.Skip.Visibility, $lr.NameEl.FontWeight')
    $null = $sb.AppendLine('        $lr.Check.IsChecked = $true;  & $d.Paint')
    $null = $sb.AppendLine('        $u2 = "{0}/{1}/{2}" -f (& $rkOf $lr.NameEl $fgDp), $lr.Skip.Visibility, $lr.NameEl.FontWeight')
    $null = $sb.AppendLine('        Write-Host ("unticked={0} -> {1} -> {2}" -f $u0, $u1, $u2)')
    $null = $sb.AppendLine('        Write-Host ("notice=" + $lr.Skip.Text)')
    $null = $sb.AppendLine('        Write-Host ("livecursor={0}" -f $lr.Card.Cursor)')
    $null = $sb.AppendLine('    }')
    # A row with nothing left to decide is inert: it refuses the click, so it must
    # not invite one either. The hover handlers are not wired at all on those,
    # which is the only thing firing the event can tell you.
    $null = $sb.AppendLine('    if ($deadR.Count) {')
    $null = $sb.AppendLine('        $dr = $deadR[0]')
    $null = $sb.AppendLine('        $hv = { param($El, $Ev)')
    $null = $sb.AppendLine('                $ea = New-Object Windows.Input.MouseEventArgs([Windows.Input.Mouse]::PrimaryDevice, 0)')
    $null = $sb.AppendLine('                $ea.RoutedEvent = $Ev; $El.RaiseEvent($ea) }')
    $null = $sb.AppendLine('        $r0 = & $rkOf $dr.Card $bgDp')
    $null = $sb.AppendLine('        & $hv $dr.Card ([Windows.UIElement]::MouseEnterEvent)')
    $null = $sb.AppendLine('        $r1 = & $rkOf $dr.Card $bgDp')
    $null = $sb.AppendLine('        & $hv $dr.Card ([Windows.UIElement]::MouseLeaveEvent)')
    $null = $sb.AppendLine('        & $d.Paint')
    $null = $sb.AppendLine('        Write-Host ("deadhover={0} -> {1} cursor={2} struck={3} opacity={4} notice={5}" -f $r0, $r1, $dr.Card.Cursor, [bool]$dr.NameEl.TextDecorations.Count, $dr.Card.Opacity, $dr.Skip.Visibility)')
    $null = $sb.AppendLine('        Write-Host ("deadink=" + (& $rkOf $dr.NameEl $fgDp))')
    $null = $sb.AppendLine('    }')
    # Clicking anywhere on the row, which the box is a 13px target in the corner
    # of. Raised on the card, so the whole gesture is what is measured.
    $null = $sb.AppendLine('    if ($liveR.Count) {')
    $null = $sb.AppendLine('        $cr = $liveR[0]')
    $null = $sb.AppendLine('        $ck = { param($El)')
    $null = $sb.AppendLine('                $ea = New-Object Windows.Input.MouseButtonEventArgs([Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left)')
    $null = $sb.AppendLine('                $ea.RoutedEvent = [Windows.UIElement]::MouseLeftButtonUpEvent; $El.RaiseEvent($ea) }')
    $null = $sb.AppendLine('        $c0 = [bool]$cr.Check.IsChecked')
    $null = $sb.AppendLine('        & $ck $cr.Card; $c1 = [bool]$cr.Check.IsChecked')
    $null = $sb.AppendLine('        & $ck $cr.Card; $c2 = [bool]$cr.Check.IsChecked')
    $null = $sb.AppendLine('        Write-Host ("rowclick={0} -> {1} -> {2}" -f $c0, $c1, $c2)')
    $null = $sb.AppendLine('    }')
    $null = $sb.AppendLine('    if ($deadR.Count) {')
    $null = $sb.AppendLine('        $dr2 = $deadR[0]')
    $null = $sb.AppendLine('        $ck2 = { param($El)')
    $null = $sb.AppendLine('                 $ea = New-Object Windows.Input.MouseButtonEventArgs([Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left)')
    $null = $sb.AppendLine('                 $ea.RoutedEvent = [Windows.UIElement]::MouseLeftButtonUpEvent; $El.RaiseEvent($ea) }')
    $null = $sb.AppendLine('        $w0 = [bool]$dr2.Check.IsChecked')
    $null = $sb.AppendLine('        & $ck2 $dr2.Card')
    $null = $sb.AppendLine('        Write-Host ("deadclick={0} -> {1}" -f $w0, [bool]$dr2.Check.IsChecked)')
    $null = $sb.AppendLine('    }')
    # Non-verbose, which is the default. The elements exist either way, so the
    # option can be turned back on without the page being rebuilt - and on a
    # script written with no plan in hand there is nothing to show, which is a
    # real state and reported as its own number rather than as a failure.
    $null = $sb.AppendLine('    $descN = @($d.Rows | Where-Object { $_.DescEl }).Count')
    $null = $sb.AppendLine('    $shown = { @($d.Rows | Where-Object { $_.DescEl -and $_.DescEl.Visibility -eq ''Visible'' }).Count }')
    $null = $sb.AppendLine('    $t0 = & $shown')
    $null = $sb.AppendLine('    $d.State.Terse = $false; & $d.Terse; $t1 = & $shown')
    $null = $sb.AppendLine('    $d.State.Terse = $true;  & $d.Terse; $t2 = & $shown')
    $null = $sb.AppendLine('    Write-Host ("described={0} of {1} elements, visible {2} -> {3} -> {4}" -f $d.Described, $descN, $t0, $t1, $t2)')
    # Refresh, pressed for real. It reads the machine again and REBUILDS the
    # rows, so what has to be checked is that the page comes back whole: the same
    # options, the ticks re-made, the filter panel re-offered, and the heading
    # saying it was read again. A rebuild that half happened leaves rows in no
    # column on a page reporting itself finished.
    $null = $sb.AppendLine('    $rfSay = { "{0} rows/{1} tickable/{2} boxes/{3} blocks" -f $d.Rows.Count, @($d.Rows | Where-Object { $_.Check.IsEnabled }).Count, @($d.Boxes).Count, @($d.Blocks).Count }')
    $null = $sb.AppendLine('    $rf0 = & $rfSay')
    $null = $sb.AppendLine('    $d.Ui.BtnRefresh.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))')
    $null = $sb.AppendLine('    Write-Host ("refresh={0} -> {1}" -f $rf0, (& $rfSay))')
    $null = $sb.AppendLine('    Write-Host ("refreshsaid=" + $d.Ui.Sub2.Text)')
    $null = $sb.AppendLine('    Write-Host ("refreshbtn=" + $d.Ui.BtnRefresh.IsEnabled)')
    # And the rebuilt rows still answer a click, which is what proves the tick
    # wiring was re-made rather than left on the boxes that were thrown away.
    $null = $sb.AppendLine('    $liveR2 = @($d.Rows | Where-Object { $_.Check.IsEnabled })')
    $null = $sb.AppendLine('    if ($liveR2.Count) {')
    $null = $sb.AppendLine('        $r2 = $liveR2[0]')
    $null = $sb.AppendLine('        $ck3 = { param($El)')
    $null = $sb.AppendLine('                 $ea = New-Object Windows.Input.MouseButtonEventArgs([Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left)')
    $null = $sb.AppendLine('                 $ea.RoutedEvent = [Windows.UIElement]::MouseLeftButtonUpEvent; $El.RaiseEvent($ea) }')
    $null = $sb.AppendLine('        $q0 = [string]$d.Ui.Tally.Text')
    $null = $sb.AppendLine('        & $ck3 $r2.Card')
    $null = $sb.AppendLine('        Write-Host ("afterrefresh=" + $(if ([string]$d.Ui.Tally.Text -ne $q0) { ''the tally followed the tick'' } else { ''THE TICK DID NOTHING'' }))')
    $null = $sb.AppendLine('    }')
    $null = $sb.AppendLine('    & $d.Theming $(if ($d.Theme -eq ''dark'') { ''light'' } else { ''dark'' })')
    $null = $sb.AppendLine('    Write-Host ("switched=" + $d.Window.Resources[''WdBg''])')
    $null = $sb.AppendLine('    try { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }')
    $null = $sb.AppendLine('    exit 0')
    $null = $sb.AppendLine('}')
    $null = $sb.AppendLine('exit (Show-WDUndoWindow -Theme $Theme)')

    Set-Content -LiteralPath $sess.UndoFile -Value $sb.ToString() -Encoding UTF8
    $null = Export-WDUndoLauncher -Path (Join-Path (Split-Path $sess.UndoFile -Parent) 'Undo-WinSetupToolkit.cmd')
    Write-WDLog "Rollback script written to $($sess.UndoFile)" -Level Success
    $sess.UndoFile
}

Export-ModuleMember -Function Get-WDRecurringEffects, Remove-WDRecurringEffect, Get-WDPastRuns,
                              Test-WDTaskPresent, Remove-WDGuardLeftovers,
                              Get-WDRemovedItems, Start-WDRemovedScan, Receive-WDRemovedScan,
                              Invoke-WDReinstall, Invoke-WDRevertPlan,
                              Get-WDUndoStatus, Export-WDUndoScript, Get-WDUndoPlan,
                              Get-WDCombinedUndoPlan, Get-WDUndoStepKey, Get-WDUndoStepState,
                              Get-WDUndoStepKind, Get-WDUndoStepText, Get-WDRevertDescription,
                              Get-WDTaskEnabledState,
                              Export-WDUndoLauncher, Get-WDUndoIconData, Get-WDIcoSubset,
                              ConvertTo-WDPsLiteral, ConvertFrom-WDUndoPrevious
