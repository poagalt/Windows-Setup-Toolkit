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
                # Rebuilt rather than carried, so only the fields named here
                # survive - a new category-level field is dropped silently
                # unless it is added.
                $categories.Add([pscustomobject]@{
                    id      = [string]$cat.id
                    name    = [string](Get-Prop $cat 'name' $cat.id)
                    order   = [int](Get-Prop $cat 'order' 100)
                    section = [string](Get-Prop $cat 'section' 'remove')
                    note    = [string](Get-Prop $cat 'note' '')
                    items   = @($items)
                })
            }
        }
    }

    if (-not $categories.Count) { throw "No usable manifest entries found under $Path" }

    # Category names may carry a {vendor} token so one manifest reads correctly
    # on every brand.
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

# A ladder, not four lists: an item belongs to a preset when its tier is at or
# below that preset's Level.
$script:Presets = [ordered]@{
    Conservative = @{ Level = 1; Blurb = 'Safe on any machine. Nothing here changes behavior, it only removes annoyances like advertising, useless pre-installed apps, AI features, and telemetry.' }
    Balanced     = @{ Level = 2; Blurb = 'The default. Removes most pre-installed apps, dials down app permissions, removes some location services, adds some quality of life fixes, and removes most AI backbone.' }
    Aggressive   = @{ Level = 3; Blurb = 'For power users who run Windows exactly as they please. This option nukes all telemetry, advertising, bloatware, and legacy leftovers, and enables most common quality of life fixes, like disabling startup apps.' }
    Extreme      = @{ Level = 4; Blurb = 'Implements more intense measures to squeeze the remaining bloat juice out of Windows. Do not use this preset unless you know what you are doing - the options it adds over Aggressive are inherently risky in many ways.' }
}

function Get-WDPresetNames { $script:Presets.Keys }
function Get-WDPresetInfo  { param([string]$Name) $script:Presets[$Name] }

function Get-WDItemTier {
    param($Item)

    # Tier 0 is opt-in only - no preset selects it, but Advanced can still tick
    # it.
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
    ,@($script:WDSections)
}

function Test-WDItemApplies {
    param($Item, $Profile, $Inventory)

    if (-not $Profile) { $Profile = Get-WDSystemProfile }
    # Asked only when there is something to ask. Test-WDGuard answers true for
    # an empty list, and this runs for every action of every item while the
    # window builds; skipping the empty case took the pass from 238 ms to 60.
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
        # A health check is a follow-up to a removal, not a reason to offer one
        # - without this, an item whose only live action is a passive handler
        # stays on the page.
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
    # Unrolled on purpose: the comma operator would make the inline
    # @(Resolve-WDPresetSelection ...).Count read 1.
    $ids.ToArray()
}

function Get-WDPresetSummary {
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
    param($Categories, $Discovered)

    $merged = New-Object System.Collections.Generic.List[psobject]
    foreach ($c in $Categories)  { $merged.Add($c) }
    foreach ($c in @($Discovered)) { $merged.Add($c) }
    ,@($merged | Sort-Object order, name)
}

function Resolve-WDPlan {
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
                Add-WDTrace -Kind 'plan-skip' -Data @{
                    item   = [string]$item.id
                    name   = [string](Get-Prop $item 'name' $item.id)
                    reason = 'item guards failed'
                    guards = @(Get-Prop $item 'guards' @())
                    why    = [string](Get-WDGuardFailure -Guards @(Get-Prop $item 'guards' @()) -Profile $Profile)
                }
                continue
            }

            $actions = @()
            foreach ($a in @(Get-Prop $item 'actions' @())) {
                if (Test-WDGuard -Guards @(Get-Prop $a 'guards' @()) -Profile $Profile) { $actions += $a }
            }
            # Test-WDItemApplies asks the same two questions and the page uses
            # it, but both checks stay: a selection saved on another machine can
            # name an item this one was never offered.
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

            # The explanatory fields ride along so the plan can answer for
            # itself later. They are named after the manifest fields because
            # Get-Prop is case-insensitive, which is what lets
            # Get-WDItemMechanics read a manifest item and a plan item with one
            # code path.
            $plan.Add([pscustomobject]@{
                Id       = [string]$item.id
                Name     = [string](Get-Prop $item 'name' $item.id)
                Category = $cat.name
                # Carried because the category object is gone by the time
                # anything downstream asks - and the guards need it: they
                # re-apply removals, never installs.
                Section  = [string](Get-WDItemSection -Item $item -Category $cat)
                Risk     = [int](Get-Prop $item 'risk' 0)
                Order    = [int](Get-Prop $item 'order' 100)
                Reboot   = [bool](Get-Prop $item 'reboot' $false)
                RiskNote = [string](Get-Prop $item 'riskNote' '')
                # Carried for the rollback script, which has to say what an
                # option was long after the manifest is out of reach.
                Desc     = [string](Get-Prop $item 'desc' '')
                SettingsPath = [string](Get-Prop $item 'settingsPath' '')
                Symptoms = @(Get-Prop $item 'symptoms' @())
                Mechanics = [string](Get-Prop $item 'mechanics' '')
                Actions  = $actions
            })
        }
    }

    # Appended to the plan rather than run behind it, so both are previewable,
    # cancellable, journalled, and reported like any other step.
    if ($plan.Count) {
        # The paths closed below are all about apps coming back, so a run that
        # only changed settings has nothing for them to do.
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
                # After close-resurrection and before the Explorer restart: the
                # sweep should see everything else removed, and Start should be
                # right when the shell reads it again.
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
        # Not gated on "did anything touch the shell": deciding that means
        # pattern-matching registry paths, and the costs are asymmetric - a
        # needless restart is one blink, a missed one reads as broken.
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
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Session,
        $Profile,
        [scriptblock]$Progress,
        [switch]$AllowDownloads,
        [switch]$AllowOwnership,
        # $null means every account, which is what the command line and the
        # re-apply guards pass.
        [string[]]$Accounts,
        # .Cancel is polled between items, .SkipItem between the actions of the
        # one running. Skip cannot interrupt a call already in flight.
        $CancelToken
    )

    if (-not $Profile) { $Profile = Get-WDSystemProfile }
    # The probe cache assumes nothing is writing while the window builds. A run
    # is when that stops being true, so it is dropped here and again at the end.
    Clear-WDRegistryProbeCache
    # Plain assignment, not an if-expression: the value is a collection that can
    # be empty, and an if-expression unrolls @() to $null - which means "every
    # account", the opposite of what was asked.
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

    Add-WDTrace -Kind 'run-start' -Data @{
        total          = $total
        preview        = [bool]$Session.Preview
        allowDownloads = [bool]$AllowDownloads
        allowOwnership = [bool]$AllowOwnership
        # $null is every account, which is not the same as none.
        accounts       = $(if ($null -eq $acctScope) { '<all>' } else { $acctScope })
        items          = @($Plan | ForEach-Object {
            [ordered]@{ id = $_.Id; name = $_.Name; section = [string]$_.Section
                        risk = $_.Risk; actions = @($_.Actions).Count }
        })
    }

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

            # A skip left from the previous item would eat this one. try/catch
            # because the token is a hashtable from the GUI and a pscustomobject
            # from the tests, and only one tolerates a key that was never set.
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
                Accounts       = $acctScope
                # So a handler can say "that will be closed by an item further
                # down" rather than reporting it still open.
                PlannedIds     = $plannedIds
                # The plan itself, for the one handler whose output is about the
                # other items: the common issues document needs their text, not
                # just their ids.
                Plan           = $Plan
            }

            $actionResults = New-Object System.Collections.Generic.List[psobject]
            $ax = 0
            foreach ($action in $item.Actions) {
                $ax++
                # Between actions, not inside one: an item stopped partway is
                # Skipped, and whatever its earlier actions did is already
                # journalled.
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
                    # An executor throwing is a bug, but it must not end the
                    # run.
                    $blew = Format-WDException $_
                    $r = New-WDResult -Status Failed -Message "Action '$type' threw" -Detail $_.Exception.Message
                    Write-WDLog "Unhandled error in $fn : $($_.Exception.GetType().Name): $($_.Exception.Message)" `
                                -Level Error -Item $item.Id
                    Write-WDLog "  at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" `
                                -Level Error -Item $item.Id
                }
                $aSw.Stop()

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
                # Set when the outcome was reached after a first attempt was
                # refused, so the row can say so without wearing a failure's
                # colour.
                Recovered = [string]$rolled.Recovered
                Seconds  = [Math]::Round($itemSw.Elapsed.TotalSeconds, 1)
            }
            $results.Add($record)

            $level = switch ($rolled.Status) {
                'Failed'      { 'Error' }
                'Blocked'     { 'Warn' }
                'Partial'     { 'Warn' }
                # Worth reading, but not a warning about this run.
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
                actions  = @($actionResults | ForEach-Object { [string]$_.Status })
            }

            & $report @{ Phase = 'Item'; Index = $i; Total = $total; Item = $item; Result = $record; Elapsed = $sw.Elapsed }
        }
    } finally {
        if ($defaultHive) { Dismount-WDDefaultHive -Hive $defaultHive }
        # Last, so it catches everything the run recycled - including items
        # processed before the irreversible flag was read.
        if ((Test-WDIrreversible) -and -not $Session.Preview) {
            if (Clear-WDRecycleBin) { Write-WDLog 'Recycle Bin emptied.' -Level Warn }
        }
        $sw.Stop()
        # In the finally, so a cancelled or crashed run still closes its trace.
        # A trace ending on an action is indistinguishable from a machine
        # switched off.
        Add-WDTrace -Kind 'run-end' -Data @{
            reached  = $i
            of       = $total
            seconds  = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
            canceled = [bool]($CancelToken -and $CancelToken.Cancel)
            reboot   = [bool]$Session.RebootNeeded
            counts   = ($results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
        }
    }

    $slow = @($results | Where-Object { $_.Seconds -ge 5 } | Sort-Object Seconds -Descending | Select-Object -First 10)
    Write-WDLog ("Run finished in {0:n0}s over {1} item(s)." -f $sw.Elapsed.TotalSeconds, $i) -Level Info
    if ($slow.Count) {
        Write-WDLog 'Slowest items:' -Level Info
        foreach ($s in $slow) { Write-WDLog ("  {0,6:n1}s  {1}" -f $s.Seconds, $s.Name) -Level Info }
    }

    Clear-WDRegistryProbeCache
    & $report @{ Phase = 'Done'; Index = $i; Total = $total; Elapsed = $sw.Elapsed; Results = $results }
    ,$results
}

function Merge-WDResults {
    param($Results)

    $r = @($Results)
    if (-not $r.Count) { return New-WDResult -Status NotPresent -Message 'Nothing to do' }

    $succeeded = @($r | Where-Object { $_.Status -in @('Removed','Changed') })
    $failed    = @($r | Where-Object { $_.Status -eq 'Failed' })
    $blocked   = @($r | Where-Object { $_.Status -eq 'Blocked' })
    $skipped   = @($r | Where-Object { $_.Status -eq 'Skipped' })
    # Counts as an unfinished half exactly as Blocked does when something else
    # succeeded, but on its own it stays Obstruction.
    $stuck     = @($r | Where-Object { $_.Status -eq 'Obstruction' })
    # A success, and weaker than Changed: an item where one action wrote and
    # another was already correct did change the machine.
    $already   = @($r | Where-Object { $_.Status -eq 'AlreadySet' })

    # Wildcard patterns overlap, so identical messages recur.
    $msgs   = (@($r | Where-Object { $_.Message } | ForEach-Object { $_.Message }) | Select-Object -Unique) -join '; '
    $detail = (@($r | Where-Object { $_.Detail }  | ForEach-Object { $_.Detail })  | Select-Object -Unique) -join ' | '
    # Never changes the verdict - it is the sentence explaining how a success
    # was reached.
    $rec = (@($r | Where-Object { $_.Recovered } | ForEach-Object { $_.Recovered }) | Select-Object -Unique) -join '; '

    # A skip is an unfinished half exactly as a failure is: the item did some of
    # what it said and stopped.
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
    # A stated reason beats a bare "not present".
    if ($skipped.Count) { return New-WDResult -Status Skipped -Message $msgs -Detail $detail }
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

    # Here rather than at the two call sites: the console and the window both
    # come through this function, and two places that must agree about "a run
    # happened" is one place plus a way to disagree.
    $null = Register-WDRunRecord -Report $summary

    $summary
}

function Save-WDSelection {
    param([string[]]$Selected, [string]$Path, $Options)
    $out = [ordered]@{ saved = (Get-Date).ToString('o'); selected = @($Selected) }
    if ($Options) {
        # Written whole, defaults included: the file is read on another machine,
        # where an absent value means that machine's default, so omitting a
        # deliberate choice makes one file mean two things.
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
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).selected) } catch { $null }
}

function Get-WDSelectionOptions {
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
    # A hashtable, which the pipeline does not unroll, so callers can assign
    # this directly without the ,@() dance.
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
