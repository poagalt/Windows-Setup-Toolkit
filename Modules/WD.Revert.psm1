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

# The whole of the generated script that is not data, kept as a file beside this
# module rather than as a here-string inside it.
#
# It was two here-strings, and that made 3,087 lines of ordinary PowerShell - 31
# functions and 49 GetNewClosure() calls - invisible to every static check this
# project has. A string literal is a string literal: the parse gate, [6]'s
# closure rule and the theme-key sweep all stopped at the quotation mark, in the
# one file whose own notes say the closure rule "has already cost the most".
# As a file it is parsed and checked like anything else.
#
# Nothing about the emitted script changes. The text is inlined verbatim at
# generate time, so the rollback script is still one self-contained file that
# imports nothing - which is its whole premise, since it is read on a machine
# somebody has just changed, possibly with the toolkit already deleted off the
# stick it came on.
#
# Everything above it in the emitted file is data; everything in it is fixed.
# That split is what makes the script testable at all - the body is the same
# bytes on every run, so a self test that exercises one exercises them all.
#
# DELIBERATELY THE SAME PAGE as the toolkit's Advanced list - heading, rule, a row
# per option with a tick and a tag, an index of counts down the side. Somebody who
# has used the toolkit has already learnt this page, and this is the screen they
# see when something has gone wrong.
#
# It is NOT the toolkit's Revert page. That lists recurring effects and removed
# software across every run, from a machine that still has the toolkit. This is
# one run, on a machine that may not.
$script:WDUndoSource = $null

function Get-WDUndoWindowSource {
    if ($null -ne $script:WDUndoSource) { return $script:WDUndoSource }
    $path = Join-Path $PSScriptRoot 'WD.UndoWindow.ps1'
    if (-not (Test-Path -LiteralPath $path)) {
        # Loud rather than silent, and this is the one place in the module where
        # that matters most: written without it, the rollback script would carry
        # its journal and neither an executor nor a window, and the one artefact
        # this project's safety argument rests on would be a stub that reports
        # success.
        throw "The rollback window source is missing: $path"
    }
    $script:WDUndoSource = [string](Get-Content -LiteralPath $path -Raw)
    $script:WDUndoSource
}

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

    $null = $sb.AppendLine((Get-WDUndoWindowSource))
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
