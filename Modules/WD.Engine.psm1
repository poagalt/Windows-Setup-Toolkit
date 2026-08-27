<#
    WD.Engine - manifest loading, plan resolution, execution.

    The engine is the only thing that knows the order of operations and the
    only thing that decides what "success" means for an item. Executors stay
    dumb and local; policy lives here.
#>

$script:ActionDispatch = @{
    'appx'        = 'Invoke-WDAppxAction'
    'appxPolicy'  = 'Invoke-WDAppxPolicyAction'
    'winget'      = 'Invoke-WDWingetAction'
    'uninstall'   = 'Invoke-WDUninstallAction'
    'registry'    = 'Invoke-WDRegistryAction'
    'registryKey' = 'Invoke-WDRegistryKeyAction'
    'service'     = 'Invoke-WDServiceAction'
    'task'        = 'Invoke-WDTaskAction'
    'feature'     = 'Invoke-WDFeatureAction'
    'capability'  = 'Invoke-WDCapabilityAction'
    'file'        = 'Invoke-WDFileAction'
    'shortcut'    = 'Invoke-WDShortcutAction'
    'script'      = 'Invoke-WDScriptAction'
}

function Import-WDManifest {
    <#
        Loads every .json in the manifest folder and merges them by category.
        Splitting the list across files is purely organizational - the engine
        sees one flat set of categories.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $files = @()
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -Recurse | Sort-Object FullName)
    } elseif (Test-Path -LiteralPath $Path) {
        $files = @(Get-Item -LiteralPath $Path)
    } else {
        throw "Manifest path not found: $Path"
    }

    $categories = New-Object System.Collections.Generic.List[psobject]
    $seenIds    = New-Object System.Collections.Generic.HashSet[string]

    foreach ($f in $files) {
        $doc = $null
        try {
            $doc = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-WDLog "Manifest '$($f.Name)' is not valid JSON and was skipped: $($_.Exception.Message)" -Level Error
            continue
        }
        if (-not $doc.PSObject.Properties['categories']) { continue }

        foreach ($cat in $doc.categories) {
            $existing = $categories | Where-Object { $_.id -eq $cat.id } | Select-Object -First 1
            $items = New-Object System.Collections.Generic.List[psobject]

            foreach ($item in @(Get-Prop $cat 'items' @())) {
                if (-not $item.PSObject.Properties['id'] -or -not $item.id) {
                    Write-WDLog "Item without an id in '$($f.Name)' was skipped." -Level Warn
                    continue
                }
                if (-not $seenIds.Add([string]$item.id)) {
                    Write-WDLog "Duplicate item id '$($item.id)' in '$($f.Name)' was skipped." -Level Warn
                    continue
                }
                $items.Add($item)
            }

            if ($existing) {
                $existing.items = @($existing.items) + @($items)
            } else {
                # Rebuilt rather than kept, so the shape is known - but only the
                # fields named here survive, which is a silent way to lose a new
                # one. 'section' is carried explicitly for that reason.
                $categories.Add([pscustomobject]@{
                    id      = [string]$cat.id
                    name    = [string](Get-Prop $cat 'name' $cat.id)
                    order   = [int](Get-Prop $cat 'order' 100)
                    section = [string](Get-Prop $cat 'section' 'remove')
                    # One line of prose under the category heading in the GUI,
                    # for the rare category that has something to say no row
                    # name can. Empty for all but one, and carried here rather
                    # than written into the interface so that a category that
                    # needs a sentence is not also a special case in the layout.
                    note    = [string](Get-Prop $cat 'note' '')
                    items   = @($items)
                })
            }
        }
    }

    if (-not $categories.Count) { throw "No usable manifest entries found under $Path" }

    # Category names may carry a {vendor} token so one manifest reads correctly
    # on every brand without the mode screen having to truncate a long label.
    $vendorLabel = 'this manufacturer'
    $diskLabel   = 'this drive'
    try {
        $p = Get-WDSystemProfile
        $vendorLabel = $p.VendorLabel
        if ($p.DiskTotalBytes -gt 0) {
            $diskLabel = '{0} is {1}% full, {2:n0} GB free' -f $p.SystemDrive, $p.DiskUsedPercent, ($p.DiskFreeBytes / 1GB)
        }
    } catch { }
    foreach ($c in $categories) {
        $c.name = ([string]$c.name).Replace('{vendor}', $vendorLabel).Replace('{disk}', $diskLabel)
    }
    Write-WDLog "Manifest loaded: $($categories.Count) categories, $(($categories | ForEach-Object { @($_.items).Count } | Measure-Object -Sum).Sum) items." -Level Info
    ,($categories | Sort-Object order, name)
}

# Presets are a ladder, not four unrelated lists: an item belongs to a preset
# when its tier is at or below that preset's level. That keeps the comparison
# table honest (Balanced always contains Conservative) and makes adding an item
# a single-number decision.
$script:Presets = [ordered]@{
    # The mode screen lists what each one removes. These say what a mode is for
    # and what it costs, which the list cannot - so they must not repeat it.
    Conservative = @{ Level = 1; Blurb = 'Safe on any machine. Nothing here changes behavior, it only removes annoyances like advertising, useless pre-installed apps, AI features, and telemetry.' }
    Balanced     = @{ Level = 2; Blurb = 'The default. Removes most pre-installed apps, dials down app permissions, removes some location services, adds some quality of life fixes, and removes most AI backbone.' }
    Aggressive   = @{ Level = 3; Blurb = 'For power users who run Windows exactly as they please. This option nukes all telemetry, advertising, bloatware, and legacy leftovers, and enables most common quality of life fixes, like disabling startup apps.' }
    Extreme      = @{ Level = 4; Blurb = 'Implements more intense measures to squeeze the remaining bloat juice out of Windows. Do not use this preset unless you know what you are doing - the options it adds over Aggressive are inherently risky in many ways.' }
}

function Get-WDPresetNames { $script:Presets.Keys }
function Get-WDPresetInfo  { param([string]$Name) $script:Presets[$Name] }

function Get-WDItemTier {
    <#
        Manifest items declare "tier" directly. Anything predating that field
        falls back to a mapping from its risk and default, so an un-migrated
        manifest still lands somewhere sensible instead of vanishing.
    #>
    param($Item)

    # Tier 0 means opt-in only: no preset ever selects it, but it is still
    # available to tick by hand in Advanced. Quality-of-life tweaks live here,
    # because they are preferences rather than debloating.
    $p = $Item.PSObject.Properties['tier']
    if ($p -and $null -ne $p.Value) {
        $t = [int]$p.Value
        if ($t -ge 0 -and $t -le 4) { return $t }
    }

    $risk = [int](Get-Prop $Item 'risk' 0)
    $def  = [bool](Get-Prop $Item 'default' $false)
    if ($def) {
        switch ($risk) { 0 { 1 } 1 { 2 } default { 3 } }
    } else {
        switch ($risk) { 2 { 4 } default { 3 } }
    }
}

$script:WDSections = @('remove', 'add', 'extras')

function Get-WDItemSection {
    <#
        'add' installs software, 'extras' is run behaviour and storage clean-ups,
        'remove' is everything else - including the settings tweaks, since they
        serve the removals.

        An item may say so itself; otherwise its category answers. Default
        'remove', so a manifest predating the field behaves as before.

        Checked against $WDSections rather than a list written out here. It WAS
        written out here, as 'add' and 'remove', and every category declaring
        'extras' silently came back 'remove' - rows in the wrong column, filed
        under the wrong filter, nothing errored.
    #>
    param($Item, $Category)

    foreach ($src in @($Item, $Category)) {
        if (-not $src) { continue }
        $p = $src.PSObject.Properties['section']
        if ($p -and $p.Value) {
            $v = ([string]$p.Value).ToLower()
            if ($v -in $script:WDSections) { return $v }
        }
    }
    'remove'
}

function Get-WDSectionNames {
    <#  The sections a manifest may name, in the order the page lays them out.  #>
    ,@($script:WDSections)
}

function Test-WDItemApplies {
    <#
        Whether an item has anything at all to do on this machine. Three
        conditions:

          1. the item's own guards pass
          2. at least one ACTION's guards pass. Guards sit on actions too, so an
             item can clear its own and still be a no-op - "Block AI features
             from coming back" is two Enterprise-only policy writes, and on Home
             it was listed, counted into every preset, then silently dropped.
          3. that action is not INERT. With -Inventory, an appx action whose every
             match here is NonRemovable does not count: the package is there,
             Windows owns it, and nothing removes it. A row that can only ever
             report "Blocked: in-box" is worse than no row.

        Matching NOTHING is deliberately not inert - that is the "already gone"
        case, and it keeps its row.

        NOT the same question as "is the thing present". An item whose target is
        already gone still belongs on the page; one that cannot act on this class
        of machine costs a row and says nothing.

        -Inventory is optional: without it the answer is the two-condition
        answer, which is never wrong, only less complete.
    #>
    param($Item, $Profile, $Inventory)

    if (-not $Profile) { $Profile = Get-WDSystemProfile }
    # Asked only when there is something to ask about. Test-WDGuard answers true
    # for an empty list, so calling it anyway is the same answer at the cost of
    # a parameter bind - and this runs for every item and every action of every
    # item while the window is being built. The great majority carry no guards
    # at all, and skipping those took the whole pass from 238 ms to about 60.
    $ig = @(Get-Prop $Item 'guards' @())
    if ($ig.Count -and -not (Test-WDGuard -Guards $ig -Profile $Profile)) { return $false }

    $acts = @(Get-Prop $Item 'actions' @())
    if (-not $acts.Count) { return $false }

    $appxAll = @()
    $inbox   = @()
    if ($Inventory) { $appxAll = @($Inventory.Appx); $inbox = @($Inventory.Inbox) }

    foreach ($a in $acts) {
        $ag = @(Get-Prop $a 'guards' @())
        if ($ag.Count -and -not (Test-WDGuard -Guards $ag -Profile $Profile)) { continue }
        # A health check is a follow-up to a removal, not a reason to offer one.
        # CoreAI is appx plus VerifyShellHealth, and without this the appx half
        # going inert leaves the item alive on the strength of a step whose own
        # description ends "Changes nothing."
        if ([string]$a.type -eq 'script' -and (Test-WDPassiveHandler -Name ([string](Get-Prop $a 'handler' '')))) { continue }
        if ($appxAll.Count -and [string]$a.type -eq 'appx') {
            $hit = New-Object System.Collections.Generic.List[string]
            foreach ($p in @(Get-Prop $a 'names' @())) {
                if (-not $p) { continue }
                foreach ($n in $appxAll) { if ($n -like $p) { $null = $hit.Add([string]$n) } }
            }
            if ($hit.Count) {
                $free = $false
                foreach ($h in $hit) { if ($inbox -notcontains $h) { $free = $true; break } }
                if (-not $free) { continue }   # every match is in-box: inert
            }
        }
        return $true
    }
    $false
}

function Resolve-WDPresetSelection {
    <#  Item ids a given preset selects, filtered to what applies here.  #>
    param($Categories, [string]$Preset, $Profile, $Inventory)

    if (-not $script:Presets.Contains($Preset)) { throw "Unknown preset '$Preset'" }
    if (-not $Profile) { $Profile = Get-WDSystemProfile }
    $level = $script:Presets[$Preset].Level

    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($cat in $Categories) {
        foreach ($item in @($cat.items)) {
            $t = Get-WDItemTier -Item $item
            if ($t -eq 0 -or $t -gt $level) { continue }
            if (-not (Test-WDItemApplies -Item $item -Profile $Profile -Inventory $Inventory)) { continue }
            $ids.Add([string]$item.id)
        }
    }
    # Emitted unrolled on purpose. Wrapping with the comma operator would make
    # the common inline form @(Resolve-WDPresetSelection ...).Count return 1,
    # because the pipeline would see a single array object rather than N ids.
    $ids.ToArray()
}

function Get-WDPresetSummary {
    <#
        Per-category counts for every preset, which is what the mode-selection
        screen renders. Returns one row per category plus a Totals row.
    #>
    param($Categories, $Profile)

    if (-not $Profile) { $Profile = Get-WDSystemProfile }
    $rows = New-Object System.Collections.Generic.List[psobject]

    foreach ($cat in $Categories) {
        $applicable = @($cat.items | Where-Object { Test-WDItemApplies -Item $_ -Profile $Profile })
        if (-not $applicable.Count) { continue }

        $row = [ordered]@{
            Category = [string]$cat.name
            Total    = $applicable.Count
        }
        foreach ($p in $script:Presets.Keys) {
            $lvl = $script:Presets[$p].Level
            $row[$p] = @($applicable | Where-Object {
                $t = Get-WDItemTier -Item $_
                $t -ne 0 -and $t -le $lvl }).Count
        }
        $rows.Add([pscustomobject]$row)
    }
    ,@($rows)
}

function Add-WDDiscoveredCategories {
    <#
        Merges runtime-discovered software into the category list so it flows
        through the same executors, journal and rollback as curated items.
    #>
    param($Categories, $Discovered)

    $merged = New-Object System.Collections.Generic.List[psobject]
    foreach ($c in $Categories)  { $merged.Add($c) }
    foreach ($c in @($Discovered)) { $merged.Add($c) }
    ,@($merged | Sort-Object order, name)
}

function Resolve-WDPlan {
    <#
        Turns manifest + selection + machine profile into the ordered list of
        work. Items whose guards do not match this machine are dropped here so
        the progress bar reflects real work rather than padded no-ops.
    #>
    param(
        [Parameter(Mandatory)]$Categories,
        [Parameter(Mandatory)][string[]]$Selected,
        $Profile
    )
    if (-not $Profile) { $Profile = Get-WDSystemProfile }
    $sel  = New-WDStringSet $Selected
    $plan = New-Object System.Collections.Generic.List[psobject]

    foreach ($cat in $Categories) {
        foreach ($item in @($cat.items)) {
            if (-not $sel.Contains([string]$item.id)) { continue }

            if (-not (Test-WDGuard -Guards @(Get-Prop $item 'guards' @()) -Profile $Profile)) {
                Write-WDLog "Skipping '$($item.id)': does not apply to this machine." -Level Debug
                # A ticked item that never reaches the plan produces no row, no
                # result, and no line anybody reads - it simply is not in the
                # report. Which guard refused it, in words, is the difference
                # between "the toolkit ignored my selection" and an answer.
                Add-WDTrace -Kind 'plan-skip' -Data @{
                    item   = [string]$item.id
                    name   = [string](Get-Prop $item 'name' $item.id)
                    reason = 'item guards failed'
                    guards = @(Get-Prop $item 'guards' @())
                    why    = [string](Get-WDGuardFailure -Guards @(Get-Prop $item 'guards' @()) -Profile $Profile)
                }
                continue
            }

            # Drop actions guarded to other hardware, so an HP profile never
            # walks through Dell's uninstall list on a Lenovo.
            $actions = @()
            foreach ($a in @(Get-Prop $item 'actions' @())) {
                if (Test-WDGuard -Guards @(Get-Prop $a 'guards' @()) -Profile $Profile) { $actions += $a }
            }
            # Test-WDItemApplies asks these same two questions, and the page now
            # uses it to leave such items off entirely. Both checks stay here
            # anyway: a saved selection from another machine can name an item
            # this one was never offered, and that must be dropped, not run.
            if (-not $actions.Count) {
                Write-WDLog "Skipping '$($item.id)': no applicable actions on this machine." -Level Debug
                Add-WDTrace -Kind 'plan-skip' -Data @{
                    item    = [string]$item.id
                    name    = [string](Get-Prop $item 'name' $item.id)
                    reason  = 'every action was guarded out'
                    dropped = @(Get-Prop $item 'actions' @() | ForEach-Object {
                        [ordered]@{ type = [string](Get-Prop $_ 'type' ''); guards = @(Get-Prop $_ 'guards' @()) }
                    })
                }
                continue
            }

            # The four explanatory fields ride along so the plan can answer for
            # itself afterwards. Get-WDItemMechanics reads a manifest item and a
            # plan item with the same code because Get-Prop's lookup is
            # case-insensitive - which is the reason these are named after the
            # manifest fields rather than after anything in here.
            $plan.Add([pscustomobject]@{
                Id       = [string]$item.id
                Name     = [string](Get-Prop $item 'name' $item.id)
                Category = $cat.name
                # Which half of the page it came from. Carried here because by
                # the time anything downstream wants to know, the category
                # object is gone - and the guards need it: what they re-apply
                # after a feature update is the removals, never the installs.
                Section  = [string](Get-WDItemSection -Item $item -Category $cat)
                Risk     = [int](Get-Prop $item 'risk' 0)
                Order    = [int](Get-Prop $item 'order' 100)
                Reboot   = [bool](Get-Prop $item 'reboot' $false)
                RiskNote = [string](Get-Prop $item 'riskNote' '')
                # The one-line description, carried for the same reason the four
                # below are: the rollback script has to say what an option WAS,
                # and by the time Export-WDUndoScript runs the manifest is not
                # in its hands. Without it the standalone window names an option
                # and counts its changes and never says what it did, which is
                # the gap the Revert page closed months ago.
                Desc     = [string](Get-Prop $item 'desc' '')
                SettingsPath = [string](Get-Prop $item 'settingsPath' '')
                Symptoms = @(Get-Prop $item 'symptoms' @())
                Mechanics = [string](Get-Prop $item 'mechanics' '')
                Actions  = $actions
            })
        }
    }

    # ---- the two steps nobody ticks ---------------------------------------
    #
    # Both follow from the selection rather than sitting on top of it as extra
    # choices, which is why they are not rows: the run that most needed
    # "close revival paths" was always the run where somebody had cleared it.
    #
    # APPENDED TO THE PLAN, not run behind it in a finally, so they are
    # previewable, cancellable, journalled, and reported like every other step.
    # A step the operator cannot see is not made better by being well intentioned.
    if ($plan.Count) {
        # Every action type that can take software off the machine. The paths
        # closed below are all about apps coming back, so a run that only
        # changed settings has nothing for them to do.
        $removals = @('appx','appxPolicy','uninstall','feature','capability')
        $removesApps = $false
        foreach ($pi in $plan) {
            foreach ($a in @($pi.Actions)) {
                if ([string](Get-Prop $a 'type' '') -in $removals) { $removesApps = $true; break }
            }
            if ($removesApps) { break }
        }
        if ($removesApps) {
            $plan.Add([pscustomobject]@{
                Id = 'close-resurrection'; Name = 'Close revival paths'
                Category = 'Double-checks'; Risk = 0; Order = 9997; Reboot = $false
                RiskNote = ''
                SettingsPath = 'Open the toolkit, choose Revert past changes, and untick everything except Close revival paths.'
                Symptoms = @('removed app came back', 'app reinstalled itself', 'store reinstalling apps',
                             'apps keep coming back', 'edge not updating', 'edge updater missing',
                             'suggested apps returned', 'app returned after update')
                Mechanics = 'Deprovisions what this run uninstalled, switches off the content-delivery values that reinstall bundled apps at the next sign-in, sets the consumer-features policy, and disables the push-to-install tasks. The Edge updater is only touched when Edge itself is gone.'
                Actions = @([pscustomobject]@{ type = 'script'; handler = 'CloseResurrectionPaths' })
            })
        }
        if ($removesApps) {
            $plan.Add([pscustomobject]@{
                # After close-resurrection, before the Explorer restart: the
                # sweep should see everything every other step removed, and
                # Start should already be right when the shell reads it again.
                Id = 'clear-stale-shortcuts'; Name = 'Clear shortcuts left pointing at nothing'
                Category = 'Double-checks'; Risk = 0; Order = 9998; Reboot = $false
                RiskNote = ''
                SettingsPath = 'Every one is recycled, so they can be restored from the Recycle Bin, or by running the rollback script.'
                Symptoms = @('removed app still in start menu', 'shortcut does nothing', 'start menu shortcut broken',
                             'app still shows in search', 'uninstalled program still listed', 'dead shortcut',
                             'shortcut says item cannot be found', 'edge still in start menu')
                Mechanics = 'Reads the target of every .lnk in the Start menu and on the desktop, for every account, and recycles the ones whose target no longer exists. Store app shortcuts have no target path and are left alone, as is anything whose target is not a full path.'
                Actions = @([pscustomobject]@{ type = 'script'; handler = 'ClearStaleShortcuts' })
            })
        }
        # Unconditional, and deliberately not gated on "did anything touch the
        # shell". Deciding that from the outside means pattern-matching registry
        # paths, and the cost of getting it wrong is asymmetric: a needless
        # restart is one blink, a missed one is a change the operator wrote,
        # cannot see, and reasonably reads as broken. It also matches what the
        # machine already did - the row this replaces was tier 1, so it ran
        # under every preset anyway.
        $plan.Add([pscustomobject]@{
            Id = 'restart-explorer'; Name = 'Restart Explorer to apply shell changes'
            Category = 'Double-checks'; Risk = 0; Order = 9999; Reboot = $false
            RiskNote = ''
            SettingsPath = 'Nothing to undo - it changed no setting. Explorer is running again by the time the run reports.'
            Symptoms = @('taskbar flickered', 'desktop went blank', 'icons disappeared briefly',
                         'screen flashed at end of run', 'explorer restarted')
            Mechanics = 'Stops and restarts explorer.exe once, at the end. The taskbar, Start menu and context menus read most of their settings at sign-in, so changes written to the registry are invisible until Explorer reads them again.'
            Actions = @([pscustomobject]@{ type = 'script'; handler = 'RestartExplorer' })
        })
    }

    ,($plan | Sort-Object Order, Category, Name)
}

function Get-WDActionTarget {
    <#
        A one-line description of what an action is aimed at, for the trace.

        Every action type names its target in a different field, and a trace
        entry saying only `type: registry` is worthless when the item wrote
        eleven values and one of them failed. Deliberately best-effort and
        deliberately lossy - it is a label to search the trace by, not a
        second copy of the action, which is what the journal already holds
        for the ones that changed something.
    #>
    param($Action)
    if (-not $Action) { return '' }
    $bits = New-Object System.Collections.Generic.List[string]
    foreach ($f in @('handler', 'names', 'ids', 'packages', 'paths', 'match', 'name', 'id', 'path')) {
        $v = Get-Prop $Action $f $null
        if ($null -eq $v -or '' -eq $v) { continue }
        if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
            $bits.Add("$f=" + ((@($v) | Select-Object -First 6) -join ','))
        } else {
            $bits.Add("$f=$v")
        }
    }
    # registry and registryKey carry their targets one level down.
    foreach ($v in @(Get-Prop $Action 'values' @())) {
        $p = [string](Get-Prop $v 'path' '')
        $n = [string](Get-Prop $v 'name' '')
        if ($p) { $bits.Add($(if ($n) { "$p\$n" } else { $p })) }
        if ($bits.Count -ge 8) { break }
    }
    foreach ($f in @('startupType', 'mode', 'scope', 'sub', 'setting')) {
        $v = Get-Prop $Action $f $null
        if ($null -ne $v -and '' -ne $v) { $bits.Add("$f=$v") }
    }
    $out = $bits -join '; '
    if ($out.Length -gt 400) { $out = $out.Substring(0, 397) + '...' }
    $out
}

function Invoke-WDPlan {
    <#
        Executes the plan. Progress is pushed through -Progress rather than
        returned, so a GUI can render it live; the full result set comes back
        at the end for the report.

        -Progress receives a hashtable per event:
            Phase   Start | Item | Done
            Index / Total / Item / Result / Elapsed
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Session,
        $Profile,
        [scriptblock]$Progress,
        [switch]$AllowDownloads,
        [switch]$AllowOwnership,
        # Which accounts' registry hives per-user settings are written into.
        # $null means every account, which is what the command line and the
        # re-apply guards pass and what every release before this one did.
        [string[]]$Accounts,
        # Object with a .Cancel boolean, polled between items, and an optional
        # .SkipItem boolean, polled between the actions of the item currently
        # running. Skip is deliberately weaker than Cancel: it abandons the rest
        # of an item's actions, it cannot interrupt one that is already inside a
        # call. The strongest guarantee available there is Invoke-WDProcess's own
        # timeout, which is what actually bounds a wedged uninstaller.
        $CancelToken
    )

    if (-not $Profile) { $Profile = Get-WDSystemProfile }
    # The "already set" probe reads the registry once per key and keeps it, on
    # the assumption that nothing is writing while the window is being built.
    # A run is precisely when that stops being true, so the cache is dropped
    # here and again at the end.
    Clear-WDRegistryProbeCache
    # Plain assignment, not an if-expression: the value is a collection and can
    # legitimately be empty, and an if-expression puts its result through the
    # pipeline, which unrolls @() to nothing and hands back $null - meaning
    # "every account", the opposite of what was asked.
    $acctScope = $null
    if ($PSBoundParameters.ContainsKey('Accounts')) { $acctScope = @($Accounts) }
    $total   = @($Plan).Count
    $plannedIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($pi in $Plan) { $null = $plannedIds.Add([string]$pi.Id) }
    $results = New-Object System.Collections.Generic.List[psobject]
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()

    $report = {
        param($payload)
        if ($Progress) {
            try { & $Progress $payload | Out-Null } catch { }
        }
    }

    & $report @{ Phase = 'Start'; Index = 0; Total = $total; Elapsed = $sw.Elapsed }

    # The shape of the run, before it starts. What was planned is not
    # recoverable from the results afterwards - a run that dies partway leaves
    # results for the items it reached and no record that the others existed.
    Add-WDTrace -Kind 'run-start' -Data @{
        total          = $total
        preview        = [bool]$Session.Preview
        allowDownloads = [bool]$AllowDownloads
        allowOwnership = [bool]$AllowOwnership
        # $null is "every account", which is not the same as none, and the two
        # have been confused twice in this codebase.
        accounts       = $(if ($null -eq $acctScope) { '<all>' } else { $acctScope })
        items          = @($Plan | ForEach-Object {
            [ordered]@{ id = $_.Id; name = $_.Name; section = [string]$_.Section
                        risk = $_.Risk; actions = @($_.Actions).Count }
        })
    }

    # Loaded once so per-user tweaks reach accounts created after this run.
    $defaultHive = $null
    try {
        $defaultHive = Mount-WDDefaultHive
        Add-WDTrace -Kind 'default-hive' -Data @{ mounted = [bool]$defaultHive; path = [string]$defaultHive }
    } catch {
        Write-WDLog "Default profile hive unavailable: $($_.Exception.Message)" -Level Warn
        Add-WDTrace -Kind 'default-hive' -Data @{ mounted = $false; threw = (Format-WDException $_) }
    }

    $i = 0
    try {
        foreach ($item in $Plan) {
            if ($CancelToken -and $CancelToken.Cancel) {
                Write-WDLog 'Canceled by user. Stopping after the current item.' -Level Warn
                break
            }
            $i++

            # A skip left over from the previous item would silently eat this
            # one. try/catch because the token is a hashtable from the GUI and a
            # pscustomobject from the tests, and only one of them tolerates a
            # key that was never there.
            if ($CancelToken) { try { $CancelToken.SkipItem = $false } catch { } }

            & $report @{ Phase = 'Item'; Index = $i; Total = $total; Item = $item; Result = $null; Elapsed = $sw.Elapsed }
            Write-WDLog "[$i/$total] $($item.Name)" -Level Info -Item $item.Id
            $itemSw = [System.Diagnostics.Stopwatch]::StartNew()

            $context = [pscustomobject]@{
                ItemId         = $item.Id
                Session        = $Session
                Profile        = $Profile
                Preview        = $Session.Preview
                DefaultHive    = $defaultHive
                AllowDownloads = [bool]$AllowDownloads
                AllowOwnership = [bool]$AllowOwnership
                # $null when unbound, because an empty list is a real answer
                # ("no accounts") and must not be what a caller that never
                # mentioned accounts gets.
                Accounts       = $acctScope
                # Handlers that report on machine state need to know what else
                # is in this run, so a simulation can say "that will be closed
                # by an item further down" instead of reporting it as still open.
                PlannedIds     = $plannedIds
                # And the plan itself, for the one handler whose whole output is
                # about the other items: the common issues document. Its rows
                # carry the lookup phrases and the revert instructions, so it
                # needs the items rather than only their ids.
                Plan           = $Plan
            }

            $actionResults = New-Object System.Collections.Generic.List[psobject]
            $ax = 0
            foreach ($action in $item.Actions) {
                $ax++
                # Between actions, not inside one. An item halfway through its
                # actions is recorded as Skipped rather than pretended to be
                # complete, and whatever the earlier actions did is already in
                # the journal, so the rollback still reverses it.
                if ($CancelToken -and $CancelToken.SkipItem) {
                    $actionResults.Add((New-WDResult -Status Skipped -Message 'Skipped at your request while it was running' `
                                                     -Detail 'Its remaining actions did not run. Anything it had already done is in the rollback script.'))
                    Write-WDLog 'Skipped at the operator''s request.' -Level Warn -Item $item.Id
                    break
                }
                $type = [string](Get-Prop $action 'type' '')
                if (-not $script:ActionDispatch.ContainsKey($type)) {
                    $actionResults.Add((New-WDResult -Status Failed -Message "Unknown action type '$type'"))
                    Add-WDTrace -Kind 'action' -Data @{
                        item = $item.Id; index = $ax; of = @($item.Actions).Count
                        type = $type; status = 'Failed'; message = 'unknown action type'
                        target = (Get-WDActionTarget $action); ms = 0
                    }
                    continue
                }
                $fn = $script:ActionDispatch[$type]
                $aSw = [System.Diagnostics.Stopwatch]::StartNew()
                $blew = $null
                try {
                    $r = & $fn -Action $action -Context $context
                    if (-not $r) { $r = New-WDResult -Status Failed -Message 'Executor returned nothing - this is a bug' }
                } catch {
                    # An executor throwing is a bug, but it must not end the run.
                    $blew = Format-WDException $_
                    $r = New-WDResult -Status Failed -Message "Action '$type' threw" -Detail $_.Exception.Message
                    Write-WDLog "Unhandled error in $fn : $($_.Exception.GetType().Name): $($_.Exception.Message)" `
                                -Level Error -Item $item.Id
                    Write-WDLog "  at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" `
                                -Level Error -Item $item.Id
                }
                $aSw.Stop()

                # One trace line per ACTION, which the item-level result cannot
                # give: an item with five actions reports one merged verdict,
                # so "Partial" says something went wrong and nothing about
                # which of the five, against what target, or how long it took.
                Add-WDTrace -Kind 'action' -Data @{
                    item     = $item.Id
                    index    = $ax
                    of       = @($item.Actions).Count
                    type     = $type
                    handler  = [string]$fn
                    target   = (Get-WDActionTarget $action)
                    status   = [string]$r.Status
                    message  = [string]$r.Message
                    detail   = [string]$r.Detail
                    reboot   = [bool]$r.Reboot
                    ms       = [int]$aSw.ElapsedMilliseconds
                    preview  = [bool]$Session.Preview
                    threw    = $blew
                }
                $actionResults.Add($r)
            }

            $rolled = Merge-WDResults -Results $actionResults
            if ($item.Reboot -and $rolled.Status -in @('Removed','Changed','Partial')) { Set-WDRebootNeeded }

            $itemSw.Stop()
            $record = [pscustomobject]@{
                Id       = $item.Id
                Name     = $item.Name
                Category = $item.Category
                Risk     = $item.Risk
                Status   = $rolled.Status
                Message  = $rolled.Message
                Detail   = $rolled.Detail
                # Empty for almost everything. Set when the outcome was reached
                # after a first attempt was refused, so the row can say the
                # thing took another route without wearing a failure's colour.
                Recovered = [string]$rolled.Recovered
                # How long this one took. Without it there is no way to answer
                # "why did that run take twenty minutes" after the fact, and the
                # honest answer is nearly always two or three vendor uninstallers
                # rather than anything the toolkit did.
                Seconds  = [Math]::Round($itemSw.Elapsed.TotalSeconds, 1)
            }
            $results.Add($record)

            $level = switch ($rolled.Status) {
                'Failed'      { 'Error' }
                'Blocked'     { 'Warn' }
                'Partial'     { 'Warn' }
                # Worth reading - something is standing in the way - but not a
                # warning about this run, which is the distinction the status
                # exists to draw.
                'Obstruction' { 'Info' }
                'NotPresent'  { 'Debug' }
                'AlreadySet'  { 'Debug' }
                default       { 'Success' }
            }
            $took = $(if ($record.Seconds -ge 1) { " [$($record.Seconds)s]" } else { '' })
            Write-WDLog "$($rolled.Status): $($rolled.Message)$took" -Level $level -Item $item.Id

            Add-WDTrace -Kind 'item' -Data @{
                index    = $i
                of       = $total
                item     = $item.Id
                name     = $item.Name
                section  = [string]$item.Section
                category = [string]$item.Category
                status   = $rolled.Status
                message  = $rolled.Message
                detail   = $rolled.Detail
                recovered = [string]$rolled.Recovered
                seconds  = $record.Seconds
                # The per-action verdicts alongside the merged one, so the
                # rule that produced Partial can be checked rather than
                # inferred.
                actions  = @($actionResults | ForEach-Object { [string]$_.Status })
            }

            & $report @{ Phase = 'Item'; Index = $i; Total = $total; Item = $item; Result = $record; Elapsed = $sw.Elapsed }
        }
    } finally {
        if ($defaultHive) { Dismount-WDDefaultHive -Hive $defaultHive }
        # Last thing, so it catches everything this run recycled - including
        # items removed before the irreversible flag was even read.
        if ((Test-WDIrreversible) -and -not $Session.Preview) {
            if (Clear-WDRecycleBin) { Write-WDLog 'Recycle Bin emptied.' -Level Warn }
        }
        $sw.Stop()
        # In the finally, so a run that is cancelled or dies inside the loop
        # still closes its own trace. A trace whose last line is an action is
        # indistinguishable from a machine that was switched off, and telling
        # those two apart is most of what this file is for.
        Add-WDTrace -Kind 'run-end' -Data @{
            reached  = $i
            of       = $total
            seconds  = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
            canceled = [bool]($CancelToken -and $CancelToken.Cancel)
            reboot   = [bool]$Session.RebootNeeded
            counts   = ($results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
        }
    }

    # Where the time went, at the foot of the log. A run that took twenty
    # minutes and a log that does not say why is a run nobody can act on, and
    # the answer is almost always a short list rather than a general slowness.
    $slow = @($results | Where-Object { $_.Seconds -ge 5 } | Sort-Object Seconds -Descending | Select-Object -First 10)
    Write-WDLog ("Run finished in {0:n0}s over {1} item(s)." -f $sw.Elapsed.TotalSeconds, $i) -Level Info
    if ($slow.Count) {
        Write-WDLog 'Slowest items:' -Level Info
        foreach ($s in $slow) { Write-WDLog ("  {0,6:n1}s  {1}" -f $s.Seconds, $s.Name) -Level Info }
    }

    # Whatever this run wrote, the probe cache is now describing the registry as
    # it was before it.
    Clear-WDRegistryProbeCache
    & $report @{ Phase = 'Done'; Index = $i; Total = $total; Elapsed = $sw.Elapsed; Results = $results }
    ,$results
}

function Merge-WDResults {
    <#
        Item-level verdict from its action results.

        Rules: any success with any failure is Partial, never a clean pass -
        a debloat tool that reports green while leaving half a product behind
        is worse than one that reports the mess.
    #>
    param($Results)

    $r = @($Results)
    if (-not $r.Count) { return New-WDResult -Status NotPresent -Message 'Nothing to do' }

    $succeeded = @($r | Where-Object { $_.Status -in @('Removed','Changed') })
    $failed    = @($r | Where-Object { $_.Status -eq 'Failed' })
    $blocked   = @($r | Where-Object { $_.Status -eq 'Blocked' })
    $skipped   = @($r | Where-Object { $_.Status -eq 'Skipped' })
    # Something in the way rather than something refused. It counts as an
    # unfinished half exactly as Blocked does when anything else succeeded -
    # the item really did stop partway - but on its own it stays what it is,
    # because the whole reason this status exists is that calling it Blocked
    # files it beside a package Windows would not remove.
    $stuck     = @($r | Where-Object { $_.Status -eq 'Obstruction' })
    # Present, and already what this option would make it. A success, and a
    # weaker one than Changed: an item where one action wrote something and
    # another found its value already correct did change the machine.
    $already   = @($r | Where-Object { $_.Status -eq 'AlreadySet' })

    # Wildcard patterns overlap, so identical messages recur; collapse them.
    $msgs   = (@($r | Where-Object { $_.Message } | ForEach-Object { $_.Message }) | Select-Object -Unique) -join '; '
    $detail = (@($r | Where-Object { $_.Detail }  | ForEach-Object { $_.Detail })  | Select-Object -Unique) -join ' | '
    # Carried up so the row can say the outcome was reached the long way round.
    # It never changes the verdict - an action that recovered reports a success
    # status, and this is the sentence explaining how.
    $rec = (@($r | Where-Object { $_.Recovered } | ForEach-Object { $_.Recovered }) | Select-Object -Unique) -join '; '

    # A skip counts as an unfinished half exactly as a failure does. An item the
    # operator abandoned partway through is Partial, not Removed - it did some
    # of what it said and stopped, and reporting it green would be the same lie
    # as reporting a half-uninstalled product green.
    if ($succeeded.Count -and ($failed.Count -or $blocked.Count -or $skipped.Count -or $stuck.Count)) {
        return New-WDResult -Status Partial -Message $msgs -Detail $detail -Recovered $rec
    }
    if ($succeeded.Count) {
        $status = 'Changed'
        if (@($succeeded | Where-Object { $_.Status -eq 'Removed' }).Count) { $status = 'Removed' }
        return New-WDResult -Status $status -Message $msgs -Detail $detail -Recovered $rec
    }
    if ($failed.Count)  { return New-WDResult -Status Failed  -Message $msgs -Detail $detail }
    if ($blocked.Count) { return New-WDResult -Status Blocked -Message $msgs -Detail $detail }
    if ($stuck.Count)   { return New-WDResult -Status Obstruction -Message $msgs -Detail $detail }
    # A stated reason beats a bare "not present": if any action was deliberately
    # skipped and nothing failed, surface that rather than the absence.
    if ($skipped.Count) { return New-WDResult -Status Skipped -Message $msgs -Detail $detail }
    # Nothing to do, and the reason is worth telling apart from absence: the
    # target is here and is already right. That distinction is the whole of why
    # a preview of what you just applied should read as a page of grey.
    if ($already.Count) { return New-WDResult -Status AlreadySet -Message $(if ($msgs) { $msgs } else { 'Already set' }) -Detail $detail }
    New-WDResult -Status NotPresent -Message $(if ($msgs) { $msgs } else { 'Not present' }) -Detail $detail
}

function Export-WDReport {
    param($Results, $Session, $Profile, [string]$PresetName = '')

    $r = @($Results)
    $summary = [ordered]@{
        sessionId  = $Session.Id
        started    = $Session.Started.ToString('o')
        finished   = (Get-Date).ToString('o')
        preview    = $Session.Preview
        # Which selection this was. Absent for the whole of this file's life,
        # which made "has this preset been applied here" unanswerable from the
        # run history - the ids were recorded and the name they went by was not.
        preset     = $PresetName
        reboot     = $Session.RebootNeeded
        machine    = [ordered]@{
            name    = $Profile.ComputerName
            os      = "$($Profile.Caption) $($Profile.DisplayVersion) (build $($Profile.Build).$($Profile.UBR))"
            edition = $Profile.Edition
            vendor  = $Profile.Vendor
            model   = $Profile.Model
            chassis = $(if ($Profile.IsPortable) { 'laptop' } else { 'desktop' })
        }
        counts     = [ordered]@{
            total      = $r.Count
            removed    = @($r | Where-Object Status -eq 'Removed').Count
            changed    = @($r | Where-Object Status -eq 'Changed').Count
            alreadySet = @($r | Where-Object Status -eq 'AlreadySet').Count
            notPresent = @($r | Where-Object Status -eq 'NotPresent').Count
            obstruction= @($r | Where-Object Status -eq 'Obstruction').Count
            partial    = @($r | Where-Object Status -eq 'Partial').Count
            blocked    = @($r | Where-Object Status -eq 'Blocked').Count
            skipped    = @($r | Where-Object Status -eq 'Skipped').Count
            failed     = @($r | Where-Object Status -eq 'Failed').Count
        }
        items      = $r
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Session.ReportFile -Encoding UTF8
    Write-WDLog "Report written to $($Session.ReportFile)" -Level Success

    # The standing record, here rather than at the two call sites, because the
    # console and the window both come through this function and two places that
    # have to agree about "a run happened" is one place plus a way for them to
    # disagree. It no-ops on a preview and never throws.
    $null = Register-WDRunRecord -Report $summary

    $summary
}

function Save-WDSelection {
    <#
        A saved selection is the ids plus the run options that are a decision
        rather than an item - whether to seize ownership of objects Windows
        refuses, whether vendor cleanup downloads are allowed, and which accounts
        per-user values are written to. Those used to live only against a preset
        name in ui-state.json, so carrying a selection to another machine carried
        the removals and silently left the authority behind.

        -Options is optional, and a file written without it is exactly the file
        this used to write. The reader treats a missing block as "use the mode's
        own defaults", which is what those files have always got.
    #>
    param([string[]]$Selected, [string]$Path, $Options)
    $out = [ordered]@{ saved = (Get-Date).ToString('o'); selected = @($Selected) }
    if ($Options) {
        # Written out whole, including values equal to the shipped default: the
        # file is read on another machine, where "absent" means "whatever this
        # machine defaults to", so omitting a deliberate choice makes one file
        # mean two things.
        #
        # ACCOUNTS STAYS THREE-VALUED: null is EVERY account (what every caller
        # predating the choice passes), [] is none, a list is those. Collapsing
        # null into empty writes to no hive; collapsing empty into null writes to
        # all of them. ConvertTo-Json round-trips both as themselves.
        $acct = $null
        if ($null -ne $Options.Accounts) { $acct = @($Options.Accounts | ForEach-Object { [string]$_ }) }
        $out['options'] = [pscustomobject][ordered]@{
            takeOwnership   = [bool]$Options.TakeOwnership
            vendorDownloads = [bool]$Options.VendorDownloads
            accounts        = $acct
        }
    }
    ([pscustomobject]$out | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Path -Encoding UTF8
    $Path
}

function Import-WDSelection {
    <#
        The ids only, and deliberately still only the ids: every caller wraps
        this in @() and expects a list, so the options are a second question
        asked by Get-WDSelectionOptions rather than a shape change here.
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).selected) } catch { $null }
}

function Get-WDSelectionOptions {
    <#
        The run options a saved selection carries, or $null when it carries none
        - which is every file written before they existed, and is the signal to
        fall back to the mode's own defaults rather than to invent values.

        Accounts is read off the property directly rather than through Get-Prop,
        and that is the whole reason this is a function rather than three lines
        at the call site. Get-Prop's result leaves through the pipeline, the
        pipeline unrolls an empty array to nothing, and the caller therefore
        receives $null - so "write to no account" would arrive as "write to every
        account". That exact bug has already been found twice in this codebase,
        once in Get-WDContextAccounts and once in Invoke-WDPlan, both times in
        the dangerous direction.
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $j = $null
    try { $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
    if (-not $j -or -not $j.PSObject.Properties['options'] -or -not $j.options) { return $null }
    $o = $j.options
    $acct = $null
    if ($o.PSObject.Properties['accounts'] -and $null -ne $o.accounts) {
        $acct = @($o.accounts | ForEach-Object { [string]$_ })
    }
    # A hashtable, which the pipeline does not unroll, so a caller may assign
    # this directly without the ,@() dance every list-returning function here
    # needs.
    @{
        TakeOwnership   = [bool](Get-Prop $o 'takeOwnership' $false)
        VendorDownloads = [bool](Get-Prop $o 'vendorDownloads' $true)
        Accounts        = $acct
    }
}

Export-ModuleMember -Function Import-WDManifest, Resolve-WDPlan, Invoke-WDPlan, Merge-WDResults,
                              Export-WDReport, Save-WDSelection, Import-WDSelection, Get-WDSelectionOptions,
                              Get-WDPresetNames, Get-WDPresetInfo, Get-WDItemTier, Get-WDItemSection,
                              Get-WDSectionNames,
                              Resolve-WDPresetSelection, Get-WDPresetSummary, Add-WDDiscoveredCategories,
                              Test-WDItemApplies
