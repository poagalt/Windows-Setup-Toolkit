<#
    WD.UITest - the interaction harness. Not imported on any ordinary launch;
    Show-WDWindow loads it only when -SelfTestSeconds is set.

    IT LIVED INSIDE Show-WDWindow, as 5,897 lines in the tick of a
    DispatcherTimer, which made 28% of the window builder test code and put the
    whole of it behind a closure that captured the frame implicitly. What it
    needed from that frame was never stated anywhere - it was 117 aliases of the
    form $somethingL = $something, in one case-insensitive scope, with a comment
    demanding that the block be grepped before anything was added to it. There
    was a duplicate sitting in it when this was written.

    THE INTERFACE IS -Refs, and it is exactly the 131 names below. [6] of the
    self test checks that the object Show-WDWindow builds carries every one of
    them and nothing it does not, so a name added here without being passed is a
    named failure rather than a $null three tests away.

    Every one of the 131 is READ ONLY by this harness - measured, not assumed,
    by taking the names it reads and subtracting the ones it assigns. Nothing
    here writes back to a frame local, so passing them by value costs nothing.
    What it does write is object CONTENTS - $selfTest.Failures above all - and
    those travel by reference exactly as they did before.

    The assertion blocks are closures made inside this function, so anything
    they touch has to be a local here first. That was true when this was a
    timer tick and it is true now; the aliasing below is the same code it was.
#>

function Invoke-WDInteractionTest {
    <#
        Drive the real window through real routed events and report what broke.

        Called from Show-WDWindow's self-test timer, on the dispatcher thread,
        with the window on screen. Constructing the interface proves nothing
        about whether its handlers can see what they close over - that only
        shows up when something is actually clicked.
    #>
    param([Parameter(Mandatory)]$Refs)

    # Show-WDWindow's frame, unpacked. This block IS the interface: 131 names,
    # checked against the caller by [6]. Do not read $Refs below - unpack here
    # and use the plain name, so the moved code is the code it always was.
    $accountChecks          = $Refs.accountChecks
    $accountKeys            = $Refs.accountKeys
    $accountTags            = $Refs.accountTags
    $addLogRow              = $Refs.addLogRow
    $advBuilt               = $Refs.advBuilt
    $advPresetButtons       = $Refs.advPresetButtons
    $advUndo                = $Refs.advUndo
    $advWork                = $Refs.advWork
    $appliedNote            = $Refs.appliedNote
    $appliedRuns            = $Refs.appliedRuns
    $applyFilter            = $Refs.applyFilter
    $applyLogFilter         = $Refs.applyLogFilter
    $applyOrder             = $Refs.applyOrder
    $bandOf                 = $Refs.bandOf
    $baseIds                = $Refs.baseIds
    $BROWSER_ID             = $Refs.BROWSER_ID
    $BROWSER_NONE           = $Refs.BROWSER_NONE
    $browserDefault         = $Refs.browserDefault
    $browserHere            = $Refs.browserHere
    $browserUi              = $Refs.browserUi
    $buildGroups            = $Refs.buildGroups
    $buildRevert            = $Refs.buildRevert
    $Categories             = $Refs.Categories
    $catHeaders             = $Refs.catHeaders
    $checkSelection         = $Refs.checkSelection
    $clearCmpFilters        = $Refs.clearCmpFilters
    $clearFilters           = $Refs.clearFilters
    $clearOverrides         = $Refs.clearOverrides
    $cmpAddButtons          = $Refs.cmpAddButtons
    $cmpBoxes               = $Refs.cmpBoxes
    $cmpButtons             = $Refs.cmpButtons
    $cmpChips               = $Refs.cmpChips
    $cmpDone                = $Refs.cmpDone
    $cmpHead                = $Refs.cmpHead
    $cmpSpyRef              = $Refs.cmpSpyRef
    $cmpState               = $Refs.cmpState
    $consequence            = $Refs.consequence
    $counts                 = $Refs.counts
    $currentDiff            = $Refs.currentDiff
    $CUSTOM_BASE            = $Refs.CUSTOM_BASE
    $diskImpact             = $Refs.diskImpact
    $dropLoaded             = $Refs.dropLoaded
    $EDGE_ID                = $Refs.EDGE_ID
    $edgeExtIds             = $Refs.edgeExtIds
    $effectiveIds           = $Refs.effectiveIds
    $enterRunPage           = $Refs.enterRunPage
    $EXCLUSIONS             = $Refs.EXCLUSIONS
    $FILTER_GROUPS          = $Refs.FILTER_GROUPS
    $filterBoxes            = $Refs.filterBoxes
    $freeBrowsers           = $Refs.freeBrowsers
    $groupCache             = $Refs.groupCache
    $GROUPS                 = $Refs.GROUPS
    $HIDE_ABSENT            = $Refs.HIDE_ABSENT
    $HIDE_APPLIED           = $Refs.HIDE_APPLIED
    $HIDE_OPT_IN            = $Refs.HIDE_OPT_IN
    $indexEntries           = $Refs.indexEntries
    $indexSpy               = $Refs.indexSpy
    $installedIds           = $Refs.installedIds
    $itemDetail             = $Refs.itemDetail
    $itemFacts              = $Refs.itemFacts
    $itemNote               = $Refs.itemNote
    $knownIds               = $Refs.knownIds
    $liveGroups             = $Refs.liveGroups
    $LOADED_KEYS            = $Refs.LOADED_KEYS
    $loadedPresets          = $Refs.loadedPresets
    $loadedRefresh          = $Refs.loadedRefresh
    $logRows                = $Refs.logRows
    $modeCols               = $Refs.modeCols
    $OPT_IN_ONLY            = $Refs.OPT_IN_ONLY
    $overrides              = $Refs.overrides
    $pal                    = $Refs.pal
    $perUserIds             = $Refs.perUserIds
    $phaseMs                = $Refs.phaseMs
    $presetDefaults         = $Refs.presetDefaults
    $presetNames            = $Refs.presetNames
    $presetSelection        = $Refs.presetSelection
    $pumpRun                = $Refs.pumpRun
    $recordApplied          = $Refs.recordApplied
    $registerLoaded         = $Refs.registerLoaded
    $renameLoadedTo         = $Refs.renameLoadedTo
    $reportDropped          = $Refs.reportDropped
    $restoreFactory         = $Refs.restoreFactory
    $REV_GROUPS             = $Refs.REV_GROUPS
    $REV_SORTS              = $Refs.REV_SORTS
    $revApplyOrder          = $Refs.revApplyOrder
    $revBlocks              = $Refs.revBlocks
    $revertPick             = $Refs.revertPick
    $revertRows             = $Refs.revertRows
    $revFilterBoxes         = $Refs.revFilterBoxes
    $revFilterSel           = $Refs.revFilterSel
    $revPaintCounts         = $Refs.revPaintCounts
    $revRailCards           = $Refs.revRailCards
    $revState               = $Refs.revState
    $rowById                = $Refs.rowById
    $rowBytes               = $Refs.rowBytes
    $rowGate                = $Refs.rowGate
    $rows                   = $Refs.rows
    $rowStrips              = $Refs.rowStrips
    $saveAsDefault          = $Refs.saveAsDefault
    $saveLoadedTo           = $Refs.saveLoadedTo
    $saveOutAndLoad         = $Refs.saveOutAndLoad
    $savesFolder            = $Refs.savesFolder
    $selfTest               = $Refs.selfTest
    $setBrowsers            = $Refs.setBrowsers
    $setOverride            = $Refs.setOverride
    $setRowExcluded         = $Refs.setRowExcluded
    $shippedNames           = $Refs.shippedNames
    $shortPreset            = $Refs.shortPreset
    $showPage               = $Refs.showPage
    $sizeFacts              = $Refs.sizeFacts
    $SORTS                  = $Refs.SORTS
    $spyIndex               = $Refs.spyIndex
    $statBlocks             = $Refs.statBlocks
    $state                  = $Refs.state
    $statusFilter           = $Refs.statusFilter
    $storage                = $Refs.storage
    $storageRows            = $Refs.storageRows
    $UA_FIELDS              = $Refs.UA_FIELDS
    $uaAddBtn               = $Refs.uaAddBtn
    $uaBuild                = $Refs.uaBuild
    $uaBuilt                = $Refs.uaBuilt
    $uaControls             = $Refs.uaControls
    $uaExtraAccts           = $Refs.uaExtraAccts
    $uaGenerate             = $Refs.uaGenerate
    $uaHeads                = $Refs.uaHeads
    $uaPaintSummary         = $Refs.uaPaintSummary
    $ui                     = $Refs.ui
    $uiStateOut             = $Refs.uiStateOut
    $UNCHECKED              = $Refs.UNCHECKED
    $updateTally            = $Refs.updateTally
    $win                    = $Refs.win

if ($advBuilt.Done) {
                Write-Host '  DEFER  the item list was built without anyone opening it' -ForegroundColor Red
                $selfTest.Failures++
            }
            # Not $rows.Count - see the note at $win.Show(). Three seconds in,
            # rows legitimately exist: the pre-warm has been building them since
            # the window appeared, which is the whole of what it is for. What
            # must be zero is how many existed BEFORE the window appeared.
            if ([int]$win.Tag.RowsAtShow) {
                Write-Host "  DEFER  $($win.Tag.RowsAtShow) row(s) were built before the window was shown" -ForegroundColor Red
                $selfTest.Failures++
            }
            # The figure the freeze is measured by, and it is measured here
            # rather than after the click: these are the steps that actually ran
            # in the background, on the screen somebody is looking at, with
            # nothing covering the window. A step that runs long here is a
            # window that stops answering for that long.
            Write-Host "  pre-warm : $($advBuilt.Warmed) step(s) in 3s, $($rows.Count) row(s), $($advWork.Count) step(s) left, longest $($advBuilt.Peak)ms at line $($advBuilt.PeakAt)"
            if ($advBuilt.Warmed -lt 5) {
                Write-Host "  DEFER  the pre-warm only managed $($advBuilt.Warmed) step(s) in three seconds" -ForegroundColor Red
                $selfTest.Failures++
            }
            # 400ms, from measurement rather than taste. The list was a single
            # step covering every category, which measured about two seconds
            # every time; sliced, the same machine reports peaks between 190 and
            # 310ms across runs, so the run-to-run spread is wider than anything
            # the slice size changes. A ceiling under that flaps and teaches
            # people to ignore it. This one is here to catch a step going back to
            # seconds, which is the failure that can be felt.
            if ($advBuilt.Peak -gt 400) {
                Write-Host "  DEFER  one background step of the item list build takes $($advBuilt.Peak)ms (line $($advBuilt.PeakAt)), which nothing can interrupt" -ForegroundColor Red
                $selfTest.Failures++
            }
            # The header bar is on screen from the first frame and speaks for the
            # selection, so it has to be right about it with no rows to read.
            $earlyFree = [int64](& $diskImpact).Freed
            # Built the way a person builds it - by clicking Advanced - rather
            # than by calling the builder. The click is the half that can break
            # on its own: the handler reaches the builder through a holder it
            # cannot see directly, and a null there is a button that opens an
            # empty page instead of throwing.
            $sw0 = [Diagnostics.Stopwatch]::StartNew()
            $ui.BtnAdvanced.RaiseEvent(
                (New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            # A step that builds part of a category puts itself back at the
            # front of the list to finish, so "did any row get built twice" is
            # a real question about that mechanism rather than a truism.
            $dupIds = @($rows | Group-Object Id | Where-Object { $_.Count -gt 1 })
            Write-Host "  deferred build : $($sw0.ElapsedMilliseconds)ms on first use, $($rows.Count) rows, longest step under the overlay $($advBuilt.PeakOpen)ms"
            if ($dupIds.Count) {
                Write-Host "  DEFER  $($dupIds.Count) row(s) were built twice: $(@($dupIds | Select-Object -First 4 | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Red
                $selfTest.Failures++
            }
            if (-not $advBuilt.Done) {
                Write-Host '  DEFER  clicking Advanced did not build the page' -ForegroundColor Red
                $selfTest.Failures++
            }
            # And behind the overlay, with the bar actually moving. A build that
            # blocks the thread for seven seconds with nothing on screen is the
            # failure this is meant to avoid, and it is invisible afterwards -
            # by then the overlay is hidden and reset - so the overlay records
            # what it did.
            $veilStats = $win.Tag.Busy.Stats
            if (-not $veilStats.Shown) {
                Write-Host '  DEFER  the page was built with nothing covering the window' -ForegroundColor Red
                $selfTest.Failures++
            } elseif ($veilStats.MaxWidth -le 0) {
                Write-Host '  DEFER  the overlay was shown but its bar never moved' -ForegroundColor Red
                $selfTest.Failures++
            } elseif (-not $veilStats.Full) {
                # This is the case the MaxWidth check above could not see, and it
                # is the one that actually shipped. The pre-warm has had three
                # seconds by the time this runs, so the click drains a list that
                # is already part empty - which is exactly the state the old
                # fixed denominator got wrong, and the bar stopped at whatever
                # share of the categories were left.
                Write-Host ('  DEFER  the bar stopped at ' +
                            "$([int][Math]::Round(100 * $veilStats.MaxWidth / 284))% and the page then appeared") -ForegroundColor Red
                $selfTest.Failures++
            }
            if ($win.Tag.Busy.Panel.Visibility -ne 'Collapsed') {
                Write-Host '  DEFER  the overlay is still up after the build' -ForegroundColor Red
                $selfTest.Failures++
            }
            & $showPage 'PageModes'
            if (-not $rows.Count) {
                Write-Host '  DEFER  building the page produced no rows at all' -ForegroundColor Red
                $selfTest.Failures++
            }
            # THE HAND-OFF LOSES NOTHING, which is the question the two-runner
            # design has to answer and the one a duplicate check cannot: the
            # pre-warm has already emptied part of $advWork by the time somebody
            # clicks, so $ensureAdvanced consumes from the FRONT rather than
            # iterating, and a category that has built eight of its rows puts
            # its own continuation back at the front to finish. An entry left in
            # the list when the page is declared done is a category stranded
            # part-built - rows that exist in no column, on a page that reports
            # itself finished.
            if ($advWork.Count) {
                Write-Host "  DEFER  $($advWork.Count) build step(s) were left behind when the page was declared finished" -ForegroundColor Red
                $selfTest.Failures++
            }
            # And the stronger form of the same question, from the other end:
            # every option this machine was offered has a row. $knownIds is what
            # the category loop filters against, so the two counts are the same
            # question asked of the input and of the output.
            # Fewer, not "different": a row built twice is a separate fault with
            # its own check above, and this one is about rows that never
            # arrived.
            if ($rows.Count -lt $knownIds.Count) {
                Write-Host "  DEFER  $($rows.Count) row(s) were built for $($knownIds.Count) applicable option(s)" -ForegroundColor Red
                $selfTest.Failures++
            }
            $lateFree = [int64](& $diskImpact).Freed
            if ($earlyFree -ne $lateFree) {
                Write-Host "  DEFER  the drive bar said $earlyFree freed before the build and $lateFree after" -ForegroundColor Red
                $selfTest.Failures++
            }
            # The bar reads sizes from $sizeFacts so it can answer with no rows
            # on the page. That is only honest while the two agree, and they are
            # built from the same manifest by two different pieces of code - so
            # every row is checked against its fact, rather than the two being
            # assumed to have stayed in step.
            $drift = @()
            foreach ($r in $rows) {
                $f = $sizeFacts[[string]$r.Id]
                if (-not $f)                        { $drift += "$($r.Id) has no size fact"; continue }
                if ([int64]$f.Delta -ne [int64]$r.Delta) { $drift += "$($r.Id) delta $($f.Delta) vs row $($r.Delta)" }
                if ([int]$f.Blind -ne [int]$r.Blind)     { $drift += "$($r.Id) blind $($f.Blind) vs row $($r.Blind)" }
                # There was an exemption for Recurring here. Its rows were built
                # outside the category loop with a hardcoded category id, so the
                # two sides could not be expected to agree; they are built the
                # same way as every other row now.
                if ([string]$f.CatId -ne [string]$r.CatId) {
                    $drift += "$($r.Id) category $($f.CatId) vs row $($r.CatId)"
                }
            }
            if ($drift.Count) {
                Write-Host "  DEFER  $($drift.Count) row(s) disagree with the size table the bar reads: $(@($drift | Select-Object -First 4) -join '; ')" -ForegroundColor Red
                $selfTest.Failures++
            }
            Write-Host "  theme          : $(if ($pal.Dark) { 'dark' } else { 'light' })"
            Write-Host "  mode columns   : $($modeCols.Count) clickable, $(($presetNames | ForEach-Object { "$_ $(@($modeCols[$_].Bullets).Count)" }) -join ', ') bullet(s)"
            # ColLeft holds category blocks, not rows - one full-width block per
            # category, each with its own pair of columns inside it.
            Write-Host "  advanced rows  : $($rows.Count) in $($ui.ColLeft.Children.Count) Remove categor$(if ($ui.ColLeft.Children.Count -eq 1) { 'y' } else { 'ies' })"
            Write-Host "  protected block: $($ui.ProtectedBlock.Children.Count) elements"
            Write-Host "  always block   : $($ui.AlwaysBlock.Children.Count) elements"
            Write-Host "  storage bar    : $($ui.DiskBar.ColumnDefinitions.Count) segment(s), $(@($storageRows).Count) clean-up(s), $(@($rows | Where-Object { $_.Delta -ne 0 }).Count) row(s) with a size"
            Write-Host "  not here       : $(@($rows | Where-Object { $_.Absent }).Count) of $($rows.Count) row(s) have nothing to act on"
            Write-Host "  filter options : $($filterBoxes.Count) across $(@($FILTER_GROUPS).Count) groups"
            # Entries only. The scroll extent cannot be measured from here -
            # PageAdvanced is Collapsed at this point and a collapsed element
            # has no layout, so it would read zero however it is asked. The jump
            # and highlight are asserted in the interaction test, which runs
            # with the page open and fails rather than skipping if it will not
            # scroll.
            # The clock is not stopped into the last phase any more. It has been
            # running since the window was mounted, so what it holds now is the
            # three seconds this test waited plus the deferred build - neither of
            # which is time before the window appeared, which is what this table
            # is for. The deferred build has its own line above.
            $slow = @($phaseMs.GetEnumerator() | Sort-Object { -[int]$_.Value } | Select-Object -First 8)
            Write-Host ("  build phases   : " + (@($slow | ForEach-Object { "$($_.Key) $([int]$_.Value)ms" }) -join '  |  '))
            # What each order offers. The rail itself is built by the first
            # $applyOrder, which has not run yet, so its entry count here would
            # always be zero - the groups are the thing worth printing anyway.
            foreach ($m in @($GROUPS.Keys)) {
                & $buildGroups $m
                $gs = $(if ($m -eq 'category') { $catHeaders } else { $groupCache[$m] })
                Write-Host ("    {0,-9}: {1}" -f $m, (@($gs | ForEach-Object { "$($_.Name) ($(@($_.Rows).Count))" }) -join '  '))
            }
            Write-Host "  legend entries : $($ui.LegendPanel.Children.Count)"
            # Text is empty once Inlines are used, so read the runs back.
            $bannerText = (($ui.TxtActivePreset.Inlines | ForEach-Object { $_.Text }) -join '')
            Write-Host "  preset banner  : $bannerText"
            Write-Host "  pages          : modes=$($ui.PageModes.Visibility) advanced=$($ui.PageAdvanced.Visibility) revert=$($ui.PageRevert.Visibility) run=$($ui.PageRun.Visibility)"
            Write-Host "  downloads      : $($ui.ChkDownloads.IsChecked)"
            Write-Host "  selected mode  : $($state.Preset)"
            & $buildRevert
            Write-Host "  revert rows    : $($revertRows.Count)"
            foreach ($p in $presetNames) { Write-Host "  preset $p : $($counts[$p]) items" }

            # The two figures the mode columns now quote. A wrong number on the
            # first screen costs more trust than the line buys, so both are
            # re-derived here from $effectiveIds rather than read back off the
            # column that was built from them.
            foreach ($p in $presetNames) {
                if ($p -eq 'Custom') { continue }
                $cq = $consequence[$p]
                if (-not $cq) { Write-Host "  MODE   $p has no consequence figures" -ForegroundColor Red; $selfTest.Failures++; continue }
                $ids = @(& $effectiveIds $p)
                $wantRisky = @($ids | Where-Object { $itemFacts[$_] -and $itemFacts[$_].Risk -ge 2 }).Count
                $wantHere  = @($ids | Where-Object { $itemFacts[$_] -and $itemFacts[$_].Present -ne $false }).Count
                if ([int]$cq.Risky -ne $wantRisky) {
                    Write-Host "  MODE   $p claims $($cq.Risky) risky, the set has $wantRisky" -ForegroundColor Red
                    $selfTest.Failures++
                }
                if ([int]$cq.Here -ne $wantHere) {
                    Write-Host "  MODE   $p claims $($cq.Here) apply here, the set has $wantHere" -ForegroundColor Red
                    $selfTest.Failures++
                }
                if ([int]$cq.Here -gt $counts[$p]) {
                    Write-Host "  MODE   $p claims more items apply than it selects" -ForegroundColor Red
                    $selfTest.Failures++
                }
            }
            Write-Host "  mode facts     : $(($presetNames | Where-Object { $_ -ne 'Custom' } | ForEach-Object { "$_ $($consequence[$_].Here)/$($counts[$_]) here, $($consequence[$_].Risky) risky" }) -join '; ')"

            # Fire real events. Constructing the UI proves nothing about whether
            # its handlers can see the variables they close over - that only
            # shows up when something is actually clicked.
            #
            # Same closure rule applies to this harness: the action blocks below
            # are closures made inside this tick, so everything they touch has to
            # be a local here first.
            Write-Host "  -- interaction --"
            $uiL      = $ui
            $colsL    = $modeCols
            $rowsL    = $rows
            $revL     = $revertRows
            # The revert page's own machinery. Checked against the rest of this
            # block before being added: 128 aliases in one scope, all
            # case-insensitive, and the last collision here turned a function
            # into an array of hashtables three tests away from where it was
            # written.
            $revPickL   = $revertPick
            $revBlocksL = $revBlocks
            $revRailL   = $revRailCards
            $revStateL  = $revState
            $revOrderL  = $revApplyOrder
            $revSelL    = $revFilterSel
            $revBoxesL  = $revFilterBoxes
            $revGrpsL   = $REV_GROUPS
            $revSortsL  = $REV_SORTS
            # Grepped for a collision before it was added, as this block's own
            # comment demands: nothing else in the file is named anything like
            # it, in any case.
            $revCountL  = $revPaintCounts
            $diffL    = $currentDiff
            $addRowL  = $addLogRow
            $filtL    = $statusFilter
            $refilterL= $applyLogFilter
            $logRowsL = $logRows
            $enterRunL= $enterRunPage
            $pumpL    = $pumpRun
            $statsL   = $statBlocks
            $orderL   = $applyOrder
            $ordersL  = $GROUPS
            $sortsL   = $SORTS
            $bandOfL  = $bandOf
            $liveGrpL = $liveGroups
            $headsAllL= $catHeaders
            $catHeadL = $catHeaders
            $idxEntriesL = $indexEntries
            $idxSpyL  = $indexSpy
            # The groups a given order lays out. Wrapped with the comma operator
            # so the caller gets the list rather than its contents.
            # Emitted unrolled, because every caller wraps the call in @(). The
            # comma operator here would hand that @() a single array object and
            # every foreach over it would run exactly once, over nothing.
            #
            # No GetNewClosure: it captures the local scope only, and $buildGroups
            # is a local of the function rather than of this block, so a closure
            # would capture it as $null. Invoked with & it resolves up the scope
            # chain instead.
            $groupsForL = {
                param([string]$Mode)
                if ($Mode -eq 'category') { return $catHeaders }
                & $buildGroups $Mode
                $groupCache[$Mode]
            }
            $spyL     = $spyIndex
            $setOvL   = $setOverride
            $clrOvL   = $clearOverrides
            $exclL    = $setRowExcluded
            $stateL   = $state
            $namesL   = $presetNames
            $baseL    = $baseIds
            $winL     = $win
            $fboxL    = $filterBoxes
            # The label of the one box that subtracts, so the test names it the
            # same way the drop-down does. Same for the two the tests below tick
            # by name.
            $hideAbsentL    = $HIDE_ABSENT
            $hideAppliedL   = $HIDE_APPLIED
            $hideOptInL     = $HIDE_OPT_IN
            $optInOnlyL     = $OPT_IN_ONLY
            $checkedOnlyL   = $CHECKED
            $uncheckedOnlyL = $UNCHECKED
            $renameToL      = $renameLoadedTo
            $clearFiltL = $clearFilters
            $setBrowL   = $setBrowsers
            $rowByIdL   = $rowById
            # The mutual-exclusion table and the tally that enforces it, so the
            # check drives the same path a click does rather than poking rows.
            #
            # NOT $exclL. That name is thirty lines above this one, holding
            # $setRowExcluded, and PowerShell variable names are case-
            # insensitive - so this quietly replaced a function with an array of
            # two hashtables, and three preview tests started reporting that
            # "System.Collections.Hashtable System.Collections.Hashtable" is not
            # a recognized command. The same collision this file has a section
            # about, from the same direction.
            $xruleL     = $EXCLUSIONS
            $rowTallyL  = $updateTally
            $edgeIdL    = $EDGE_ID
            # The extensions that follow Edge out. Empty on a machine with no
            # Edge profile, which the check that reads it skips itself over.
            $edgeExtL   = $edgeExtIds
            $browIdL    = $BROWSER_ID
            $checkSelL  = $checkSelection
            $presetSelL = $presetSelection
            $browUiL    = $browserUi
            $browEdgeL  = @($browserUi.Panels | Where-Object { $_.Kind -eq 'edge' })[0]
            $browAddL   = @($browserUi.Panels | Where-Object { $_.Kind -eq 'add' })[0]
            $noneL      = $BROWSER_NONE
            # Which browsers the machine already has, and which the picker will
            # therefore offer. The tests below used to name Chrome, which is a
            # fine choice on a machine without Chrome and an assertion that the
            # picker must offer something it now deliberately refuses to.
            $browHereL  = $browserHere
            $browFreeL  = $freeBrowsers
            $browDefL   = $browserDefault
            $headsL     = $catHeaders
            $custBaseL  = $CUSTOM_BASE
            $cmpAddL    = $cmpAddButtons
            # The Compare rail's scroll spy, driven directly. It normally runs
            # off ScrollChanged, which the dispatcher raises on the next arrange
            # - and this pass does not give it one.
            $cmpSpyL    = $cmpSpyRef
            $cmpDoneL   = $cmpDone
            $cmpClearL  = $clearCmpFilters
            $cmpBoxesL  = $cmpBoxes
            # The two picker blocks, so the layout check can ask which grid
            # column each one landed in rather than assuming.
            $cmpHeadL   = $cmpHead
            # Which two presets the page is comparing, so the identical-sides
            # case can be set up and checked without reading it back off the
            # buttons that are the thing under test.
            $cmpStateL  = $cmpState
            # Loading a selection from a file, without the file dialog that
            # gates it in the GUI - the same seam every other modal has here.
            $regLoadL    = $registerLoaded
            $dropLoadL   = $dropLoaded
            $loadRefreshL = $loadedRefresh
            $loadedL     = $loadedPresets
            # The seam behind the mode screen's Save, so the pass can save a
            # loaded preset back to its own file without the dialog that asks
            # which file - a dialog blocks, and the question it asks is not the
            # part under test.
            $saveLoadedL = $saveLoadedTo
            $saveOutL    = $saveOutAndLoad
            $inkCountL   = @($LOADED_KEYS).Count
            $savesFolderL = $savesFolder
            # What a preset is called where twelve characters is the budget.
            $shortL      = $shortPreset
            # Everything a load could not honor, as text, so the pass can read
            # the report without the MessageBox that shows it.
            $droppedL    = $reportDropped
            $advBtnsL    = $advPresetButtons
            $shippedL    = $shippedNames
            $presetNamesL = $presetNames
            $cmpBtnsL    = $cmpButtons
            # Ticking a Compare filter box through the box itself, so the test
            # drives the same path a click does rather than poking the set.
            #
            # $cmpBoxesL, not $cmpBoxes - the rule this file keeps re-learning
            # and which the note above $groupsForL already spells out. This block
            # is itself a scriptblock, so GetNewClosure here captures THIS
            # block's locals; the function's $cmpBoxes arrives as $null, and the
            # symptom is a filter panel that plainly holds thirty-six boxes and
            # a test insisting it holds none.
            $cmpTickL   = {
                param([string]$Group, [string]$Name, [bool]$On)
                $b = @($cmpBoxesL | Where-Object { $_.Group -eq $Group -and $_.Name -eq $Name })
                if (-not $b.Count) { throw "no Compare filter box named '$Name' in $Group" }
                $b[0].Box.IsChecked = $On
            }.GetNewClosure()
            $saveDefL   = $saveAsDefault
            $factoryL   = $restoreFactory
            $instIdsL   = $installedIds
            $applyFiltL = $applyFilter
            $stripsL    = $rowStrips
            $gateL      = $rowGate
            $detailL    = $itemDetail
            $catsL      = $Categories
            $uaBuildL   = $uaBuild
            $uaBuiltL   = $uaBuilt
            $uaGenL     = $uaGenerate
            $uaPaintL   = $uaPaintSummary
            $uaCtrlsL   = $uaControls
            $uaFieldsL  = $UA_FIELDS
            $uaHeadsL   = $uaHeads
            $uaAcctsL   = $uaExtraAccts
            $uaAddAcctH = $uaAddBtn
            $effIdsL    = $effectiveIds
            $ovL        = $overrides
            $defsL      = $presetDefaults
            # The applied marker, driven through its two seams rather than by
            # running a real apply - which is not a thing a self test that
            # changes nothing gets to do. $recAppliedL is what the end of an
            # apply calls, $appliedNoteL is what the mode column paints, and
            # $appliedRunsL is the table between them so the pass can put it
            # back the way it found it.
            $appliedNoteL = $appliedNote
            $recAppliedL  = $recordApplied
            $appliedRunsL = $appliedRuns
            $uiOutL     = $uiStateOut
            $advUndoL   = $advUndo
            $storeL     = $storage
            $storeRowsL = $storageRows
            $bytesL     = $rowBytes
            $noteMapL   = $itemNote
            $cmpDetailL = $cmpChips
            $acctBoxL   = $accountChecks
            $acctTagsL  = $accountTags
            $acctKeysL  = $accountKeys
            $perUserL   = $perUserIds
            # Which section a row actually ended up in. In category order a row
            # sits inside its category's own two columns, inside the category
            # block, inside the section's left panel - so "is this panel a
            # direct child of ColLeft" stopped being the question the moment
            # categories became full-width blocks. Walking the logical parents
            # asks the question the tests actually mean, and keeps asking it
            # correctly however many wrappers the layout grows later.
            $secOfL = {
                param($El)
                # The two fixed blocks are as much a part of Extras as its
                # columns are - they sit inside the same box, above them - so a
                # row hosted in one has landed in Extras, not nowhere.
                $map = [ordered]@{ ColLeft = 'remove'; ColRight = 'remove'
                                   AddLeft = 'add';    AddRight = 'add'
                                   ExtraLeft = 'extras'; ExtraRight = 'extras'
                                   RunOptionsBlock = 'extras'; AlwaysBlock = 'extras' }
                $node = $El
                while ($node) {
                    foreach ($k in $map.Keys) { if ($uiL[$k] -eq $node) { return [string]$map[$k] } }
                    $node = $(if ($node -is [Windows.FrameworkElement]) { $node.Parent } else { $null })
                }
                $null
            }.GetNewClosure()
            # The panel a row is directly in, whichever layout put it there.
            $colOfL = {
                param($El)
                $(if ($El -is [Windows.FrameworkElement]) { $El.Parent } else { $null })
            }.GetNewClosure()
            $tickL = {
                param([string]$Group, [string]$Name, [bool]$On)
                $b = @($fboxL | Where-Object { $_.Group -eq $Group -and $_.Name -eq $Name })
                if (-not $b.Count) { throw "no box named '$Name' in the $Group group" }
                $b[0].Box.IsChecked = $On
            }
            $fails = New-Object System.Collections.Generic.List[string]
            $cellText = { param($tb) (($tb.Inlines | ForEach-Object { $_.Text }) -join '') }
            $try = {
                param([string]$what, [scriptblock]$act)
                try { & $act; Write-Host "  OK    $what" }
                catch {
                    # The stack matters more than the message here: a closure
                    # that captured null throws from a line that looks correct.
                    $at = @($_.ScriptStackTrace -split "`n" | Select-Object -First 3) -join ' <- '
                    $fails.Add("$what : $($_.Exception.Message)`n        at $at")
                    Write-Host "  FAIL  $what" -ForegroundColor Red
                }
            }
            $clickBtn = {
                param($b)
                $b.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            }
            $clickEl = {
                param($el)
                $e = New-Object Windows.Input.MouseButtonEventArgs(
                        [Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left)
                $e.RoutedEvent = [Windows.UIElement]::MouseLeftButtonUpEvent
                $el.RaiseEvent($e)
            }
            # Getting to the Compare page is TWO gestures now, and this is the
            # pair of them. The card's button can only name one preset, so it
            # asks which other one to compare against and the answer is a click
            # on another card - which is why a dozen checks that used to press
            # one button now go through here rather than each spelling out the
            # handshake. It picks the other side itself: any preset that is not
            # the one selected will do, and which one is not what those checks
            # are about.
            $goCompare = {
                param([string]$Other)
                $cmpBtn = $uiL.BtnCompare
                & $clickBtn $cmpBtn
                if (-not $Other) {
                    $Other = @($shippedL | Where-Object { $_ -ne [string]$stateL.Preset })[0]
                }
                & $clickEl $colsL[[string]$Other].Border
            }
            # Getting to the list of one run's changes is TWO gestures now, the
            # same shape as Compare: the past-runs page is a card per run, and
            # Show all options on one of them is what opens the list. Answers
            # with $true when it got there, since a machine with no runs at all
            # has nothing to open and that is not a failure.
            $goRevertList = {
                & $clickBtn $uiL.BtnRevert
                $cards = @($uiL.RevHomeCards.Children)
                if (-not $cards.Count) { return $false }
                $open = $null
                foreach ($c in $cards) {
                    if ($c.Tag -and $c.Tag.Open -and $c.Tag.Can) { $open = $c.Tag.Open; break }
                }
                if (-not $open) { return $false }
                & $clickBtn $open
                $true
            }
            # Moving the pointer over something is an interaction like any other,
            # and one that needs no click to happen - so a handler that throws on
            # hover cannot be avoided by not clicking. The rail's did, and took
            # the window down with it.
            $hoverEl = {
                param($el, [bool]$Leave)
                $e = New-Object Windows.Input.MouseEventArgs([Windows.Input.Mouse]::PrimaryDevice, 0)
                $e.RoutedEvent = $(if ($Leave) { [Windows.UIElement]::MouseLeaveEvent }
                                   else        { [Windows.UIElement]::MouseEnterEvent })
                $el.RaiseEvent($e)
            }

            # Every test below reads the page as it is arranged, and the
            # arrangement is a saved preference. Left to inherit it, a third of
            # this pass failed on a machine whose last session ended in Bloat
            # rating - which does not lay the Add section out at all, so the
            # browser picker is legitimately off the page and the PowerToys
            # options legitimately have nowhere to be. That is a test failing on
            # a setting rather than on a defect, and worse, it only happens to
            # somebody who has used the application. The pass starts from the
            # arrangement the application ships with; the handful of tests that
            # are *about* grouping set their own and put this back.
            $stateL.Group = 'category'
            if ($rowsL.Count) { & $orderL }
            # The application opens on the home page now, and almost everything
            # below is about the mode screen or somewhere reached from it. This
            # is the first card, pressed once, rather than each test working out
            # for itself where it is - which is the shape that leaves a geometry
            # check silently measuring a collapsed page.
            & $try 'the home page opens on the three choices' {
                if ($uiL.PageHome.Visibility -ne 'Visible') { throw 'the window did not open on the home page' }
                if ($uiL.StorageBlock.Visibility -ne 'Collapsed') { throw 'the drive bar is up on the home page' }
                foreach ($b in @($uiL.BtnDebloat, $uiL.BtnRevert, $uiL.BtnUnattend)) {
                    if (-not $b) { throw 'a home card is missing' }
                    if (-not $b.IsEnabled) { throw "'$($b.Content)' is not pressable" }
                }
                & $clickBtn $uiL.BtnDebloat
                if ($uiL.PageModes.Visibility -ne 'Visible') { throw 'the first card did not open the mode screen' }
                if ($uiL.PageHome.Visibility -ne 'Collapsed') { throw 'the home page is still up behind it' }
                if ($uiL.StorageBlock.Visibility -ne 'Visible') { throw 'the drive bar did not come back with the page' }
                & $clickBtn $uiL.BtnModesBack
                if ($uiL.PageHome.Visibility -ne 'Visible') { throw 'Back did not return to the home page' }
                & $clickBtn $uiL.BtnDebloat
            }.GetNewClosure()
            # $shippedL, not $namesL, everywhere this pass is about the mode
            # GRID. The two lists were the same until a saved selection could be
            # loaded as a preset, and they are deliberately not the same now: a
            # file joins $presetNames and pointedly does not get a column. Left
            # as $namesL these looked at $modeCols for a name that has no entry
            # there and asked a $null for its Border - which nobody saw until a
            # session that had loaded a file, because with none loaded the two
            # lists still agree. The Compare picker below is the one place that
            # genuinely wants every preset, and it still uses $namesL.
            $ladderL = @($shippedL | Where-Object { $_ -ne 'Custom' })
            foreach ($p in $shippedL) {
                & $try "click mode column '$p'" { & $clickEl $colsL[$p].Border }.GetNewClosure()
            }
            foreach ($p in $shippedL) {
                & $try "click mode column '$p' after re-sort" { & $clickEl $colsL[$p].Border }.GetNewClosure()
            }
            & $try 'the selected card carries the way into the list' {
                # THE CONTAINERS, not the buttons. A button's own Visibility is
                # Visible on all five cards for the whole session - what carries
                # Hidden is the panel holding Show all options and Compare, and
                # Preview itself, which lives in a row of its own so that Save
                # and Reset can share it. Read off the buttons this said all five
                # cards were offering their controls at once.
                foreach ($p in $shippedL) {
                    & $clickEl $colsL[$p].Border
                    foreach ($k in $shippedL) {
                        $want = $(if ($k -eq $p) { 'Visible' } else { 'Hidden' })
                        foreach ($part in @(@{ N = 'the two above Preview'; V = [string]$colsL[$k].Acts.Visibility },
                                            @{ N = 'Preview';              V = [string]$colsL[$k].Go.Visibility })) {
                            # HIDDEN, not Collapsed, and that is the whole reason
                            # the grid does not jump a button's height every time
                            # somebody clicks between two modes: all five cards
                            # share one Auto row and Collapsed takes the space
                            # back.
                            if ($part.V -ne $want) {
                                throw "$k has $($part.N) $($part.V) while $p is selected, wanted $want"
                            }
                        }
                    }
                }
            }.GetNewClosure()
            & $try 'Compare asks which other preset, then goes' {
                & $clickEl $colsL['Balanced'].Border
                & $clickBtn $colsL['Balanced'].Cmp
                if ($uiL.CmpPickBar.Visibility -ne 'Visible') { throw 'nothing asked which other one' }
                if ($uiL.TxtCmpPick.Text -notmatch 'Balanced') { throw "the question reads '$($uiL.TxtCmpPick.Text)'" }
                if ($uiL.PageCompare.Visibility -eq 'Visible') { throw 'it went straight there without asking' }
                # Cancel puts the question away and leaves the page alone.
                & $clickBtn $uiL.BtnCmpPickCancel
                if ($uiL.CmpPickBar.Visibility -ne 'Collapsed') { throw 'Cancel left the question up' }
                if ($uiL.PageModes.Visibility -ne 'Visible') { throw 'Cancel navigated somewhere' }

                # Answering with the SAME card is not a comparison, so it
                # cancels rather than opening a page saying the two are alike.
                & $clickBtn $colsL['Balanced'].Cmp
                & $clickEl $colsL['Balanced'].Border
                if ($uiL.PageCompare.Visibility -eq 'Visible') { throw 'it compared a preset with itself' }
                if ($uiL.CmpPickBar.Visibility -ne 'Collapsed') { throw 'the question survived its own answer' }

                # And answering with another card goes, with both sides set to
                # what was actually picked rather than to whatever the page was
                # comparing last time.
                & $clickBtn $colsL['Balanced'].Cmp
                & $clickEl $colsL['Extreme'].Border
                if ($uiL.PageCompare.Visibility -ne 'Visible') { throw 'answering did not open the comparison' }
                if ($uiL.CmpPickBar.Visibility -ne 'Collapsed') { throw 'the question is still up on the way out' }
                if ([string]$cmpStateL.A -ne 'Balanced' -or [string]$cmpStateL.B -ne 'Extreme') {
                    throw "it is comparing '$($cmpStateL.A)' with '$($cmpStateL.B)'"
                }
                # Picking must not select: the card you were on is still the one
                # selected, or answering a question has quietly changed the run.
                if ([string]$stateL.Preset -ne 'Balanced') { throw "picking selected '$($stateL.Preset)'" }
                & $clickBtn $uiL.BtnCompareBack
            }.GetNewClosure()
            & $try 'the card button opens the list on that preset' {
                & $clickEl $colsL['Aggressive'].Border
                & $clickBtn $colsL['Aggressive'].Open
                if ($uiL.PageAdvanced.Visibility -ne 'Visible') { throw 'the button did not open the list' }
                if ($uiL.PageModes.Visibility -eq 'Visible') { throw 'the mode screen is still up' }
                if ($stateL.Preset -ne 'Aggressive') { throw "landed on '$($stateL.Preset)'" }
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'Custom selects but does not navigate' {
                & $clickEl $colsL['Custom'].Border
                if ($stateL.Preset -ne 'Custom') { throw "preset is '$($stateL.Preset)'" }
                if ($uiL.PageModes.Visibility -ne 'Visible') { throw 'left the mode screen' }
                if ($uiL.PageAdvanced.Visibility -eq 'Visible') { throw 'opened Advanced by itself' }
                # Picking Custom has to leave somebody told where to go next,
                # and "Custom does nothing and says nothing" is the failure this
                # has always been guarding against. It used to be checked on the
                # tally under the grid, which said so in a sentence; the answer
                # is a control on the card itself now, which is a better one -
                # so this asserts the card is offering it rather than that some
                # line of prose mentions it.
                $cu = $colsL['Custom']
                if ([string]$cu.Acts.Visibility -ne 'Visible') { throw 'Custom offers nothing to do next' }
                if ([string]$cu.Open.Content -ne 'Show all options') {
                    throw "Custom's way into the list reads '$($cu.Open.Content)'"
                }
                foreach ($p in $shippedL) {
                    if ($colsL[$p].Blurb.FontWeight -eq 'Bold') { throw "$p's blurb is bold" }
                }
            }.GetNewClosure()
            # The lists are authored, so nothing can check them against the
            # manifest - that is the trade the authored form makes. What can be
            # checked is the shape: every rung says something, Custom says
            # nothing, and no rung restates a line from the rung below it, which
            # is what "ADDS TO PREVIOUS" claims at the top of four columns.
            & $try 'every ladder mode lists what it removes' {
                $seen = @{}
                foreach ($n in $ladderL) {
                    $b = @($colsL[$n].Bullets)
                    if (-not $b.Count) { throw "$n lists nothing" }
                    foreach ($e in $b) {
                        $line = [string]$e
                        if ($line.Trim().Length -lt 4) { throw "$n has an empty bullet" }
                        # A bullet is a phrase, not a paragraph - the column is
                        # about 220px wide and anything longer wraps to four
                        # lines and pushes the button off the card.
                        if ($line.Length -gt 80) { throw "$n's bullet '$line' is $($line.Length) characters" }
                        $key = $line.ToLowerInvariant()
                        if ($seen.ContainsKey($key)) { throw "$n repeats '$line' from $($seen[$key])" }
                        $seen[$key] = $n
                    }
                }
                if (@($colsL['Custom'].Bullets).Count) { throw 'Custom lists removals' }
            }.GetNewClosure()
            # Custom selects no removals. The one thing it does tick is the
            # common issues lookup, which its own column promises - so the
            # assertion is "nothing but that", not "nothing at all".
            & $try 'Advanced from Custom starts empty but for the two records' {
                & $clickBtn $uiL.BtnAdvanced
                $on = @($rowsL | Where-Object { $_.Check.IsChecked -and $custBaseL -notcontains $_.Id })
                if ($on.Count) { throw "$($on.Count) item(s) still ticked, e.g. $($on[0].Id)" }
                foreach ($want in $custBaseL) {
                    $r = @($rowsL | Where-Object { $_.Id -eq $want })
                    if ($r.Count -and -not $r[0].Check.IsChecked) {
                        throw "Custom's column promises $want and it is not selected"
                    }
                }
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            # Five columns have to fit at the smallest window the user can drag
            # to. The mode grid does not scroll sideways, so anything wider is
            # simply cut off.
            & $try 'mode grid fits at minimum width' {
                $was = $winL.Width
                try {
                    $winL.Width = $winL.MinWidth
                    $winL.UpdateLayout()
                    $view = $uiL.ModeGrid.Parent
                    $need = $uiL.ModeGrid.ActualWidth
                    if ($need -and $view.ViewportWidth -and $need -gt $view.ViewportWidth + 0.5) {
                        throw "grid wants $([int]$need)px, viewport is $([int]$view.ViewportWidth)px"
                    }
                } finally { $winL.Width = $was; $winL.UpdateLayout() }
            }.GetNewClosure()
            foreach ($b in @('BtnConservative','BtnBalanced','BtnAggressive','BtnExtreme','BtnCustom')) {
                & $try "click preset button $b" { & $clickBtn $uiL[$b] }.GetNewClosure()
            }
            & $try 'preset edits show on the mode grid' {
                # Drives the same path as answering Yes to "save preset
                # changes", which is modal and therefore untestable directly.
                & $clickEl $colsL['Balanced'].Border
                $base = @($baseL['Balanced'])
                $spare = @($rowsL | Where-Object { $_.Id -notin $base } | Select-Object -First 2 | ForEach-Object { $_.Id })
                $drop  = @($base | Select-Object -First 1)
                if (-not $spare.Count -or -not $drop.Count) { throw 'no items available to fake an edit with' }
                & $setOvL 'Balanced' $spare $drop
                $tot = & $cellText $colsL['Balanced'].Num
                if ($tot -notmatch '\d+ items? added')   { throw "the count reads '$tot'" }
                if ($tot -notmatch '\d+ items? removed') { throw "the count reads '$tot'" }
                # And an untouched preset must stay clean.
                $clean = & $cellText $colsL['Conservative'].Num
                if ($clean -match 'items? (added|removed)') { throw "Conservative reads '$clean'" }
                if ($uiL.PresetEditRow.Visibility -ne 'Visible') { throw 'Save and Reset stayed hidden' }

                # Re-entering Advanced must still show those items as changed.
                # Saving an edit is not the same as it becoming the new normal.
                & $clickBtn $uiL.BtnAdvanced
                $still = @($rowsL | Where-Object { $_.DiffTag.Visibility -eq 'Visible' })
                $ids   = @($still | ForEach-Object { $_.Id })
                foreach ($want in @($spare + $drop)) {
                    if ($want -notin $ids) { throw "'$want' lost its changed mark on re-entry" }
                }
                foreach ($rr in $still) {
                    $tag = $(if ($rr.Id -in $drop) { 'removed' } else { 'added' })
                    if ($rr.DiffTag.Text -ne $tag) { throw "'$($rr.Id)' is marked '$($rr.DiffTag.Text)', expected '$tag'" }
                }
                & $clickBtn $uiL.BtnBackModes      # no prompt: nothing differs from what is saved

                & $clrOvL
                if ($uiL.PresetEditRow.Visibility -ne 'Collapsed') { throw 'Save and Reset stayed visible' }
                $after = & $cellText $colsL['Balanced'].Num
                if ($after -match 'items? (added|removed)') { throw "reset left '$after'" }
            }.GetNewClosure()
            & $try 'the applied marker appears, and goes when the preset is edited' {
                # Driven through the two seams rather than by running an apply.
                # The marker's whole condition is a comparison, and a comparison
                # is exactly what can be got wrong while the line still appears.
                & $clickEl $colsL['Conservative'].Border
                $ran = @(& $effIdsL 'Conservative')
                if (-not $ran.Count) { throw 'Conservative selects nothing to fake a run with' }

                # A run that IS the preset records; the card then says so.
                if (-not (& $recAppliedL 'Conservative' $ran 'C:\Some\Run Folder')) {
                    throw 'a run matching the preset exactly was not recorded'
                }
                $note = & $appliedNoteL 'Conservative'
                if ($note -notmatch '^Applied on ')          { throw "the marker reads '$note'" }
                if ($note -notmatch 'C:\\Some\\Run Folder')  { throw "the marker does not name the run folder: '$note'" }
                # And it is painted, not just computed.
                & $clickEl $colsL['Conservative'].Border
                if ($colsL['Conservative'].Applied.Visibility -ne 'Visible') { throw 'the card does not show it' }
                if ($colsL['Balanced'].Applied.Visibility -ne 'Collapsed')   { throw 'a preset that was never run shows a marker' }

                # Edit the preset and the marker must go. This is the half that
                # matters: a green line over a mode the machine no longer
                # matches reads as a promise, and it would be a false one.
                $spare = @($rowsL | Where-Object { $_.Id -notin $ran } | Select-Object -First 1 | ForEach-Object { $_.Id })
                if (-not $spare.Count) { throw 'no item available to fake an edit with' }
                & $setOvL 'Conservative' $spare @()
                if (& $appliedNoteL 'Conservative') { throw 'the marker survived an edit to the preset' }
                if ($colsL['Conservative'].Applied.Visibility -ne 'Collapsed') { throw 'the card still shows it after an edit' }
                & $clrOvL
                if (-not (& $appliedNoteL 'Conservative')) { throw 'undoing the edit did not bring the marker back' }

                # A run that is NOT the preset records nothing at all. Five rows
                # excluded on the preview page is not an application of the
                # preset, and marking the card as though it were is the lie this
                # test exists to stop.
                $narrowed = @($ran | Select-Object -First ([Math]::Max(1, $ran.Count - 1)))
                if ($narrowed.Count -lt $ran.Count) {
                    if (& $recAppliedL 'Balanced' $narrowed 'C:\Nope') { throw 'a narrowed run was recorded as the preset' }
                    if (& $appliedNoteL 'Balanced') { throw 'a narrowed run left a marker' }
                }

                # It reaches the settings file, unlike an override.
                $out = & $uiOutL
                if (-not $out.PSObject.Properties['applied']) { throw 'the settings payload has no applied map' }
                if (-not $out.applied.PSObject.Properties['Conservative']) { throw 'the applied run was not written out' }

                # Put the table back: this pass is documented as changing
                # nothing, and $saveUiState is gated on NoPrompts so nothing
                # reached disk - but the rest of the pass reads these cards.
                $appliedRunsL.Remove('Conservative')
                & $clickEl $colsL['Conservative'].Border
                if ($colsL['Conservative'].Applied.Visibility -ne 'Collapsed') { throw 'the marker outlived its record' }
            }.GetNewClosure()
            & $try 'every dialog builds in the theme rather than in system white' {
                # ShowDialog blocks the dispatcher with nobody to dismiss it, so
                # the only thing that can be asked headlessly is whether the
                # dialog assembles - which is exactly the half that broke when
                # these were MessageBoxes, because a MessageBox assembles fine
                # and then draws itself white.
                foreach ($shape in @(@('Just so you know.', 'Info', 'OK', 'None'),
                                     @('Really?', 'Confirm', 'YesNo', 'Warning'),
                                     @('It broke.', 'Failed', 'OK', 'Error'),
                                     @('Which one?', 'Pick', 'YesNo', 'Question'),
                                     @('Go on?', 'Hmm', 'OKCancel', 'None'))) {
                    $dlg = Show-WDMessage $shape -BuildOnly
                    if (-not $dlg) { throw "'$($shape[2])/$($shape[3])' built nothing" }
                    if ($dlg.Title -ne $shape[1]) { throw "title is '$($dlg.Title)'" }
                    $dlg.Measure((New-Object Windows.Size(560, 2000)))
                    $dlg.UpdateLayout()
                    # Walk it and insist every piece of text came from the
                    # theme. Black is WPF's default and the tell for an element
                    # that resolved nothing.
                    $stack = New-Object System.Collections.Generic.Stack[object]
                    $stack.Push($dlg.Content)
                    $texts = 0; $btns = 0; $def = 0; $can = 0
                    while ($stack.Count) {
                        $el = $stack.Pop()
                        if ($el -is [Windows.Controls.TextBlock]) {
                            $texts++
                            $b = $el.Foreground
                            if ($b -isnot [Windows.Media.SolidColorBrush] -or
                                $b.Color -eq [Windows.Media.Colors]::Black) {
                                throw "a text block in '$($shape[1])' is not painted from the theme"
                            }
                        }
                        if ($el -is [Windows.Controls.Button]) {
                            $btns++
                            if ($el.IsDefault) { $def++ }
                            if ($el.IsCancel)  { $can++ }
                            if (-not $el.Style) { throw "button '$($el.Content)' picked up no style" }
                        }
                        if ($el -is [Windows.Controls.Panel])            { foreach ($k in $el.Children) { $stack.Push($k) } }
                        elseif ($el -is [Windows.Controls.Border])       { if ($el.Child)   { $stack.Push($el.Child) } }
                        elseif ($el -is [Windows.Controls.ScrollViewer]) { if ($el.Content) { $stack.Push($el.Content) } }
                    }
                    if (-not $texts) { throw "'$($shape[1])' has no message in it" }
                    $want = @{ 'OK' = 1; 'OKCancel' = 2; 'YesNo' = 2; 'YesNoCancel' = 3 }[$shape[2]]
                    if ($btns -ne $want) { throw "'$($shape[2])' drew $btns button(s), expected $want" }
                    # Enter and Escape both have to answer something, or the
                    # dialog is one somebody can only leave with the mouse.
                    if ($def -ne 1) { throw "'$($shape[2])' has $def default button(s)" }
                    if ($can -ne 1) { throw "'$($shape[2])' has $can cancel button(s)" }
                }
                # Long text scrolls rather than running off the screen, which is
                # what the Details panel does on a forty-action item.
                $long = ((1..200 | ForEach-Object { "Registry: HKLM:\SOFTWARE\Long\Path$_ -> V = 0" }) -join "`n")
                $tall = Show-WDMessage @($long, 'Details', 'OK', 'None') -BuildOnly
                $tall.Measure((New-Object Windows.Size(560, 4000)))
                if ($tall.DesiredSize.Height -gt $tall.MaxHeight + 1) {
                    throw "a 200-line message wants $([int]$tall.DesiredSize.Height)px past the $([int]$tall.MaxHeight)px cap"
                }
                # And the two call forms agree - the packed one is what all
                # forty converted sites use.
                $p1 = Show-WDMessage @('x', 'T', 'YesNo', 'Warning') -BuildOnly
                $p2 = Show-WDMessage 'x' 'T' 'YesNo' 'Warning' -BuildOnly
                if ($p1.Title -ne $p2.Title) { throw 'the packed and plain call forms disagree' }
            }.GetNewClosure()
            & $try 'Custom never shows edit deltas' {
                & $clickEl $colsL['Custom'].Border
                & $clickBtn $uiL.BtnAdvanced
                $rowsL[0].Check.IsChecked = $true
                $rowsL[1].Check.IsChecked = $true
                & $setOvL 'Custom' @($rowsL[0].Id, $rowsL[1].Id) @()
                $tot = & $cellText $colsL['Custom'].Num
                if ($tot -match 'items? (added|removed)') { throw "Custom's count reads '$tot'" }
                & $clrOvL
                # Untick before leaving, or Back raises the save prompt and the
                # modal blocks the dispatcher with nobody to dismiss it.
                $rowsL[0].Check.IsChecked = $false
                $rowsL[1].Check.IsChecked = $false
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'Back keeps edits without asking, and drops them when reverted' {
                & $clickEl $colsL['Aggressive'].Border
                & $clickBtn $uiL.BtnAdvanced
                $base  = @($baseL['Aggressive'])
                $spare = @($rowsL | Where-Object { $_.Id -notin $base } | Select-Object -First 1)
                if (-not $spare.Count) { throw 'nothing available to add' }
                $spare[0].Check.IsChecked = $true
                & $clickBtn $uiL.BtnBackModes
                if ($uiL.PageModes.Visibility -ne 'Visible') { throw 'did not return to the mode screen' }
                $tot = & $cellText $colsL['Aggressive'].Num
                if ($tot -notmatch '1 item added') { throw "edit was not kept, the count reads '$tot'" }
                # Undoing the edit must clear the override, not store an empty one.
                & $clickBtn $uiL.BtnAdvanced
                if (-not $spare[0].Check.IsChecked) { throw 'the kept edit did not come back' }
                $spare[0].Check.IsChecked = $false
                & $clickBtn $uiL.BtnBackModes
                $back = & $cellText $colsL['Aggressive'].Num
                if ($back -match 'items? (added|removed)') { throw "reverted edit left '$back'" }
                if ($uiL.PresetEditRow.Visibility -ne 'Collapsed') { throw 'Save and Reset stayed visible' }
            }.GetNewClosure()
            & $try "a group's Select all fills and clears it" {
                & $clickBtn $uiL.BtnAdvanced
                $sec = @($headsL | Where-Object { @($_.Rows).Count -gt 1 } | Select-Object -First 1)
                if (-not $sec.Count) { throw 'no section with more than one row' }
                $mine = @($sec[0].Rows | Where-Object { $_.Check.IsEnabled -and $_.Panel.Visibility -eq 'Visible' })
                if ($mine.Count -lt 2) { throw 'the section has fewer than two usable rows' }

                # A partly-ticked section fills; a full one clears. Assert the
                # section ends up uniform rather than assuming which way.
                $wasAllOn = -not @($mine | Where-Object { -not $_.Check.IsChecked }).Count
                & $clickBtn $sec[0].SelAll
                $odd = @($mine | Where-Object { [bool]$_.Check.IsChecked -eq $wasAllOn })
                if ($odd.Count) { throw "$($odd.Count) row(s) did not follow the heading" }

                & $clickBtn $sec[0].SelAll          # and back the other way
                $odd = @($mine | Where-Object { [bool]$_.Check.IsChecked -ne $wasAllOn })
                if ($odd.Count) { throw "$($odd.Count) row(s) did not toggle back" }

                # It acts on what is on screen, so a filtered-out row is left be.
                # Clear the section first, or rows already ticked would look
                # like rows the heading reached.
                $stateL.Suspend = $true
                try   { foreach ($r in $sec[0].Rows) { $r.Check.IsChecked = $false } }
                finally { $stateL.Suspend = $false }
                & $tickL 'Risk' 'Risky' $true
                $hidden = @($sec[0].Rows | Where-Object { $_.Panel.Visibility -ne 'Visible' })
                if (-not $hidden.Count) {
                    Write-Host '        (every row in this section is risky, filter case unchecked)'
                } else {
                    & $clickBtn $sec[0].SelAll
                    $touched = @($hidden | Where-Object { $_.Check.IsChecked })
                    if ($touched.Count) { throw "$($touched.Count) filtered-out row(s) were ticked anyway" }
                }
                & $clearFiltL
                & $clickBtn $uiL.BtnBalanced     # back to a known state
            }.GetNewClosure()
            & $try 'the mode bars survive a rebuild' {
                # Editing a preset rebuilds the grid without resizing it, and
                # the bars are new objects with no width of their own.
                #
                # The page has to be on screen first. A rebuild while it is
                # collapsed produces borders that were never arranged, so every
                # bar is legitimately NaN - which is a fact about the harness
                # rather than about the bars, and this inherited whichever page
                # the previous test happened to leave open.
                & $clickBtn $uiL.BtnDebloat
                $uiL.ModeGrid.UpdateLayout()
                & $clrOvL
                $before = $colsL['Aggressive'].Fill.Width
                if (-not ($before -gt 0)) { throw "bar started at $before" }
                & $setOvL 'Balanced' @($rowsL[0].Id) @()
                foreach ($n in $ladderL) {
                    $w = $colsL[$n].Fill.Width
                    if (-not ($w -gt 0)) { throw "$n's bar is $w after a rebuild" }
                }
                & $clrOvL
                $uiL.ModeGrid.UpdateLayout()
                # A mode that selects everything it can draws a full bar. The
                # fill used to be sized against the card's width minus a
                # hardcoded 38px inset, so the top rung rendered visibly short
                # of full directly under a line saying it had selected all of
                # them. Measured against the track, ratio 1.0 must cover it.
                foreach ($n in $ladderL) {
                    if ([Math]::Abs([double]$colsL[$n].Ratio - 1.0) -gt 0.0001) { continue }
                    $t = $colsL[$n].Track.ActualWidth
                    $w = $colsL[$n].Fill.Width
                    if ($t -gt 0 -and [Math]::Abs($w - $t) -gt 1.0) {
                        throw "$n selects everything, and its bar is $([int]$w)px of $([int]$t)px"
                    }
                }
            }.GetNewClosure()
            & $try 'toggle an item row'    { & $clickEl $rowsL[0].Panel }.GetNewClosure()
            & $try 'toggle an item box'    { $rowsL[1].Check.IsChecked = -not $rowsL[1].Check.IsChecked }.GetNewClosure()
            & $try 'type in the filter'    { $uiL.TxtFilter.Text = 'copilot' }.GetNewClosure()
            & $try 'clear the filter'      { $uiL.TxtFilter.Text = '' }.GetNewClosure()
            & $try 'open the filter drop-down' { $uiL.BtnFilter.IsChecked = $true }.GetNewClosure()
            & $try 'filter: changed items'     { & $tickL 'View' 'Changed from preset' $true }.GetNewClosure()
            & $try 'clear the filter panel'    { & $clickBtn $uiL.BtnFilterClear }.GetNewClosure()
            & $try 'filter groups combine: OR within, AND across' {
                & $clickBtn $uiL.BtnBalanced        # a known mix of ticked and unticked
                & $clearFiltL
                $catA = $rowsL[0].Category
                $catB = @($rowsL | Where-Object { $_.Category -ne $catA } | Select-Object -First 1).Category
                if (-not $catB) { throw 'only one category on this machine' }

                & $tickL 'Cat' $catA $true
                $onlyA = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                if (@($onlyA | Where-Object { $_.Category -ne $catA }).Count) { throw 'a foreign category survived' }

                & $tickL 'Cat' $catB $true
                $both = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                if ($both.Count -le $onlyA.Count) { throw 'a second category did not widen the list' }
                if (@($both | Where-Object { $_.Category -notin @($catA, $catB) }).Count) { throw 'a third category leaked in' }

                # Risk is a separate group, so it narrows rather than widens.
                & $tickL 'Risk' 'No risk' $true
                $narrow = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                if ($narrow.Count -gt $both.Count) { throw 'adding a risk box widened the list' }
                if (@($narrow | Where-Object { [int]$_.Risk -ne 0 }).Count) { throw 'a risky row survived the No risk filter' }

                # And the count on screen has to agree with what is on screen -
                # both halves of it. The denominator is the visible set, and the
                # numerator is how many of those are ticked, which is the number
                # anyone working through a filter actually wants.
                $selNarrow = @($narrow | Where-Object { $_.Check.IsChecked }).Count
                if ($uiL.TxtFilterCount.Text -ne "$selNarrow of $($narrow.Count) selected  (filtered)") {
                    throw "count reads '$($uiL.TxtFilterCount.Text)', $selNarrow of $($narrow.Count) visible are ticked"
                }
                if ($uiL.BtnFilter.Content -ne 'Filter (3)') { throw "button reads '$($uiL.BtnFilter.Content)'" }

                # The button says how many; the chips say which, and each drops
                # its own. A chip strip that disagrees with $filterSel is worse
                # than no chip strip - it would offer to remove a filter that is
                # not on.
                $chipText = {
                    @($uiL.FilterChips.Children | ForEach-Object {
                        ($_.Child.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] } |
                         ForEach-Object { $_.Text }) -join ''
                    })
                }
                $chips = @(& $chipText)
                foreach ($want in @($catA, $catB, 'No risk')) {
                    if (-not @($chips | Where-Object { $_ -like "$want*" }).Count) {
                        throw "no chip for '$want'; chips are: $($chips -join ' | ')"
                    }
                }
                if ($uiL.FilterChips.Visibility -ne 'Visible') { throw 'the chip strip is hidden while three filters are on' }

                # Clicking one drops exactly that facet.
                $riskChip = @($uiL.FilterChips.Children | Where-Object {
                    (($_.Child.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] } |
                      ForEach-Object { $_.Text }) -join '') -like 'No risk*' })[0]
                & $riskChip.Tag
                if ($uiL.BtnFilter.Content -ne 'Filter (2)') {
                    throw "dropping one chip left the button at '$($uiL.BtnFilter.Content)'"
                }
                if (@(& $chipText | Where-Object { $_ -like 'No risk*' }).Count) { throw 'the dropped chip is still there' }
                & $tickL 'Risk' 'No risk' $true

                # Ticking a row must move it. That is the half that used to
                # freeze: a plain click runs the tally, never the filter.
                $spare = @($narrow | Where-Object { $_.Check.IsEnabled -and -not $_.Check.IsChecked })
                if ($spare.Count) {
                    $spare[0].Check.IsChecked = $true
                    if ($uiL.TxtFilterCount.Text -ne "$($selNarrow + 1) of $($narrow.Count) selected  (filtered)") {
                        throw "ticking a visible row left the count at '$($uiL.TxtFilterCount.Text)'"
                    }
                    $spare[0].Check.IsChecked = $false
                }

                & $clearFiltL
                if ($uiL.BtnFilter.Content -ne 'Filter') { throw "button reads '$($uiL.BtnFilter.Content)' after clearing" }
                $visAll = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                $selAll = @($visAll | Where-Object { $_.Check.IsChecked }).Count
                if ($uiL.TxtFilterCount.Text -ne "$selAll of $($visAll.Count) selected") { throw "count reads '$($uiL.TxtFilterCount.Text)'" }
            }.GetNewClosure()
            # The one box in the drop-down that subtracts instead of narrowing.
            # Every other facet answers "show me only X"; this answers "stop
            # showing me the ones I cannot use", which is not expressible as a
            # positive selection over any of them - so it is worth checking that
            # it takes away exactly the rows it names and nothing else.
            & $try 'the filter can hide options that are not on this machine' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                $absent = @($rowsL | Where-Object { $_.Absent })
                $before = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                & $tickL 'Avail' $hideAbsentL $true
                try {
                    $after = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                    if (@($after | Where-Object { $_.Absent }).Count) {
                        throw 'a "not on this machine" row survived the box that hides them'
                    }
                    # And nothing else went with them. The visible-and-absent
                    # count is what it should have removed, exactly.
                    $wasAbsent = @($before | Where-Object { $_.Absent }).Count
                    if ($after.Count -ne $before.Count - $wasAbsent) {
                        throw "hiding $wasAbsent absent row(s) took the page from $($before.Count) to $($after.Count)"
                    }
                    if ($uiL.BtnFilter.Content -ne 'Filter (1)') { throw "the button reads '$($uiL.BtnFilter.Content)'" }
                } finally { & $tickL 'Avail' $hideAbsentL $false }
                $back = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                if ($back.Count -ne $before.Count) { throw 'unticking it did not bring the rows back' }
                if (-not $absent.Count) { Write-Host '        (nothing on this machine is absent, so only the no-op path ran)' }
            }.GetNewClosure()
            # The third subtracting box, and the one this page most needed: on a
            # machine where a mode has already been applied it leaves exactly the
            # rows a run would still change.
            #
            # Two things are asserted that the tag alone cannot show. Absent and
            # applied must be EXCLUSIVE - both mean "a run finds nothing to do"
            # and a row wearing both says it twice in words that disagree about
            # why - and hiding the applied rows must take away those rows and no
            # others.
            & $try 'the filter can hide options that are already applied' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                $both = @($rowsL | Where-Object { $_.Applied -and $_.Absent })
                if ($both.Count) {
                    throw "$($both.Count) row(s) are tagged both applied and not-on-this-machine, e.g. $($both[0].Id)"
                }
                $before = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                $wasDone = @($before | Where-Object { $_.Applied }).Count
                & $tickL 'Avail' $hideAppliedL $true
                try {
                    $after = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                    if (@($after | Where-Object { $_.Applied }).Count) {
                        throw 'an "already applied" row survived the box that hides them'
                    }
                    if ($after.Count -ne $before.Count - $wasDone) {
                        throw "hiding $wasDone applied row(s) took the page from $($before.Count) to $($after.Count)"
                    }
                } finally { & $tickL 'Avail' $hideAppliedL $false }
                $back = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                if ($back.Count -ne $before.Count) { throw 'unticking it did not bring the rows back' }
                Write-Host "        ($wasDone of $($before.Count) visible option(s) are already applied on this machine)"
            }.GetNewClosure()
            # A row a preset selects must stay operable however finished it is.
            # The tag is a statement about the machine; disabling the box would
            # be a statement about the control, and it would take away the only
            # way to drop that item from the preset - which is exactly why the
            # probe is split in two rather than widened.
            & $try 'an already-applied row a preset selects is still tickable' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                $done = @($rowsL | Where-Object { $_.Applied -and [int]$_.Tier -ne 0 -and -not $_.Gated })
                foreach ($r in @($done | Select-Object -First 8)) {
                    if (-not $r.Check.IsEnabled) { throw "$($r.Id) is already applied and its box was disabled" }
                }
                if (-not $done.Count) { Write-Host '        (no preset-selected row is already applied here)' }
                else { Write-Host "        ($($done.Count) preset-selected row(s) already applied, all still tickable)" }
            }.GetNewClosure()
            # Opt-in only. Two claims, and the second is the one that matters:
            # it selects exactly the rows tagged "opt-in", and it AND-s with the
            # view boxes rather than OR-ing. It sits under the VIEW heading,
            # which is where somebody looks for it, but in a group of its own -
            # boxes inside a group are OR-ed, so a real fourth VIEW box would
            # pass the first half and fail this one, coming back as everything
            # ticked plus everything nobody ticks. Heading and group are
            # different things and this is what keeps them apart.
            & $try 'the filter can narrow to the opt-in options' {
                & $clickBtn $uiL.BtnAdvanced
                & $clickBtn $uiL.BtnBalanced
                & $clearFiltL
                $before = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                $wantOn = @($before | Where-Object { [int]$_.Tier -eq 0 })
                if (-not $wantOn.Count) { throw 'no tier-0 row is on the page, so the box could never do anything' }
                # One of them, ticked by hand - which is the only way an opt-in
                # row is ever ticked, and what makes the intersection below
                # smaller than either side of it. A row that can actually be
                # ticked: a tier-0 option can still be already-done or gated,
                # and those refuse the click for their own good reasons.
                $mine = @($wantOn | Where-Object {
                    $_.Check.IsEnabled -and -not $_.Absent -and -not $_.Done -and -not $_.Requires
                })[0]
                if (-not $mine) { throw 'every opt-in row on the page is disabled, so none of them can be ticked' }
                $mine.Check.IsChecked = $true
                if (-not $mine.Check.IsChecked) { throw "'$($mine.Id)' would not stay ticked" }
                try {
                    & $tickL 'Tier' $optInOnlyL $true
                    $after = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                    $stray = @($after | Where-Object { [int]$_.Tier -ne 0 })
                    if ($stray.Count) { throw "$($stray.Count) row(s) no mode calls opt-in survived, e.g. '$($stray[0].Id)'" }
                    if ($after.Count -ne $wantOn.Count) {
                        throw "$($wantOn.Count) opt-in row(s) were on the page and $($after.Count) came back"
                    }
                    if ($uiL.BtnFilter.Content -ne 'Filter (1)') { throw "the button reads '$($uiL.BtnFilter.Content)'" }
                    # And now the AND. "Checked only" snapshots on the way in, so
                    # it is ticked after the row is.
                    & $tickL 'Tier' $optInOnlyL $false
                    & $tickL 'View' $checkedOnlyL $true
                    try {
                        $justTicked = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' }).Count
                        & $tickL 'Tier' $optInOnlyL $true
                        $both = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                        if ($both.Count -ne 1 -or $both[0].Id -ne $mine.Id) {
                            throw ("ticked + opt-in came back as $($both.Count) row(s); " +
                                   "the two groups are being OR-ed, not AND-ed")
                        }
                        # Printed rather than only asserted, so the numbers show
                        # that "1" is the intersection and not something both
                        # sides would have produced anyway - an OR would read
                        # $($justTicked + $after.Count - 1) here.
                        Write-Host "        ($($after.Count) opt-in, $justTicked ticked, 1 in both)"
                    } finally { & $tickL 'View' $checkedOnlyL $false }
                } finally {
                    & $tickL 'Tier' $optInOnlyL $false
                    $mine.Check.IsChecked = $false
                }
                $back = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                if ($back.Count -ne $before.Count) { throw 'unticking it did not bring the rest back' }
            }.GetNewClosure()
            # A heading's Reset appears only once that group differs from the
            # mode, and it puts back that group and nothing else. The "and
            # nothing else" half is the one worth asserting: the obvious
            # implementation resets against $effectiveIds, which folds in every
            # other group's edits and would quietly undo them too.
            & $try "a group's Reset appears when it differs and puts back only itself" {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                & $clickBtn $uiL.BtnBalanced
                $pair = @($liveGrpL | Where-Object {
                    @($_.Rows | Where-Object { $_.Check.IsEnabled }).Count -ge 1 -and $_.Reset } |
                    Select-Object -First 2)
                if ($pair.Count -lt 2) { throw 'need two groups with a tickable row each' }
                foreach ($g in $pair) {
                    if ($g.Reset.Visibility -ne 'Collapsed') { throw "$($g.Name) offered Reset with nothing changed" }
                }
                $a = @($pair[0].Rows | Where-Object { $_.Check.IsEnabled })[0]
                $b = @($pair[1].Rows | Where-Object { $_.Check.IsEnabled })[0]
                $aWas = [bool]$a.Check.IsChecked
                $bWas = [bool]$b.Check.IsChecked
                $a.Check.IsChecked = -not $aWas
                $b.Check.IsChecked = -not $bWas
                if ($pair[0].Reset.Visibility -ne 'Visible') { throw 'the changed group does not offer Reset' }
                if ($pair[1].Reset.Visibility -ne 'Visible') { throw 'the second changed group does not offer Reset' }

                & $clickBtn $pair[0].Reset
                if ([bool]$a.Check.IsChecked -ne $aWas) { throw 'Reset did not put its own group back' }
                if ($pair[0].Reset.Visibility -ne 'Collapsed') { throw 'Reset stayed on a group it had just put back' }
                # The other group is untouched, and still says so.
                if ([bool]$b.Check.IsChecked -eq $bWas) { throw 'Reset reached into another group' }
                if ($pair[1].Reset.Visibility -ne 'Visible') { throw 'the other group stopped offering Reset' }

                # One gesture, one undo entry.
                & $clickBtn $uiL.BtnAdvUndo
                if ([bool]$a.Check.IsChecked -eq $aWas) { throw 'undoing the reset did not bring the edit back' }

                $b.Check.IsChecked = $bWas
                $a.Check.IsChecked = $aWas
                & $clrOvL
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            # The case a single pass could not do: the group holds both halves
            # of a mutual exclusion, so one of the two rows it has to put back is
            # disabled at the moment the reset starts and only becomes settable
            # once the other has been cleared.
            & $try "a group's Reset puts back a row another tick was holding down" {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                & $clickBtn $uiL.BtnBalanced
                foreach ($x in @($xruleL)) {
                    $src = $rowByIdL[[string]$x.When]
                    $dst = $rowByIdL[[string]$x.Blocks]
                    if (-not $src -or -not $dst) { continue }
                    # Both halves in one group, or resetting it cannot reach the
                    # blocker and the row stays down - which is correct, and not
                    # what this is about.
                    $grp = @($liveGrpL | Where-Object {
                                $_.Reset -and @($_.Rows | Where-Object { [string]$_.Id -eq [string]$x.When }).Count -and
                                              @($_.Rows | Where-Object { [string]$_.Id -eq [string]$x.Blocks }).Count })
                    if (-not $grp.Count) { continue }
                    if (-not $src.Check.IsEnabled -or -not $dst.Check.IsEnabled) { continue }

                    $srcWas = [bool]$src.Check.IsChecked
                    $dstWas = [bool]$dst.Check.IsChecked
                    # Ticking the blocker is what disables and clears the other,
                    # so this one gesture changes both rows.
                    $src.Check.IsChecked = $true
                    if ($dst.Check.IsEnabled) { throw "'$($x.Blocks)' is still tickable with '$($x.When)' on" }
                    if ($grp[0].Reset.Visibility -ne 'Visible') {
                        throw "$($grp[0].Name) does not offer Reset after an exclusion changed two of its rows"
                    }

                    & $clickBtn $grp[0].Reset
                    if ([bool]$src.Check.IsChecked -ne $srcWas) { throw "Reset left '$($x.When)' where it was" }
                    if (-not $dst.Check.IsEnabled) { throw "Reset left '$($x.Blocks)' disabled" }
                    if ([bool]$dst.Check.IsChecked -ne $dstWas) {
                        throw "Reset did not put '$($x.Blocks)' back - it was held down when the reset started"
                    }
                    if ($grp[0].Reset.Visibility -ne 'Collapsed') { throw 'Reset stayed on a group it had put back' }
                    & $clrOvL
                    & $clickBtn $uiL.BtnBackModes
                    return
                }
                throw 'no group holds both halves of an exclusion, so this proves nothing'
            }.GetNewClosure()
            # The other direction, and the pair that rules itself out. Opt-in
            # only narrows to tier 0; this takes tier 0 away. Ticking both would
            # select nothing at all, which is why they disable each other - and
            # they sit in different groups, so the rule cannot be a per-group one.
            & $try 'hiding opt-in options takes them away, and rules out its opposite' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                $before = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                $optIn  = @($before | Where-Object { [int]$_.Tier -eq 0 })
                if (-not $optIn.Count) { throw 'no opt-in row is on the page, so this would prove nothing' }
                & $tickL 'Avail' $hideOptInL $true
                try {
                    $after = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                    $stray = @($after | Where-Object { [int]$_.Tier -eq 0 })
                    if ($stray.Count) {
                        throw "$($stray.Count) opt-in row(s) survived the box that hides them, e.g. '$($stray[0].Id)'"
                    }
                    if ($after.Count -ne $before.Count - $optIn.Count) {
                        throw "hiding $($optIn.Count) opt-in row(s) took the page from $($before.Count) to $($after.Count)"
                    }
                    # Its opposite is out of play while this is on, by name and in
                    # the other group.
                    $twin = @($fboxL | Where-Object { $_.Group -eq 'Tier' -and $_.Name -eq $optInOnlyL })
                    if (-not $twin.Count) { throw 'Opt-in only is not in the drop-down' }
                    if ($twin[0].Box.IsEnabled) { throw 'Opt-in only is still tickable while opt-in rows are hidden' }
                } finally { & $tickL 'Avail' $hideOptInL $false }
                $twin = @($fboxL | Where-Object { $_.Group -eq 'Tier' -and $_.Name -eq $optInOnlyL })
                if (-not $twin[0].Box.IsEnabled) { throw 'Opt-in only did not come back' }
                # And the same rule from the other side.
                & $tickL 'Tier' $optInOnlyL $true
                try {
                    $mine = @($fboxL | Where-Object { $_.Group -eq 'Avail' -and $_.Name -eq $hideOptInL })
                    if (-not $mine.Count) { throw 'Hide opt-in is not in the drop-down' }
                    if ($mine[0].Box.IsEnabled) { throw 'Hide opt-in is still tickable while narrowed to opt-in' }
                } finally { & $tickL 'Tier' $optInOnlyL $false }
                # The two subtracting boxes AND rather than OR: both on hides
                # both kinds, where two selective boxes in one group would show
                # both kinds.
                & $tickL 'Avail' $hideOptInL $true
                & $tickL 'Avail' $hideAbsentL $true
                try {
                    $both = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                    if (@($both | Where-Object { [int]$_.Tier -eq 0 -or $_.Absent }).Count) {
                        throw 'the two hide boxes are being OR-ed, so one of them undid the other'
                    }
                } finally {
                    & $tickL 'Avail' $hideAbsentL $false
                    & $tickL 'Avail' $hideOptInL $false
                }
                $back = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                if ($back.Count -ne $before.Count) { throw 'unticking them did not bring the rows back' }
            }.GetNewClosure()
            # There was a chip here saying "N selected, not shown", offered
            # whenever a filter narrowed away a ticked row, and this test drove
            # it. Both are gone: a filter narrows what is on screen and changes
            # nothing about what is selected, and the footer says so on every
            # pass. What is left is the assertion that it stays gone - the chip
            # strip is where a warning would reappear, and a yellow one in it
            # means something on this page thinks a filter is a hazard.
            & $try 'narrowing the list away from a ticked row raises no alarm' {
                & $clickBtn $uiL.BtnAdvanced
                & $clickBtn $uiL.BtnBalanced
                & $clearFiltL
                $ticked = @($rowsL | Where-Object { $_.Check.IsChecked })
                if ($ticked.Count -lt 2) { throw "Balanced ticked $($ticked.Count) row(s)" }
                $cat = [string]$ticked[0].Category
                & $tickL 'Cat' $cat $true
                $lost = @($rowsL | Where-Object { $_.Check.IsChecked -and $_.Panel.Visibility -ne 'Visible' })
                if (-not $lost.Count) { throw "filtering to '$cat' hid nothing that was ticked" }
                # One chip, and it is the facet that was picked - not a warning
                # about the rows that facet excluded.
                $texts = @($uiL.FilterChips.Children | ForEach-Object {
                    ($_.Child.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] } |
                     ForEach-Object { $_.Text }) -join '' })
                if (@($texts | Where-Object { $_ -like '*not shown*' }).Count) {
                    throw "the not-shown warning is back: '$($texts -join ' / ')'"
                }
                if (-not @($texts | Where-Object { $_ -like "$cat*" }).Count) {
                    throw "the picked facet has no chip: '$($texts -join ' / ')'"
                }
                # And the count says it is speaking for a narrowed page, which is
                # what stands in for the warning.
                if ($uiL.TxtFilterCount.Text -notmatch 'filtered') {
                    throw "the count does not say it is filtered: '$($uiL.TxtFilterCount.Text)'"
                }
                & $clearFiltL
            }.GetNewClosure()
            & $try 'checked and unchecked views are snapshots' {
                & $clickBtn $uiL.BtnBalanced
                & $clearFiltL
                & $tickL 'View' 'Checked only' $true
                $shown = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                if (-not $shown.Count) { throw 'the checked view is empty' }
                if (@($shown | Where-Object { -not $_.Check.IsChecked }).Count) { throw 'an unticked row is in the checked view' }

                # The whole point: unticking must not delete the row you just
                # clicked, and neither must a search afterwards.
                $victim = $shown[0]
                $victim.Check.IsChecked = $false
                if ($victim.Panel.Visibility -ne 'Visible') { throw 'the row vanished when it was unticked' }
                $uiL.TxtFilter.Text = ' '           # trims to empty, but re-runs the filter
                if ($victim.Panel.Visibility -ne 'Visible') { throw 'the row vanished when the filter re-ran' }
                $uiL.TxtFilter.Text = ''

                # Unticking and reticking is how you get a fresh snapshot.
                & $tickL 'View' 'Checked only' $false
                & $tickL 'View' 'Unchecked only' $true
                if ($victim.Panel.Visibility -ne 'Visible') { throw 'the unticked row is missing from the unchecked view' }

                # A bulk preset change invalidates the snapshot, so the snapshot
                # is re-taken - the box stays ticked. It used to untick itself,
                # which answered the staleness by silently throwing away a
                # filter the user had set, while they were looking at the page
                # it had narrowed.
                #
                # In a finally, because a throw between ticking a view box and
                # clearing it strands the filter and every later test then runs
                # against a page narrowed to almost nothing. That has now
                # happened twice.
                try {
                    & $clickBtn $uiL.BtnAggressive
                    $box = @($fboxL | Where-Object { $_.Group -eq 'View' -and $_.Name -eq 'Unchecked only' })
                    if (-not $box.Count -or -not $box[0].Box.IsChecked) {
                        throw 'a preset change cleared the view filter instead of refreshing it'
                    }
                    # And it is the new preset's unticked rows, not the old
                    # preset's - which is the staleness the clearing was for.
                    $stale = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' -and $_.Check.IsChecked })
                    if ($stale.Count) {
                        throw "$($stale.Count) row(s) the new preset ticked are still in the unchecked view"
                    }
                } finally { & $clearFiltL }
            }.GetNewClosure()
            & $try 'close the filter drop-down' { & $clickBtn $uiL.BtnFilterDone }.GetNewClosure()
            # The browser offer itself is modal, so the harness drives what the
            # dialog would have returned and checks everything downstream of it.
            & $try 'the browser picker follows Edge removal in and out' {
                $edge = $rowByIdL[$edgeIdL]
                if (-not $edge) { throw 'Edge removal is missing from the list' }
                if ($rowByIdL.ContainsKey($browIdL)) { throw 'the browser install is listed as its own row' }
                if (-not $browUiL.Strip) { throw 'the strip under Edge removal was never built' }
                if (-not $browAddL)      { throw 'the Add section has no browser picker' }
                # Every browser plus None, and no blank entries: a null name
                # here is what produced an empty radio button once before.
                $labels = @($browEdgeL.Buttons.Keys)
                if ($labels.Count -lt 4) { throw "only $($labels.Count) browser choice(s)" }
                if (@($labels | Where-Object { -not $_ }).Count) { throw 'a blank choice is in the picker' }
                if ($labels -notcontains 'Google Chrome') { throw 'Chrome is not on the list' }
                if (@($browAddL.Buttons.Keys).Count -ne $labels.Count) { throw 'the two pickers offer different lists' }
                # A browser already on the machine is listed and unclickable -
                # listed, because the catalog is what the toolkit can install
                # and hiding an entry would read as not supporting it.
                foreach ($n in @($browHereL)) {
                    foreach ($p in @($browEdgeL, $browAddL)) {
                        if ($p.Buttons[$n].IsEnabled) { throw "$n is already installed and still offered" }
                        if ("$($p.Buttons[$n].Content)" -notlike '*installed*') { throw "$n does not say it is installed" }
                    }
                }
                # Two free browsers are needed below - one to pick, one to add
                # beside it. Every machine this can run on has at least five.
                $free = @($browFreeL)
                if ($free.Count -lt 2) { throw "only $($free.Count) browser(s) left to install" }
                $pick1 = [string]$free[0]
                $pick2 = [string]$free[1]

                # Nobody has ever picked, which is not the same state as having
                # picked None: $null asks, an empty list is an answer.
                $stateL.BrowserPreferred = $null
                & $setBrowL @() $false
                & $clickBtn $uiL.BtnBalanced           # Balanced no longer removes Edge
                if ($edge.Check.IsChecked) { throw 'Balanced still selects Edge removal' }
                if ($browUiL.Strip.Visibility -ne 'Collapsed') { throw 'the strip showed without Edge removal' }
                # The Add block is not tied to Edge - it is an install offered
                # on its own terms, and it stays on the page.
                if ($uiL.BrowserAddBlock.Visibility -ne 'Visible') { throw 'the Add picker vanished with Edge removal' }
                if (@($stateL.BrowserChoices).Count) { throw 'a browser is queued without Edge removal' }

                & $clickBtn $uiL.BtnAggressive         # Aggressive does
                if (-not $edge.Check.IsChecked) { throw 'Aggressive does not select Edge removal' }
                if ($browUiL.Strip.Visibility -ne 'Visible') { throw 'the strip stayed hidden' }
                # Defaulted rather than asked - and what the right default is
                # depends on the machine, so it is asked of the machine. With no
                # browser but Edge, one is queued and it is not one that is
                # already here. With any other browser installed, nothing is
                # queued at all: the only reason to install one is to avoid
                # stranding somebody, and they are not stranded.
                if ($browDefL) {
                    if (@($stateL.BrowserChoices) -join ',' -ne $browDefL) { throw "defaulted to '$($stateL.BrowserChoices -join ', ')', expected $browDefL" }
                    if ($browHereL.Contains([string]$browDefL)) { throw "defaulted to $browDefL, which is already installed" }
                    if (-not $stateL.BrowserAuto) { throw 'a defaulted choice is not marked as one' }
                    if ((& $checkSelL) -notcontains $browIdL) { throw 'the run would not install it' }
                } else {
                    if (-not $browHereL.Count) { throw 'no default browser, and no browser on the machine either' }
                    if (@($stateL.BrowserChoices).Count) {
                        throw "queued '$($stateL.BrowserChoices -join ', ')' on a machine that already has $(@($browHereL) -join ', ')"
                    }
                    if ($stateL.BrowserAuto) { throw 'nothing was queued but the state says it was defaulted' }
                    if ((& $checkSelL) -contains $browIdL) { throw 'the run would install a browser nobody asked for' }
                }

                & $setBrowL @($pick1) $true
                if (@($stateL.BrowserChoices) -join ',' -ne $pick1) { throw 'the choice was not recorded' }
                if ($stateL.BrowserAuto) { throw 'a deliberate pick is still marked as defaulted' }
                if ($browEdgeL.Label.Text -notmatch [regex]::Escape($pick1)) { throw "the strip reads '$($browEdgeL.Label.Text)'" }
                if ($browEdgeL.Buttons[$pick1].FontWeight -ne 'Bold') { throw 'the choice is not marked' }
                # One choice, two pickers: the Add block has to say the same.
                if ($browAddL.Label.Text -notmatch [regex]::Escape($pick1)) { throw "the Add picker reads '$($browAddL.Label.Text)'" }
                if ($browAddL.Buttons[$pick1].FontWeight -ne 'Bold') { throw 'the Add picker did not follow' }

                # Several at once. Clicking a second browser adds it rather than
                # replacing the first: nothing about installing one is a reason
                # not to install another.
                & $clickBtn $browAddL.Buttons[$pick2]
                $both = @($stateL.BrowserChoices)
                if ($both.Count -ne 2) { throw "a second pick gave '$($both -join ', ')'" }
                if ($both -notcontains $pick2 -or $both -notcontains $pick1) { throw "picked '$($both -join ', ')'" }
                # Catalog order, not click order, so both pickers and the run
                # report read the list the same way round.
                if ($both[0] -ne $pick1) { throw "the list came back in click order: '$($both -join ', ')'" }
                if ($browEdgeL.Label.Text -notmatch "$([regex]::Escape($pick1)) and $([regex]::Escape($pick2))") { throw "the strip reads '$($browEdgeL.Label.Text)'" }
                foreach ($n in $both) {
                    if ($browEdgeL.Buttons[$n].FontWeight -ne 'Bold') { throw "$n is not marked on the Edge strip" }
                    if ($browAddL.Buttons[$n].FontWeight  -ne 'Bold') { throw "$n is not marked on the Add picker" }
                }
                if ((& $checkSelL) -notcontains $browIdL) { throw 'two browsers queued nothing' }
                # And clicking one again takes it back off.
                & $clickBtn $browAddL.Buttons[$pick1]
                if (@($stateL.BrowserChoices) -join ',' -ne $pick2) { throw "unticking left '$($stateL.BrowserChoices -join ', ')'" }
                if ($browEdgeL.Buttons[$pick1].FontWeight -eq 'Bold') { throw 'the dropped browser is still marked' }

                # None is a real answer, not a way out of the feature.
                & $clickBtn $browAddL.Buttons[$noneL]
                if (@($stateL.BrowserChoices).Count) { throw 'None still queued a browser' }
                if ((& $checkSelL) -contains $browIdL) { throw 'None still installs something' }
                if ($edge.Check.IsChecked -ne $true) { throw 'None unticked Edge removal' }

                # A browser picked on purpose is an install in its own right, so
                # backing out of Edge removal leaves it alone. Only the one this
                # defaulted to on the user's behalf is withdrawn with it.
                & $setBrowL @($pick2) $true
                $edge.Check.IsChecked = $false
                if (@($stateL.BrowserChoices) -join ',' -ne $pick2) { throw 'unticking Edge dropped a deliberate pick' }
                if ($browUiL.Strip.Visibility -ne 'Collapsed') { throw 'the strip stayed visible' }
                if ((& $checkSelL) -notcontains $browIdL) { throw 'the run would no longer install it' }

                $stateL.BrowserPreferred = $null
                & $setBrowL @() $false
                & $clickBtn $uiL.BtnAggressive         # defaults again, if it defaults at all
                if ($browDefL) {
                    if (-not $stateL.BrowserAuto) { throw 'the default was not marked as defaulted' }
                } else {
                    # Nothing to default to: the machine already has a browser.
                    # Staged, so the withdrawal below is still exercised.
                    & $setBrowL @([string]@($browFreeL)[0]) $false
                    $stateL.BrowserAuto = $true
                }
                & $clickBtn $uiL.BtnConservative
                if (@($stateL.BrowserChoices).Count) { throw 'a gentler preset kept a choice nobody made' }
                if ((& $presetSelL) -contains $browIdL) { throw 'the preset run would still install it' }
            }.GetNewClosure()
            & $try 'the picker follows the filter, and an explicit pick survives' {
                & $clickBtn $uiL.BtnAggressive
                $edge = $rowByIdL[$edgeIdL]
                if (-not $edge.Check.IsChecked) { throw 'Aggressive does not select Edge removal' }

                # The strip is a sibling of the Edge row, not a child, so
                # filtering the row away has to take it along explicitly.
                $uiL.TxtFilter.Text = 'zzz-nothing-matches-this'
                if ($edge.Panel.Visibility -ne 'Collapsed') { throw 'the Edge row survived the filter' }
                if ($browUiL.Strip.Visibility -ne 'Collapsed') { throw 'the strip stayed on screen without its row' }
                # The Add block is not that row's dependant, but it is still part
                # of a page that is being filtered.
                if ($uiL.BrowserAddBlock.Visibility -ne 'Collapsed') { throw 'the Add picker survived a filter matching nothing' }
                $uiL.TxtFilter.Text = ''
                if ($browUiL.Strip.Visibility -ne 'Visible') { throw 'the strip did not come back with its row' }
                if ($uiL.BrowserAddBlock.Visibility -ne 'Visible') { throw 'the Add picker did not come back' }

                # A pick is not the same thing as a queued choice. Going through
                # a mode that leaves Edge alone keeps a deliberate pick queued -
                # it is an install of its own - and coming back must not reset it
                # to the default.
                $keep = [string]@($browFreeL)[-1]
                & $setBrowL @($keep) $true
                & $clickBtn $uiL.BtnConservative
                if (@($stateL.BrowserChoices) -join ',' -ne $keep) { throw 'a gentler preset dropped a deliberate pick' }
                & $clickBtn $uiL.BtnAggressive
                if (@($stateL.BrowserChoices) -join ',' -ne $keep) { throw "the pick came back as '$($stateL.BrowserChoices -join ', ')'" }
                $stateL.BrowserPreferred = $null
                & $setBrowL @() $false
            }.GetNewClosure()
            & $try "Edge's extensions follow the tick, and not the mode" {
                & $clickBtn $uiL.BtnAdvanced
                $edge = $rowByIdL[$edgeIdL]
                if (-not $edge) { throw 'Edge removal is missing from the list' }
                $ext = @(@($edgeExtL) | ForEach-Object { $rowByIdL[[string]$_] } |
                         Where-Object { $_ -and $_.Check.IsEnabled })
                if (-not $ext.Count) {
                    Write-Host '        (no Edge extensions on this machine to follow it)' -ForegroundColor DarkGray
                    return
                }

                # A mode is not a gesture. Picking one that removes Edge must
                # leave these alone: they are tier 0 because an extension is
                # something a person deliberately added, and a preset that
                # silently ticked three extra rows would read as edited from the
                # moment it was selected.
                & $clickBtn $uiL.BtnConservative
                foreach ($r in $ext) { $r.Check.IsChecked = $false }
                & $clickBtn $uiL.BtnAggressive
                if (-not $edge.Check.IsChecked) { throw 'Aggressive does not select Edge removal' }
                $took = @($ext | Where-Object { $_.Check.IsChecked })
                if ($took.Count) { throw "picking a mode ticked $($took.Count) extension(s) nobody asked for" }

                # Ticking the removal by hand does take them.
                $edge.Check.IsChecked = $false
                $edge.Check.IsChecked = $true
                $miss = @($ext | Where-Object { -not $_.Check.IsChecked })
                if ($miss.Count) { throw "$($miss.Count) Edge extension(s) were left behind" }

                # And backing out takes back exactly those.
                $edge.Check.IsChecked = $false
                $left = @($ext | Where-Object { $_.Check.IsChecked })
                if ($left.Count) { throw "$($left.Count) extension(s) stayed ticked after Edge was dropped" }

                # One ticked deliberately beforehand is not this coupling's to
                # withdraw - the same rule a browser picked by name follows.
                $mine = $ext[0]
                $mine.Check.IsChecked = $true
                $edge.Check.IsChecked = $true
                $edge.Check.IsChecked = $false
                if (-not $mine.Check.IsChecked) { throw 'a deliberately ticked extension was withdrawn with Edge' }
                & $clickBtn $uiL.BtnConservative
            }.GetNewClosure()
            & $try 'excluding Edge in the preview withdraws the browser it offered' {
                # The defaulted browser only exists because Edge is going, so
                # dropping Edge from the run drops it too.
                # Through a mode that leaves Edge alone first: that is what puts
                # the question back on the table, so Aggressive defaults again.
                $stateL.BrowserPreferred = $null
                & $setBrowL @() $false
                & $clickBtn $uiL.BtnBalanced
                & $clickBtn $uiL.BtnAggressive
                if ($browDefL) {
                    if (-not $stateL.BrowserAuto) { throw 'Aggressive did not default a browser' }
                } else {
                    # This machine already has a browser, so nothing is
                    # defaulted and there would be nothing to withdraw. Stage
                    # what a default would have left behind, so the withdrawal
                    # is still covered on a machine where it cannot arise.
                    if ($stateL.BrowserAuto) { throw 'a browser was defaulted on a machine that already has one' }
                    & $setBrowL @([string]@($browFreeL)[0]) $false
                    $stateL.BrowserAuto = $true
                }
                & $addRowL 'Removed' 'Uninstall Microsoft Edge' 'detail' $edgeIdL
                & $addRowL 'Changed' 'Install Google Chrome'    'detail' $browIdL
                $edgeTag = $logRowsL[$logRowsL.Count - 2].Element.Tag
                & $exclL $edgeTag $true
                if (-not $stateL.Excluded.Contains($browIdL)) { throw 'the browser survived excluding Edge' }
                & $exclL $edgeTag $false
                if ($stateL.Excluded.Contains($browIdL)) { throw 'the browser stayed excluded when Edge came back' }
                $logRowsL.Clear(); $uiL.LogList.Items.Clear(); $stateL.Excluded.Clear()

                # One asked for by name is not Edge's dependant and stays.
                & $setBrowL @('Mozilla Firefox') $true
                & $addRowL 'Removed' 'Uninstall Microsoft Edge' 'detail' $edgeIdL
                & $addRowL 'Changed' 'Install Mozilla Firefox'  'detail' $browIdL
                $edgeTag = $logRowsL[$logRowsL.Count - 2].Element.Tag
                & $exclL $edgeTag $true
                if ($stateL.Excluded.Contains($browIdL)) { throw 'excluding Edge withdrew a browser asked for on its own' }
                $logRowsL.Clear(); $uiL.LogList.Items.Clear(); $stateL.Excluded.Clear()
                $stateL.BrowserPreferred = $null
                & $setBrowL @() $false
            }.GetNewClosure()
            Write-Host "  modified banner: $((($uiL.TxtActivePreset.Inlines | ForEach-Object { $_.Text }) -join ''))"
            $tagged = @($rowsL | Where-Object { $_.DiffTag.Visibility -eq 'Visible' })
            Write-Host "  marked rows    : $($tagged.Count) -> $((($tagged | ForEach-Object { "$($_.Id)=$($_.DiffTag.Text)" }) -join ', '))"
            & $try 'marks match the banner' {
                $d = & $diffL
                $t = @($rowsL | Where-Object { $_.DiffTag.Visibility -eq 'Visible' }).Count
                if ($t -ne ($d.Added.Count + $d.Removed.Count)) { throw "banner says $($d.Added.Count)+$($d.Removed.Count), $t rows marked" }
                $bold = @($rowsL | Where-Object { $_.DiffTag.Visibility -eq 'Visible' -and $_.Name.FontWeight -ne 'Bold' }).Count
                if ($bold) { throw "$bold marked row(s) are not bold" }
                # The badge is the only count of the selection on this page now -
                # the footer's "N of M selected" is gone - so it has to carry
                # both numbers rather than just the one.
                $txt = (($uiL.TxtActivePreset.Inlines | ForEach-Object { $_.Text }) -join '')
                if ($txt -notmatch ':\s\d+ of \d+ options') { throw "the badge reads '$txt'" }
                if ($txt -match '\s:\s') { throw "the badge has a space before its colon: '$txt'" }
                $n = [int]([regex]::Match($txt, ':\s(\d+) of (\d+) options').Groups[1].Value)
                $of = [int]([regex]::Match($txt, ':\s(\d+) of (\d+) options').Groups[2].Value)
                if ($n -ne @($d.Selected).Count) { throw "the badge counts $n selected, the diff says $(@($d.Selected).Count)" }
                if ($of -ne $rowsL.Count) { throw "the badge says $of options, the page holds $($rowsL.Count)" }
            }.GetNewClosure()
            # Reset presets, Preview, Apply, Revert selected and the risk badge
            # all raise a modal MessageBox, which would block the dispatcher
            # forever with nobody to dismiss it. Those stay manual.
            Write-Host "  SKIP  modal actions (reset presets, preview, apply, risk badge)"
            & $try 'open Advanced'         { & $clickBtn $uiL.BtnAdvanced }.GetNewClosure()
            & $try 'back to modes'         { & $clickBtn $uiL.BtnBackModes }.GetNewClosure()
            & $try 'switching preset in Advanced keeps the edit' {
                & $clrOvL
                & $clickBtn $uiL.BtnAdvanced
                & $clickBtn $uiL.BtnBalanced
                $base  = @($baseL['Balanced'])
                $spare = @($rowsL | Where-Object { $_.Id -notin $base } | Select-Object -First 1)
                if (-not $spare.Count) { throw 'nothing available to add' }
                $spare[0].Check.IsChecked = $true

                # Switching away must not quietly discard it.
                & $clickBtn $uiL.BtnAggressive
                $tot = & $cellText $colsL['Balanced'].Num
                if ($tot -notmatch '1 item added') { throw "Balanced's count reads '$tot'" }

                # And coming back must show it, still marked as a change.
                & $clickBtn $uiL.BtnBalanced
                if (-not $spare[0].Check.IsChecked) { throw 'the edit did not come back' }
                if ($spare[0].DiffTag.Visibility -ne 'Visible') { throw 'the edit is no longer marked' }
                & $clrOvL
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'switching preset says so, and says what it kept' {
                & $clrOvL
                & $clickBtn $uiL.BtnAdvanced
                # Arriving on the page is not a switch. The note must be silent
                # here or it is standing over every visit rather than answering
                # a gesture.
                $uiL.TxtPresetNote.Visibility = 'Collapsed'
                & $clickBtn $uiL.BtnBalanced
                $read = { ($uiL.TxtPresetNote.Inlines | ForEach-Object { $_.Text }) -join '' }
                if ($uiL.TxtPresetNote.Visibility -ne 'Visible') { throw 'nothing was said about the switch' }
                $said = & $read
                if ($said -notmatch 'Balanced') { throw "the note does not name the preset: '$said'" }
                if ($said -notmatch 'option') { throw "the note says nothing about the count: '$said'" }

                # An edit pending when you leave is folded into an override
                # without a word anywhere else, so this is the one place it is
                # ever said out loud.
                $base  = @($baseL['Balanced'])
                $spare = @($rowsL | Where-Object { $_.Id -notin $base -and $_.Check.IsEnabled } | Select-Object -First 1)
                if (-not $spare.Count) { throw 'nothing available to add' }
                $spare[0].Check.IsChecked = $true
                & $clickBtn $uiL.BtnAggressive
                $said = & $read
                if ($said -notmatch 'Aggressive') { throw "the note does not name the new preset: '$said'" }
                if ($said -notmatch 'kept') { throw "the note did not report the kept edit: '$said'" }
                if ($said -notmatch 'Balanced') { throw "the note does not say what was kept: '$said'" }
                & $clrOvL
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'Advanced undoes a run of edits, gesture by gesture' {
                & $clrOvL
                & $clickBtn $uiL.BtnAdvanced
                & $clickBtn $uiL.BtnBalanced
                if ($uiL.BtnAdvUndo.Visibility -ne 'Collapsed') { throw 'a fresh page arrived with an undo stack' }

                # Three single toggles, by the box and by the row - both are
                # gestures, and only one of them raises the box's own Click.
                $picks = @($rowsL | Where-Object { $_.Check.IsEnabled } | Select-Object -First 3)
                if ($picks.Count -lt 3) { throw 'not enough rows to edit' }
                $was = @($picks | ForEach-Object { [bool]$_.Check.IsChecked })
                $picks[0].Check.IsChecked = -not $was[0]; & $clickBtn $picks[0].Check
                $picks[1].Check.IsChecked = -not $was[1]; & $clickBtn $picks[1].Check
                & $clickEl $picks[2].Panel
                if (@($advUndoL).Count -ne 3) { throw "$(@($advUndoL).Count) gesture(s) recorded, expected 3" }
                if ("$($uiL.BtnAdvUndo.Content)" -notmatch '3') { throw "the button reads '$($uiL.BtnAdvUndo.Content)'" }
                for ($i = 2; $i -ge 0; $i--) {
                    & $clickBtn $uiL.BtnAdvUndo
                    if ([bool]$picks[$i].Check.IsChecked -ne $was[$i]) { throw "row $i did not go back" }
                }
                if ($uiL.BtnAdvUndo.Visibility -ne 'Collapsed') { throw 'the empty stack still offers Undo' }

                # A whole section is one gesture, not thirty. Through the group's
                # own Select all button: clicking the heading used to do this and
                # deliberately no longer does anything at all, since a heading
                # beside a collapse control cannot say which of the two a click
                # on it meant.
                $head = $headsL[0]
                $secWas = @($head.Rows | ForEach-Object { [bool]$_.Check.IsChecked })
                & $clickBtn $head.SelAll
                if (@($advUndoL).Count -ne 1) { throw "a section click recorded $(@($advUndoL).Count) entries" }
                & $clickBtn $uiL.BtnAdvUndo
                for ($i = 0; $i -lt $head.Rows.Count; $i++) {
                    if ([bool]$head.Rows[$i].Check.IsChecked -ne $secWas[$i]) { throw 'the section did not go back whole' }
                }
                if ($uiL.BtnAdvUndo.Visibility -ne 'Collapsed') { throw 'one gesture took more than one undo' }

                # The heading itself is inert. This is the half that would fail
                # silently: leave the old handler on and every collapse click
                # near the name also ticks or clears thirty rows, which reads as
                # the collapse button being broken rather than as the heading
                # still being live.
                $inertWas = @($head.Rows | ForEach-Object { [bool]$_.Check.IsChecked })
                & $clickEl $head.Head
                for ($i = 0; $i -lt $head.Rows.Count; $i++) {
                    if ([bool]$head.Rows[$i].Check.IsChecked -ne $inertWas[$i]) {
                        throw 'clicking the group heading still changes the boxes'
                    }
                }
                if (@($advUndoL).Count) { throw 'clicking the group heading recorded an undo entry' }

                # Collapse folds the rows away and leaves the heading, and the
                # sign says which way it goes next.
                if ($head.Grid.Visibility -ne 'Visible') { throw 'the group started collapsed' }
                if ("$($head.Toggle.Content)" -ne '-') { throw "an expanded group reads '$($head.Toggle.Content)'" }
                & $clickBtn $head.Toggle
                if ($head.Grid.Visibility -ne 'Collapsed') { throw 'the rows did not fold away' }
                if ($head.Head.Visibility -ne 'Visible') { throw 'collapsing took the heading with it' }
                if ("$($head.Toggle.Content)" -ne '+') { throw "a collapsed group reads '$($head.Toggle.Content)'" }
                & $clickBtn $head.Toggle
                if ($head.Grid.Visibility -ne 'Visible') { throw 'the rows did not come back' }
                if ("$($head.Toggle.Content)" -ne '-') { throw 'the sign did not go back' }
                # Folding a group moves every heading below it, so the toggle
                # invalidates the rail's measured offsets and then re-runs the
                # spy. Deliberately NOT asserted on $indexSpy.Offsets being null
                # afterwards, which is what the first version of this did: the
                # handler re-measures immediately, so the cache is repopulated by
                # design and the assertion was testing that the second half of
                # the fix had not happened. What is observable is that the rows
                # fold and nothing gets ticked, and that is what is checked above.

                # And the pair in the toolbar does it to all of them at once,
                # through the same function - a second copy of "what collapsed
                # looks like" is how the sign and the visibility come to disagree.
                $withRows = @($liveGrpL | Where-Object { $_.Toggle -and @($_.Rows).Count })
                if ($withRows.Count -lt 2) { throw 'fewer than two groups on the page to fold' }
                & $clickBtn $uiL.BtnCollapseAll
                $open = @($withRows | Where-Object { $_.Grid.Visibility -eq 'Visible' })
                if ($open.Count) { throw "$($open.Count) group(s) stayed open through Collapse all" }
                $wrongSign = @($withRows | Where-Object { "$($_.Toggle.Content)" -ne '+' })
                if ($wrongSign.Count) { throw "$($wrongSign.Count) sign(s) still read '-' after Collapse all" }
                & $clickBtn $uiL.BtnExpandAll
                $shut = @($withRows | Where-Object { $_.Grid.Visibility -ne 'Visible' })
                if ($shut.Count) { throw "$($shut.Count) group(s) stayed folded through Expand all" }
                $wrongSign = @($withRows | Where-Object { "$($_.Toggle.Content)" -ne '-' })
                if ($wrongSign.Count) { throw "$($wrongSign.Count) sign(s) still read '+' after Expand all" }

                # Applying a preset is not an edit, and it replaces every box -
                # so it must not leave 200 entries behind to be undone.
                & $clickEl $picks[0].Panel
                & $clickBtn $uiL.BtnAggressive
                if (@($advUndoL).Count) { throw 'a preset switch left the old stack in place' }
                if ($uiL.BtnAdvUndo.Visibility -ne 'Collapsed') { throw 'Undo survived a preset switch' }
                & $clrOvL
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'Advanced splits into Remove and Add, and the filter follows' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                # Sections exist under Category and nowhere else, and the page no
                # longer opens on Category - so this says which arrangement it is
                # talking about instead of inheriting whatever was left set.
                $wasG = [string]$stateL.Group
                $stateL.Group = 'category'; & $orderL
                $addRows = @($rowsL | Where-Object { $_.Section -eq 'add' })
                if ($addRows.Count -lt 10) { throw "only $($addRows.Count) row(s) landed in Add" }
                if (@($rowsL | Where-Object { $_.Section -eq 'remove' }).Count -lt 50) { throw 'the Remove section lost its rows' }
                # The two-column density lives inside each category now, not
                # across the section: in category order every category is a
                # full-width block down the section's left panel, so the
                # section's own right panel must be empty and each category
                # long enough to be worth splitting must have filled both of
                # its own columns.
                $uiL.AddColumns.UpdateLayout()
                if (-not $uiL.AddLeft.Children.Count)  { throw 'the Add section is empty' }
                if ($uiL.AddRight.Children.Count)      { throw 'a category block landed in the section right column' }
                if ($uiL.AddLeft.ActualWidth -le 0)    { throw 'the Add section has no width' }
                if ($uiL.AddHeadBlock.ActualHeight -le 0) { throw 'the Add banner has no height' }
                $addCats = @($catHeadL | Where-Object { $_.Section -eq 'add' })
                if (-not $addCats.Count) { throw 'the Add section drew no categories' }
                # A category whose rows are one indivisible parent-and-children
                # block cannot be split at all, so it is not evidence either way.
                $bigAdd = @($addCats | Where-Object {
                                @($_.Rows).Count -ge 4 -and
                                @($_.Rows | Where-Object { -not $_.Requires }).Count -gt 1 })
                if (-not $bigAdd.Count) { throw 'no Add category is long enough to exercise the split' }
                foreach ($ch in $bigAdd) {
                    if (-not $ch.L.Children.Count -or -not $ch.R.Children.Count) {
                        $dep = @($ch.Rows | Where-Object { $_.Requires }).Count
                        throw ("$($ch.Name) has $(@($ch.Rows).Count) rows ($dep dependent) and split " +
                               "$($ch.L.Children.Count)/$($ch.R.Children.Count)")
                    }
                }
                # Below four rows it stays one column, and then the gutter and
                # the second column have to give their width back or the rows
                # sit in the left half of an empty band.
                foreach ($ch in @($addCats | Where-Object { @($_.Rows).Count -lt 4 })) {
                    if ($ch.R.Children.Count) { throw "$($ch.Name) is too short to split and was split anyway" }
                    if ([double]$ch.Grid.ColumnDefinitions[2].Width.Value -ne 0) {
                        throw "$($ch.Name) uses one column and kept the width of two"
                    }
                }
                # The Add section is not all installers - the quality-of-life
                # tweaks live here too, and those do belong to modes. What no
                # mode may pick up is something that installs software, and that
                # is checked by action in [3] of the self test rather than here.
                $ptRows = @($rowsL | Where-Object { $_.Requires -eq 'add-powertoys' })
                if ($ptRows.Count -lt 3) { throw 'the PowerToys options are not marked as dependent' }

                & $tickL 'Sec' 'Add' $true
                $strays = @($rowsL | Where-Object { $_.Section -eq 'remove' -and $_.Panel.Visibility -eq 'Visible' })
                if ($strays.Count) { throw "$($strays.Count) Remove row(s) survived filtering to Add" }
                if (-not @($addRows | Where-Object { $_.Panel.Visibility -eq 'Visible' }).Count) { throw 'filtering to Add hid the Add rows too' }
                if ($uiL.RemoveHeadBlock.Visibility -ne 'Collapsed') { throw 'the Remove banner stayed with nothing under it' }
                if ($uiL.AddHeadBlock.Visibility -ne 'Visible') { throw 'the Add banner went with the wrong rows' }
                if ($uiL.BrowserAddBlock.Visibility -ne 'Visible') { throw 'the browser block is not counted as Add' }

                & $tickL 'Sec' 'Add' $false
                & $tickL 'Sec' 'Remove' $true
                if (@($addRows | Where-Object { $_.Panel.Visibility -eq 'Visible' }).Count) { throw 'an Add row survived filtering to Remove' }
                if ($uiL.AddHeadBlock.Visibility -ne 'Collapsed') { throw 'the Add banner stayed under a Remove filter' }
                if ($uiL.BrowserAddBlock.Visibility -ne 'Collapsed') { throw 'the browser block stayed under a Remove filter' }

                & $clearFiltL
                if ($uiL.RemoveHeadBlock.Visibility -ne 'Visible') { throw 'clearing the filter left Remove hidden' }
                if ($uiL.AddHeadBlock.Visibility -ne 'Visible')    { throw 'clearing the filter left Add hidden' }
                $stateL.Group = $wasG; & $orderL
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'PowerToys options wait for the PowerToys install' {
                & $clrOvL
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                $parent = $rowByIdL['add-powertoys']
                if (-not $parent) { throw 'the PowerToys install row is missing' }
                $kids = @($rowsL | Where-Object { $_.Requires -eq 'add-powertoys' })
                if ($kids.Count -lt 3) { throw "only $($kids.Count) dependent option(s)" }

                if ($instIdsL.Contains('add-powertoys')) {
                    # Already on the machine: there is nothing to install, so the
                    # options stand on their own and the install row is out of
                    # play. Configuring PowerToys you already have is the normal
                    # case, not an edge one.
                    if ($parent.Check.IsEnabled) { throw 'the install row is still tickable with PowerToys installed' }
                    if (@($kids | Where-Object { $_.Panel.Visibility -ne 'Visible' }).Count) {
                        throw 'the options are hidden on a machine that already has PowerToys'
                    }
                    # An option already in the state it would set is out of play
                    # like anything else that is already done. Whatever is left
                    # has to stay tickable with the install row untouched.
                    $spare = @($kids | Where-Object { -not $instIdsL.Contains($_.Id) })
                    if ($spare.Count) {
                        $spare[0].Check.IsChecked = $true
                        & $applyFiltL
                        if (-not $spare[0].Check.IsChecked) { throw 'an option was withdrawn although PowerToys is installed' }
                        $spare[0].Check.IsChecked = $false
                    } else {
                        Write-Host '  (every PowerToys option is already set on this machine)'
                    }
                } else {
                    $parent.Check.IsChecked = $false
                    if (@($kids | Where-Object { $_.Panel.Visibility -eq 'Visible' }).Count) {
                        throw 'a PowerToys option is on screen without the install'
                    }
                    $parent.Check.IsChecked = $true
                    if (@($kids | Where-Object { $_.Panel.Visibility -ne 'Visible' }).Count) {
                        throw 'ticking the install did not bring its options out'
                    }
                    # And going away takes anything ticked underneath it with it -
                    # a queued option nobody can see is a queued option nobody meant.
                    $kids[0].Check.IsChecked = $true
                    $parent.Check.IsChecked  = $false
                    if ($kids[0].Check.IsChecked) { throw 'an option stayed ticked after its parent went' }
                    if ((& $checkSelL) -contains $kids[0].Id) { throw 'the run would still configure it' }
                }
                & $clrOvL
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'software already on the machine is out of play' {
                $onBox = @($rowsL | Where-Object { $instIdsL.Contains($_.Id) })
                Write-Host "  already installed: $(@($onBox | ForEach-Object { $_.Id }) -join ', ')"
                foreach ($r in $onBox) {
                    if ($r.Check.IsEnabled) { throw "$($r.Id) is still tickable" }
                    if ($r.Check.IsChecked) { throw "$($r.Id) is queued for install anyway" }
                    # Panel, not StackPanel. The name line inside a row is a
                    # WrapPanel now - a horizontal StackPanel measures its
                    # children with infinite width and pushed the trailing chips
                    # off a narrow window - and this walk had the concrete type
                    # written into it twice.
                    $tags = @($r.Panel.Children |
                              Where-Object { $_ -is [Windows.Controls.Panel] } |
                              ForEach-Object { $_.Children } |
                              Where-Object { $_ -is [Windows.Controls.Panel] } |
                              ForEach-Object { $_.Children } |
                              Where-Object { $_ -is [Windows.Controls.TextBlock] -and "$($_.Text)" -match 'already (installed|set)' })
                    if (-not $tags.Count) { throw "$($r.Id) is disabled with nothing to say why" }
                }
                # And nothing that is already here can reach a run.
                $queued = @(& $checkSelL | Where-Object { $instIdsL.Contains($_) })
                if ($queued.Count) { throw "$($queued.Count) installed item(s) are in the selection" }
            }.GetNewClosure()
            & $try 'Save can make the edit the new normal, and factory undoes it' {
                & $clrOvL
                & $clickBtn $uiL.BtnAdvanced
                & $clickBtn $uiL.BtnBalanced
                $spare = @($rowsL | Where-Object { $_.Id -notin @($baseL['Balanced']) -and $_.Check.IsEnabled -and -not $_.Requires } |
                           Select-Object -First 1)
                if (-not $spare.Count) { throw 'nothing available to add' }
                $spare[0].Check.IsChecked = $true
                if ($spare[0].DiffTag.Visibility -ne 'Visible') { throw 'the edit is not marked as one' }

                # Promoting it: the item stays selected, but it is no longer a
                # change to anything, so the mark goes and Reset has nothing.
                if (-not (& $saveDefL)) { throw 'Save reported nothing to do' }
                if (-not $spare[0].Check.IsChecked) { throw 'the item came unticked' }
                if ($spare[0].DiffTag.Visibility -ne 'Collapsed') { throw 'it is still marked as an edit' }
                if ($ovL.ContainsKey('Balanced')) { throw 'it is still stored as an edit' }
                if (@(& $effIdsL 'Balanced') -notcontains $spare[0].Id) { throw 'Balanced does not include it' }
                if ($uiL.BtnResetOne.Visibility -ne 'Collapsed') { throw 'Reset offered to undo the new default' }
                # A mode further up the ladder is untouched: this redefined
                # Balanced, not the manifest.
                $bal = & $cellText $colsL['Balanced'].Num
                if ($bal -match 'items? (added|removed)') { throw "Balanced still reads as edited: '$bal'" }

                # Factory defaults is the only way back, and it takes the lot.
                & $factoryL
                & $clickBtn $uiL.BtnBalanced
                if (@(& $effIdsL 'Balanced') -contains $spare[0].Id) { throw 'the redefined preset survived a factory restore' }
                if ($spare[0].Check.IsChecked) { throw 'the row stayed ticked after a factory restore' }
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            # What outlives the window and what does not. Closing is not a
            # gesture this pass can make - the window is the harness - so what is
            # asserted is what the settings file would be handed, which is the
            # whole of the mechanism: an unsaved edit is never written, so there
            # is nothing for the next launch to read back.
            #
            # Every assertion here is about a property that is absent, which is
            # the kind nothing catches by accident. Re-add `overrides` to that
            # object and the application still works perfectly - edits simply
            # start coming back from a session nobody remembers, marked green and
            # red on a page most people never open, and carried by every future
            # run of a preset whose name still says Balanced.
            & $try 'the settings file keeps what was saved on purpose and drops what was not' {
                & $factoryL
                & $clickBtn $uiL.BtnAdvanced
                & $clickBtn $uiL.BtnBalanced
                $spare = @($rowsL | Where-Object { $_.Id -notin @($baseL['Balanced']) -and $_.Check.IsEnabled -and -not $_.Requires } |
                           Select-Object -First 1)
                if (-not $spare.Count) { throw 'nothing available to add' }

                # An unsaved edit, recorded through the same seam Advanced uses
                # when it leaves the page. It is in the tables and it is not in
                # what would be written - and the first half is what stops the
                # second half passing for want of an edit to drop.
                & $setOvL 'Balanced' @($spare[0].Id) @()
                if (-not $ovL.ContainsKey('Balanced')) { throw 'the edit was not recorded at all' }
                $out = & $uiOutL
                if ($out.PSObject.Properties['overrides']) {
                    throw 'the settings file carries an overrides property, so unsaved edits come back'
                }
                if ($out.presetDefaults.PSObject.Properties['Balanced']) {
                    throw 'an unsaved edit was written out as a redefined mode'
                }
                & $clrOvL

                # Saved as the new default. Now it is precisely the thing that
                # does outlive the window, and it is written.
                & $clickBtn $uiL.BtnBalanced
                $spare[0].Check.IsChecked = $true
                if (-not (& $saveDefL)) { throw 'Save reported nothing to do' }
                if ($ovL.ContainsKey('Balanced')) { throw 'promoting the edit left it an edit' }
                if (-not $defsL.ContainsKey('Balanced')) { throw 'the redefined mode is not in the table' }
                $kept = (& $uiOutL).presetDefaults.PSObject.Properties['Balanced']
                if (-not $kept) { throw 'the redefined mode was not written' }
                if (@($kept.Value.Added) -notcontains $spare[0].Id) {
                    throw 'the redefined mode was written without the item that was added to it'
                }

                # And an edit on top of a redefined mode moves neither answer:
                # the default is still written, the edit still is not. This is
                # the case that matters, because it is the one where dropping the
                # wrong layer would take somebody's saved work with it.
                & $setOvL 'Balanced' @() @($spare[0].Id)
                $out = & $uiOutL
                if ($out.PSObject.Properties['overrides']) { throw 'an edit on top of a default reached the file' }
                $still = $out.presetDefaults.PSObject.Properties['Balanced']
                if (-not $still) { throw 'the redefined mode was dropped by an unsaved edit on top of it' }
                if (@($still.Value.Added) -notcontains $spare[0].Id) {
                    throw 'the unsaved edit was folded into the redefined mode'
                }

                & $factoryL
                & $clickBtn $uiL.BtnBalanced
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'every row sits in the columns of the section it claims' {
                # Checked row by row rather than by counting what landed in each
                # column pair. The counting version passed for months while every
                # Extras row was being laid out in the Remove columns: the id
                # 'extras' was not in the set Get-WDItemSection would accept, so
                # those rows called themselves 'remove', and a test that asks
                # "does this section have rows anywhere" agreed with them.
                #
                # Under Category, deliberately, because sections exist there and
                # nowhere else - and because Bloat rating does not lay the Add
                # section out at all, so on a machine whose saved grouping is
                # Bloat rating every Add row is legitimately parented nowhere.
                # This inherited whatever the settings file had in it, which is
                # a test that passes or fails on a preference.
                $wasSec = [string]$stateL.Group
                $stateL.Group = 'category'; & $orderL
                $where = @{ remove = $true; add = $true; extras = $true }
                $seen = @{}
                foreach ($r in $rowsL) {
                    $sec = [string]$r.Section
                    if (-not $where.ContainsKey($sec)) { throw "$($r.Id) claims section '$sec'" }
                    $landed = & $secOfL $r.Panel
                    if ($landed -ne $sec) {
                        throw "$($r.Id) says $sec and was laid out in $(if ($landed) { $landed } else { 'no section' })"
                    }
                    $seen[$sec] = [int]$seen[$sec] + 1
                }
                foreach ($s in @($where.Keys)) {
                    if (-not $seen.ContainsKey($s)) { throw "the $s section drew a header with no rows under it" }
                }
                $stateL.Group = $wasSec; & $orderL
            }.GetNewClosure()

            # Ordering re-parents rows, which nothing else in this application
            # has ever done - the filter only hides them. So every order is
            # walked, and the invariants that survive a re-lay are checked each
            # time: rows stay in their own section's columns, dependants stay
            # under their parent, the browser picker stays under the Edge row,
            # and the whole set is still on screen.
            # The fraction is how somebody judges what is left in a block, so
            # its denominator has to be the number of decisions there actually
            # are. It counted every row that was not "not on this machine",
            # which is one of four reasons a box refuses a tick - the others
            # being already-installed, already-set, and ruled out by another
            # choice - so a category holding one of those read 25/26 with every
            # box on the page ticked and nothing left to click.
            & $try 'a block with nothing left to tick reads N of N, in green' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                # The biggest block, so this is asked of a real category rather
                # than of whichever one happens to be first.
                $ents = @($idxEntriesL | Where-Object { $_.Kind -eq 'jump' -and @($_.Rows).Count -gt 3 })
                if (-not $ents.Count) { throw 'no block on the rail has rows to count' }
                $e = @($ents | Sort-Object { -(@($_.Rows).Count) })[0]
                $was = @($e.Rows | ForEach-Object { [bool]$_.Check.IsChecked })
                try {
                    foreach ($r in $e.Rows) { if ($r.Check.IsEnabled) { $r.Check.IsChecked = $true } }
                    $can = @($e.Rows | Where-Object { $_.Check.IsEnabled -or $_.Check.IsChecked }).Count
                    if ($e.Count.Text -ne "$can/$can") {
                        throw "'$($e.Name)' reads '$($e.Count.Text)' with every row it will accept ticked"
                    }
                    $green = $winL.Resources['WdOk']
                    if (-not $green) { throw 'there is no Ok brush in the theme' }
                    if ($e.Count.Foreground -ne $green) {
                        throw "'$($e.Name)' is full and its fraction is not green"
                    }
                    # And a block with something still to do is not green, or
                    # the color says nothing.
                    $spare = @($e.Rows | Where-Object { $_.Check.IsEnabled -and $_.Check.IsChecked })
                    if ($spare.Count) {
                        $spare[0].Check.IsChecked = $false
                        if ($e.Count.Foreground -eq $green) {
                            throw "'$($e.Name)' stayed green with a row unticked"
                        }
                    }
                } finally {
                    for ($i = 0; $i -lt @($e.Rows).Count; $i++) {
                        if ($e.Rows[$i].Check.IsEnabled) { $e.Rows[$i].Check.IsChecked = $was[$i] }
                    }
                }
            }.GetNewClosure()
            # Two halves of one question. Both at once is every row, which is
            # what no filter already says, so whichever is on takes the other
            # out of play.
            & $try 'checked only and unchecked only rule each other out' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                $boxOf = {
                    param([string]$Nm)
                    $b = @($fboxL | Where-Object { $_.Group -eq 'View' -and $_.Name -eq $Nm })
                    if (-not $b.Count) { throw "no box named '$Nm' in the View group" }
                    $b[0].Box
                }
                $on  = & $boxOf $checkedOnlyL
                $off = & $boxOf $uncheckedOnlyL
                if (-not $on.IsEnabled -or -not $off.IsEnabled) { throw 'one of the pair starts disabled' }
                try {
                    & $tickL 'View' $checkedOnlyL $true
                    if ($off.IsEnabled) { throw 'Unchecked only stayed live with Checked only on' }
                    & $tickL 'View' $checkedOnlyL $false
                    if (-not $off.IsEnabled) { throw 'Unchecked only stayed disabled after the other was cleared' }
                    & $tickL 'View' $uncheckedOnlyL $true
                    if ($on.IsEnabled) { throw 'Checked only stayed live with Unchecked only on' }
                } finally {
                    & $tickL 'View' $checkedOnlyL $false
                    & $tickL 'View' $uncheckedOnlyL $false
                }
                if (-not $on.IsEnabled -or -not $off.IsEnabled) { throw 'clearing both left one disabled' }
            }.GetNewClosure()
            # Save has three answers and all of them are about a change that has
            # not been made, so with nothing changed it is not offered - the same
            # rule its Reset neighbour has always followed.
            & $try 'Save is offered only when there is something to save' {
                & $clickBtn $uiL.BtnAdvanced
                & $clickBtn $uiL.BtnBalanced
                & $clearFiltL
                if ($uiL.BtnSave.Visibility -ne 'Collapsed') { throw 'Save offered to save an untouched preset' }
                $spare = @($rowsL | Where-Object {
                    $_.Check.IsEnabled -and -not $_.Check.IsChecked -and
                    $_.Panel.Visibility -eq 'Visible' -and -not $_.Requires })
                if (-not $spare.Count) { throw 'nothing on the page can be ticked, so this proves nothing' }
                $spare[0].Check.IsChecked = $true
                try {
                    if ($uiL.BtnSave.Visibility -ne 'Visible') { throw 'Save stayed hidden after an edit' }
                    if ($uiL.BtnResetOne.Visibility -ne 'Visible') { throw 'Reset and Save disagree about the edit' }
                } finally { $spare[0].Check.IsChecked = $false }
                if ($uiL.BtnSave.Visibility -ne 'Collapsed') { throw 'Save stayed after the edit was taken back' }
            }.GetNewClosure()
            # The rail measures its offsets from the laid-out page, and the page
            # is always built before it is shown - by the pre-warm timer and by
            # $ensureAdvanced alike, both of which end in $applyFilter, which
            # ends in the spy. So the first thing ever to ask for those offsets
            # was asking about a page with no layout, where every heading
            # transforms to Y=0. A table of zeros is still a table, so it was
            # cached and never measured again: the highlight named the first
            # category for the rest of the session however far anybody scrolled,
            # and switching the grouping and back was the only way out, because
            # that is what threw the table away while the page was up.
            & $try 'the rail refuses to measure a page that has no layout' {
                & $clickBtn $uiL.BtnAdvanced
                $stateL.Group = 'category'; & $orderL
                # The state the page is in at the moment it finishes building.
                $uiL.PageAdvanced.Visibility = 'Collapsed'
                $idxSpyL.Offsets = $null
                & $spyL
                if ($idxSpyL.Offsets) { throw 'the rail measured a page that was not on screen' }
                $uiL.PageAdvanced.Visibility = 'Visible'
                $uiL.AdvContent.UpdateLayout()
                & $spyL
                if (-not $idxSpyL.Offsets) { throw 'the rail would not measure the page once it was up' }
                $ys = @($idxSpyL.Offsets.Values | Sort-Object -Unique)
                if ($ys.Count -lt 2) {
                    throw "every heading measured to offset $($ys -join ','), so the highlight can never move"
                }
            }.GetNewClosure()
            & $try 'the index rail maps the page, counts it, and jumps to it' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                $wasGroup = [string]$stateL.Group
                $stateL.Group = 'category'
                & $orderL

                # The rail carries three kinds of thing now: a card per group, an
                # unclickable separator per section, and a card for each of the
                # fixed blocks that are on the page whatever the list is sorted
                # by. So it is not one entry per category any more.
                $ents  = @($idxEntriesL | Where-Object { $_.Kind -eq 'jump' })
                $seps  = @($idxEntriesL | Where-Object { $_.Kind -eq 'sep' })
                $fixed = @($ents | Where-Object { -not @($_.Rows).Count })
                if (@($seps | ForEach-Object { $_.Name }) -join ',' -ne 'Remove,Add,Extras') {
                    throw "the section titles read '$(@($seps | ForEach-Object { $_.Name }) -join ',')'"
                }
                if ($fixed.Count -ne 4) { throw "$($fixed.Count) fixed card(s), expected Web browser, Default behaviors, Authority and App Options" }
                foreach ($want in @('Web browser', 'Default behaviors', 'Authority', 'App Options')) {
                    if (-not @($fixed | Where-Object { $_.Name -eq $want }).Count) { throw "no '$want' card on the rail" }
                }
                if (($ents.Count - $fixed.Count) -ne $catHeadL.Count) {
                    throw "$($ents.Count - $fixed.Count) group card(s) for $($catHeadL.Count) categories"
                }

                # The rail lists the page in the order the page reads, top to
                # bottom. This is the assertion the two-column layout could not
                # support: with whole categories packed into two page-tall
                # columns, two of them sat side by side at every scroll position
                # and no single list could be right about the order. Measured
                # from the laid-out page rather than from $catHeaders, so it
                # answers for the layout and not for the list it was built from.
                $uiL.AdvContent.UpdateLayout()
                $lastY = [double]::NegativeInfinity
                foreach ($e in $ents) {
                    if (-not $e.Head.IsDescendantOf($uiL.AdvContent)) {
                        throw "$($e.Name) is on the rail but not on the page"
                    }
                    $y = [double]$e.Head.TransformToAncestor($uiL.AdvContent).Transform(
                            (New-Object Windows.Point 0, 0)).Y
                    if ($y -lt $lastY) {
                        throw "the rail lists $($e.Name) at $([int]$y), below an entry it lists after"
                    }
                    $lastY = $y
                }

                # The hairline scrollbar. Only that the rail picks the style up
                # at all - a {DynamicResource} that resolves to nothing is
                # silent, and so is an implicit style that never reaches the bar
                # inside a ScrollViewer's template.
                #
                # How WIDE it draws is asserted in "the preset pickers scroll on
                # a hairline", by measuring ActualWidth after a real arrange.
                # This used to read the Width setter off the style here, which is
                # exactly the mistake that file has a section about: the property
                # was 5 the whole time the bar was being laid out at the system's
                # 17px, because the theme style's MinWidth was winning and no
                # setter can tell you that.
                if (-not $winL.Resources['WdScrollThumb']) {
                    throw 'the thin scrollbar thumb has no brush to resolve'
                }
                $sbStyle = $uiL.IndexScroll.Resources[[Windows.Controls.Primitives.ScrollBar]]
                if (-not $sbStyle) { throw 'the rail did not pick up the thin scrollbar style' }
                if ($sbStyle.BasedOn -ne $winL.Resources['WdRailBar']) {
                    throw 'the rail has a scrollbar style of its own rather than the shared one'
                }
                # The count on an entry has to be the rows it points at, or the
                # rail is a progress map of something else. A fixed card has no
                # rows and must show nothing rather than 0/0, which would read as
                # "nothing selected here" about a block that holds no selections.
                foreach ($e in $ents) {
                    if (-not @($e.Rows).Count) {
                        if ($e.Count.Text) { throw "$($e.Name) is a fixed block and shows a count of '$($e.Count.Text)'" }
                        continue
                    }
                    # Rows with nothing to act on are in neither half: they
                    # cannot be ticked, so counting them would leave a category
                    # whose every target is already gone reading as unfinished
                    # work for ever.
                    #
                    # Asked of the box, exactly as $paintIndex asks it, and not
                    # of $_.Absent. Absent is one of four reasons a box refuses a
                    # tick - the others are already-installed, already-set, and
                    # ruled out by another option - and this used to ask only
                    # about the first while the code it checks had already moved
                    # to the one question that covers all four. So it failed on
                    # any machine holding one of the other three: a category with
                    # sixteen already-set QoL rows reported the rail off by one
                    # and named the CODE as wrong. A row that is disabled but
                    # ticked anyway stays in both halves, because the run will
                    # still act on it.
                    $live = @($e.Rows | Where-Object { $_.Check.IsEnabled -or $_.Check.IsChecked })
                    $on = @($live | Where-Object { $_.Check.IsChecked }).Count
                    if ($e.Count.Text -ne "$on/$($live.Count)") {
                        throw "$($e.Name) reads '$($e.Count.Text)', its selectable rows are $on of $($live.Count)"
                    }
                }
                # And the fraction is about the block, not about the filter.
                # It briefly counted only what a filter was showing, so the
                # denominator shrank as the user typed and no two readings could
                # be compared.
                $before = @($ents | Where-Object { @($_.Rows).Count } | ForEach-Object { "$($_.Key)=$($_.Count.Text)" }) -join ','
                $uiL.TxtFilter.Text = 'zzz-nothing-matches-this'
                $after = @($ents | Where-Object { @($_.Rows).Count } | ForEach-Object { "$($_.Key)=$($_.Count.Text)" }) -join ','
                $uiL.TxtFilter.Text = ''
                if ($before -ne $after) { throw 'a search box changed the rail fractions' }
                # Ticking a row moves the rail, which is the half that would
                # freeze if the paint only ran from the filter.
                $pick = @($ents | Where-Object { @($_.Rows | Where-Object { $_.Check.IsEnabled -and -not $_.Check.IsChecked }).Count })[0]
                if ($pick) {
                    $before = $pick.Count.Text
                    $row = @($pick.Rows | Where-Object { $_.Check.IsEnabled -and -not $_.Check.IsChecked })[0]
                    $row.Check.IsChecked = $true
                    if ($pick.Count.Text -eq $before) { throw "ticking a row left $($pick.Name) reading '$before'" }
                    $row.Check.IsChecked = $false
                }

                # Clicking an entry scrolls to it. The harness window has no
                # real viewport, so the ScrollViewer is given one - without it
                # ScrollableHeight is zero and every assertion below would pass
                # by never running, which is the failure mode this file keeps
                # warning about.
                $hadHeight = $uiL.AdvScroll.Height
                $uiL.AdvScroll.Height = 420
                $uiL.AdvScroll.UpdateLayout()
                if ($uiL.AdvScroll.ScrollableHeight -gt 10) {
                    $far = $ents[$ents.Count - 1]
                    & $clickEl $far.Panel
                    $uiL.AdvScroll.UpdateLayout()
                    if ($uiL.AdvScroll.VerticalOffset -le 0) {
                        throw "clicking the last entry left the page at offset $($uiL.AdvScroll.VerticalOffset)"
                    }
                    # And the highlight follows the scroll rather than the click.
                    & $spyL
                    if (-not $idxSpyL.Active) { throw 'nothing is highlighted after scrolling' }
                    $uiL.AdvScroll.ScrollToVerticalOffset(0)
                    $uiL.AdvScroll.UpdateLayout()
                    & $spyL
                    # By Key, not by Name. Two blocks can share a title - three
                    # "Risky" cards, one per section, was the shape that broke
                    # this - so the highlight is keyed on position and the
                    # assertion has to be too, or it would pass on the very
                    # collision it exists to catch.
                    if ($idxSpyL.Active -ne $ents[0].Key) {
                        $lit = @($idxEntriesL | Where-Object { $_.Key -eq $idxSpyL.Active })
                        throw ("back at the top the rail lit '$(if ($lit.Count) { $lit[0].Name } else { $idxSpyL.Active })', " +
                               "expected '$($ents[0].Name)'")
                    }
                    # One card lit, never a set of them. This is the bug from the
                    # user's report expressed as an invariant rather than as a
                    # story about Risk order: whatever the titles are, the
                    # highlight marks a place on the page and there is only one
                    # place the page is at.
                    $on = @($idxEntriesL | Where-Object { "$($_.Panel.Tag)" -eq 'on' })
                    if ($on.Count -ne 1) {
                        throw "$($on.Count) rail card(s) are lit at once: $(@($on | ForEach-Object { $_.Name }) -join ', ')"
                    }
                    # And the same thing with a filter on, which is where this
                    # was broken: the offsets were measured once and only
                    # $applyOrder ever threw them away, so with rows collapsed
                    # the click scrolled to the right heading and the highlight
                    # landed on whichever one used to sit at that offset.
                    & $tickL 'Sec' 'Add' $true
                    $uiL.AdvScroll.UpdateLayout()
                    $live = @($ents | Where-Object {
                                 $_.Head.Visibility -eq 'Visible' -and
                                 @($_.Rows | Where-Object { $_.Panel.Visibility -eq 'Visible' }).Count })
                    if ($live.Count -lt 2) { throw "filtering to Add left $($live.Count) categor(y/ies) on the page" }
                    $checked = 0
                    foreach ($target in @($live[$live.Count - 1], $live[0])) {
                        & $clickEl $target.Panel
                        $uiL.AdvScroll.UpdateLayout()
                        & $spyL
                        # A heading near the bottom cannot be brought to the top
                        # of a page that has run out of scroll, and the spy is
                        # then right to name the heading that is at the top. Only
                        # a target the page can actually reach is evidence, so
                        # the ones it cannot are skipped rather than asserted -
                        # and the count below refuses to let both be skipped.
                        $ty = [double]$target.Head.TransformToAncestor($uiL.AdvContent).Transform(
                                (New-Object Windows.Point 0, 0)).Y
                        if ($ty -gt [double]$uiL.AdvScroll.ScrollableHeight) { continue }
                        $checked++
                        if ($idxSpyL.Active -ne $target.Key) {
                            $lit = @($idxEntriesL | Where-Object { $_.Key -eq $idxSpyL.Active })
                            throw ("with a filter on, clicking '$($target.Name)' highlighted " +
                                   "'$(if ($lit.Count) { $lit[0].Name } else { $idxSpyL.Active })'")
                        }
                    }
                    if (-not $checked) { throw 'no filtered entry was reachable, so the filtered jump proves nothing' }
                    & $tickL 'Sec' 'Add' $false
                    $uiL.AdvScroll.ScrollToVerticalOffset(0)
                    $uiL.AdvScroll.UpdateLayout()
                } else {
                    throw "the page would not scroll even at a fixed height ($($uiL.AdvScroll.ScrollableHeight)px)"
                }
                $uiL.AdvScroll.Height = $hadHeight
                $uiL.AdvScroll.UpdateLayout()

                # The rail follows the order rather than standing down in it.
                # Every order groups the page, so every order has an index; what
                # changes is what the cards are called and whether the section
                # titles mean anything.
                # Plain scriptblock, no GetNewClosure - $idxEntriesL belongs to
                # the harness scope, not to this one, so a closure would capture
                # nothing and every list would come back empty.
                $railNames = {
                    param([string]$Kind)
                    $idxEntriesL | Where-Object { $_.Kind -eq $Kind } | ForEach-Object { [string]$_.Name }
                }

                # Where the browser picker lives when it is at home, read while
                # it still is. Under A-Z it is filed under W instead, and this
                # is what says it came back.
                $bHome = $uiL.BrowserAddBlock.Parent
                if (-not $bHome) { throw 'the browser picker is not on the page under Category' }

                # Every grouping but Category is one list, so the only separator
                # is the one saying where the list stops and the page furniture
                # starts. Three alphabets, one per section, is exactly what made
                # a name impossible to look up.
                $stateL.Group = 'alpha'; & $orderL
                $cards = @(& $railNames 'jump')
                if (@(& $railNames 'sep') -join ',' -ne 'ALSO ON THIS PAGE') {
                    $gs = @(& $groupsForL 'alpha')
                    throw ("A-Z shows separators '$(@(& $railNames 'sep') -join ',')' over $($cards.Count) card(s); " +
                           "the grouping built $($gs.Count) group(s): " + (@($gs | ForEach-Object { "$($_.Name)[$($_.Section)]" }) -join ' '))
                }
                # Letter cards: a single letter, or a range, and nothing else.
                $letters = @($cards | Where-Object { $_ -match '^[A-Z#](-[A-Z#])?$' })
                if ($letters.Count -lt 5) { throw "A-Z produced $($letters.Count) letter card(s): $($cards -join ', ')" }
                foreach ($g in @(& $groupsForL 'alpha')) {
                    foreach ($r in $g.Rows) {
                        $ch = ([string]$r.Name.Text).ToUpper()
                        $ch = $(if ($ch.Length -and $ch[0] -ge 'A' -and $ch[0] -le 'Z') { [string]$ch[0] } else { '#' })
                        # A dependent row rides with its parent, so only the
                        # leading rows have to match the card they sit under.
                        if ($r.Requires) { continue }
                        $lo = [string]$g.Name[0]
                        $hi = [string]$g.Name[$g.Name.Length - 1]
                        if ($ch -lt $lo -or $ch -gt $hi) { throw "'$($r.Name.Text)' sits under '$($g.Name)'" }
                    }
                }

                # The browser picker is a choice rather than a row, so under
                # every other grouping it has nowhere to be and stands down. An
                # alphabet has somewhere: it is called Web browser, so it is
                # under W, laid out down the Remove panel with everything else.
                # The loop above already checked the letter, since the picker is
                # a member of its block like any row - this checks it is a
                # member of exactly one, is actually drawn, and did not drag the
                # Add heading along with it.
                $bIn = @(@(& $groupsForL 'alpha') | Where-Object {
                            @($_.Rows | Where-Object { [string]$_.Id -eq '__browser-block' }).Count })
                if ($bIn.Count -ne 1) { throw "the browser picker is in $($bIn.Count) letter block(s), expected 1" }
                if (-not $uiL.BrowserAddBlock.Parent) { throw 'the browser picker was never laid out under A-Z' }
                if ($uiL.BrowserAddBlock.Visibility -ne 'Visible') { throw 'the browser picker is off the page under A-Z' }
                if ($uiL.AddBox.Visibility -eq 'Visible') { throw 'the Add box opened for a picker that is no longer in it' }

                $stateL.Group = 'risk'; & $orderL
                # Nowhere to be, so nowhere: not in a band, and not drawn.
                if (@(@(& $groupsForL 'risk') | Where-Object {
                        @($_.Rows | Where-Object { [string]$_.Id -eq '__browser-block' }).Count }).Count) {
                    throw 'the browser picker was filed under a risk level'
                }
                if ($uiL.BrowserAddBlock.Visibility -ne 'Collapsed') { throw 'the browser picker stayed on a page with no Add section' }
                $cards = @(& $railNames 'jump')
                foreach ($want in @('Risky', 'Caution', 'No risk')) {
                    if ($cards -notcontains $want) { throw "Risk has no '$want' card: $($cards -join ', ')" }
                    if (@($cards | Where-Object { $_ -eq $want }).Count -ne 1) {
                        throw "Risk shows '$want' more than once: $($cards -join ', ')"
                    }
                }

                # Every band named once, in the order $BLOAT_BAND declares, with
                # the right name on the right band. Indexing the ordered
                # dictionary this used to be with an integer bound to the
                # position overload rather than the key, so each band came out
                # wearing its neighbor's label and nothing said so.
                $stateL.Group = 'bloat'; & $orderL
                $cards = @(& $railNames 'jump')
                foreach ($want in @('Data collection','Advertising and nagging','Bloatware',
                                    'Legacy and leftovers','Sometimes useful','Not recommended',
                                    'Not a removal - unrated','Your apps')) {
                    if (@($cards | Where-Object { $_ -eq $want }).Count -ne 1) {
                        throw "the bloat bands read '$($cards -join ', ')', with no single '$want'"
                    }
                }
                foreach ($g in @(& $groupsForL 'bloat')) {
                    foreach ($r in $g.Rows) {
                        if ($r.Requires) { continue }
                        $want = switch ($g.Name) {
                            'Your apps'                    { 'apps' }
                            'Not a removal - unrated'      { 0 }
                            'Data collection'                    { 1 }
                            'Advertising and nagging'      { 2 }
                            'Bloatware'                    { 3 }
                            'Legacy and leftovers'         { 4 }
                            'Sometimes useful'             { 5 }
                            'Not recommended'              { 6 }
                        }
                        if ((& $bandOfL $r) -ne $want) {
                            throw "'$($r.Name.Text)' is band $(& $bandOfL $r) and sits under '$($g.Name)'"
                        }
                    }
                }
                $yours = @(@(& $groupsForL 'bloat') | Where-Object { $_.Name -eq 'Your apps' })
                if (-not $yours.Count) { throw 'there is no Your apps band' }
                foreach ($r in $yours[0].Rows) {
                    if ($r.Requires) { continue }
                    if ([string]$r.CatId -notlike 'discovered-*') {
                        throw "'$($r.Name.Text)' is in Your apps and came from '$($r.CatId)', not the scan"
                    }
                }
                # Add is not in this grouping at all, and that is the one place
                # the page stops showing everything - so it is checked from both
                # ends. No Add row may be laid out, and every Add row must be
                # collapsed rather than left Visible with no parent, or every
                # count on the page speaks for rows nobody can see.
                foreach ($g in @(& $groupsForL 'bloat')) {
                    foreach ($r in $g.Rows) {
                        if ([string]$r.Section -eq 'add') {
                            throw "'$($r.Name.Text)' is an Add row and the bloat grouping laid it out"
                        }
                    }
                }
                $addRows = @($rowsL | Where-Object { [string]$_.Section -eq 'add' })
                if (-not $addRows.Count) { throw 'there are no Add rows, so omitting them proves nothing' }
                $stray = @($addRows | Where-Object { $_.Panel.Visibility -eq 'Visible' })
                if ($stray.Count) {
                    throw "$($stray.Count) Add row(s) still count as visible under the bloat grouping, e.g. '$($stray[0].Name.Text)'"
                }
                # And the rail says so. A page that quietly drops forty rows is
                # a page that lies; this is the line that stops it being one.
                $omits = @($idxEntriesL | Where-Object { $_.Kind -eq 'omit' })
                if ($omits.Count -ne 1) {
                    throw "the rail carries $($omits.Count) not-listed notice(s) under the bloat grouping, expected 1"
                }
                if ($omits[0].Panel.IsHitTestVisible) { throw 'the not-listed notice takes the pointer as though it were a jump' }
                # Nowhere else. Category shows everything, so a notice there
                # would be describing a page that is not missing anything.
                $stateL.Group = 'category'; & $orderL
                if (@($idxEntriesL | Where-Object { $_.Kind -eq 'omit' }).Count) {
                    throw 'Category grouping claims something is not listed'
                }
                # And the picker is back where it started, in the block it was
                # taken out of rather than merely somewhere on the page.
                if ($uiL.BrowserAddBlock.Parent -ne $bHome) { throw 'the browser picker did not come home from A-Z' }
                if ($uiL.BrowserAddBlock.Visibility -ne 'Visible') { throw 'the browser picker came home collapsed' }
                if (@($rowsL | Where-Object { [string]$_.Section -eq 'add' -and $_.Panel.Visibility -ne 'Visible' }).Count -eq $addRows.Count) {
                    throw 'the Add rows never came back after leaving the bloat grouping'
                }
                $stateL.Group = 'bloat'; & $orderL

                $stateL.Group = 'space'; & $orderL
                $cards = @(& $railNames 'jump')
                if (@(& $railNames 'sep') -join ',' -ne 'ALSO ON THIS PAGE') { throw 'Storage savings kept the section titles' }
                if ($cards -notcontains 'Inconsequential') { throw "no Inconsequential band: $($cards -join ', ')" }
                if ("$($uiL.RemoveHead.Text)" -eq 'Remove') { throw 'the unsectioned list still calls itself Remove' }
                foreach ($g in @(& $groupsForL 'space')) {
                    if ($g.Name -eq 'Inconsequential') { continue }
                    foreach ($r in $g.Rows) {
                        if ($r.Requires) { continue }
                        if ([int64](& $bytesL $r) -gt -500MB) {
                            throw "'$($r.Name.Text)' frees $((& $bytesL $r)) and is above the floor"
                        }
                    }
                }

                $stateL.Group = 'category'; & $orderL
                if ("$($uiL.RemoveHead.Text)" -ne 'Remove') { throw 'the Remove banner did not come back' }
                $stateL.Group = $wasGroup
                & $orderL
            }.GetNewClosure()
            # Hovering is an interaction, and one the user cannot decline: the
            # pointer crosses the rail on the way to anything left of the list.
            # The handlers are built inside closures, which is where this file's
            # oldest trap lives - reach one scope too far and the handler holds
            # $null, and the throw comes out of the dispatcher, which closes the
            # window instead of logging anything. Nothing but firing the event
            # finds that.
            & $try 'hovering the rail and the rows tints them rather than throwing' {
                & $clickBtn $uiL.BtnAdvanced
                $hover = $winL.Resources['WdRowHover']
                $flat  = $winL.Resources['WdFlat']
                if (-not $hover -or -not $flat) { throw 'the hover brushes are not in the theme' }
                $sel   = $winL.Resources['WdCardSel']
                $cards = @($idxEntriesL | Where-Object { $_.Kind -eq 'jump' })
                if (-not $cards.Count) { throw 'the rail is empty, so hovering it proves nothing' }
                $tinted = 0
                foreach ($c in $cards) {
                    # The card the page is currently under is already lit, and
                    # the hover must leave that alone - a highlight that dims to
                    # a hover tint as the pointer crosses it says the pointer
                    # moved the page.
                    $held = ("$($c.Panel.Tag)" -eq 'on')
                    $want = $(if ($held) { $sel } else { $hover })
                    & $hoverEl $c.Panel $false
                    if ("$($c.Panel.Background)" -ne "$want") {
                        throw "the rail card '$($c.Name)' reads $($c.Panel.Background) under the pointer, expected $want"
                    }
                    & $hoverEl $c.Panel $true
                    $rest = $(if ($held) { $sel } else { $flat })
                    if ("$($c.Panel.Background)" -ne "$rest") {
                        throw "the rail card '$($c.Name)' reads $($c.Panel.Background) after the pointer left, expected $rest"
                    }
                    if (-not $held) { $tinted++ }
                }
                if (-not $tinted) { throw 'every rail card claimed to be the highlighted one' }
                # Separators are not places to go, so they must not light up or
                # answer the pointer at all.
                foreach ($s in @($idxEntriesL | Where-Object { $_.Kind -eq 'sep' })) {
                    if ($s.Panel.IsHitTestVisible) { throw "the section title '$($s.Name)' takes the pointer" }
                }
                $row = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })[0]
                if (-not $row) { throw 'no visible row to hover' }
                & $hoverEl $row.Panel $false
                if ("$($row.Panel.Background)" -ne "$hover") { throw 'item rows do not tint under the pointer' }
                & $hoverEl $row.Panel $true
                if ("$($row.Panel.Background)" -ne "$flat") { throw 'an item row kept its tint after the pointer left' }
            }.GetNewClosure()
            # A control that is never given a Foreground keeps the system one,
            # which is black - and on the dark page that is black on black: the
            # control is there, sized and clickable, with an invisible label.
            # "Selected first" shipped that way. Rather than measure contrast,
            # this asks the question that actually went wrong - is this text
            # painted out of the theme at all? - which needs no threshold and
            # names the element instead of a ratio.
            & $try 'every label on both screens is painted out of the theme' {
                $owned = @{}
                foreach ($d in @($winL.Resources.MergedDictionaries)) {
                    foreach ($k in @($d.Keys)) {
                        if ("$k" -notlike 'Wd*') { continue }
                        if ($d[$k] -is [Windows.Media.Brush]) { $owned["$($d[$k])"] = "$k" }
                    }
                }
                if ($owned.Count -lt 5) { throw "the theme owns $($owned.Count) brush(es), so this would pass by knowing nothing" }
                # System chrome keeps its own colors on purpose: a Button, a
                # text box and a drop-down are light-faced in both themes, and
                # this file explains why in three places. Everything inside one
                # belongs to it.
                #
                # A CheckBox is a ButtonBase and a ToggleButton, so exempting
                # either of those by name exempted the one control this check
                # exists for. A tick box draws its label on the page's own
                # background in its own Foreground - it is not chrome, whatever
                # it inherits from - so it is named back in.
                $chrome = @([Windows.Controls.Primitives.ButtonBase], [Windows.Controls.TextBox],
                            [Windows.Controls.ComboBox], [Windows.Controls.ListBox],
                            [Windows.Controls.Primitives.ScrollBar], [Windows.Controls.ProgressBar])
                $notChrome = @([Windows.Controls.CheckBox], [Windows.Controls.RadioButton])
                $strays = New-Object System.Collections.Generic.List[string]
                $seen   = @{ N = 0 }
                $walk = {
                    param($El, [bool]$InChrome)
                    if (-not ($El -is [Windows.FrameworkElement]) -or -not $El.IsVisible) { return }
                    $chr = $InChrome
                    foreach ($t in $chrome)    { if ($t.IsInstanceOfType($El)) { $chr = $true } }
                    foreach ($t in $notChrome) { if ($t.IsInstanceOfType($El)) { $chr = $false } }
                    if (-not $chr) {
                        # Only the things that actually put text on the page,
                        # and the brush that actually paints it. A row's
                        # CheckBox has no content of its own - its label is the
                        # TextBlock beside it - so its foreground paints
                        # nothing; a TextBlock built from Runs paints from the
                        # Runs, and its own foreground is never used.
                        $pairs = @()
                        if ($El -is [Windows.Controls.TextBlock]) {
                            if ($El.Inlines.Count) {
                                foreach ($il in $El.Inlines) {
                                    if ("$($il.Text)") { $pairs += ,@("$($il.Text)", $il.Foreground) }
                                }
                            } elseif ($El.Text) {
                                $pairs += ,@([string]$El.Text, $El.Foreground)
                            }
                        } elseif ($El -is [Windows.Controls.ContentControl] -and $El.Content -is [string] -and $El.Content) {
                            $pairs += ,@([string]$El.Content, $El.Foreground)
                        }
                        foreach ($pr in $pairs) {
                            $seen.N++
                            if ($owned.ContainsKey("$($pr[1])")) { continue }
                            $nm = $(if ($El.Name) { [string]$El.Name } else { [string]$pr[0] })
                            if ($nm.Length -gt 28) { $nm = $nm.Substring(0, 28) }
                            $strays.Add("$($El.GetType().Name) '$nm' is painted $($pr[1])")
                        }
                    }
                    foreach ($k in @([Windows.LogicalTreeHelper]::GetChildren($El))) { & $walk $k $chr }
                }
                # Both screens, walked where they are actually on: a collapsed
                # element has no layout and reports itself invisible, so the
                # page has to be open for its labels to be reachable at all.
                & $clickBtn $uiL.BtnAdvanced
                $uiL.PageAdvanced.UpdateLayout()
                foreach ($root in @($uiL.PageAdvanced, $uiL.HeaderBar)) { & $walk $root $false }
                $onAdv = $seen.N
                & $clickBtn $uiL.BtnBackModes
                $uiL.PageModes.UpdateLayout()
                & $walk $uiL.PageModes $false
                if ($onAdv -lt 100) { throw "only $onAdv piece(s) of text on Advanced were reachable, so this proves nothing" }
                if ($seen.N -le $onAdv) { throw 'the mode screen contributed no text at all' }
                if ($strays.Count) {
                    throw "$($strays.Count) of $($seen.N) not from the theme: " + (@($strays | Select-Object -First 6) -join '; ')
                }
                & $clickBtn $uiL.BtnAdvanced
            }.GetNewClosure()
            & $try 'ordering re-lays the list without losing or moving anything between sections' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                $wasG = [string]$stateL.Group
                $wasS = [string]$stateL.Sort
                $laid = @($rowsL)

                foreach ($mode in @($ordersL.Keys)) {
                    $stateL.Group = $mode
                    & $orderL

                    # Every row is still on the page in every order, except the
                    # sections a grouping deliberately omits - and those have to
                    # be off the page rather than merely unparented, which the
                    # bloat test above asserts from the other direction.
                    foreach ($r in $laid) {
                        if ($stateL.OffPage.Contains([string]$r.Id)) { continue }
                        $where = & $secOfL $r.Panel
                        if (-not $where) { throw "$($r.Id) fell out of the page under '$mode'" }
                        if ($stateL.Sectioned -and $where -ne [string]$r.Section) {
                            throw "$($r.Id) says $($r.Section) and was laid out in $where under '$mode'"
                        }
                    }

                    # A dependent row must be in the same column as its parent
                    # and below it. Same column is the load-bearing half: an
                    # indented option at the top of the other column is indented
                    # under nothing at all.
                    foreach ($r in @($laid | Where-Object { $_.Requires })) {
                        if ($stateL.OffPage.Contains([string]$r.Id)) { continue }
                        $par = $rowByIdL[$r.Requires]
                        if (-not $par) { continue }
                        $col = & $colOfL $r.Panel
                        if (-not $col) { throw "$($r.Id) is nowhere under '$mode'" }
                        $pi = $col.Children.IndexOf($par.Panel)
                        if ($pi -lt 0) { throw "$($r.Id) was split from $($par.Id) under '$mode'" }
                        if ($col.Children.IndexOf($r.Panel) -lt $pi) { throw "$($r.Id) sits above $($par.Id) under '$mode'" }
                    }

                    # Category headings only mean something when the grouping is
                    # by category; under any other one they belong to blocks that
                    # are not on the page, and a detached block still claiming to
                    # be Visible is a lie waiting to be read.
                    $shownHeads = @($headsAllL | Where-Object { $_.Head.Visibility -eq 'Visible' }).Count
                    if ($mode -eq 'category') {
                        if (-not $shownHeads) { throw 'by-category drew no headings' }
                    } elseif ($shownHeads) {
                        throw "$shownHeads category heading(s) survived the '$mode' grouping, which does not use them"
                    }
                }

                # Rows in the order the page reads them: every live block in rail
                # order, left column then right. Read from the laid-out page, not
                # from the lists it was built from, because the whole point of
                # this is whether the layout matches the arrangement asked for.
                # The two checks below used to walk ColLeft.Children looking for
                # row panels - ColLeft has held group blocks since the layout
                # changed, so both loops ran over an empty list and asserted
                # nothing at all.
                $ofPanel = @{}
                foreach ($r in $rowsL) { $ofPanel[$r.Panel] = $r }
                $pageRows = {
                    $out = New-Object System.Collections.Generic.List[psobject]
                    foreach ($g in $liveGrpL) {
                        foreach ($col in @($g.L, $g.R)) {
                            foreach ($ch in $col.Children) {
                                if ($ofPanel.ContainsKey($ch)) { $out.Add($ofPanel[$ch]) }
                            }
                        }
                    }
                    # No leading comma. This feeds a pipeline, so the rows have
                    # to arrive one at a time; ",$out" hands the whole List over
                    # as a single object, Where-Object then tests the List's own
                    # (member-enumerated) properties, and the filter drops
                    # everything while looking like it simply found nothing.
                    $out
                }

                # And the arrangement is actually an arrangement. Grouping and
                # sort are separate controls, so each is asked for on its own and
                # then the pair is asked for together.
                $stateL.Group = 'alpha'; $stateL.Sort = 'name'; & $orderL
                $names = @(& $pageRows | Where-Object { -not $_.Requires } | ForEach-Object { [string]$_.Name.Text })
                if ($names.Count -lt 50) {
                    throw ("only $($names.Count) row(s) were laid out, so A-Z proves nothing " +
                           "(live groups $(@($liveGrpL).Count), panels known $($ofPanel.Count), " +
                           "first block holds $(if (@($liveGrpL).Count) { @($liveGrpL)[0].L.Children.Count } else { 'n/a' }))")
                }
                $sortedNames = @($names | Sort-Object)
                for ($i = 0; $i -lt $names.Count; $i++) {
                    if ($names[$i] -ne $sortedNames[$i]) { throw "A-Z put '$($names[$i])' where '$($sortedNames[$i])' belongs" }
                }

                # The two bands of the storage grouping, which is where "sort by
                # size" used to be checked. The grouping draws the boundary the
                # sort could only imply, so the assertion is about membership
                # rather than order: nothing above the floor may be in the band
                # named for what is below it.
                $stateL.Group = 'space'; $stateL.Sort = 'name'; & $orderL
                $graded = 0
                foreach ($g in $liveGrpL) {
                    if ($g.Name -eq 'Inconsequential') { continue }
                    foreach ($r in $g.Rows) {
                        if ($r.Requires) { continue }
                        $graded++
                        if ([int64](& $bytesL $r) -gt -500MB) {
                            throw "'$($r.Name.Text)' is in '$($g.Name)' and frees $((& $bytesL $r))"
                        }
                    }
                }
                if (-not $graded) { throw 'the storage grouping put nothing above the floor, so this proves nothing' }

                # The pair. Blocks come from the grouping, order inside a block
                # comes from the sort, and neither has anything to say about the
                # other - which is the whole reason there are two controls.
                $stateL.Group = 'bloat'; $stateL.Sort = 'name'; & $orderL
                foreach ($g in $liveGrpL) {
                    $inBand = @($g.Rows | Where-Object { -not $_.Requires } | ForEach-Object { [string]$_.Name.Text })
                    if ($inBand.Count -lt 3) { continue }
                    $laidOut = New-Object System.Collections.Generic.List[string]
                    foreach ($col in @($g.L, $g.R)) {
                        foreach ($ch in $col.Children) {
                            if ($ofPanel.ContainsKey($ch) -and -not $ofPanel[$ch].Requires) {
                                $laidOut.Add([string]$ofPanel[$ch].Name.Text)
                            }
                        }
                    }
                    $want = @($inBand | Sort-Object)
                    for ($i = 0; $i -lt $want.Count; $i++) {
                        if ($laidOut[$i] -ne $want[$i]) {
                            throw "in '$($g.Name)' the name sort put '$($laidOut[$i])' where '$($want[$i])' belongs"
                        }
                    }
                }

                # Selected first floats the ticked rows in whatever grouping is
                # on, and follows a preset change. It used to be offered under
                # Category alone, and it re-sorted only when its own box was
                # clicked - so switching mode left the rows the new mode had just
                # ticked sitting at the back of their block. It is the second
                # entry of the Sort drop-down now rather than a check box of its
                # own, so it is asked for the way every other sort is.
                if (-not $sortsL.Contains('selected')) { throw 'Sort by no longer offers Selected first' }
                $stateL.Sort = 'selected'
                & $orderL
                $frontFirst = {
                    param([string]$Where)
                    foreach ($g in $liveGrpL) {
                        $seenOff = $false
                        foreach ($col in @($g.L, $g.R)) {
                            $seenOff = $false
                            foreach ($ch in $col.Children) {
                                if (-not $ofPanel.ContainsKey($ch)) { continue }
                                $r = $ofPanel[$ch]
                                if ($r.Requires) { continue }
                                if ($r.Check.IsChecked) {
                                    if ($seenOff) { throw "$Where : '$($r.Name.Text)' is ticked and sits below an unticked row in '$($g.Name)'" }
                                } else { $seenOff = $true }
                            }
                        }
                    }
                }
                & $frontFirst 'under Bloat rating'
                & $clickBtn $uiL.BtnExtreme
                & $frontFirst 'after switching to Extreme'
                & $clickBtn $uiL.BtnBalanced
                & $frontFirst 'after switching back to Balanced'
                # And back to the plain alphabet, which must actually undo it -
                # a sort that only ever adds a rule is a sort that latches.
                $stateL.Sort = 'name'
                & $orderL
                $anyBelow = $false
                foreach ($g in $liveGrpL) {
                    $seenOff = $false
                    foreach ($ch in $g.L.Children) {
                        if (-not $ofPanel.ContainsKey($ch)) { continue }
                        $r = $ofPanel[$ch]
                        if ($r.Requires) { continue }
                        if ($r.Check.IsChecked -and $seenOff) { $anyBelow = $true }
                        if (-not $r.Check.IsChecked) { $seenOff = $true }
                    }
                }
                if (-not $anyBelow) { throw 'Name (A-Z) still floats every ticked row to the top' }

                # A search empties bands, and an emptied band is not a heading
                # over nothing. This walked $catHeaders, so under every grouping
                # but Category it was looking at blocks that were not on the page
                # and every band kept its heading through any search.
                $uiL.TxtFilter.Text = 'onedrive'
                $standing = @($liveGrpL | Where-Object {
                    $_.Block.Visibility -eq 'Visible' -and
                    -not @($_.Rows | Where-Object { $_.Panel.Visibility -eq 'Visible' }).Count })
                if ($standing.Count) {
                    throw "$($standing.Count) empty band(s) kept a heading through a search: $(@($standing | ForEach-Object { $_.Name }) -join ', ')"
                }
                if (-not @($liveGrpL | Where-Object { $_.Block.Visibility -eq 'Visible' }).Count) {
                    throw 'searching for onedrive emptied the whole page, so this proves nothing'
                }
                $uiL.TxtFilter.Text = ''

                $stateL.Group = $wasG; $stateL.Sort = $wasS; & $orderL
            }.GetNewClosure()
            # The answer file is written on a machine that does not exist yet, so
            # nothing about it can be checked by looking at this one. What can be
            # checked is that the form and the file agree: every field reaches
            # the options object, every option reaches the XML, and the one
            # answer that destroys data is off unless somebody said otherwise.
            # The per-item dialog is a MessageBox, so the harness cannot open
            # one - it would block the dispatcher with nobody to press OK. What
            # it can do is call the seam that builds the text, which is why the
            # seam exists. Same rule as $setOverride and $clearOverrides.
            & $try 'every row can say what it actually does to the machine' {
                & $clickBtn $uiL.BtnAdvanced
                $checked = 0
                $noLines = @()
                foreach ($c in $catsL) {
                    foreach ($i in @(Get-Prop $c 'items' @())) {
                        if (-not @(Get-Prop $i 'actions' @()).Count) { continue }
                        $txt = [string](& $detailL $i)
                        $checked++
                        if ($txt -notmatch 'WHAT THIS CHANGES') { throw "'$($i.id)' produced no detail at all" }
                        if ($txt -match 'Nothing was recorded') { $noLines += [string]$i.id }
                        if ($txt -notmatch 'Revertible: (fully|partially|no)') {
                            throw "'$($i.id)' does not say whether it can be taken back"
                        }
                        # Both of these belong to the common issues document
                        # now, and a dialog read before anything has happened is
                        # the wrong place for either.
                        if ($txt -match 'WHERE TO CHANGE IT BACK') { throw "'$($i.id)' still shows the revert instructions" }
                        if ($txt -match 'IF THIS TURNS OUT') { throw "'$($i.id)' still shows the symptoms" }
                    }
                }
                if ($checked -lt 100) { throw "only $checked item(s) were asked, so this proves nothing" }
                if ($noLines.Count) { throw "$($noLines.Count) item(s) act and describe nothing: $(@($noLines | Select-Object -First 4) -join ', ')" }
                # And the row carries a way in. The risk badge was the only one
                # and two thirds of the list has no badge.
                $row = @($rowsL | Where-Object { $_.Panel.Visibility -eq 'Visible' })[0]
                if (-not $row) { throw 'no visible row to check' }
                # A bordered chip with a hand cursor, not a word in the same
                # size and color as the tag two inches to its left. It read as
                # a label because it was one, which is the complaint this
                # replaced.
                $found = $null
                foreach ($el in $row.Panel.Children) {
                    foreach ($ch in @($el.Children)) {
                        foreach ($leaf in @($ch.Children)) {
                            if ($leaf -is [Windows.Controls.Border] -and
                                $leaf.Child -is [Windows.Controls.TextBlock] -and
                                "$($leaf.Child.Text)" -eq 'Details') { $found = $leaf }
                        }
                    }
                }
                if (-not $found) { throw 'the row has no way into the detail dialog' }
                if ("$($found.Cursor)" -ne 'Hand') { throw 'the Details control does not answer the pointer as a button' }
                if ($found.BorderThickness.Left -le 0) { throw 'the Details control has no edge, so it reads as a label' }
            }.GetNewClosure()
            # Two options that cannot both be honoured, and the page has to say
            # which one took the other away. Extreme selects both as shipped,
            # which is the case that made this necessary: a run that empties the
            # Recycle Bin beside a row promising a script that puts files back.
            & $try 'an option ruled out by another says so and cannot be ticked' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                foreach ($x in $xruleL) {
                    $src = $rowByIdL[[string]$x.When]
                    $dst = $rowByIdL[[string]$x.Blocks]
                    if (-not $src -or -not $dst) { throw "the rule names '$($x.When)'/'$($x.Blocks)' and one of them is not a row" }
                    if ($dst.Absent) { continue }

                    # Off: the blocked row is an ordinary row.
                    $src.Check.IsChecked = $false; & $rowTallyL
                    if (-not $dst.Check.IsEnabled) { throw "'$($x.Blocks)' is disabled with nothing blocking it" }
                    if ($dst.Gate.Visibility -eq 'Visible') { throw "'$($x.Blocks)' explains a block that is not in force" }

                    # On: unticked, inert, and carrying the reason.
                    $dst.Check.IsChecked = $true
                    $src.Check.IsChecked = $true; & $rowTallyL
                    if ($dst.Check.IsChecked)  { throw "'$($x.Blocks)' stayed ticked under '$($x.When)'" }
                    if ($dst.Check.IsEnabled)  { throw "'$($x.Blocks)' still takes a tick under '$($x.When)'" }
                    if ($dst.Gate.Visibility -ne 'Visible') { throw "'$($x.Blocks)' was disabled with no reason shown" }
                    if ([string]$dst.Gate.Text -ne [string]$x.Why) { throw "'$($x.Blocks)' shows the wrong reason" }

                    # And back again, or a rule would be a one-way trip.
                    $src.Check.IsChecked = $false; & $rowTallyL
                    if (-not $dst.Check.IsEnabled) { throw "'$($x.Blocks)' did not come back" }
                    if ($dst.Gate.Visibility -eq 'Visible') { throw "'$($x.Blocks)' kept the reason after the block cleared" }

                    # The preset that selects both must not read as edited for a
                    # rule it did not break: $effectiveIds drops the blocked id
                    # too, so the baseline and the boxes agree.
                    foreach ($p in @('Conservative','Balanced','Aggressive','Extreme')) {
                        $ids = @(& $effIdsL $p)
                        if ($ids -contains [string]$x.When -and $ids -contains [string]$x.Blocks) {
                            throw "$p selects both '$($x.When)' and '$($x.Blocks)'"
                        }
                    }
                    & $clickBtn $uiL.BtnExtreme
                    $d = & $diffL
                    if (@($d.Removed) -contains [string]$x.Blocks) {
                        throw "Extreme reads as edited because '$($x.Blocks)' is ruled out"
                    }
                }
                & $clickBtn $uiL.BtnBalanced
            }.GetNewClosure()

            & $try 'a row with nothing to act on cannot be ticked and does not answer the pointer' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                $absent = @($rowsL | Where-Object { $_.Absent })
                if (-not $absent.Count) {
                    Write-Host '        (nothing on this machine is absent, so this proves nothing)'
                } else {
                    foreach ($r in $absent) {
                        if ($r.Check.IsEnabled) { throw "'$($r.Id)' is not on this machine and its box still takes a tick" }
                        if ("$($r.Panel.Cursor)" -eq 'Hand') { throw "'$($r.Id)' still offers a hand cursor" }
                    }
                    # And no mode leaves one ticked. Disabling a box a preset
                    # selects would otherwise take away the only way to drop it -
                    # which is the objection that kept these tickable, and it
                    # only holds while a preset can still select them.
                    foreach ($p in @('Conservative','Balanced','Aggressive','Extreme')) {
                        & $clickBtn $uiL["Btn$p"]
                        $stuck = @($absent | Where-Object { $_.Check.IsChecked })
                        if ($stuck.Count) {
                            throw "$p ticked $($stuck.Count) row(s) that are not on this machine and cannot be unticked, e.g. '$($stuck[0].Id)'"
                        }
                    }
                    # And that must not read as an edit the user made.
                    $d = & $diffL
                    $ghost = @($d.Removed | Where-Object { $id = $_; @($absent | Where-Object { $_.Id -eq $id }).Count })
                    if ($ghost.Count) { throw "$($ghost.Count) absent row(s) are being marked as edits to the preset" }
                }
                # The pointer still works on a live one, or the check above
                # would pass on a page where nothing tints at all.
                $live = @($rowsL | Where-Object { -not $_.Absent -and $_.Panel.Visibility -eq 'Visible' })[0]
                if ($live -and "$($live.Panel.Cursor)" -ne 'Hand') { throw 'an ordinary row stopped offering a hand cursor' }
            }.GetNewClosure()
            & $try 'the answers collected beside a row follow that row in and out' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                foreach ($id in @('wu-defer-feature', 'wu-defer-quality')) {
                    if (-not $stripsL.ContainsKey($id)) { throw "'$id' has no strip beside it" }
                }
                # 'issues-doc' had one too - a folder picker asking where to
                # write the document. It went with the desktop run folder, which
                # answers the same want for every file at once, so the row must
                # now be a plain tick box.
                if ($stripsL.ContainsKey('issues-doc')) { throw 'the issues document is still asking for a folder' }
                $row = $rowByIdL['wu-defer-feature']
                $strip = $stripsL['wu-defer-feature']
                if (-not $row) { throw 'the feature deferral row is missing' }
                $was = [bool]$row.Check.IsChecked
                # These two follow their row's VISIBILITY and not its tick. The
                # number is the whole of what the option does, so it is worth
                # reading and worth setting before deciding whether to take the
                # option - which means the box cannot be hidden behind the tick
                # it is meant to inform.
                $row.Check.IsChecked = $false
                & $applyFiltL
                if ($strip.Visibility -ne 'Visible') { throw 'the days box went away with its option unticked' }
                $row.Check.IsChecked = $true
                & $applyFiltL
                if ($strip.Visibility -ne 'Visible') { throw 'the days box stayed hidden with its option ticked' }
                # Off the page is the other half, and it is the half a strip gets
                # wrong: it is a sibling of its row rather than a child, so
                # nothing hides it implicitly and a filtered-away row used to
                # leave its box sitting under whatever row landed above it.
                $uiL.TxtFilter.Text = 'zzz-nothing-matches-this'
                try {
                    if ($row.Panel.Visibility -ne 'Collapsed') { throw 'the search box did not take the row away' }
                    if ($strip.Visibility -ne 'Collapsed') { throw 'the days box stayed on a page its row had left' }
                } finally { $uiL.TxtFilter.Text = '' }
                if ($strip.Visibility -ne 'Visible') { throw 'the days box did not come back with its row' }
                # And the number reaches the state the run reads from.
                $box = @($strip.Child.Children | Where-Object { $_ -is [Windows.Controls.TextBox] })[0]
                if (-not $box) { throw 'the days box has no text field' }
                # "Defer for [ 30 ] days (max 365)". The ceiling is a fact about
                # the field rather than the end of the sentence, so it is in
                # parentheses after the unit; "days, up to 365" read as one
                # phrase and left the reader working out which number the box
                # wanted.
                $said = (@($strip.Child.Children |
                           Where-Object { $_ -is [Windows.Controls.TextBlock] } |
                           ForEach-Object { [string]$_.Text }) -join ' ')
                if ($said -notmatch '^Defer for\b') { throw "the days row opens with '$said'" }
                if ($said -notmatch '\(max 365\)')  { throw "the days row does not say its ceiling: '$said'" }
                $box.Text = '9999'
                $box.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.TextBoxBase]::LostFocusEvent)))
                if ([int]$stateL.DeferDays.Feature -ne 365) {
                    throw "9999 days was accepted as $($stateL.DeferDays.Feature); Windows ignores anything over 365"
                }
                if ("$($box.Text)" -ne '365') { throw 'the box still shows a number that will not be written' }
                $row.Check.IsChecked = $was
                & $applyFiltL
            }.GetNewClosure()
            & $try 'the default-browser row appears only when there is a browser for it' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                if (-not $gateL.ContainsKey('set-default-browser')) { throw 'the row is not gated at all' }
                $row = $rowByIdL['set-default-browser']
                if (-not $row) { throw 'the default-browser row is missing' }
                $wasChoice = @($stateL.BrowserChoices)
                & $setBrowL @() $false
                $withNone = ($row.Panel.Visibility -eq 'Visible')
                & $setBrowL @('Mozilla Firefox') $false
                if ($row.Panel.Visibility -ne 'Visible') { throw 'queuing a browser did not bring the row back' }
                & $setBrowL $wasChoice $false
                # On a machine that already has another browser the row is
                # always there, and this says which case was measured rather
                # than quietly passing either way.
                Write-Host "        (another browser installed: $(if ($withNone) { 'yes' } else { 'no' }))"
            }.GetNewClosure()
            & $try 'the index rail can be resized and remembers it' {
                & $clickBtn $uiL.BtnAdvanced
                if (-not $uiL.IndexSplit) { throw 'there is no splitter beside the rail' }
                $was = [double]$uiL.IndexCol.Width.Value
                $uiL.IndexCol.Width = New-Object Windows.GridLength 260
                $uiL.PageAdvanced.UpdateLayout()
                if ([double]$uiL.IndexCol.Width.Value -ne 260) { throw 'the rail column would not take a new width' }
                if ([double]$uiL.IndexCol.MinWidth -le 0 -or [double]$uiL.IndexCol.MaxWidth -le [double]$uiL.IndexCol.MinWidth) {
                    throw 'the rail column has no sane bounds, so a drag could put the list off the page'
                }
                $uiL.IndexCol.Width = New-Object Windows.GridLength $was
                $uiL.PageAdvanced.UpdateLayout()
            }.GetNewClosure()
            & $try 'the answer file page is a form over the file it writes' {
                & $clickBtn $uiL.BtnUnattend
                if ($uiL.PageUnattend.Visibility -ne 'Visible') { throw 'the answer file page did not open' }
                # Asserted on the click alone, and before the two calls below,
                # or it asserts nothing: $uaBuild marks itself Done on the way
                # in, so the same test after one of those can never fail.
                #
                # What this cannot prove is the fix it belongs to. The page is
                # now built before it is shown rather than after - it used to
                # swap the pages over, pump a frame, and then build, which
                # painted the empty page on purpose. Both orders finish inside
                # the click, so a synchronous check afterwards sees the same
                # thing either way; the difference is which frame was painted in
                # between, and nothing here can see a frame. What is checked is
                # the weaker standing claim - opening the page leaves it built
                # and populated - and the figure below is the honest measure of
                # how much there was to hide.
                if (-not $uaBuiltL.Done) { throw 'the page was shown before it was built' }
                if (-not $uiL.UaContent.Children.Count) { throw 'the page was shown with nothing on it' }
                Write-Host "  ua page      : built in $($uaBuiltL.Ms)ms"
                & $uaBuildL
                & $uaPaintL
                if (-not $uiL.UaContent.Children.Count) { throw 'the page built no sections' }
                if ($uiL.UaIndexPanel.Children.Count -ne $uaHeadsL.Count) {
                    throw "$($uiL.UaIndexPanel.Children.Count) rail card(s) for $($uaHeadsL.Count) section(s)"
                }
                # Every authored field is on the page and readable. A field that
                # exists in the table and not in the form is a control somebody
                # sets that the file then ignores - silent, and the exact shape
                # of bug this table exists to prevent.
                foreach ($f in $uaFieldsL) {
                    if (-not @($uaCtrlsL | Where-Object { $_.Key -eq [string]$f.K }).Count) {
                        throw "the field '$($f.K)' is in the table and not on the page"
                    }
                }
                $o = & $uaGenL
                if (-not $o.Check.Ok) { throw "the default form produces a bad file: $($o.Check.Problems -join '; ')" }
                # Untouched, the page has to produce the file most people want,
                # because that is the whole of its answer to "usable by anyone".
                foreach ($want in @('BypassNRO', 'HideOnlineAccountScreens', 'BypassTPMCheck', 'AllowTelemetry', '<LocalAccount ')) {
                    if ($o.Xml -notmatch [regex]::Escape($want)) { throw "the default file is missing $want" }
                }
                if ($o.Xml -match '<WillWipeDisk>') { throw 'the default file wipes a disk' }
                # Compared as a code point, not with StartsWith. U+FEFF is a
                # zero-width no-break space, and .NET's default culture-sensitive
                # comparison treats it as ignorable - so "<?xml".StartsWith(BOM)
                # is TRUE and the assertion fails on a perfectly good file.
                if ($o.Xml.Length -and [int]$o.Xml[0] -eq 0xFEFF) { throw 'the generated XML starts with a byte order mark' }
                # And the form actually drives it, rather than the defaults
                # being generated twice. One field of each kind is moved.
                $byKey = @{}
                foreach ($c in $uaCtrlsL) { $byKey[$c.Key] = $c }
                $byKey['ComputerName'].Ctrl.Text = 'WD-TEST-PC'
                $byKey['BypassHardwareChecks'].Ctrl.IsChecked = $false
                foreach ($rb in $byKey['AccountGroup'].Ctrl) { $rb.IsChecked = ([string]$rb.Tag -eq 'Users') }
                $byKey['ExtraFirstLogon'].Ctrl.Text = "echo one`r`n`r`necho two"
                $o2 = & $uaGenL
                if (-not $o2.Check.Ok) { throw "an edited form produces a bad file: $($o2.Check.Problems -join '; ')" }
                if ($o2.Options.ComputerName -ne 'WD-TEST-PC') { throw 'the computer name did not reach the options' }
                if ($o2.Options.AccountGroup -ne 'Users') { throw 'the account type radio did not reach the options' }
                if (@($o2.Options.ExtraFirstLogon).Count -ne 2) {
                    throw "the command box produced $(@($o2.Options.ExtraFirstLogon).Count) command(s), expected 2 with the blank line dropped"
                }
                if ($o2.Xml -notmatch 'WD-TEST-PC') { throw 'the computer name did not reach the file' }
                if ($o2.Xml -match 'BypassTPMCheck') { throw 'the hardware bypass was unticked and is still in the file' }
                # Put it back, and prove the disk answer is reachable at all -
                # a control nothing can select is a control that only looks safe.
                $byKey['ComputerName'].Ctrl.Text = ''
                $byKey['BypassHardwareChecks'].Ctrl.IsChecked = $true
                foreach ($rb in $byKey['AccountGroup'].Ctrl) { $rb.IsChecked = ([string]$rb.Tag -eq 'Administrators') }
                $byKey['ExtraFirstLogon'].Ctrl.Text = ''
                foreach ($rb in $byKey['DiskLayout'].Ctrl) { $rb.IsChecked = ([string]$rb.Tag -eq 'wipe-gpt') }
                $o3 = & $uaGenL
                if ($o3.Xml -notmatch '<WillWipeDisk>') { throw 'asking to wipe the disk produced a file that does not' }
                foreach ($rb in $byKey['DiskLayout'].Ctrl) { $rb.IsChecked = ([string]$rb.Tag -eq 'none') }
                $o4 = & $uaGenL
                if ($o4.Xml -match '<WillWipeDisk>') { throw 'the disk answer latched on once it had been set' }
                if ("$($uiL.TxtUaTally.Text)" -notmatch '\d') { throw 'the footer does not say what the file carries' }
                & $clickBtn $uiL.BtnUaBack
                if ($uiL.PageModes.Visibility -ne 'Visible') { throw 'Back from the answer file page did not return to the modes' }
            }.GetNewClosure()
            & $try 'the setup file page defaults safely and drives its drop-downs' {
                & $clickBtn $uiL.BtnUnattend
                & $uaBuildL
                $byKey = @{}
                foreach ($c in $uaCtrlsL) { $byKey[$c.Key] = $c }

                # The note before the fields. Somebody who has never made one of
                # these arrives at a form, and the one thing they have to be
                # told is what it is and that it does nothing to this machine.
                if ([string]$uaHeadsL[0].Key -ne 'note') {
                    throw "the page opens on '$($uaHeadsL[0].Name)' rather than the note"
                }

                # Automatic sign-in is off, and stays off. It is the one default
                # on this page that hands the machine to whoever is standing at
                # it, and a default that drifts here is not something anybody
                # would notice until it mattered.
                if ($byKey['AutoLogon'].Ctrl.IsChecked) { throw 'automatic sign-in is ticked by default' }
                $o = & $uaGenL
                if ($o.Options.AutoLogon) { throw 'the options default automatic sign-in on' }
                if ($o.Xml -match '<AutoLogon>') { throw 'the default file signs in automatically' }
                # And it is reachable, or the check above passes on a control
                # that does nothing.
                $byKey['AutoLogon'].Ctrl.IsChecked = $true
                $on = & $uaGenL
                if ($on.Xml -notmatch '<AutoLogon>') { throw 'ticking automatic sign-in changed nothing' }
                if ($on.Xml -notmatch '<LogonCount>') { throw 'automatic sign-in has no count' }
                $byKey['AutoLogon'].Ctrl.IsChecked = $false

                # The three drop-downs, and the one thing that makes them worth
                # having: picking a display language moves the two locales with
                # it, so the ordinary case is one gesture rather than three.
                foreach ($k in @('UILanguage','SystemLocale','UserLocale','InputLocale','TimeZone')) {
                    if ($byKey[$k].Kind -ne 'combo') { throw "$k is a $($byKey[$k].Kind), not a drop-down" }
                    if ($byKey[$k].Ctrl.Items.Count -lt 5) { throw "$k offers $($byKey[$k].Ctrl.Items.Count) choice(s)" }
                    if (-not $byKey[$k].Ctrl.SelectedItem) { throw "$k has nothing selected" }
                }
                # Readable names, not codes: the keyboard is the field this was
                # worst on and the one nobody can answer from a code.
                $kb = [string]$byKey['InputLocale'].Ctrl.SelectedItem.Content
                if ($kb -match '^[0-9a-f]{4}:') { throw "the keyboard list shows codes: '$kb'" }
                # The time zone list is read off Windows, and its first entry is
                # the one that lets Setup decide.
                if ([string]$byKey['TimeZone'].Ctrl.SelectedItem.Tag -ne '') { throw 'the time zone does not default to automatic' }

                $want = 'de-DE'
                foreach ($it in $byKey['UILanguage'].Ctrl.Items) {
                    if ([string]$it.Tag -eq $want) { $byKey['UILanguage'].Ctrl.SelectedItem = $it }
                }
                $r = & $uaGenL
                if ($r.Options.UILanguage -ne $want) { throw "the language drop-down did not reach the options" }
                if ($r.Options.SystemLocale -ne $want) { throw 'the system locale did not follow the language' }
                if ($r.Options.UserLocale -ne $want) { throw 'the date format did not follow the language' }
                if ($r.Xml -notmatch $want) { throw 'the language did not reach the file' }
                # The coupling is a checkbox now, and this is what changed with
                # it. It used to follow "until somebody sets one of the two
                # deliberately", which this test asserted by setting one and
                # checking it stopped - a good rule that nothing on the page
                # ever mentioned, so nobody could know it existed or that it had
                # ended. The tick says both. What is asserted now is that it
                # does what it says: on, they follow; off, they do not.
                if (-not $byKey['SyncLocales'].Ctrl.IsChecked) { throw 'the locale sync is not on by default' }
                foreach ($it in $byKey['UserLocale'].Ctrl.Items) {
                    if ([string]$it.Tag -eq 'en-GB') { $byKey['UserLocale'].Ctrl.SelectedItem = $it }
                }
                foreach ($it in $byKey['UILanguage'].Ctrl.Items) {
                    if ([string]$it.Tag -eq 'fr-FR') { $byKey['UILanguage'].Ctrl.SelectedItem = $it }
                }
                $r2 = & $uaGenL
                if ($r2.Options.UserLocale -ne 'fr-FR') { throw 'the date format did not follow with the sync on' }
                if ($r2.Options.SystemLocale -ne 'fr-FR') { throw 'the system locale did not follow with the sync on' }
                # Cleared, and now they hold whatever they are set to. IsChecked
                # then Click: $clickBtn raises the routed event without running
                # the CheckBox's own toggle, so a bare click would fire the
                # handler against the old state.
                $byKey['SyncLocales'].Ctrl.IsChecked = $false
                & $clickBtn $byKey['SyncLocales'].Ctrl
                foreach ($it in $byKey['UserLocale'].Ctrl.Items) {
                    if ([string]$it.Tag -eq 'en-GB') { $byKey['UserLocale'].Ctrl.SelectedItem = $it }
                }
                foreach ($it in $byKey['UILanguage'].Ctrl.Items) {
                    if ([string]$it.Tag -eq 'de-DE') { $byKey['UILanguage'].Ctrl.SelectedItem = $it }
                }
                $r3 = & $uaGenL
                if ($r3.Options.UserLocale -ne 'en-GB') { throw 'the date format followed the language with the sync off' }
                # And ticking it again applies it there and then, rather than
                # waiting for the next time the language happens to change.
                $byKey['SyncLocales'].Ctrl.IsChecked = $true
                & $clickBtn $byKey['SyncLocales'].Ctrl
                $r4 = & $uaGenL
                if ($r4.Options.UserLocale -ne 'de-DE') { throw 'ticking the sync did not apply it' }
                if ($r4.Options.SystemLocale -ne 'de-DE') { throw 'ticking the sync missed the system locale' }
                foreach ($it in $byKey['UILanguage'].Ctrl.Items) {
                    if ([string]$it.Tag -eq 'en-US') { $byKey['UILanguage'].Ctrl.SelectedItem = $it }
                }
                foreach ($it in $byKey['UserLocale'].Ctrl.Items) {
                    if ([string]$it.Tag -eq 'en-US') { $byKey['UserLocale'].Ctrl.SelectedItem = $it }
                }

                # Wi-Fi was collected and silently dropped for its whole first
                # life - the fields existed and nothing read them. This is the
                # assertion that would have caught it.
                $byKey['WifiSsid'].Ctrl.Text = 'WD Test Network'
                $byKey['WifiPassword'].Ctrl.Password = 'not-a-real-password'
                $w = & $uaGenL
                if (-not $w.Check.Ok) { throw "a Wi-Fi network produced a bad file: $($w.Check.Problems -join '; ')" }
                if ($w.Xml -notmatch 'wlan add profile') { throw 'a Wi-Fi network wrote no profile' }
                $byKey['WifiSsid'].Ctrl.Text = ''
                $byKey['WifiPassword'].Ctrl.Password = ''

                # And the run-a-preset option, which needs two commands in two
                # different passes to work at all. Whether it happens is the
                # section's own On/Off now, not a "do not" entry in the mode
                # list - so the switch is what this drives, and the default has
                # to be off or every file anybody generates would debloat the
                # machine it installs.
                if ($byKey['RunToolkit'].Kind -ne 'switch') { throw 'the toolkit section has no On/Off' }
                $off = & $uaGenL
                if ($off.Options.RunToolkit) { throw 'auto-debloat is on by default' }
                if ($off.Xml -match 'Setup\\Scripts\\WinSetupToolkit') { throw 'the default file runs the toolkit' }
                foreach ($rb in $byKey['RunToolkit'].Ctrl) { $rb.IsChecked = [bool]$rb.Tag.On }
                foreach ($rb in $byKey['RunPreset'].Ctrl) { $rb.IsChecked = ([string]$rb.Tag -eq 'Balanced') }
                $rp = & $uaGenL
                if (-not $rp.Check.Ok) { throw "running a preset produced a bad file: $($rp.Check.Problems -join '; ')" }
                if ($rp.Xml -notmatch 'WinSetupToolkit\.ps1') { throw 'nothing in the file runs the toolkit' }
                if ($rp.Xml -notmatch 'Setup\\Scripts\\WinSetupToolkit') { throw 'nothing copies the toolkit onto the machine' }
                # ---- the run is SetupComplete.cmd, and it is decoded ---------
                #
                # The .cmd body is base64 inside the specialize command, so a
                # substring search of the XML cannot see any of what it does -
                # which is exactly why this decodes it rather than asserting on
                # the wrapper. Everything below is a thing that has been wrong
                # at some point: the mode not reaching the command line, the
                # missing -Console that made the whole feature open a window and
                # wait, and the guard that keeps a machine where the copy step
                # found nothing from running a script that is not there.
                if ($rp.Xml -notmatch 'SetupComplete\.cmd') { throw 'no SetupComplete.cmd is written' }
                $b64 = ''
                if ($rp.Xml -match "FromBase64String\('([A-Za-z0-9+/=]+)'\)") { $b64 = $Matches[1] }
                if (-not $b64) { throw 'the SetupComplete.cmd body is not in the file' }
                $setupCmd = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
                if ($setupCmd -notmatch '-Preset Balanced') { throw 'the command does not name the mode' }
                if ($setupCmd -notmatch '-Console')  { throw 'the command would open the interface instead of applying' }
                if ($setupCmd -notmatch '-Apply')    { throw 'the command does not apply anything' }
                if ($setupCmd -notmatch '-SetupRun') { throw 'the command does not say it is a setup run' }
                if ($setupCmd -notmatch 'if not exist') { throw 'the command has no guard for a missing toolkit' }
                # And it is NOT in FirstLogonCommands any more. That pass runs
                # after somebody has signed in, which is the whole thing this
                # moved away from.
                $fl = ''
                if ($rp.Xml -match '(?s)<FirstLogonCommands>(.*?)</FirstLogonCommands>') { $fl = $Matches[1] }
                if ($fl -match 'WinSetupToolkit\.ps1') { throw 'the run is still queued at the first sign-in' }
                # And the switch turns it off again, which is the half a "do
                # not" entry in a list of modes used to serve.
                foreach ($rb in $byKey['RunToolkit'].Ctrl) { $rb.IsChecked = (-not [bool]$rb.Tag.On) }
                $rp2 = & $uaGenL
                if ($rp2.Xml -match 'Setup\\Scripts\\WinSetupToolkit') { throw 'the run option latched on once it had been set' }

                # ---- and it is unavailable to a standard account -------------
                #
                # The run itself needs no administrator any more - it happens as
                # Local System before anybody signs in - but the account this
                # file creates is the one that would have to undo it, and a
                # standard user cannot. Debloating a machine and leaving its
                # only account unable to reverse that is the one combination
                # this page must not be able to produce.
                $onRb = @($byKey['RunToolkit'].Ctrl | Where-Object { [bool]$_.Tag.On })
                if (-not $onRb.Count) { throw 'the toolkit section has no On' }
                foreach ($rb in $byKey['AccountGroup'].Ctrl) { $rb.IsChecked = ([string]$rb.Tag -eq 'Users') }
                if ($onRb[0].IsEnabled) { throw 'On is still available with a standard account' }
                if ($onRb[0].IsChecked) { throw 'On stayed selected after the account became standard' }
                $std = & $uaGenL
                if ($std.Options.RunToolkit) { throw 'a standard account still produced a file that debloats' }
                if ($std.Xml -match 'Setup\\Scripts\\WinSetupToolkit') { throw 'the file runs the toolkit for a standard account' }
                # Put back, and On becomes available again - a gate that only
                # closes is a gate somebody has to restart the application to
                # get past.
                foreach ($rb in $byKey['AccountGroup'].Ctrl) { $rb.IsChecked = ([string]$rb.Tag -eq 'Administrators') }
                if (-not $onRb[0].IsEnabled) { throw 'On stayed unavailable after the account went back to Administrator' }

                # The edition is a drop-down of names now rather than a text box
                # plus an index box. Two controls for one answer, one of which
                # silently beat the other.
                if ($byKey['ImageName'].Kind -ne 'combo') { throw 'the edition is not a drop-down' }
                if ($byKey.ContainsKey('ImageIndex')) { throw 'the edition number field is still on the page' }
                foreach ($it in $byKey['ImageName'].Ctrl.Items) {
                    if ([string]$it.Tag -eq 'Windows 11 Pro') { $byKey['ImageName'].Ctrl.SelectedItem = $it }
                }
                $ed = & $uaGenL
                if ($ed.Xml -notmatch 'Windows 11 Pro') { throw 'the edition did not reach the file' }
                foreach ($it in $byKey['ImageName'].Ctrl.Items) {
                    if ([string]$it.Tag -eq '') { $byKey['ImageName'].Ctrl.SelectedItem = $it }
                }

                # Accounts are added rather than fixed at two, and each one has
                # to reach the file. Driven through the real button.
                if ($byKey.ContainsKey('SecondName')) { throw 'the fixed second account is still on the page' }
                $before = @($uaAcctsL).Count
                & $clickBtn $uaAddAcctH.Btn
                & $clickBtn $uaAddAcctH.Btn
                if (@($uaAcctsL).Count -ne $before + 2) { throw "the button added $(@($uaAcctsL).Count - $before) account(s)" }
                $uaAcctsL[$uaAcctsL.Count - 2].Name.Text = 'WDGuest'
                $uaAcctsL[$uaAcctsL.Count - 1].Name.Text = 'WDSecond'
                foreach ($rb in $uaAcctsL[$uaAcctsL.Count - 1].Groups) {
                    $rb.IsChecked = ([string]$rb.Tag -eq 'Administrators')
                }
                $ac = & $uaGenL
                if (@($ac.Options.ExtraAccounts).Count -ne 2) {
                    throw "$(@($ac.Options.ExtraAccounts).Count) extra account(s) were read back, expected 2"
                }
                if ($ac.Xml -notmatch 'WDGuest') { throw 'an added account did not reach the file' }
                if ($ac.Xml -notmatch 'WDSecond') { throw 'the second added account did not reach the file' }
                if (-not $ac.Check.Ok) { throw "two extra accounts produced a bad file: $($ac.Check.Problems -join '; ')" }
                # An account with no name is not an account. It is dropped on
                # the way out rather than emitted as a nameless LocalAccount.
                $uaAcctsL[$uaAcctsL.Count - 1].Name.Text = ''
                $ac2 = & $uaGenL
                if (@($ac2.Options.ExtraAccounts).Count -ne 1) { throw 'a nameless account was carried anyway' }
                # And Remove takes them off the page again.
                while (@($uaAcctsL).Count -gt $before) {
                    $card = $uaAcctsL[$uaAcctsL.Count - 1].Card
                    $btn = @($card.Child.Children[0].Children | Where-Object { $_ -is [Windows.Controls.Button] })[0]
                    & $clickBtn $btn
                }
                if (@($uaAcctsL).Count -ne $before) { throw 'Remove did not take the account away' }

                # ---- the saved-selection file only exists under one answer ---
                #
                # It is the one field on the page that means nothing under four
                # of the five answers to the question above it, and it used to
                # sit there under all five with "Only for the last option"
                # printed underneath.
                $profCard = $byKey['RunProfileFile'].Card
                if ($profCard.Visibility -ne 'Collapsed') {
                    throw 'the saved selection file is on the page with a mode selected'
                }
                foreach ($rb in $byKey['RunPreset'].Ctrl) {
                    $rb.IsChecked = ([string]$rb.Tag -eq 'profile')
                }
                if ($profCard.Visibility -ne 'Visible') { throw 'choosing a file did not reveal the file field' }
                foreach ($rb in $byKey['RunPreset'].Ctrl) {
                    $rb.IsChecked = ([string]$rb.Tag -eq 'Balanced')
                }
                if ($profCard.Visibility -ne 'Collapsed') { throw 'the file field stayed after choosing a mode' }
                # And the answer itself still round-trips, which is what the
                # gating could have broken: the radios carry their value on the
                # Tag and the reveal must not be wearing that slot.
                $rp3 = & $uaGenL
                if ($rp3.Options.RunPreset -ne 'Balanced') {
                    throw "the mode came back as '$($rp3.Options.RunPreset)'"
                }

                # ---- the wipe labels name the disk that is actually typed ----
                #
                # "Erase disk 0" beside a Disk number box reading 2 is the form
                # being wrong about which drive it destroys, in the one place on
                # this page where being wrong cannot be undone.
                $wipe = @($byKey['DiskLayout'].Ctrl | Where-Object { [string]$_.Tag -eq 'wipe-gpt' })
                if (-not $wipe.Count) { throw 'the GPT wipe option is missing' }
                $byKey['DiskId'].Ctrl.Text = '2'
                if ([string]$wipe[0].Content -notmatch 'disk 2\b') {
                    throw "the wipe label reads '$($wipe[0].Content)' with disk 2 typed"
                }
                if ([string]$wipe[0].Content -match '\$0') { throw 'the label still shows its placeholder' }
                $byKey['DiskId'].Ctrl.Text = '0'
                if ([string]$wipe[0].Content -notmatch 'disk 0\b') {
                    throw "the wipe label did not go back: '$($wipe[0].Content)'"
                }

                # The computer name refuses what Windows will not accept, as it
                # is typed - not afterwards, on the machine, at a screen this
                # file was written to skip.
                if ([int]$byKey['ComputerName'].Ctrl.MaxLength -ne 15) {
                    throw "the computer name accepts $($byKey['ComputerName'].Ctrl.MaxLength) characters"
                }
                $byKey['ComputerName'].Ctrl.Text = 'has spaces here'
                if ([string]$byKey['ComputerName'].Ctrl.Text -match '\s') {
                    throw "the computer name kept its spaces: '$($byKey['ComputerName'].Ctrl.Text)'"
                }
                $byKey['ComputerName'].Ctrl.Text = ''

                # Bypassing the internet requirement empties the rest of the
                # Wi-Fi section rather than leaving four fields that mean
                # nothing beside it. It is bypassed by default, so the section
                # starts as the one question - which is the state most files
                # want and the reason this is worth doing at all.
                #
                # IsChecked is set and then Click raised: $clickBtn raises the
                # routed event without running the CheckBox's own toggle, so a
                # bare click would fire the handler against the old state.
                $wifiBox = $byKey['BypassInternet'].Ctrl
                if (-not $wifiBox.IsChecked) { throw 'the internet requirement is not bypassed by default' }
                if ($byKey['WifiSsid'].Card.Visibility -ne 'Collapsed') {
                    throw 'the Wi-Fi fields are on the page with the internet requirement bypassed'
                }
                $wifiBox.IsChecked = $false; & $clickBtn $wifiBox
                if ($byKey['WifiSsid'].Card.Visibility -ne 'Visible') { throw 'the Wi-Fi fields did not appear' }
                if ($byKey['NetworkLocation'].Card.Visibility -ne 'Visible') { throw 'the network type did not appear' }
                $wifiBox.IsChecked = $true; & $clickBtn $wifiBox
                if ($byKey['WifiSsid'].Card.Visibility -ne 'Collapsed') { throw 'the Wi-Fi fields did not go again' }

                & $clickBtn $uiL.BtnUaBack
            }.GetNewClosure()

            # A selection loaded from a file is a preset everywhere except the
            # mode grid. That is four screens and one settings file, and the
            # failure this guards against is the quiet one: it appears in
            # Advanced, works there, and turns out to be missing from Compare.
            & $try 'a selection loaded from a file becomes a preset everywhere' {
                $tmp = Join-Path ([IO.Path]::GetTempPath()) "wd-selftest-load-$([Guid]::NewGuid().ToString('N').Substring(0,8)).json"
                # Real ids plus one that is not, so the machine-filtering half
                # is exercised rather than assumed.
                $real = @($rowsL | Where-Object { -not $_.Absent } | Select-Object -First 6 | ForEach-Object { $_.Id })
                if ($real.Count -lt 3) { throw 'not enough live rows to build a selection from' }
                $null = Save-WDSelection -Selected (@($real) + @('wd-not-a-real-id')) -Path $tmp
                $before = @($presetNamesL).Count
                # Declared out here so the finally can clean them up whichever
                # assertion the run dies on. A copy left registered would put
                # the preset list one longer than it started and fail the last
                # line of this test rather than the line that actually broke.
                $copyName = ''
                $tmp2     = ''
                try {
                    $name = & $regLoadL $tmp
                    if (-not $name) { throw 'the file did not load' }
                    & $loadRefreshL
                    if (@($presetNamesL).Count -ne $before + 1) { throw 'the preset list did not grow' }
                    if ($shippedL -contains $name) { throw 'a loaded file joined the shipped modes' }
                    # And it is in what the settings file would be handed, which
                    # is what brings it back tomorrow. Unsaved edits are the one
                    # thing that file deliberately forgets, and a loaded
                    # selection is not one of them - it is a file somebody went
                    # and found. The path rather than the ids, because the file
                    # is theirs and re-reading it is the point.
                    if (@((& $uiOutL).loadedPresets) -notcontains $tmp) {
                        throw 'the loaded file is not in what the settings file would keep'
                    }
                    # Filtered to what this machine has: the made-up id is gone.
                    $ids = @(& $effIdsL $name)
                    if ($ids -contains 'wd-not-a-real-id') { throw 'an id this machine has never heard of survived the load' }
                    if (@($ids).Count -ne $real.Count) { throw "$($ids.Count) id(s) came back, expected $($real.Count)" }
                    # ---- and what was dropped is said, not swallowed ---------
                    #
                    # "42 of 48 apply here" tells somebody six things went and
                    # nothing about which six or why, on the screen where that
                    # decides whether the file is still the one they meant.
                    $said = [string](& $droppedL @($name))
                    if (-not $said) { throw 'the load dropped an id and reported nothing' }
                    if ($said -notmatch 'wd-not-a-real-id') {
                        throw "the report does not name what it dropped: '$said'"
                    }
                    if ($said -notmatch 'different build') {
                        throw "the report does not say why it dropped it: '$said'"
                    }
                    # A file with nothing wrong with it gets no dialog at all.
                    if ([string](& $droppedL @('Balanced'))) {
                        throw 'a preset with nothing dropped still produced a report'
                    }
                    # Advanced, Compare and the box under the columns.
                    if (-not $advBtnsL.Contains($name)) { throw 'Advanced has no button for it' }
                    if (-not $cmpBtnsL['A'].ContainsKey($name)) { throw 'the Compare picker has no button for it' }
                    # Found by name, not taken as Children[0]. The box lists
                    # every file that has been loaded, and one loaded in an
                    # earlier session is restored at startup and sits above
                    # this one - so the first row belongs to somebody else and
                    # the assertions below were about the wrong preset.
                    $mine = @($uiL.LoadedPanel.Children |
                              Where-Object { $_.Tag -and [string]$_.Tag.Name -eq $name })
                    if (-not $mine.Count) { throw 'the box under the columns has no row for it' }
                    # And the mode grid is still five columns wide.
                    if (@($colsL.Keys).Count -ne $shippedL.Count) {
                        throw "the mode grid grew to $(@($colsL.Keys).Count) columns"
                    }
                    # Selectable from Advanced.
                    & $clickBtn $advBtnsL[$name]
                    if ($stateL.Preset -ne $name) { throw 'the Advanced button did not select it' }

                    # And from its own row in the box, which is the route that
                    # goes through $selectPreset and therefore the only one that
                    # writes the mode screen's tally. Clicking the Advanced
                    # button above does not - it calls $applyPresetToChecks, and
                    # the mode page is not open - so asserting the tally after
                    # that read whatever the last mode click had left there.
                    & $clickBtn $uiL.BtnBalanced
                    & $clickEl $mine[0]
                    if ($stateL.Preset -ne $name) { throw 'the row in the box did not select it' }
                    # And says so where it lives. The tally under the grid used
                    # to carry "loaded from a file"; with that gone the row in
                    # the box is the one place a loaded preset can say it is the
                    # selected one, and no mode column may claim to be.
                    if ([string]$mine[0].Tag.Mark.Text -ne 'SELECTED') {
                        throw "the row reads '$($mine[0].Tag.Mark.Text)'"
                    }
                    foreach ($p in $shippedL) {
                        if ([string]$colsL[$p].Check.Text -eq 'SELECTED') {
                            throw "$p also claims to be selected"
                        }
                    }
                    # Two caps, and both matter for a different reason. The name
                    # itself is the home screen's, where a row has the width of
                    # the window; the short form is what the Advanced and
                    # Compare button rows print, where five or more sit side by
                    # side and one long one pushes the rest off the row.
                    foreach ($p in @($presetNamesL)) {
                        # ([string]$p).Length, not [string]$p.Length - the second
                        # stringifies the LENGTH and then compares "6" against
                        # "16" as text, which is true.
                        if (([string]$p).Length -gt 50) { throw "the preset name '$p' is $(([string]$p).Length) characters" }
                        $sh = [string](& $shortL ([string]$p))
                        if ($sh.Length -gt 12) { throw "the short form of '$p' is '$sh', $($sh.Length) characters" }
                    }
                    # And the short forms are distinct, or two buttons in the
                    # Advanced row read the same thing and pick different
                    # presets.
                    $shorts = @($presetNamesL | ForEach-Object { [string](& $shortL ([string]$_)) })
                    if (@($shorts | Sort-Object -Unique).Count -ne $shorts.Count) {
                        throw "two presets share a short form: $($shorts -join ', ')"
                    }

                    # ---- Save appears with Reset, and writes the file back ---
                    #
                    # The mode screen offered Reset on an edited preset and no
                    # way to keep the edit, so the only route to keeping one was
                    # a page somebody on the mode screen has no reason to open.
                    if ($uiL.PresetEditRow.Visibility -ne 'Collapsed') {
                        throw 'Save offered itself on a preset nobody has edited'
                    }
                    & $setOvL $name @() @($ids[0])
                    # Re-found, not reused. $setOverride rebuilds the mode grid,
                    # which repaints the box under it, so the Border captured
                    # before the edit is an orphan by now.
                    $mine = @($uiL.LoadedPanel.Children |
                              Where-Object { $_.Tag -and [string]$_.Tag.Name -eq $name })
                    if (-not $mine.Count) { throw 'the row went missing after the edit' }
                    & $clickEl $mine[0]
                    if ($uiL.PresetEditRow.Visibility -ne 'Visible') { throw 'Save stayed hidden on an edited preset' }
                    if ($uiL.BtnSavePreset.Content -ne 'Save') {
                        throw "the button reads '$($uiL.BtnSavePreset.Content)'"
                    }
                    # And it is standing on the card of the preset it speaks
                    # for, not in the footer. That is the whole point of the
                    # pair having no preset name on them. Walked up the logical
                    # parents rather than asked with IsDescendantOf, which reads
                    # the visual tree - and this pass never lays the page out.
                    $mine = @($uiL.LoadedPanel.Children |
                              Where-Object { $_.Tag -and [string]$_.Tag.Name -eq $name })
                    $p = $uiL.PresetEditRow; $hops = 0
                    while ($p -and $p -ne $mine[0] -and $hops -lt 8) { $p = $p.Parent; $hops++ }
                    if ($p -ne $mine[0]) { throw "the Save/Reset row is not on $name's own row" }
                    # Written through the seam rather than the dialog: the dialog
                    # blocks, and what is being tested is that saving to the file
                    # it came from leaves the preset unedited and the file
                    # holding what the preset holds.
                    & $saveLoadedL $name $tmp
                    if ($uiL.PresetEditRow.Visibility -ne 'Collapsed') {
                        throw 'the preset still reads as edited after being saved'
                    }
                    $onDisk = @(Import-WDSelection -Path $tmp)
                    $now    = @(& $effIdsL $name)
                    if (@($onDisk).Count -ne @($now).Count) {
                        throw "the file holds $(@($onDisk).Count) id(s) and the preset $(@($now).Count)"
                    }

                    # ---- saved to another file: three things, one gesture ----
                    #
                    # The file is written, loaded as a preset of its own and
                    # selected, and the preset it came from goes back to its
                    # default. It used to do the first of those and nothing
                    # else, so the thing you had just made was the one thing not
                    # in front of you and the preset stayed edited; before that
                    # it renamed the source and re-pointed it, which took the
                    # original off the list entirely.
                    $tmp2 = Join-Path ([IO.Path]::GetTempPath()) 'wd-selftest-copy.json'
                    # Read before the edit, so "back to its default" below is
                    # measured against what this preset really was rather than
                    # against a table that might have moved with it.
                    $unedited = @(& $effIdsL $name)
                    & $setOvL $name @() @($ids[1])
                    $wasIds  = @(& $effIdsL $name)
                    $wasPath = [string]$loadedL[$name].Path
                    if (@($wasIds).Count -eq @($unedited).Count) {
                        throw 'the edit changed nothing, so the reset below would prove nothing'
                    }
                    & $saveOutL $name $tmp2 $null
                    $copyName = [IO.Path]::GetFileNameWithoutExtension($tmp2)
                    if ($presetNamesL -notcontains $name) {
                        throw "'$name' left the list when it was saved to another file"
                    }
                    if ($presetNamesL -notcontains $copyName) {
                        throw "saving to $tmp2 did not produce a preset called '$copyName'"
                    }
                    if ([string]$stateL.Preset -ne $copyName) {
                        throw "the selection is on '$($stateL.Preset)' rather than the new '$copyName'"
                    }
                    # Registered in every table, not only in the list: a preset
                    # in $presetNames with no base set is the dangling-name
                    # crash by another route.
                    if (@($baseL.Keys) -notcontains $copyName) { throw "no base set under '$copyName'" }
                    # The new preset holds the edit that was saved.
                    $copyIds = @(& $effIdsL $copyName)
                    if (@($copyIds).Count -ne @($wasIds).Count) {
                        throw "the file holds $(@($copyIds).Count) id(s), the edit was $(@($wasIds).Count)"
                    }
                    # The source is still pointed at its own file...
                    if ([string]$loadedL[$name].Path -ne $wasPath) {
                        throw "the source now points at '$($loadedL[$name].Path)' rather than '$wasPath'"
                    }
                    # ...and is back to what that file holds. This is the half
                    # that was asked for: the edit moved into the new file
                    # rather than being copied into it and left behind.
                    $srcNow = @(& $effIdsL $name)
                    if (@($srcNow).Count -ne @($unedited).Count) {
                        throw "the source kept $(@($srcNow).Count) id(s) rather than its own $(@($unedited).Count)"
                    }
                    & $clickEl @($uiL.LoadedPanel.Children |
                                 Where-Object { $_.Tag -and [string]$_.Tag.Name -eq $name })[0]
                    if ($uiL.PresetEditRow.Visibility -ne 'Collapsed') {
                        throw 'the source still reads as edited after the edit was saved elsewhere'
                    }

                    # ---- renamed, file and all -------------------------------
                    #
                    # The name of one of these IS the name of its file, and the
                    # list is rebuilt from paths at startup, so a rename that
                    # left the file alone would be undone by the next launch and
                    # would meanwhile describe a file it no longer matched.
                    # Driven through the seam rather than the button, which
                    # opens a dialog and would block the harness.
                    $wantName = 'wd-selftest-renamed'
                    $newPath  = Join-Path ([IO.Path]::GetTempPath()) "$wantName.json"
                    $got = [string](& $renameToL $name $wantName)
                    if ($got -ne $wantName) { throw "the rename answered '$got'" }
                    $name = $wantName
                    $tmp  = $newPath
                    if ($presetNamesL -notcontains $wantName) { throw 'the renamed preset is not in the list' }
                    if (-not (Test-Path -LiteralPath $newPath)) { throw 'the file did not move with the name' }
                    if ([string]$loadedL[$wantName].Path -ne $newPath) {
                        throw "the entry points at '$($loadedL[$wantName].Path)'"
                    }
                    # Moved in every table, not only in the list: a key left
                    # behind under the old name is the dangling-name crash by
                    # another route.
                    if (@($baseL.Keys) -notcontains $wantName) { throw "no base set under '$wantName'" }
                    if (-not $advBtnsL.Contains($wantName)) { throw 'Advanced has no button for the new name' }
                    # And it refuses rather than half-doing it. A name already
                    # in use must be turned down BEFORE the file moves, or the
                    # file and the preset come apart - which is the one state
                    # this feature exists to prevent.
                    $refused = [string](& $renameToL $wantName 'Balanced')
                    if ($refused -eq 'Balanced') { throw 'the rename took a name already in use' }
                    if ([string]$loadedL[$wantName].Path -ne $newPath) {
                        throw 'a refused rename moved the file anyway'
                    }

                    # ---- and taken away again, through the real button -------
                    #
                    # Removing the preset that is SELECTED is the case that used
                    # to leave $state.Preset naming something that no longer
                    # existed, and then take the window down at whatever read it
                    # next. It is also the likeliest gesture there is: loading a
                    # file selects it, so "load it, look at it, remove it" hits
                    # this every time. The header's Remove button, not
                    # $dropLoaded, because the click path is what has to survive.
                    #
                    # It acts on the selection, so the selection has to be on it
                    # first - which is also the whole reason the button is up
                    # there rather than on each row.
                    $row = @($uiL.LoadedPanel.Children |
                             Where-Object { $_.Tag -and [string]$_.Tag.Name -eq $name })
                    if (-not $row.Count) { throw 'the row went missing before it could be removed' }
                    & $clickEl $row[0]
                    if ([string]$stateL.Preset -ne $name) { throw 'the row would not select itself' }
                    # And the pair is live, because something is selected.
                    if (-not $uiL.BtnRemovePreset.IsEnabled) {
                        throw 'Remove is dead while a loaded preset is selected'
                    }
                    if (-not $uiL.BtnRenamePreset.IsEnabled) {
                        throw 'Rename is dead while a loaded preset is selected'
                    }
                    # And the row offers the three things a mode card offers,
                    # because a selection loaded from a file is a preset like
                    # any other and there was nothing to do with one from here.
                    if ([string]$row[0].Tag.Acts.Visibility -ne 'Visible') {
                        throw 'the selected row offers nothing to do with it'
                    }
                    if (@($row[0].Tag.Acts.Children).Count -ne 3) {
                        throw "the row offers $(@($row[0].Tag.Acts.Children).Count) actions, not three"
                    }
                    & $clickBtn $uiL.BtnRemovePreset
                    if ($presetNamesL -contains $name) { throw 'Remove left it in the preset list' }
                    if (-not ($presetNamesL -contains $stateL.Preset)) {
                        throw "the selection was left on '$($stateL.Preset)', which is not a preset"
                    }
                    # And the screen followed it. The selection landed on a
                    # shipped mode, so that mode's card has to be the one saying
                    # SELECTED - a card still reading "click to select" while
                    # $state.Preset names it is the visible half of the bug this
                    # guards against.
                    $on = @($shippedL | Where-Object { [string]$colsL[$_].Check.Text -eq 'SELECTED' })
                    if (($on -join ',') -ne [string]$stateL.Preset) {
                        throw "the cards say '$($on -join ', ')' and the state says '$($stateL.Preset)'"
                    }
                    # With the selection now on a shipped mode, the two buttons
                    # that speak for a loaded preset have nothing to speak for -
                    # dead, but STILL THERE. Collapsing them took 160px out of
                    # the middle of the row and slid Remove all along to fill
                    # it, which reads as Remove all having disappeared.
                    if ($uiL.BtnRemovePreset.IsEnabled) {
                        throw 'Remove is still live with a shipped mode selected'
                    }
                    if ($uiL.BtnRenamePreset.IsEnabled) {
                        throw 'Rename is still live with a shipped mode selected'
                    }
                    foreach ($b in @('BtnRemovePreset','BtnRenamePreset','BtnRemoveAllPresets')) {
                        if ($uiL[$b].Visibility -ne 'Visible') {
                            throw "$b left the row when the selection moved, so the row reflows"
                        }
                    }
                } finally {
                    if ($copyName) { & $dropLoadL $copyName }
                    & $dropLoadL $name
                    & $loadRefreshL
                    & $clickBtn $uiL.BtnBalanced
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                    if ($tmp2) { Remove-Item -LiteralPath $tmp2 -Force -ErrorAction SilentlyContinue }
                }
                if (@($presetNamesL).Count -ne $before) { throw 'dropping it left the preset list longer' }
                if ($advBtnsL.Contains($name)) { throw 'Advanced kept its button' }
            }.GetNewClosure()

            # Load all. Read-only against whatever is really in profile_saves -
            # writing test files into somebody's saves folder is exactly the
            # kind of trace this toolkit is not allowed to leave - and anything
            # it does load is dropped again, because $loadedRefresh writes the
            # list to the settings file and a test must not decide what is open
            # tomorrow.
            #
            # The second click is the assertion that matters. $registerLoaded
            # will take the same path twice and call the second one "thing (2)",
            # so a button that does not skip what is already loaded is a
            # duplicate factory rather than a convenience.
            & $try 'Load all takes the saves folder in one gesture, and only once' {
                & $clickBtn $uiL.BtnBackModes
                $folder = [string](& $savesFolderL)
                $files = @()
                if (Test-Path -LiteralPath $folder) {
                    $files = @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File -ErrorAction SilentlyContinue |
                               ForEach-Object { [string]$_.FullName })
                }
                $had = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
                foreach ($k in @($loadedL.Keys)) { $null = $had.Add([string]$loadedL[$k].Path) }
                $expect = @($files | Where-Object { -not $had.Contains([string]$_) })
                $before = @($presetNamesL | ForEach-Object { [string]$_ })
                $added  = @()
                try {
                    & $clickBtn $uiL.BtnLoadAll
                    $added = @($presetNamesL | Where-Object { $before -notcontains [string]$_ })
                    if (@($added).Count -ne @($expect).Count) {
                        throw "$(@($expect).Count) file(s) were there to load and $(@($added).Count) arrived"
                    }
                    # Every one of them is a preset everywhere, not just a name
                    # in a list - the same bar a hand-loaded file has to clear.
                    foreach ($n in $added) {
                        if (-not $advBtnsL.Contains([string]$n)) { throw "Advanced has no button for '$n'" }
                        if (@($baseL.Keys) -notcontains [string]$n) { throw "no base set under '$n'" }
                    }
                    $mid = @($presetNamesL).Count
                    & $clickBtn $uiL.BtnLoadAll
                    if (@($presetNamesL).Count -ne $mid) {
                        throw "a second Load all added $(@($presetNamesL).Count - $mid) duplicate(s)"
                    }
                    if (-not $expect.Count) {
                        Write-Host '        (the saves folder is empty or wholly loaded, so only the no-op path ran)'
                    }
                } finally {
                    foreach ($n in $added) { & $dropLoadL ([string]$n) }
                    & $loadRefreshL
                    & $clickBtn $uiL.BtnBalanced
                }
                if (@($presetNamesL).Count -ne $before.Count) {
                    throw 'dropping what it loaded left the preset list longer'
                }
            }.GetNewClosure()

            # The other half of the chrome rule, and the half the "painted out
            # of the theme" check cannot make: that one exempts everything
            # inside a ComboBox, which is right - the closed bar is system-drawn
            # - and that exemption is exactly what let five drop-downs on the
            # setup page ship with their items painted in theme brushes. The
            # popup is drawn on the system window brush, which is white in both
            # themes, so the dark theme's near-white text on it was white on
            # white. Nothing inside a ComboBox may carry a local brush; the
            # system owns that control end to end.
            #
            # Runs here rather than beside the other theme checks because the
            # setup page's drop-downs do not exist until that page has been
            # opened, and a check that silently examines three combos instead of
            # eight is the kind of pass that proves nothing. It opens the page
            # itself rather than relying on the test above having left it there.
            & $try 'no drop-down paints its own items' {
                & $clickBtn $uiL.BtnUnattend
                & $uaBuildL
                $bad   = New-Object System.Collections.Generic.List[string]
                $found = New-Object System.Collections.Generic.List[string]
                # Both trees, deduplicated, and the logical one is what makes
                # this work at all.
                #
                # It walked the VISUAL tree only, and a visual tree exists for
                # what has been measured and arranged. These drop-downs are built
                # in code onto a page that was made visible a moment earlier and
                # never laid out, so GetChildrenCount answered 0 at the first
                # ContentPresenter and the sweep found the two combos in the
                # Advanced toolbar and none of the seven on this page - eleven
                # items, and the guard below correctly refused to call that a
                # pass. Logical children are parented the instant they are added,
                # with no layout involved, which is the right question here: this
                # is about what a control carries, not about what is on screen.
                #
                # Visited set over every element rather than just the combos,
                # because an element is commonly reachable down both trees and
                # re-walking its subtree each time turns one pass over ~5000
                # elements into something much worse.
                $seenEl = New-Object 'System.Collections.Generic.HashSet[object]'
                $sweep = {
                    param($El)
                    if ($null -eq $El) { return }
                    if (-not ($El -is [Windows.DependencyObject])) { return }
                    if (-not $seenEl.Add($El)) { return }
                    if ($El -is [Windows.Controls.ComboBox]) {
                        $n = 0
                        foreach ($it in @($El.Items)) {
                            if (-not ($it -is [Windows.Controls.ComboBoxItem])) { continue }
                            $n++
                            foreach ($p in @('Foreground', 'Background')) {
                                $fld = $it.GetType().GetField("${p}Property", 'Public,Static,FlattenHierarchy')
                                if (-not $fld) { continue }
                                $src = [Windows.DependencyPropertyHelper]::GetValueSource($it, $fld.GetValue($null))
                                if ("$($src.BaseValueSource)" -eq 'Local') {
                                    $bad.Add("'$($it.Content)' sets its own $p")
                                }
                            }
                        }
                        $found.Add("$($El.Name):$n")
                        # Its items ARE its logical children, and they have just
                        # been read. Descending would find them again as the same
                        # objects, which the visited set would drop anyway.
                        return
                    }
                    foreach ($c in @([Windows.LogicalTreeHelper]::GetChildren($El))) { & $sweep $c }
                    # Guarded on Visual, not on DependencyObject: a TextElement -
                    # every Run in every inline-built label - is a
                    # DependencyObject and not a Visual, and GetChildrenCount
                    # throws on one rather than answering zero.
                    if ($El -is [Windows.Media.Visual]) {
                        $vn = [Windows.Media.VisualTreeHelper]::GetChildrenCount($El)
                        for ($i = 0; $i -lt $vn; $i++) { & $sweep ([Windows.Media.VisualTreeHelper]::GetChild($El, $i)) }
                    }
                }
                & $sweep $winL
                & $clickBtn $uiL.BtnUaBack
                $total = 0
                foreach ($f in $found) { $total += [int]($f -split ':')[-1] }
                if ($total -lt 20) {
                    throw ("only $total drop-down item(s) across $($found.Count) combo(s) were reachable, " +
                           "so this proved nothing: $($found -join ', ')")
                }
                Write-Host "  drop-downs   : $($found.Count) combo(s), $total item(s) checked"
                if ($bad.Count) { throw (($bad | Select-Object -First 4) -join '; ') }
            }.GetNewClosure()

            & $try 'the application settings sit apart and name the other theme' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                if ($uiL.AppOptBox.Visibility -ne 'Visible') { throw 'the settings box is missing' }
                $want = if ($stateL.Theme -eq 'dark') { 'light' } else { 'dark' }
                if ("$($uiL.BtnTheme.Content)" -notmatch $want) {
                    throw "in $($stateL.Theme) the button offers '$($uiL.BtnTheme.Content)'"
                }
                if (-not $uiL.BtnFactory) { throw 'Restore factory defaults is missing' }
                # Not part of the list, so no filter has anything to say about it.
                $uiL.TxtFilter.Text = 'zzz-nothing-matches-this'
                if ($uiL.AppOptBox.Visibility -ne 'Collapsed') { throw 'the settings box survived a filter' }
                $uiL.TxtFilter.Text = ''
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'the window wears the system backdrop, or plainly does not' {
                # Two states, and both are correct - the point is that they never
                # half-happen. Mica on means the page must be transparent, or the
                # material is behind an opaque sheet and invisible. Mica off means
                # the page must be solid, or the window is a see-through hole.
                $mica = [bool]$winL.Tag.Mica
                $clear = [Windows.Media.Brushes]::Transparent
                if ([Environment]::OSVersion.Version.Build -ge 22621 -and -not $mica) {
                    throw "build $([Environment]::OSVersion.Version.Build) supports Mica and DWM refused it"
                }
                if ($mica) {
                    if ($winL.Background -ne $clear)     { throw 'Mica is on and the window is still opaque' }
                    if ($uiL.Root.Background -ne $clear) { throw 'Mica is on and the page is still opaque' }
                    $src = [Windows.Interop.HwndSource]::FromHwnd(
                             (New-Object Windows.Interop.WindowInteropHelper $winL).Handle)
                    if ($src.CompositionTarget.BackgroundColor -ne [Windows.Media.Colors]::Transparent) {
                        throw 'WPF is still painting its own background over the backdrop'
                    }
                } else {
                    if ($uiL.Root.Background -eq $clear) { throw 'Mica is off and the page was cleared anyway' }
                }
                # The caption follows the palette either way, and that one works
                # back to Windows 10.
                if ($winL.WindowStyle -eq 'None') { throw 'the native title bar was thrown away' }
            }.GetNewClosure()
            & $try 'the run-behavior block is part of the unfiltered page' {
                & $clickBtn $uiL.BtnAdvanced
                if ($uiL.RunOptionsBlock.Visibility -ne 'Visible') { throw 'it is missing from the plain page' }
                # It holds no items, so no filter can ever have anything to say
                # about it - showing it under "changed from preset" claims those
                # two checkboxes are changes.
                $uiL.TxtFilter.Text = 'zzz-nothing-matches-this'
                if ($uiL.RunOptionsBlock.Visibility -ne 'Collapsed') { throw 'it survived a text filter' }
                if ($uiL.ProtectedBlock.Visibility -ne 'Collapsed') { throw 'the protected block survived a text filter' }
                $uiL.TxtFilter.Text = ''
                if ($uiL.RunOptionsBlock.Visibility -ne 'Visible') { throw 'it did not come back' }
                & $tickL 'View' 'Changed from preset' $true
                if ($uiL.RunOptionsBlock.Visibility -ne 'Collapsed') { throw 'it survived the changed-items filter' }
                & $tickL 'View' 'Changed from preset' $false
                if ($uiL.RunOptionsBlock.Visibility -ne 'Visible') { throw 'clearing the filter did not bring it back' }
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'the storage bar draws the drive and adds up to it' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                foreach ($r in $rowsL) { $r.Check.IsChecked = $false }
                $snap = $storeL.Snapshot
                if (-not $snap) { throw 'no measurement to draw' }
                if (-not $uiL.DiskBar.ColumnDefinitions.Count) { throw 'the bar has no segments' }
                # The one thing a stacked bar must not do is misrepresent a
                # proportion. Its columns are star-weighted by bytes, so their
                # weights have to come to the size of the volume - a segment
                # left out or counted twice shows up here and nowhere else.
                $star = { $t = 0.0; foreach ($c in $uiL.DiskBar.ColumnDefinitions) { $t += $c.Width.Value }; $t }
                $slip = [Math]::Abs((& $star) - $snap.TotalBytes) / [double]$snap.TotalBytes
                if ($slip -gt 0.001) {
                    throw ("the segments come to {0:n0} bytes on a {1:n0} byte drive" -f (& $star), $snap.TotalBytes)
                }
                if (-not $snap.Scaled) { throw 'the fixture was meant to exercise the scaled branch' }
                # And it still adds up once the selection has taken a bite out
                # of it: whatever is drawn as freed has to come off the blocks it
                # is leaving, or the bar overflows the volume.
                $sized = @($storeRowsL | Where-Object { $storeL.Snapshot.Items[$_.Id] -gt 0 })
                if (-not $sized.Count) { throw 'no clean-up with a size to tick' }
                foreach ($r in $sized) { $r.Check.IsChecked = $true }
                $slip = [Math]::Abs((& $star) - $snap.TotalBytes) / [double]$snap.TotalBytes
                if ($slip -gt 0.001) { throw ("with a selection the bar comes to {0:n0} bytes" -f (& $star)) }
                foreach ($r in $sized) { $r.Check.IsChecked = $false }

                # Laid out, not just built: a stacked bar with no width is a row
                # of nothing and would satisfy every count above while not being
                # on screen at all. It lives in the header now, so it is also the
                # one part of the page that has to survive every filter.
                $uiL.Root.UpdateLayout()
                if ($uiL.DiskBarFrame.ActualWidth -le 0) {
                    Write-Host '  note    the bar has no size yet, so its geometry went unchecked'
                } elseif ($uiL.DiskBarFrame.ActualWidth -gt $uiL.HeaderBar.ActualWidth) {
                    throw 'the bar is wider than the header it sits in'
                }
                $uiL.TxtFilter.Text = 'zzz-nothing-matches-this'
                if ($uiL.StorageBlock.Visibility -ne 'Visible') { throw 'a filter hid the drive' }
                $uiL.TxtFilter.Text = ''
                & $clickBtn $uiL.BtnBackModes
                if ($uiL.StorageBlock.Visibility -ne 'Visible') { throw 'the mode page has no drive on it' }
            }.GetNewClosure()
            & $try 'the bar answers for what the selection frees and what it costs' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                foreach ($r in $rowsL) { $r.Check.IsChecked = $false }
                $stateL.BrowserPreferred = $null
                & $setBrowL @() $false
                $segs = { param([string]$Word) @($uiL.DiskBar.Children | Where-Object { $_.ToolTip -match $Word }) }
                if (@(& $segs 'give back').Count) { throw 'a freed segment is drawn with nothing selected' }
                if ($uiL.DiskNote.Text -notmatch 'Nothing selected changes that') { throw "the note reads '$($uiL.DiskNote.Text)'" }

                $sized = @($storeRowsL | Where-Object { $storeL.Snapshot.Items[$_.Id] -gt 0 })
                $sized[0].Check.IsChecked = $true
                if (-not @(& $segs 'give back').Count) { throw 'ticking a clean-up did not draw it on the bar' }
                $want = Format-WDBytes ([int64]$storeL.Snapshot.Items[$sized[0].Id])
                if ($uiL.DiskNote.Text -notmatch [regex]::Escape($want)) {
                    throw "the note says '$($uiL.DiskNote.Text)', expected $want"
                }
                if ($uiL.DiskNote.Text -notmatch 'frees about') { throw "a clean-up did not read as freeing: '$($uiL.DiskNote.Text)'" }

                # An install pushes the other way, and the bar has a block for it
                # on the far side of the free-space boundary.
                $inst = @($rowsL | Where-Object { $_.Delta -gt 0 -and $_.Check.IsEnabled })
                if (-not $inst.Count) { throw 'nothing on the page installs anything' }
                $inst[0].Check.IsChecked = $true
                if (-not @(& $segs 'would install').Count) { throw 'an install is not drawn on the bar' }
                $hit = $storeL.Impact
                if ($hit.Added -ne $inst[0].Delta) { throw "the install counted $($hit.Added), the row says $($inst[0].Delta)" }
                if ($uiL.DiskNote.Text -notmatch 'installs') { throw "the note ignored the install: '$($uiL.DiskNote.Text)'" }

                # A browser is a picker, not a row, so nothing in the row loop
                # sees it. It still occupies a drive.
                $before = $storeL.Impact.Added
                # One the machine has not got: an installed browser is dropped
                # by the picker rather than queued, so naming a fixed one here
                # made the test depend on which browsers this machine happens to
                # have.
                & $setBrowL @([string]@($browFreeL)[0]) $true
                if ($storeL.Impact.Added -le $before) { throw 'picking a browser cost nothing' }
                $stateL.BrowserPreferred = $null
                & $setBrowL @() $false

                foreach ($r in $rowsL) { $r.Check.IsChecked = $false }
            }.GetNewClosure()
            & $try 'the header sentence accounts for what the selection does' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                foreach ($r in $rowsL) { $r.Check.IsChecked = $false }
                $sized = @($storeRowsL | Where-Object { $storeL.Snapshot.Items[$_.Id] -gt 0 })
                foreach ($r in $sized) { $r.Check.IsChecked = $true }
                $blind = @($storeRowsL | Where-Object { $_.Id -in @($storeL.Snapshot.Unmeasured) })
                foreach ($r in $blind) { $r.Check.IsChecked = $true }
                $inst = @($rowsL | Where-Object { $_.Delta -gt 0 -and $_.Check.IsEnabled })[0]
                $inst.Check.IsChecked = $true

                $hit = $storeL.Impact
                # Every line has to add up to the total the header quotes. A
                # details list that disagrees with the headline is worse than no
                # details list.
                $sumF = 0L; foreach ($f in $hit.Frees) { $sumF += $f.Bytes }
                $sumA = 0L; foreach ($a in $hit.Adds)  { $sumA += $a.Bytes }
                if ($sumF -ne $hit.Freed) { throw "the freed lines come to $sumF, the header says $($hit.Freed)" }
                if ($sumA -ne $hit.Added) { throw "the install lines come to $sumA, the header says $($hit.Added)" }
                # The band is the sum of what each figure can be wrong by, and
                # nothing without a figure contributes to it - an unmeasurable
                # item is named, never averaged in.
                $want = 0.0
                foreach ($f in $hit.Frees) { $want += $f.Bytes * $(if ($f.Kind -eq 'measured') { 0.05 } else { 0.25 }) }
                foreach ($a in $hit.Adds)  { $want += $a.Bytes * 0.40 }
                if ([Math]::Abs($hit.Slop - $want) -gt 2) { throw "the band is $($hit.Slop), expected $([int]$want)" }
                if ($hit.Slop -le 0) { throw 'an approximate total was quoted with no band at all' }
                if (-not $hit.Blind.Count) { throw 'the fixture was meant to include something unmeasurable' }
                if ($uiL.DiskNote.Text -notmatch 'give or take') { throw "the header quotes no band: '$($uiL.DiskNote.Text)'" }
                if ($uiL.DiskNote.Text -notmatch 'nothing can size') { throw 'the header hid the unmeasurable items' }

                # The Details drop-down used to be checked here, line by line,
                # against these same totals. It is gone, and the arithmetic above
                # is what it was really testing - the header sentence is now the
                # only thing that quotes these numbers, and it is asserted above.
                foreach ($r in $rowsL) { $r.Check.IsChecked = $false }
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'the account choice governs the rows it governs, and says which' {
                & $clickBtn $uiL.BtnAdvanced
                & $clearFiltL
                if (-not $acctBoxL.Count) { throw 'no accounts to choose between' }
                if (-not $acctTagsL.Count) { throw 'no row claims to be per-account' }

                # Everything ticked is the default and has to be what a run gets.
                foreach ($e in $acctBoxL) { $e.Box.IsChecked = $true }
                $all = @(& $acctKeysL)
                if ($all.Count -ne $acctBoxL.Count) { throw "ticking everything gave $($all.Count) of $($acctBoxL.Count)" }
                $tag = $acctTagsL[0].Tag
                if ($tag.Text -notmatch 'account') { throw "the row reads '$($tag.Text)'" }

                # And unticking is carried through to the rows rather than only
                # to the run - a choice the list does not reflect is a choice
                # nobody can check before pressing Preview.
                foreach ($e in $acctBoxL) { $e.Box.IsChecked = $false }
                if (@(& $acctKeysL).Count) { throw 'unticking everything still selected an account' }
                if ($tag.Text -notmatch 'no accounts') { throw "with nothing ticked the row reads '$($tag.Text)'" }
                if ($uiL.LblAccounts.Text -notmatch 'skipped') { throw 'the block did not say per-user settings would be skipped' }

                # Only per-user rows carry the tag. A policy in HKLM applies
                # whatever is ticked and must not claim otherwise.
                $tagged = @($acctTagsL | ForEach-Object { $_.Id })
                foreach ($id in $tagged) {
                    if (-not $perUserL.Contains($id)) { throw "$id is tagged per-account and is not" }
                }
                if (@($rowsL | Where-Object { $_.Id -notin $tagged -and $perUserL.Contains($_.Id) }).Count) {
                    throw 'a per-account row went untagged'
                }
                foreach ($e in $acctBoxL) { $e.Box.IsChecked = $true }
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'ownership follows the mode, until the user says otherwise' {
                $stateL.OwnershipChoice = $null
                & $clickBtn $uiL.BtnAdvanced
                & $clickBtn $uiL.BtnBalanced
                if ($uiL.ChkOwnership.IsChecked) { throw 'Balanced seizes ACLs' }
                & $clickBtn $uiL.BtnAggressive
                if (-not $uiL.ChkOwnership.IsChecked) { throw 'Aggressive does not take ownership' }
                & $clickBtn $uiL.BtnExtreme
                if (-not $uiL.ChkOwnership.IsChecked) { throw 'Extreme does not take ownership' }
                & $clickBtn $uiL.BtnConservative
                if ($uiL.ChkOwnership.IsChecked) { throw 'Conservative seizes ACLs' }

                # The mode grid is the other way into the same decision, and the
                # box it drives is a page away from it.
                & $clickBtn $uiL.BtnBackModes
                & $clickEl $colsL['Aggressive'].Border
                if (-not $uiL.ChkOwnership.IsChecked) { throw 'the mode grid did not set it' }

                # A person ticking the box outranks every later mode switch.
                # Raising Click does not toggle the box, so set it and then
                # click: the handler has to see an interaction, not a write.
                & $clickBtn $uiL.BtnAdvanced
                $uiL.ChkOwnership.IsChecked = $false
                & $clickBtn $uiL.ChkOwnership
                if ($null -eq $stateL.OwnershipChoice -or $stateL.OwnershipChoice) {
                    throw 'the refusal was not recorded'
                }
                & $clickBtn $uiL.BtnExtreme
                if ($uiL.ChkOwnership.IsChecked) { throw 'Extreme overrode an explicit no' }

                $stateL.OwnershipChoice = $null
                & $clickBtn $uiL.BtnBalanced
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'Reset appears per-preset and undoes only that preset' {
                & $clrOvL
                & $clickBtn $uiL.BtnAdvanced
                & $clickBtn $uiL.BtnBalanced
                if ($uiL.BtnResetOne.Visibility -ne 'Collapsed') { throw 'Reset showed with nothing to reset' }

                $spare = @($rowsL | Where-Object { $_.Id -notin @($baseL['Balanced']) } | Select-Object -First 1)
                if (-not $spare.Count) { throw 'nothing available to add' }
                $spare[0].Check.IsChecked = $true
                if ($uiL.BtnResetOne.Visibility -ne 'Visible') { throw 'Reset stayed hidden after an edit' }
                if ($uiL.BtnResetOne.Content -ne 'Reset Balanced') { throw "button reads '$($uiL.BtnResetOne.Content)'" }

                # Edit a second mode, so the reset can be shown not to touch it.
                & $clickBtn $uiL.BtnAggressive
                $other = @($rowsL | Where-Object { $_.Id -notin @($baseL['Aggressive']) } | Select-Object -First 1)
                $other[0].Check.IsChecked = $true
                & $clickBtn $uiL.BtnBalanced

                & $clickBtn $uiL.BtnResetOne
                if ($uiL.BtnResetOne.Visibility -ne 'Collapsed') { throw 'Reset stayed visible after resetting' }
                if ($spare[0].Check.IsChecked) { throw 'the edit survived the reset' }
                $bal = & $cellText $colsL['Balanced'].Num
                if ($bal -match 'items? (added|removed)') { throw "Balanced still reads '$bal'" }
                $agg = & $cellText $colsL['Aggressive'].Num
                if ($agg -notmatch '1 item added') { throw "Aggressive lost its edit too: '$agg'" }
                # The mode-screen button speaks for the mode on screen and for
                # nothing else: hidden on a Balanced that has just been reset,
                # back again on an Aggressive that is still edited.
                if ($uiL.PresetEditRow.Visibility -ne 'Collapsed') { throw 'Reset offered to reset an unedited Balanced' }
                & $clickBtn $uiL.BtnAggressive
                if ($uiL.PresetEditRow.Visibility -ne 'Visible') { throw 'Reset hid on a mode that is still edited' }
                # No preset name on it. It is standing on the card of the preset
                # it acts on, which is what a name in the label was for.
                if ($uiL.BtnResetPresets.Content -ne 'Reset') { throw "the button reads '$($uiL.BtnResetPresets.Content)'" }
                if ($uiL.PresetEditRow.Parent -ne $colsL['Aggressive'].Panel) {
                    throw 'the Save/Reset pair is not on the Aggressive column'
                }
                & $clrOvL
                & $clickBtn $uiL.BtnBackModes
            }.GetNewClosure()
            & $try 'compare two modes' {
                # Against the shipped ladder, so an edit left by an earlier step
                # cannot make a rung look like it removes less than the one below.
                & $clrOvL
                & $goCompare
                if ($uiL.PageCompare.Visibility -ne 'Visible') { throw 'the compare page did not open' }
                if (-not $uiL.CompareGrid.Children.Count) { throw 'the comparison is empty' }
                if ($uiL.CompareARow.Children.Count -ne $namesL.Count) { throw 'a mode is missing from the picker' }
                # Each mode's button carries its own color, not a shared one.
                #
                # Up to the size of the palette. A loaded preset takes the first
                # ink nobody is wearing, so there is a distinct color for every
                # one of them until the inks run out - past that they repeat,
                # and saying so is better than either a failure nobody can act
                # on or a check that quietly stops meaning anything.
                $room = @($namesL).Count -le @($shippedL).Count + $inkCountL
                $seenCol = @{}
                foreach ($btn in $uiL.CompareARow.Children) {
                    $key = [string]$btn.BorderBrush.Color
                    if ($seenCol.ContainsKey($key) -and $room) {
                        throw "$($btn.Content) and $($seenCol[$key]) share a border color, with inks to spare"
                    }
                    $seenCol[$key] = [string]$btn.Content
                }
                if (-not $room) {
                    Write-Host "        ($(@($namesL).Count) presets against $inkCountL loaded inks, so colors repeat)"
                }

                # Neighboring rungs: the higher one is a strict superset, so
                # the difference must run one way only.
                foreach ($btn in $uiL.CompareARow.Children) { if ($btn.Content -eq 'Balanced')   { & $clickBtn $btn } }
                foreach ($btn in $uiL.CompareBRow.Children) { if ($btn.Content -eq 'Aggressive') { & $clickBtn $btn } }
                $t = $uiL.TxtCompareTally.Text
                if ($t -notmatch '0 only in Balanced') { throw "tally reads '$t'" }
                if ($t -match ', 0 only in Aggressive') { throw "Aggressive adds nothing over Balanced: '$t'" }

                # A ladder rung never has anything the rung above lacks, so one
                # of these two columns is always empty - and the assertion is
                # that the page is STILL two columns. It used to give the
                # populated side the whole width and split it in two, which is
                # the layout this test used to check for; the point of the view
                # is reading one mode against the other, and a page that stops
                # having two sides the moment one is empty stops doing that.
                #
                # Column 2 is the right-hand half (1 is the rule between them),
                # so a card there is proof both halves are still laid out.
                $twoUp = @($uiL.CompareGrid.Children | Where-Object {
                    [Windows.Controls.Grid]::GetColumn($_) -eq 2 -and
                    [Windows.Controls.Grid]::GetColumnSpan($_) -le 1 })
                if (-not $twoUp.Count) { throw 'the empty side lost its column' }
                $rule = @($uiL.CompareGrid.Children | Where-Object {
                    [Windows.Controls.Grid]::GetColumn($_) -eq 1 -and $_ -is [Windows.Controls.Border] })
                if (-not $rule.Count) { throw 'there is no rule down the middle' }
                # The two pickers are in the pinned header, one per column, and
                # each is inside the column it picks.
                $aCol = [Windows.Controls.Grid]::GetColumn($cmpHeadL.A.Parent)
                $bCol = [Windows.Controls.Grid]::GetColumn($cmpHeadL.B.Parent)
                if ($aCol -ne 0 -or $bCol -ne 2) {
                    throw "the pickers sit in columns $aCol and $bCol rather than over their own halves"
                }
                # And the picker comes first in its column, with the heading it
                # answers underneath it.
                foreach ($k in @('A', 'B')) {
                    $col = $cmpHeadL[$k].Parent
                    if ($col.Parent -ne $uiL.CompareHead) { throw "the $k picker is not in the pinned header" }
                    if ($col.Children[0] -ne $cmpHeadL[$k]) { throw "the $k heading is above its own picker" }
                    # Compare / against sits on the buttons' own line, and
                    # outside the scroller. Both halves matter: inside it, the
                    # word slides off to the left as soon as somebody scrolls
                    # towards a preset near the end of the row, and it is the one
                    # thing on that line whose job is to stay where it is.
                    $wrapK = $cmpHeadL[$k]
                    $lblK = @($wrapK.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] })
                    $svK  = @($wrapK.Children | Where-Object { $_ -is [Windows.Controls.ScrollViewer] })
                    if (-not $lblK.Count) { throw "the $k picker has no Compare/against label" }
                    if (-not $svK.Count)  { throw "the $k picker's button row is not in a scroller" }
                    # Siblings in one grid, so they are on the same line; and the
                    # label is a child of the wrapper rather than of the scroller,
                    # so it cannot be scrolled.
                    if ([Windows.Controls.Grid]::GetColumn($lblK[0]) -ne 0 -or
                        [Windows.Controls.Grid]::GetColumn($svK[0])  -ne 1) {
                        throw "the $k label and its buttons are not side by side"
                    }
                    if ($lblK[0].Parent -ne $wrapK) { throw "the $k label will scroll with the buttons" }
                }
                # The header does not scroll, so it is not in the scroller. This
                # is the whole of the change: eighty cards down, the two columns
                # used to have nothing on screen naming the modes they held.
                $inScroll = @($uiL.CompareGrid.Children | Where-Object {
                    $_ -is [Windows.Controls.StackPanel] -and $_.Children.Count -and
                    $_.Children[0] -eq $cmpHeadL.A })
                if ($inScroll.Count) { throw 'the header is inside the scroller and will scroll away' }

                # Custom selects no removals, so it is the empty side too. Its
                # count is asked of the preset rather than written as a literal
                # - it is its base (the rollback script and the lookup file),
                # not zero, and both of those are in every ladder rung too, so
                # nothing is ever only in Custom.
                foreach ($btn in $uiL.CompareARow.Children) { if ($btn.Content -eq 'Custom') { & $clickBtn $btn } }
                $t = $uiL.TxtCompareTally.Text
                $nCustom = @(& $effIdsL 'Custom').Count
                if ($t -notmatch "Custom $nCustom item") { throw "tally reads '$t', expected $nCustom" }
                if ($t -notmatch ', 0 only in Custom') { throw "tally reads '$t'" }
                $inRight = @($uiL.CompareGrid.Children | Where-Object {
                    [Windows.Controls.Grid]::GetColumn($_) -eq 2 -and
                    [Windows.Controls.Grid]::GetColumnSpan($_) -le 1 })
                if (-not $inRight.Count) { throw 'the right-hand column vanished with Custom on the left' }
            }.GetNewClosure()
            # Two segments per gap rather than one span, and the reason is the
            # rule down the middle: a Border across all three columns would be
            # drawn straight through it, and a cross is a shape neither line
            # meant to make.
            & $try 'compare rules one category off from the next' {
                & $goCompare
                foreach ($btn in $uiL.CompareARow.Children) { if ($btn.Content -eq 'Conservative') { & $clickBtn $btn } }
                foreach ($btn in $uiL.CompareBRow.Children) { if ($btn.Content -eq 'Extreme')      { & $clickBtn $btn } }
                # The rail is one entry per heading and the jumps are the ones
                # that have cards under them, so it is the count of blocks the
                # page actually laid out.
                $cats = @($uiL.CmpIndexPanel.Children | Where-Object { $_.Tag -and $_.Tag.Head }).Count
                if ($cats -lt 2) { throw "Conservative against Extreme laid out $cats block(s), too few to separate" }
                # Height 1 is what makes one of these: the rule down the middle
                # is a Border too, and it is 1 WIDE with no height set at all.
                $lines = @($uiL.CompareGrid.Children | Where-Object {
                    $_ -is [Windows.Controls.Border] -and [double]$_.Height -eq 1 })
                if (@($lines).Count -ne ($cats - 1) * 2) {
                    throw "$cats blocks came back with $(@($lines).Count) segment(s), expected $((($cats - 1) * 2))"
                }
                foreach ($ln in $lines) {
                    if ([Windows.Controls.Grid]::GetColumn($ln) -eq 1) {
                        throw 'a category rule was drawn through the rule down the middle'
                    }
                    if ([Windows.Controls.Grid]::GetColumnSpan($ln) -gt 1) {
                        throw 'a category rule spans the page rather than stopping at the divider'
                    }
                }
                # One per side per gap. All of them landing in one column would
                # satisfy the count above and rule off half the page.
                $left = @($lines | Where-Object { [Windows.Controls.Grid]::GetColumn($_) -eq 0 }).Count
                if ($left -ne $cats - 1) { throw "$left of the $(@($lines).Count) segments are on the left" }
            }.GetNewClosure()
            # A quarter of the standard thickness, retemplated to the thumb
            # alone - on the Compare pickers and on Advanced's, which are the
            # same control on two pages.
            #
            # Measured, never asked. The first version of this check read the
            # Height setter off the style and passed while every bar on screen
            # stayed 17px: the default ScrollBar theme style sets Height AND
            # MinHeight from a trigger on Orientation=Horizontal, a theme-style
            # trigger outranks a plain style setter, and MinHeight beats Height
            # in layout - so the property was set, read back correctly, and did
            # nothing. Only ActualHeight after a real arrange can tell.
            & $try 'the preset pickers scroll on a hairline' {
                & $goCompare
                if (-not $winL.Resources['WdScrollThumb'])      { throw 'the bar thumb has no brush to resolve' }
                if (-not $winL.Resources['WdScrollThumbHover']) { throw 'the bar has no hover brush to resolve' }
                $full = [double][Windows.SystemParameters]::HorizontalScrollBarHeight
                & $clickBtn $uiL.BtnAdvanced
                $bars = @($uiL.CompareARow, $uiL.CompareBRow, $uiL.PresetRow)
                foreach ($row in $bars) {
                    $sv = $row.Parent
                    if (-not ($sv -is [Windows.Controls.ScrollViewer])) {
                        throw 'a picker row is not inside a scroller'
                    }
                    # Narrowed so the bar has to appear. Whether these rows
                    # happen to overflow at this window size depends on how many
                    # presets the machine has loaded, and a check that quietly
                    # measures a Collapsed bar measures nothing.
                    $was = $sv.Width
                    $sv.Width = 60
                    try {
                        $sv.UpdateLayout()
                        $sb = $sv.Template.FindName('PART_HorizontalScrollBar', $sv)
                        if (-not $sb) { throw 'the scroller has no horizontal bar to style' }
                        if ($sb.Visibility -ne 'Visible') { throw 'the bar did not appear on an overflowing row' }
                        if ([double]$sb.ActualHeight -le 0) { throw 'the bar was never arranged' }
                        # Half the standard, not the old quarter. 4.25px was
                        # findable only by somebody who already knew it was
                        # there; 7px still reads as a hairline beside a row of
                        # buttons and can be taken hold of.
                        if ([double]$sb.ActualHeight -gt $full * 0.5) {
                            throw "the bar draws $([Math]::Round($sb.ActualHeight, 2))px against a standard $full"
                        }
                    } finally {
                        $sv.Width = $was
                        $sv.UpdateLayout()
                    }
                }
                # Scoped, not global. The lists below these pickers want real
                # scrollbars somebody can grab.
                foreach ($big in @($uiL.CmpScroll, $uiL.AdvScroll)) {
                    $sb = $big.Template.FindName('PART_VerticalScrollBar', $big)
                    if ($sb -and [double]$sb.ActualWidth -gt 0 -and [double]$sb.ActualWidth -lt 8) {
                        throw 'the hairline reached a list somebody has to be able to grab'
                    }
                }
                # And the two index rails, which want the opposite: a 5px
                # hairline beside a 184px column, not a second column.
                #
                # Measured after an arrange, never off the setter. Their styles
                # set Width and, until this was checked, not MinWidth - so the
                # property read back as 5 while the theme style's MinWidth of 17
                # won the layout and the bar drew at full width the whole time.
                # Every bar in the application answers the pointer, and there are
                # exactly three templates to answer for. A trigger cannot be
                # driven from here - IsMouseOver comes from real hit-testing, not
                # from a routed event this can raise - so what is asserted is
                # that each template HAS the hover state, and that both rails use
                # the one shared definition rather than a copy of it. Two copies
                # is how one of them came to have a MinWidth and neither a hover.
                foreach ($k in @('WdVBarTemplate', 'WdHBarTemplate', 'WdRailBarTemplate')) {
                    $tpl = $winL.Resources[$k]
                    if (-not $tpl) { throw "$k is not in the window resources" }
                    $hov = @($tpl.Triggers | Where-Object { $_.Property -and [string]$_.Property.Name -eq 'IsMouseOver' })
                    if (-not $hov.Count) { throw "$k has no hover state, so that bar never answers the pointer" }
                }
                $railTpl = $winL.Resources['WdRailBarTemplate']

                $vfull = [double][Windows.SystemParameters]::VerticalScrollBarWidth
                $railsSeen = 0
                # HOW to get there rather than WHICH button, because getting to
                # Compare is two gestures now - its card button can only name
                # one preset and has to ask which other one.
                foreach ($pair in @(@{ Go = { & $clickBtn $uiL.BtnAdvanced }; Rail = $uiL.IndexScroll; Name = 'Advanced' },
                                    @{ Go = $goCompare; Rail = $uiL.CmpIndexScroll; Name = 'Compare' })) {
                    # On screen first. A collapsed page never arranges, so a bar
                    # measured from the other page measures nothing at all.
                    & $pair.Go
                    $rail = $pair.Rail
                    $wasH = $rail.Height
                    $rail.Height = 40
                    try {
                        $rail.UpdateLayout()
                        $sb = $rail.Template.FindName('PART_VerticalScrollBar', $rail)
                        if (-not $sb) { throw "the $($pair.Name) rail has no vertical bar to style" }
                        if ($sb.Template -ne $railTpl) {
                            throw "the $($pair.Name) rail bar is on a template of its own rather than the shared one"
                        }
                        # An empty rail cannot overflow, which is a fact about
                        # the machine rather than about the bar. Skipped, and the
                        # count below stops both being skipped in silence.
                        if ($sb.Visibility -ne 'Visible' -or [double]$sb.ActualWidth -le 0) { continue }
                        $railsSeen++
                        if ([double]$sb.ActualWidth -gt $vfull * 0.5) {
                            throw "the $($pair.Name) rail bar draws $([Math]::Round($sb.ActualWidth, 2))px against a standard $vfull"
                        }
                    } finally {
                        $rail.Height = $wasH
                        $rail.UpdateLayout()
                    }
                }
                if (-not $railsSeen) { throw 'neither index rail could be made to overflow, so nothing was measured' }
                & $clickBtn $uiL.BtnAdvanced
            }.GetNewClosure()
            # Every long page puts its scrollbar hard against the window edge,
            # and every one of them gets there the same way: no right margin on
            # the outer grid, and the inset carried as the ScrollViewer's own
            # Padding, which insets the CONTENT and not the bar. Put the margin
            # back and the bar floats 20px in with a strip of empty page outside
            # it, which reads as a layout that has come loose. The setup page
            # was doing exactly that until somebody said so.
            #
            # Measured after an arrange, from the page each scroller is on, and
            # skipped loudly rather than quietly if a page did not lay out -
            # every gap reads as zero when nothing has a width, which passes
            # this check by measuring nothing.
            & $try 'every page keeps its scrollbar against the window edge' {
                # One page open at a time, through each one's own Back button.
                # Every Open handler only collapses PageModes, so opening a
                # second without leaving the first stacks them - both still lay
                # out, so the measurement would survive it, but leaving the pile
                # standing for whatever runs next would not.
                & $clickBtn $uiL.BtnBackModes
                $seen = 0
                # ALL FIVE, and the two that were missing are the reason this is
                # worth saying: the mode screen and Revert were not in this list,
                # and the mode screen - the page the application opens on - had a
                # 20px right margin for its whole life. Three of five pages
                # checked is a check somebody trusts and should not.
                #
                # HOW to get to each page rather than WHICH button opens it. The
                # mode screen is reached from a card on the home page now, and
                # Compare takes two gestures - so an element per page stopped
                # being able to describe this.
                foreach ($p in @(@{ Go = { & $clickBtn $uiL.BtnDebloat };  Back = $uiL.BtnModesBack;   Page = $uiL.PageModes;    Sv = $uiL.ModeScroll; Name = 'Modes' },
                                 @{ Go = { & $clickBtn $uiL.BtnAdvanced }; Back = $uiL.BtnBackModes;   Page = $uiL.PageAdvanced; Sv = $uiL.AdvScroll;  Name = 'Advanced' },
                                 @{ Go = { $null = & $goRevertList };      Back = $uiL.BtnRevertBack;  Page = $uiL.PageRevert;   Sv = $uiL.RevScroll;  Name = 'Revert' },
                                 @{ Go = { & $clickBtn $uiL.BtnRevert };   Back = $uiL.BtnRevHomeBack; Page = $uiL.PageRevertHome; Sv = $uiL.RevHomeScroll; Name = 'Past runs' },
                                 @{ Go = $goCompare;                       Back = $uiL.BtnCompareBack; Page = $uiL.PageCompare;  Sv = $uiL.CmpScroll;  Name = 'Compare' },
                                 @{ Go = { & $clickBtn $uiL.BtnUnattend }; Back = $uiL.BtnUaBack;      Page = $uiL.PageUnattend; Sv = $uiL.UaScroll;   Name = 'Setup file' })) {
                    & $p.Go
                    $p.Page.UpdateLayout()
                    if ([double]$p.Page.ActualWidth -le 0 -or [double]$p.Sv.ActualWidth -le 0) {
                        if ($p.Back) { & $clickBtn $p.Back }
                        continue
                    }
                    $seen++
                    $right = $p.Sv.TransformToAncestor($p.Page).Transform(
                                 (New-Object Windows.Point ([double]$p.Sv.ActualWidth), 0)).X
                    $gap = [double]$p.Page.ActualWidth - $right
                    if ($gap -gt 1) {
                        throw ("$($p.Name) leaves $([Math]::Round($gap, 1))px of page outside its scrollbar - " +
                               'take the right margin off the grid and give the ScrollViewer the inset as Padding')
                    }
                    # And the inset itself has to survive, or the rows end up
                    # touching the bar instead of the margin doing it wrong.
                    if ([double]$p.Sv.Padding.Right -lt 1) {
                        throw "$($p.Name) has no content padding, so its rows run into the scrollbar"
                    }
                    if ($p.Back) { & $clickBtn $p.Back }
                }
                # SIX, not five. This measured three of five for a long time,
                # which is a check somebody trusts and should not - the mode
                # screen and Revert were both missing from its list while it
                # claimed to speak for every page. Past runs is the sixth.
                if ($seen -lt 6) { throw "$seen of 6 pages laid out, so this measured less than it claims" }
                # And the bar is wide enough to be thrown at, not only aimed at.
                # Measured after a real arrange rather than read off the setter:
                # the theme style sets MinWidth as well, and Min beats the plain
                # property in layout - so a bar can read back at one width while
                # arranging at another, which this file has been caught by twice.
                $advBar = $null
                & $clickBtn $uiL.BtnAdvanced
                $uiL.AdvScroll.UpdateLayout()
                $advBar = Get-WDChildScrollBar $uiL.AdvScroll 'Vertical'
                if ($advBar -and [double]$advBar.ActualWidth -gt 0) {
                    if ([Math]::Abs([double]$advBar.ActualWidth - [double]$script:WDVBarWidth) -gt 0.5) {
                        throw ("the list bar arranges at $([Math]::Round($advBar.ActualWidth,1))px but " +
                               "`$script:WDVBarWidth says $($script:WDVBarWidth) - the Compare header reserves " +
                               'its gutter from that number, so the two have to agree')
                    }
                }
            }.GetNewClosure()
            & $try 'compare indexes the difference down its own rail' {
                & $clrOvL
                & $goCompare
                & $cmpClearL
                foreach ($btn in $uiL.CompareARow.Children) { if ($btn.Content -eq 'Conservative') { & $clickBtn $btn } }
                foreach ($btn in $uiL.CompareBRow.Children) { if ($btn.Content -eq 'Extreme') { & $clickBtn $btn } }
                $cards = @($uiL.CmpIndexPanel.Children)
                if (-not $cards.Count) { throw 'the rail is empty on a page full of differences' }
                # Two numbers, one per side, in the order the columns are in.
                # A single total could not say which half a difference was on,
                # which is the whole question the page answers.
                $counted = @($cards | ForEach-Object { [string]$_.Child.Children[0].Text })
                $bad = @($counted | Where-Object { $_ -notmatch '^\d+ \| \d+$' })
                if ($bad.Count) { throw "a rail card counts '$($bad[0])'" }
                # One card per heading on the page, in page order. Measured off
                # the laid-out page rather than off the list the rail was built
                # from, which cannot answer for the layout - the same assertion
                # the Advanced rail makes, for the same reason.
                $uiL.CmpScroll.UpdateLayout()
                $jumps = @($cards | Where-Object { $_.Tag -and $_.Tag.Head })
                if (-not $jumps.Count) { throw 'not one rail card leads anywhere' }
                $lastY = [double]::NegativeInfinity
                foreach ($c in $jumps) {
                    $head = $c.Tag.Head
                    if (-not $head.IsDescendantOf($uiL.CompareGrid)) {
                        throw 'a rail card points at a heading that is not on the page'
                    }
                    $y = [double]$head.TransformToAncestor($uiL.CompareGrid).Transform(
                            (New-Object Windows.Point 0, 0)).Y
                    if ($y -lt $lastY) { throw 'the rail lists a heading above one it lists after' }
                    $lastY = $y
                }
                # A category both modes handle the same way is still on the rail,
                # reading 0 | 0, and it is not a place to go. Conservative
                # against Extreme is the widest pair there is, so if this finds
                # none the rail is not listing agreements at all.
                $agreed = @($cards | Where-Object { -not $_.IsHitTestVisible -and $_.Opacity -eq 1.0 })
                if (-not $agreed.Count) { throw 'no category is listed as one the two modes agree about' }
                foreach ($c in $agreed) {
                    if ([string]$c.Child.Children[0].Text -ne '0 | 0') {
                        throw "an agreed category counts '$($c.Child.Children[0].Text)'"
                    }
                }
                # The count is the only thing on this rail that says at a glance
                # whether there is anything under an entry. Blue where there is
                # and something to click, gray where the number is 0 | 0 - which
                # is the application's own rule for Accent, so a blue number on
                # an inert card would be reading as a control.
                $blue = $winL.Resources['WdAccent']
                $gray = $winL.Resources['WdMuted']
                if (-not $blue -or -not $gray) { throw 'the rail count colors are not in the theme' }
                foreach ($c in $jumps) {
                    if ($c.Child.Children[0].Foreground -ne $blue) {
                        throw "'$($c.Child.Children[1].Text)' leads somewhere and its count is not blue"
                    }
                }
                foreach ($c in $agreed) {
                    if ($c.Child.Children[0].Foreground -ne $gray) {
                        throw "'$($c.Child.Children[1].Text)' is 0 | 0 and its count is not gray"
                    }
                }
                # The highlight follows the scroll, the same spy the Advanced
                # rail has. It matters more here: Advanced repeats its headings
                # down the middle of the list, so one is always in sight, and
                # this page has two columns of cards with small headings that
                # leave the screen ten cards in.
                & $cmpSpyL.Fn
                $lit = @($jumps | Where-Object { $_.Tag.On })
                if ($lit.Count -ne 1) { throw "$($lit.Count) rail card(s) are lit at the top of the page" }
                if ($lit[0] -ne $jumps[0]) { throw 'the top of the page lit something other than the first heading' }
                # And it moves. Only asserted when the scroll actually lands -
                # a viewport shorter than its own content is the harness's
                # business, not the spy's.
                if ($uiL.CmpScroll.ScrollableHeight -gt 0 -and $jumps.Count -gt 1) {
                    $pick = $jumps[[Math]::Min(2, $jumps.Count - 1)]
                    $y = [double]$pick.Tag.Head.TransformToAncestor($uiL.CompareGrid).Transform(
                            (New-Object Windows.Point 0, 0)).Y
                    $uiL.CmpScroll.ScrollToVerticalOffset($y)
                    $uiL.CmpScroll.UpdateLayout()
                    if ([Math]::Abs([double]$uiL.CmpScroll.VerticalOffset - $y) -lt 2) {
                        & $cmpSpyL.Fn
                        if (-not $pick.Tag.On) { throw 'scrolling to a heading did not light its rail card' }
                        if (@($jumps | Where-Object { $_.Tag.On }).Count -ne 1) {
                            throw 'the old highlight stayed lit beside the new one'
                        }
                    }
                    $uiL.CmpScroll.ScrollToVerticalOffset(0)
                    $uiL.CmpScroll.UpdateLayout()
                    & $cmpSpyL.Fn
                }

                # And it follows the page. A search that empties the comparison
                # leaves the rail standing - every category is still one the two
                # modes cover - but nothing on it can be clicked, because there
                # is no longer a heading anywhere to scroll to.
                $uiL.TxtCmpSearch.Text = 'zzz-nothing-matches-this'
                try {
                    $live = @($uiL.CmpIndexPanel.Children | Where-Object { $_.Tag -and $_.Tag.Head })
                    if ($live.Count) { throw 'the rail still offers a jump to a heading that is gone' }
                    if ([double]$uiL.CmpIndexCol.Width.Value -le 0) { throw 'the rail gave up its column' }
                } finally { $uiL.TxtCmpSearch.Text = '' }
                if (-not @($uiL.CmpIndexPanel.Children | Where-Object { $_.Tag -and $_.Tag.Head }).Count) {
                    throw 'the rail did not come back'
                }
                & $cmpClearL
            }.GetNewClosure()
            # The three controls the page grew when eighty cards turned out to be
            # unreadable without them. Driven through the real controls, because
            # the whole risk here is a rebuild that reads a box nobody wired up.
            & $try 'compare narrows, arranges and searches the difference' {
                & $clrOvL
                & $goCompare
                foreach ($btn in $uiL.CompareARow.Children) { if ($btn.Content -eq 'Conservative') { & $clickBtn $btn } }
                foreach ($btn in $uiL.CompareBRow.Children) { if ($btn.Content -eq 'Extreme') { & $clickBtn $btn } }
                & $cmpClearL
                $wide = $uiL.CompareGrid.Children.Count
                if (-not $wide) { throw 'the comparison is empty before anything is filtered' }
                if ("$($uiL.BtnCmpFilter.Content)" -ne 'Filter') { throw "the button already reads '$($uiL.BtnCmpFilter.Content)'" }

                # A search that matches nothing empties the page and says which
                # kind of empty it is - "these modes are the same" would be a lie.
                $uiL.TxtCmpSearch.Text = 'zzz-nothing-matches-this'
                $txt = @($uiL.CompareGrid.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] } |
                         ForEach-Object { $_.Text }) -join ' '
                if ($txt -notmatch 'matches what you are filtering for') { throw "an empty search reads '$txt'" }
                if ($uiL.TxtCmpCount.Text -notmatch '^0 of \d') { throw "the count reads '$($uiL.TxtCmpCount.Text)'" }
                # And the footer still speaks for the modes rather than the box.
                # Anchored on the comma. Unanchored, '0 only in Extreme' is also
                # a substring of '40 only in Extreme', so this failed the moment
                # the count happened to land on a multiple of ten - and it threw
                # between setting the search box and clearing it, so every later
                # compare test then ran against a page narrowed to nothing.
                if ($uiL.TxtCompareTally.Text -match ', 0 only in Extreme') { throw 'the tally followed the search box' }
                $uiL.TxtCmpSearch.Text = ''
                if ($uiL.CompareGrid.Children.Count -ne $wide) { throw 'clearing the search did not bring the page back' }

                # One facet, through the real box.
                & $cmpTickL 'Risk' 'Risky' $true
                if ("$($uiL.BtnCmpFilter.Content)" -ne 'Filter (1)') { throw "the button reads '$($uiL.BtnCmpFilter.Content)'" }
                if ($uiL.TxtCmpCount.Text -notmatch ' of ') { throw 'the filtered count is missing' }
                $shown = [int](($uiL.TxtCmpCount.Text -split ' ')[0])
                if (-not $shown) { throw 'Extreme has nothing marked risky that Conservative lacks' }
                & $cmpTickL 'Risk' 'Risky' $false

                # Arranging. Every grouping has to produce headings, and the
                # bands have to come out in band order rather than alphabetically.
                $headsFor = {
                    param([string]$Mode)
                    foreach ($it in $uiL.CmbCmpGroup.Items) { if ([string]$it.Tag -eq $Mode) { $uiL.CmbCmpGroup.SelectedItem = $it } }
                    @($uiL.CompareGrid.Children |
                      Where-Object { $_ -is [Windows.Controls.StackPanel] -and $_.Orientation -eq 'Horizontal' } |
                      ForEach-Object { ($_.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] } |
                                        ForEach-Object { $_.Text }) -join '' })
                }
                foreach ($m in @('category', 'bloat', 'risk')) {
                    if (-not @(& $headsFor $m).Count) { throw "grouping by $m produced no headings" }
                }
                $riskHeads = @(& $headsFor 'risk' | Where-Object { $_ -match '^(Risky|Caution|No risk)' })
                if ($riskHeads.Count -gt 1 -and $riskHeads[0] -notmatch '^Risky') {
                    throw "risk headings came out as '$($riskHeads -join ', ')'"
                }
                foreach ($it in $uiL.CmbCmpGroup.Items) { if ([string]$it.Tag -eq 'category') { $uiL.CmbCmpGroup.SelectedItem = $it } }
                & $cmpClearL
            }.GetNewClosure()

            # Two identical sides used to take the page apart.
            #
            # The picker row was built only in the branch that draws cards, so
            # comparing a preset with itself - or with any preset holding the
            # same items - left $g.Children.Clear() having detached both pickers
            # and nothing putting them back. The rail empties at the same moment
            # (no headings, so no cards) and its column collapses to zero, which
            # is the vanishing sidebar. What is left is one sentence on an empty
            # page with no control on it that can change either side: a softlock
            # whose only exit is Back.
            & $try 'comparing a preset with itself leaves a way out' {
                & $clrOvL
                & $goCompare
                & $cmpClearL
                $pickIn = {
                    param($Row, [string]$Name)
                    foreach ($b in $Row.Children) { if ([string]$b.Content -eq $Name) { & $clickBtn $b; return } }
                    throw "no '$Name' button in the picker"
                }
                & $pickIn $uiL.CompareARow 'Balanced'
                & $pickIn $uiL.CompareBRow 'Balanced'
                if ([string]$cmpStateL.A -ne 'Balanced' -or [string]$cmpStateL.B -ne 'Balanced') {
                    throw "the sides read '$($cmpStateL.A)' and '$($cmpStateL.B)'"
                }
                # The page says what is going on rather than going blank.
                $txt = @($uiL.CompareGrid.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] } |
                         ForEach-Object { $_.Text }) -join ' '
                if ($txt -notmatch 'compared with itself') { throw "the page reads '$txt'" }
                # And both pickers are still ON the page. Walked up the logical
                # parents rather than asked with IsDescendantOf, which reads the
                # visual tree and is only populated once the page has been laid
                # out - this pass never gives it the chance.
                foreach ($k in @('A', 'B')) {
                    $p = $cmpHeadL[$k]; $hops = 0
                    while ($p -and $p -ne $uiL.CompareHead -and $hops -lt 8) { $p = $p.Parent; $hops++ }
                    if ($p -ne $uiL.CompareHead) { throw "the $k picker is not on the page" }
                }
                # Which means the way out is a click, not a trip to Back.
                & $pickIn $uiL.CompareBRow 'Extreme'
                if ([string]$cmpStateL.B -ne 'Extreme') { throw 'the picker did not answer a click' }
                if (-not $uiL.CompareGrid.Children.Count) { throw 'switching sides left the page empty' }
                & $cmpClearL
            }.GetNewClosure()

            # Compare is a page of decisions, so what it lists has to be things
            # that can actually be decided. An item whose target is not on this
            # machine is drawn gray and disabled in Advanced and was sitting
            # here behind a live "Add to Balanced" button.
            & $try 'compare lists nothing that cannot be selected' {
                & $clrOvL
                & $goCompare
                & $cmpClearL
                $absentIds = @($rowsL | Where-Object { $_.Absent } | ForEach-Object { [string]$_.Id })
                if ($absentIds.Count) {
                    $offered = @($cmpAddL | Where-Object { $absentIds -contains [string]$_.Tag.Id })
                    if ($offered.Count) {
                        throw "$($offered.Count) option(s) not on this machine are offered here, e.g. '$($offered[0].Tag.Id)'"
                    }
                }
                # And nothing already installed, which Advanced disables for the
                # same reason by a different route.
                $done = @($rowsL | Where-Object { $_.Done } | ForEach-Object { [string]$_.Id })
                if ($done.Count) {
                    $bad = @($cmpAddL | Where-Object { $done -contains [string]$_.Tag.Id })
                    if ($bad.Count) { throw "'$($bad[0].Tag.Id)' is already done and is offered here" }
                }
                # Every button that survived is one a click can actually use.
                $dead = @($cmpAddL | Where-Object { -not $_.IsEnabled })
                if ($dead.Count) { throw "$($dead.Count) hand-over button(s) are on the page and disabled" }
            }.GetNewClosure()

            & $try 'compare aligns both sides and flags what you added' {
                # Only an edit can make two modes each have something the other
                # lacks, so this is also the only way to reach the side-by-side
                # layout: add to Aggressive something Extreme does not take.
                & $clrOvL
                $base  = @($baseL['Aggressive'])
                # The added item has to come from a category Extreme also adds
                # to, or the two sides share no heading and nothing can line up.
                # Picking the first spare row was luck, and the Add section -
                # which no preset touches - is where that luck ran out.
                $extremeOnly = @($rowsL | Where-Object { $_.Id -in @($baseL['Extreme']) -and $_.Id -notin $base })
                $shared = @($extremeOnly | ForEach-Object { $_.Category } | Sort-Object -Unique)
                $spare = @($rowsL | Where-Object { $_.Category -in $shared -and
                                                   $_.Id -notin $base -and $_.Id -notin @($baseL['Extreme']) } |
                           Select-Object -First 1 | ForEach-Object { $_.Id })
                if (-not $spare.Count) { throw 'no spare item in a category Extreme also adds to' }
                & $setOvL 'Aggressive' $spare @()
                foreach ($btn in $uiL.CompareARow.Children) { if ($btn.Content -eq 'Aggressive') { & $clickBtn $btn } }
                foreach ($btn in $uiL.CompareBRow.Children) { if ($btn.Content -eq 'Extreme')    { & $clickBtn $btn } }
                $t = $uiL.TxtCompareTally.Text
                if ($t -match ', 0 only in Aggressive') { throw "tally reads '$t'" }
                if ($t -match ', 0 only in Extreme')    { throw "tally reads '$t'" }

                # With both sides populated nothing spans, so the two columns
                # stay in step and each category heading lines up with its twin.
                # The rule down the middle is skipped: it lives in column 1 and
                # spans every row by design, which is the one thing on this page
                # that is meant to cross both halves.
                $rowsUsed = @{}
                foreach ($el in $uiL.CompareGrid.Children) {
                    if ([Windows.Controls.Grid]::GetColumn($el) -eq 1) { continue }
                    if ([Windows.Controls.Grid]::GetColumnSpan($el) -gt 1) {
                        throw "something spans both columns while both sides have items"
                    }
                    $rw = [Windows.Controls.Grid]::GetRow($el)
                    if (-not $rowsUsed.ContainsKey($rw)) { $rowsUsed[$rw] = 0 }
                    $rowsUsed[$rw]++
                }
                if (@($rowsUsed.Values | Where-Object { $_ -eq 2 }).Count -lt 2) {
                    throw 'no row holds both sides, so nothing is aligned'
                }

                $tags = @()
                foreach ($el in $uiL.CompareGrid.Children) {
                    if ($el -isnot [Windows.Controls.StackPanel]) { continue }
                    foreach ($card in $el.Children) {
                        if ($card -isnot [Windows.Controls.Border]) { continue }
                        # Card is a DockPanel now - the hand-it-over button is
                        # docked right, the text stack fills the rest.
                        $inner = @($card.Child.Children | Where-Object { $_ -is [Windows.Controls.StackPanel] })[0]
                        if (-not $inner) { continue }
                        $head = $inner.Children[0]
                        # Visible, not merely present. Every card carries the tag
                        # now - cards are kept between builds and repainted, so
                        # the parts that come and go have to exist to be hidden -
                        # and a count of the ones that exist is a count of the
                        # cards.
                        foreach ($bit in $head.Children) {
                            if ($bit -is [Windows.Controls.Border] -and $bit.Child.Text -eq 'you added this' -and
                                $bit.Visibility -eq 'Visible') {
                                $tags += [string]$head.Children[0].Text
                            }
                        }
                    }
                }
                if ($tags.Count -ne 1) { throw "$($tags.Count) item(s) tagged, expected 1" }
                & $clrOvL
            }.GetNewClosure()
            & $try 'compare says everything the list says about the same item' {
                # Compare builds its own cards from the manifest rather than
                # reusing the Advanced rows, so anything added to a row has to be
                # added here too or the two pages disagree.
                #
                # The badge has been reversed TWICE, both times the same defect
                # from opposite sides: two pages carrying one badge and disagreeing
                # about whether it answers a click. It is a MARKER now, on both,
                # with the note reachable through the Details chip.
                #
                # The "not on this machine" half asserts the OPPOSITE of what it
                # used to, and that is the point. Those items used to be listed
                # here with a gray tag - honest if they are listed at all, and they
                # should not be, since Advanced disables that row while here it sat
                # behind a live "Add to Balanced" button. They are filtered out of
                # both selections before anything is compared.
                & $clrOvL
                foreach ($btn in $uiL.CompareARow.Children) { if ($btn.Content -eq 'Balanced')   { & $clickBtn $btn } }
                foreach ($btn in $uiL.CompareBRow.Children) { if ($btn.Content -eq 'Aggressive') { & $clickBtn $btn } }

                $badges = @(); $absent = @(); $seen = 0
                foreach ($el in $uiL.CompareGrid.Children) {
                    if ($el -isnot [Windows.Controls.StackPanel]) { continue }
                    foreach ($card in $el.Children) {
                        if ($card -isnot [Windows.Controls.Border]) { continue }
                        $inner = @($card.Child.Children | Where-Object { $_ -is [Windows.Controls.StackPanel] })[0]
                        if (-not $inner) { continue }
                        $seen++
                        $head = $inner.Children[0]
                        foreach ($bit in $head.Children) {
                            # A badge by what it IS - a bordered word in the risk
                            # palette - rather than by carrying a note on its Tag,
                            # which is what it used to be found by and is exactly
                            # the thing being removed.
                            if ($bit -is [Windows.Controls.Border] -and
                                $bit.Child -is [Windows.Controls.TextBlock] -and
                                [string]$bit.Child.Text -in @('caution','risky')) { $badges += $bit }
                            if ($bit -is [Windows.Controls.TextBlock] -and $bit.Text -match 'not on this machine') { $absent += $bit }
                        }
                    }
                }
                if (-not $seen) { throw 'no cards to look at' }
                if (-not $badges.Count) { throw 'not one card carries a risk badge' }
                foreach ($b in $badges) {
                    # A MARKER. The hand cursor is the loudest half of "this is a
                    # control", so it is the half asserted.
                    if ($b.Cursor -eq 'Hand') { throw 'a badge still reads as clickable' }
                    if ($b.Tag) { throw 'a badge still carries what a click would have needed' }
                }
                # And the note it used to open is still one click away, on every
                # card - which is the only reason the badge may stop answering.
                if (-not @($cmpDetailL).Count) { throw 'no card offers a Details chip' }
                $withNote = 0
                foreach ($d in @($cmpDetailL)) {
                    if ([string]$noteMapL[[string]$d.Id]) { $withNote++ }
                }
                if (-not $withNote) { throw 'not one Details chip on the page can reach a risk note' }
                # Not one card, because not one of them can be here.
                if ($absent.Count) {
                    throw "$($absent.Count) card(s) are still saying an item is not on this machine"
                }
                $gone = @($rowsL | Where-Object { $_.Absent } | ForEach-Object { [string]$_.Id })
                if ($gone.Count) {
                    $here = @($cmpAddL | Where-Object { $gone -contains [string]$_.Tag.Id })
                    if ($here.Count) { throw "'$($here[0].Tag.Id)' is not on this machine and has a card" }
                }
            }.GetNewClosure()
            & $try 'compare hands an item to the mode that is missing it' {
                & $clrOvL
                foreach ($btn in $uiL.CompareARow.Children) { if ($btn.Content -eq 'Balanced')   { & $clickBtn $btn } }
                foreach ($btn in $uiL.CompareBRow.Children) { if ($btn.Content -eq 'Aggressive') { & $clickBtn $btn } }
                if (-not $cmpAddL.Count) { throw 'nothing on the page could be handed over' }
                # Unedited, Aggressive is a superset of Balanced: every card is
                # Aggressive-only, so every button points the same way.
                $wrong = @($cmpAddL | Where-Object { $_.Tag.Target -ne 'Balanced' })
                if ($wrong.Count) { throw "$($wrong.Count) button(s) offer the wrong mode" }

                $cards  = $cmpAddL.Count
                $go     = $cmpAddL[0]
                $id     = [string]$go.Tag.Id
                # In the tree is not the same as on the screen: a card laid out
                # as a plain stack leaves the docked button zero-wide.
                $uiL.CompareGrid.UpdateLayout()
                if ($go.ActualWidth -le 0) { throw 'the button has no width on the page' }
                $before = @(& $effIdsL 'Balanced').Count
                & $clickBtn $go

                if (@(& $effIdsL 'Balanced') -notcontains $id) { throw 'Balanced did not take the item' }
                if (@(& $effIdsL 'Balanced').Count -ne $before + 1) { throw 'the count moved by more than the one item' }
                # The card stays where it was, marked done. A card that vanished
                # on click left nothing to show for the click.
                if ($cmpAddL.Count -ne $cards) { throw 'the card left the page instead of being marked' }
                $ghost = @($cmpAddL | Where-Object { $_.Tag.Id -eq $id })
                if (-not $ghost.Count) { throw 'the item lost its card' }
                if (-not $ghost[0].Tag.Done) { throw 'the button still offers to add it' }
                # The same button, now offering the opposite.
                if ("$($ghost[0].Content)" -notmatch 'remove') { throw "the button reads '$($ghost[0].Content)'" }
                if (-not $ghost[0].IsHitTestVisible) { throw 'the button cannot be clicked to take it back' }
                if (-not $ghost[0].IsEnabled) { throw 'the button is disabled rather than offering removal' }
                if ($uiL.TxtCompareNote.Text -notmatch 'Balanced') { throw "the note reads '$($uiL.TxtCompareNote.Text)'" }
                if ($uiL.BtnCompareUndo.Visibility -ne 'Visible') { throw 'no way back from the add' }
                # The edit is an ordinary preset edit, so the mode grid counts it.
                $bal = & $cellText $colsL['Balanced'].Num
                if ($bal -notmatch '1 item added') { throw "Balanced's column reads '$bal'" }

                # The card's own button is the direct way back, and it must undo
                # its own item rather than whichever was most recent.
                & $clickBtn $ghost[0]
                if (@(& $effIdsL 'Balanced') -contains $id) { throw 'the remove button left the item in Balanced' }
                if ($cmpAddL.Count -ne $cards) { throw 'removing lost the card' }
                $again = @($cmpAddL | Where-Object { $_.Tag.Id -eq $id })
                if (-not $again.Count -or $again[0].Tag.Done) { throw 'the button stayed marked as added' }
                if ("$($again[0].Content)" -notmatch 'Add to') { throw "it did not go back to offering the add: '$($again[0].Content)'" }
                if ($uiL.BtnCompareUndo.Visibility -ne 'Collapsed') { throw 'the stack still offers an undo' }
                if ($ovL.ContainsKey('Balanced')) { throw 'an edit that undid itself was still stored' }

                # Handing back something the user had taken out has to clear the
                # removal rather than record an addition, or the override claims
                # the id twice.
                $victim = @(& $effIdsL 'Balanced')[0]
                & $setOvL 'Balanced' @() @($victim)
                foreach ($btn in $uiL.CompareARow.Children) { if ($btn.Content -eq 'Balanced')   { & $clickBtn $btn } }
                $back = @($cmpAddL | Where-Object { $_.Tag.Id -eq $victim -and $_.Tag.Target -eq 'Balanced' })
                if (-not $back.Count) { throw 'the item removed from Balanced is not offered back to it' }
                & $clickBtn $back[0]
                if (@(& $effIdsL 'Balanced') -notcontains $victim) { throw 'it did not come back at all' }
                if ($ovL.ContainsKey('Balanced')) {
                    if (@($ovL['Balanced'].Added) -contains $victim) { throw 'it came back as an addition' }
                    throw 'Balanced is still marked as edited'
                }
                & $clrOvL
            }.GetNewClosure()
            # A hand-over used to take about a second, and every millisecond of it
            # was spent building things that had not changed: the whole mode
            # screen, which is not even on display from here, and eighty cards
            # whose only difference from the eighty already on the page was which
            # way one button pointed.
            #
            # Timed on the widest pair the ladder offers, which is the case the
            # complaint was about, and checked by identity rather than by
            # appearance. "It looks right afterwards" was already true of the
            # slow version; what this asserts is that the same objects are still
            # there, which is the only thing that makes it fast.
            & $try 'handing an item across repaints rather than rebuilds' {
                & $clrOvL
                & $goCompare
                & $cmpClearL
                foreach ($btn in $uiL.CompareARow.Children) { if ($btn.Content -eq 'Conservative') { & $clickBtn $btn } }
                foreach ($btn in $uiL.CompareBRow.Children) { if ($btn.Content -eq 'Extreme')      { & $clickBtn $btn } }
                $go = @($cmpAddL | Where-Object { -not $_.Tag.Done })[0]
                if (-not $go) { throw 'nothing on the widest pair could be handed over' }
                $cards = $cmpAddL.Count
                if ($cards -lt 20) { throw "only $cards card(s) between Conservative and Extreme" }
                $numWas  = $colsL['Conservative'].Num
                $textWas = & $cellText $numWas

                $sw = [Diagnostics.Stopwatch]::StartNew()
                & $clickBtn $go
                $ms = $sw.ElapsedMilliseconds

                # The card was repainted, not remade: the very button that was
                # clicked is the one now standing on the page offering to undo it.
                $still = @($cmpAddL | Where-Object { [object]::ReferenceEquals($_, $go) })
                if (-not $still.Count) { throw 'the card was rebuilt rather than repainted' }
                if (-not $go.Tag.Done) { throw 'the button did not change direction' }
                if ("$($go.Content)" -notmatch 'remove') { throw "the button reads '$($go.Content)'" }
                # And so was the mode screen, which is a page away and did not
                # need laying out again to say a different number.
                if (-not [object]::ReferenceEquals($colsL['Conservative'].Num, $numWas)) {
                    throw 'the whole mode grid was rebuilt for an edit that moved a count'
                }
                $textNow = & $cellText $colsL['Conservative'].Num
                if ($textNow -eq $textWas) { throw "the mode column still reads '$textNow'" }
                if ($textNow -notmatch '1 item added') { throw "the column reads '$textNow'" }

                # Not a benchmark, a regression guard, and the same reasoning as
                # the theme switch below. The thing being guarded against is a
                # full rebuild of this page, which for seventy cards is around a
                # second and a half.
                #
                # Raised once, from 800, and NOT because the page got heavier -
                # that was the first guess and the measurements refuted it.
                # Drawing every heading on both sides and ruling the blocks off
                # added about eighty elements per build and cost nothing you can
                # see: 373 ms before that change, 367 after, on the same idle
                # machine.
                #
                # What moves this number is what else the machine is doing. The
                # same build measured 548, 692 and 868 during runs whose total
                # was 123, 138 and 115 seconds against an idle 94. Eight hundred
                # sat inside that spread, so it failed on load rather than on a
                # regression - which is the one thing a guard must not do.
                # Twelve hundred is still far below the ~1.5s a real rebuild of
                # seventy cards costs, which is the thing being caught.
                if ($ms -gt 1200) { throw "the hand-over took ${ms} ms over $cards card(s), which is a rebuild" }
                Write-Host ("  compare handed an item across in {0} ms over {1} cards" -f $ms, $cards)
                & $clrOvL
            }.GetNewClosure()
            & $try 'compare undoes a run of hand-overs, one visit at a time' {
                & $clrOvL
                & $goCompare                         # a fresh visit empties the stack
                foreach ($btn in $uiL.CompareARow.Children) { if ($btn.Content -eq 'Balanced')   { & $clickBtn $btn } }
                foreach ($btn in $uiL.CompareBRow.Children) { if ($btn.Content -eq 'Aggressive') { & $clickBtn $btn } }
                if ($uiL.BtnCompareUndo.Visibility -ne 'Collapsed') { throw 'a fresh visit arrived with an undo stack' }

                $taken = @()
                foreach ($n in 1, 2, 3) {
                    $next = @($cmpAddL | Where-Object { -not $_.Tag.Done })[0]
                    if (-not $next) { throw "ran out of items after $($taken.Count)" }
                    $taken += [string]$next.Tag.Id
                    & $clickBtn $next
                }
                if (@($cmpDoneL).Count -ne 3) { throw "$(@($cmpDoneL).Count) recorded, expected 3" }
                if ("$($uiL.BtnCompareUndo.Content)" -notmatch '3') { throw "the button reads '$($uiL.BtnCompareUndo.Content)'" }
                foreach ($t in $taken) {
                    if (@(& $effIdsL 'Balanced') -notcontains $t) { throw 'an item did not make it across' }
                }
                if (@($cmpAddL | Where-Object { $_.Tag.Done }).Count -ne 3) { throw 'not every taken card is marked' }

                # Newest first, and each one only takes back its own item.
                for ($i = 2; $i -ge 0; $i--) {
                    & $clickBtn $uiL.BtnCompareUndo
                    $now = @(& $effIdsL 'Balanced')
                    if ($now -contains $taken[$i]) { throw "undo $i left its own item behind" }
                    for ($j = 0; $j -lt $i; $j++) {
                        if ($now -notcontains $taken[$j]) { throw 'undo reached past the most recent hand-over' }
                    }
                }
                if ($uiL.BtnCompareUndo.Visibility -ne 'Collapsed') { throw 'the empty stack still offers Undo' }
                if ($ovL.ContainsKey('Balanced')) { throw 'three adds and three undos left an edit behind' }

                # Leaving the page ends the run: the edits stay, the stack does not.
                & $clickBtn $cmpAddL[0]
                & $clickBtn $uiL.BtnCompareBack
                & $goCompare
                if ($uiL.BtnCompareUndo.Visibility -ne 'Collapsed') { throw 'undo survived a trip to the mode screen' }
                if (-not $ovL.ContainsKey('Balanced')) { throw 'the edit itself was lost on the way out' }
                & $clrOvL
            }.GetNewClosure()
            & $try 'back from Compare'     { & $clickBtn $uiL.BtnCompareBack }.GetNewClosure()
            & $try 'the past runs page lists a card per run' {
                & $clickBtn $uiL.BtnRevert
                if ($uiL.PageRevertHome.Visibility -ne 'Visible') { throw 'Revert did not land on the past runs page' }
                if ($uiL.PageRevert.Visibility -eq 'Visible') { throw 'it went straight to the long read' }
                $cards = @($uiL.RevHomeCards.Children)
                $runs  = @($revPickL.Runs)
                # One card per run, plus an all-runs card when there is more than
                # one run to put together.
                $want = $runs.Count + $(if ($runs.Count -gt 1) { 1 } else { 0 })
                if ($cards.Count -ne $want) { throw "$($cards.Count) cards for $($runs.Count) run(s), wanted $want" }
                if (-not $runs.Count -and $uiL.TxtRevHomeHint.Text -notmatch 'nothing to put back') {
                    throw "with no runs the page reads '$($uiL.TxtRevHomeHint.Text)'"
                }
                foreach ($c in $cards) {
                    if (-not $c.Tag.Open -or -not $c.Tag.Now) { throw 'a card is missing one of its two buttons' }
                    if (-not $c.Tag.State) { throw 'a card has no still-in-place line' }
                    # A run whose rollback script is gone is still NAMED and
                    # cannot be acted on. Both buttons follow that one fact.
                    if ([bool]$c.Tag.Open.IsEnabled -ne [bool]$c.Tag.Can) { throw 'Show all options disagrees with the script' }
                    if ([bool]$c.Tag.Now.IsEnabled  -ne [bool]$c.Tag.Can) { throw 'Revert everything disagrees with the script' }
                }
                # Every card that cannot answer yet has queued itself for the
                # shared read rather than printing a figure it does not have.
                foreach ($c in $cards) {
                    if ($c.Tag.State.Text -match 'still in place|already been reversed|could not be checked') { continue }
                    if ($c.Tag.State.Text -notmatch 'Reading') { throw "a card says '$($c.Tag.State.Text)'" }
                }
                # And the cards are all one height, which a WrapPanel does not do
                # on its own - see $fitRevertCards.
                if ($cards.Count -gt 1) {
                    $hs = @($cards | ForEach-Object { [Math]::Round([double]$_.ActualHeight) } | Select-Object -Unique)
                    if ($hs.Count -gt 1 -and @($hs | Where-Object { $_ -gt 0 }).Count -gt 1) {
                        throw "the cards are ragged: $($hs -join ', ')px"
                    }
                }
                & $clickBtn $uiL.BtnRevHomeBack
                if ($uiL.PageHome.Visibility -ne 'Visible') { throw 'Back did not return to the home page' }
            }.GetNewClosure()
            & $try 'open Revert' {
                if (-not (& $goRevertList)) {
                    Write-Host '        (no revertible run on this machine, list unopened)'
                    return
                }
                if ($uiL.PageRevert.Visibility -ne 'Visible') { throw 'Show all options did not open the list' }
                # And Back goes to the cards, not past them to the application's
                # home page - this page is one step in now.
                & $clickBtn $uiL.BtnRevertBack
                if ($uiL.PageRevertHome.Visibility -ne 'Visible') { throw 'Back skipped the past runs page' }
                $null = & $goRevertList
            }.GetNewClosure()
            if ($revL.Count) {
                & $try 'toggle a revert row' { $revL[0].Check.IsChecked = $true; $revL[0].Check.IsChecked = $false }.GetNewClosure()

                # The revert page is the rollback script's window built inside
                # the application, so it is driven the way that one is: every
                # grouping laid out, every sort applied, the filter opened and
                # cleared, the search narrowed, both Select alls pressed, a
                # group folded, and a Details panel opened. What is asserted is
                # the shape rather than the contents - which options a machine
                # has to put back is a fact about the machine.
                & $try 'revert page has a rail card per block' {
                    if (-not $revBlocksL.Count) { throw 'the page laid out no blocks at all' }
                    if ($revRailL.Count -ne $revBlocksL.Count) {
                        throw "$($revBlocksL.Count) block(s) against $($revRailL.Count) rail card(s)"
                    }
                    # Position, not label: two groups can share a title, and
                    # keying the spy on one lights three cards at once.
                    $keys = @($revBlocksL | ForEach-Object { [string]$_.Key })
                    if (@($keys | Select-Object -Unique).Count -ne $keys.Count) { throw 'two blocks share a key' }
                }.GetNewClosure()

                & $try 'every revert grouping lays something out' {
                    $was = [string]$revStateL.Group
                    foreach ($g in $revGrpsL) {
                        $revStateL.Group = [string]$g.Key
                        & $revOrderL
                        if (-not $revBlocksL.Count) { throw "grouping by $($g.Key) laid out nothing" }
                        if ($revRailL.Count -ne $revBlocksL.Count) { throw "grouping by $($g.Key) left the rail out of step" }
                    }
                    $revStateL.Group = $was
                    & $revOrderL
                }.GetNewClosure()

                & $try 'every revert sort applies' {
                    $was = [string]$revStateL.Sort
                    foreach ($s in $revSortsL) {
                        $revStateL.Sort = [string]$s.Key
                        & $revOrderL
                        foreach ($b in $revBlocksL) {
                            if (@($b.Ordered).Count -ne @($b.Group.Members).Count) {
                                throw "sorting by $($s.Key) lost rows out of a block"
                            }
                        }
                    }
                    $revStateL.Sort = $was
                    & $revOrderL
                }.GetNewClosure()

                # Two columns, which is the whole reason a block is a Grid. A
                # block of four or more visible rows must use both; below four it
                # deliberately stays one and gives the right half its width back.
                & $try 'a full revert block uses both columns' {
                    $big = @($revBlocksL | Where-Object { @($_.Ordered | Where-Object { $_.Card.Visibility -eq 'Visible' }).Count -ge 4 })
                    if ($big.Count) {
                        $b = $big[0]
                        if ($b.ColR.Children.Count -lt 1) { throw 'a block of four or more rows left its right column empty' }
                        if ($b.Grid.ColumnDefinitions[2].Width.Value -le 0) { throw 'the right column was given no width' }
                    }
                    $small = @($revBlocksL | Where-Object { @($_.Ordered | Where-Object { $_.Card.Visibility -eq 'Visible' }).Count -in 1..3 })
                    if ($small.Count -and $small[0].ColR.Children.Count) {
                        throw 'a block of under four rows was split into two columns'
                    }
                }.GetNewClosure()

                & $try 'the revert filter narrows and clears' {
                    $all = @($revL | Where-Object { $_.Card.Visibility -eq 'Visible' }).Count
                    $box = @($revBoxesL | Where-Object { $_.Group -eq 'State' })
                    if ($box.Count) {
                        $box[0].Box.IsChecked = $true
                        & $clickBtn $box[0].Box
                        if (-not $revSelL['State'].Count) { throw 'ticking a facet did not record it' }
                        if ($uiL.RevFilterChips.Visibility -ne 'Visible') { throw 'a live facet drew no chip' }
                        if ($uiL.BtnRevFilter.Content -notmatch '^Filter \(\d+\)$') { throw "the button does not say how many: $($uiL.BtnRevFilter.Content)" }
                        & $clickBtn $uiL.BtnRevFilterClear
                        if ($revSelL['State'].Count) { throw 'Clear all left a facet behind' }
                        if ($uiL.RevFilterChips.Visibility -ne 'Collapsed') { throw 'Clear all left a chip on screen' }
                        if (@($revL | Where-Object { $_.Card.Visibility -eq 'Visible' }).Count -ne $all) {
                            throw 'Clear all did not put every row back'
                        }
                    }
                }.GetNewClosure()

                & $try 'the revert search narrows the page' {
                    $all = @($revL | Where-Object { $_.Card.Visibility -eq 'Visible' }).Count
                    $uiL.RevFind.Text = 'zzzznothingmatchesthis'
                    if (@($revL | Where-Object { $_.Card.Visibility -eq 'Visible' }).Count -ne 0) {
                        throw 'a search that matches nothing still showed rows'
                    }
                    if ($uiL.TxtRevCount.Text -notmatch '^0 of \d+ options$') { throw "the count does not say what is shown: $($uiL.TxtRevCount.Text)" }
                    $uiL.RevFind.Text = ''
                    if (@($revL | Where-Object { $_.Card.Visibility -eq 'Visible' }).Count -ne $all) {
                        throw 'clearing the search did not put every row back'
                    }
                }.GetNewClosure()

                # Rows arrive TICKED - an option still in place is one somebody
                # opening this page wants back - so the first press clears the
                # page and the second takes it. Asserted without assuming which
                # way round, because the direction is a property of where the
                # page starts and the invariant is that the two presses are
                # opposites and the label names the press about to happen.
                & $try 'revert Select all takes the page and gives it back' {
                    $live = @($revL | Where-Object { $_.Check.IsEnabled -and $_.Card.Visibility -eq 'Visible' })
                    if ($live.Count) {
                        # A bare block, not a closure: GetNewClosure() here would
                        # copy this invocation's locals only, and $uiL lives at
                        # the enclosing closure's module scope. Bare, it resolves
                        # up the chain at the moment it is called.
                        $say = { "$([string]$uiL.BtnRevSelectAll.Content)/$(@($live | Where-Object { $_.Check.IsChecked }).Count)" }
                        $s0 = & $say
                        & $clickBtn $uiL.BtnRevSelectAll
                        $s1 = & $say
                        & $clickBtn $uiL.BtnRevSelectAll
                        $s2 = & $say
                        foreach ($s in @($s0, $s1, $s2)) {
                            if ($s -ne "Select none/$($live.Count)" -and $s -ne 'Select all/0') {
                                throw "the button and the ticks disagree: $s"
                            }
                        }
                        if ($s1 -eq $s0) { throw "a press changed nothing, still $s1" }
                        if ($s2 -ne $s0) { throw "pressing twice did not come back to $s0, gave $s2" }
                    }
                }.GetNewClosure()

                & $try 'revert groups fold and unfold' {
                    & $clickBtn $uiL.BtnRevCollapseAll
                    foreach ($b in $revBlocksL) {
                        if ($b.Body.Visibility -ne 'Collapsed') { throw 'Collapse all left a group open' }
                        if ([string]$b.Toggle.Content -ne '+') { throw 'a folded group still shows a minus' }
                    }
                    & $clickBtn $uiL.BtnRevExpandAll
                    foreach ($b in $revBlocksL) {
                        if ($b.Body.Visibility -ne 'Visible') { throw 'Expand all left a group shut' }
                        if ([string]$b.Toggle.Content -ne '-') { throw 'an open group still shows a plus' }
                    }
                }.GetNewClosure()

                & $try 'a revert row can say what it would do' {
                    $r = $revL[0]
                    if (-not [string]$r.DetailText) { throw 'a row carries no detail text, so the search cannot look inside it' }
                    $chip = $null
                    foreach ($el in $r.Line.Children) {
                        if ($el -is [Windows.Controls.Border] -and $el.Child -is [Windows.Controls.TextBlock] -and
                            [string]$el.Child.Text -eq 'Details') { $chip = $el }
                    }
                    if (-not $chip) { throw 'the row has no Details chip' }
                    # Built on first open, so the first press has to create it
                    # and the second has to fold it away rather than making a
                    # second copy.
                    & $clickEl $chip
                    if (-not $r.Detail.Det) { throw 'pressing Details built no panel' }
                    if ([string]$r.Detail.Det.Text -ne [string]$r.DetailText) { throw 'the panel does not show what the row says it would do' }
                    & $clickEl $chip
                    if ($r.Detail.Det.Visibility -ne 'Collapsed') { throw 'a second press did not fold the panel away' }
                    & $clickEl $chip
                    if ($r.Detail.Det.Visibility -ne 'Visible') { throw 'a third press did not bring it back' }
                    # Hovering is an interaction too, and one nobody can avoid.
                    & $hoverEl $chip $false
                    & $hoverEl $chip $true
                    & $hoverEl $r.Card $false
                    & $hoverEl $r.Card $true
                }.GetNewClosure()

                # A row with nothing left to decide must not invite a click, and
                # the tint is the loudest part of that invitation - it is this
                # application's own signal for "you can act on this". Asserted by
                # firing the real event and reading the resolved brush, because
                # the handler is built inside a closure and nothing but firing it
                # finds a handler wired to nothing.
                & $try 'an already-back revert row does not answer the pointer' {
                    $hover = $winL.Resources['WdRowHover']
                    $flat  = $winL.Resources['WdFlat']
                    if (-not $hover -or -not $flat) { throw 'the hover brushes are not in the theme' }
                    $dead = @($revL | Where-Object { -not $_.Check.IsEnabled })
                    $live = @($revL | Where-Object { $_.Check.IsEnabled })
                    if (-not $live.Count) { throw 'every option is already back, so a live row cannot be compared' }
                    # The live row first, or a page where nothing tints would
                    # pass this by tinting nothing.
                    & $hoverEl $live[0].Card $false
                    if ("$($live[0].Card.Background)" -ne "$hover") {
                        throw "a live revert row reads $($live[0].Card.Background) under the pointer, expected $hover"
                    }
                    & $hoverEl $live[0].Card $true
                    if ("$($live[0].Card.Background)" -ne "$flat") { throw 'a live revert row kept the tint' }
                    if ("$($live[0].Card.Cursor)" -ne 'Hand') { throw 'a live revert row offers no hand cursor' }
                    if ($dead.Count) {
                        & $hoverEl $dead[0].Card $false
                        if ("$($dead[0].Card.Background)" -eq "$hover") {
                            throw 'an already-back row still tints under the pointer'
                        }
                        & $hoverEl $dead[0].Card $true
                        if ("$($dead[0].Card.Cursor)" -eq 'Hand') {
                            throw 'an already-back row still offers a hand cursor'
                        }
                    }
                }.GetNewClosure()

                # Every option here arrives ticked, so a clear box is an edit -
                # the same edit as clearing a row a preset selected, and marked
                # the same way. The notice is the half the colour cannot carry:
                # on that page a tick is what a run will do, and on this one it
                # is what a run will undo.
                & $try 'unticking a revert option marks it and says what that means' {
                    $bad2 = $winL.Resources['WdBad']
                    $txt2 = $winL.Resources['WdText']
                    $live = @($revL | Where-Object { $_.Check.IsEnabled })
                    if (-not $live.Count) { throw 'no live row to untick' }
                    $r = $live[0]
                    if (-not $r.NameEl) { throw 'a revert row hands out no name element' }
                    if (-not $r.Skip)   { throw 'a revert row carries no notice line' }
                    if ([string]$r.Skip.Text -ne 'Option will not be reverted') {
                        throw "the notice reads '$($r.Skip.Text)'"
                    }
                    $r.Check.IsChecked = $true;  & $revCountL
                    if ($r.Skip.Visibility -ne 'Collapsed') { throw 'a ticked row claims it will not be reverted' }
                    $r.Check.IsChecked = $false; & $revCountL
                    if ("$($r.NameEl.Foreground)" -ne "$bad2") { throw "an unticked row's name reads $($r.NameEl.Foreground)" }
                    if ("$($r.NameEl.FontWeight)" -ne 'Bold')  { throw 'an unticked row is not bold' }
                    if ($r.Skip.Visibility -ne 'Visible')      { throw 'an unticked row shows no notice' }
                    $r.Check.IsChecked = $true;  & $revCountL
                    if ("$($r.NameEl.Foreground)" -ne "$txt2") { throw 're-ticking did not put the name back' }
                    if ("$($r.NameEl.FontWeight)" -ne 'SemiBold') { throw 're-ticking did not put the weight back' }
                    if ($r.Skip.Visibility -ne 'Collapsed')    { throw 're-ticking left the notice up' }
                    # AND AN ALREADY-BACK ROW IS NOT AN EDIT. It is unticked too
                    # and always was, so the reset branch must leave its Muted,
                    # struck-through name alone - which is why that branch is
                    # gated on the notice being up rather than on the tick.
                    $dead = @($revL | Where-Object { -not $_.Check.IsEnabled })
                    if ($dead.Count) {
                        $d = $dead[0]
                        & $revCountL
                        if ("$($d.NameEl.Foreground)" -ne "$($winL.Resources['WdMuted'])") {
                            throw "an already-back row's name was repainted to $($d.NameEl.Foreground)"
                        }
                        if ($d.Skip.Visibility -ne 'Collapsed') {
                            throw 'an already-back row claims it will not be reverted'
                        }
                        if (-not $d.NameEl.TextDecorations.Count) {
                            throw 'an already-back row lost its strikethrough'
                        }
                    }
                }.GetNewClosure()

                # The page costs the best part of ten seconds to build, and it
                # is built again every time the run picker moves - so both go
                # behind the same overlay the Advanced build uses. Stats is what
                # tells a bar that filled from one that sat at zero, which is
                # invisible afterwards because by then it is hidden and reset.
                & $try 'opening Revert runs behind the busy overlay' {
                    $st = $uiL.PageRevert.Parent
                    $bz = $winL.Tag.Busy
                    if (-not $bz) { throw 'the window has no busy overlay' }
                    if (-not $bz.Stats.Shown)      { throw 'the overlay was never shown for the revert build' }
                    if ($bz.Stats.MaxWidth -le 0)  { throw 'the overlay was shown but its bar never moved' }
                    if (-not $bz.Stats.Full)       { throw 'the bar never reached the end before the page appeared' }
                    if ($bz.Panel.Visibility -ne 'Collapsed') { throw 'the overlay was left up over the finished page' }
                    if ($null -eq $st) { throw 'the revert page is not parented' }
                }.GetNewClosure()

                & $try 'the run picker offers all runs and each run' {
                    $btns = @($uiL.RevertRunRow.Children)
                    if (-not $btns.Count) { throw 'the picker has no entries at all' }
                    if ([string]$btns[0].Tag -ne 'all') { throw 'All runs is not the first entry' }
                    if ($btns.Count -ne (@($revPickL.Runs).Count + 1)) {
                        throw "$($btns.Count) picker entries for $(@($revPickL.Runs).Count) run(s)"
                    }
                    # Whatever card opened this list is what the picker is
                    # showing. It used to assert 'all' outright, which was true
                    # while this page was reached from a footer button that had
                    # no scope to carry - a card names one.
                    $on = @($btns | Where-Object { [string]$_.Tag -eq [string]$revPickL.Sel })
                    if (-not $on.Count) { throw "the picker has no entry for the scope it is showing: $($revPickL.Sel)" }
                    if ($on[0].FontWeight -ne 'SemiBold') { throw 'the picker does not mark the scope it is showing' }
                }.GetNewClosure()
            }
            & $try 'back from Revert'      { & $clickBtn $uiL.BtnRevertBack }.GetNewClosure()

            # The run page's log and its status filters are otherwise only
            # reachable by starting a real run, which the harness cannot do.
            & $try 'log rows filter cleanly' {
                & $addRowL 'Removed' 'harness A' 'detail' $null
                & $addRowL 'Blocked' 'harness B' 'detail' $null
                & $addRowL 'Removed' 'harness C' 'detail' $null
                $before = $uiL.LogList.Items.Count
                $filtL['Removed'] = $false
                & $refilterL
                $hidden = $uiL.LogList.Items.Count
                $filtL['Removed'] = $true
                & $refilterL
                $restored = $uiL.LogList.Items.Count
                # Hidden rows must leave the list entirely, or they show as gaps.
                if ($before -ne 3 -or $hidden -ne 1 -or $restored -ne 3) {
                    throw "expected 3 then 1 then 3 items, got $before/$hidden/$restored"
                }
                $logRowsL.Clear(); $uiL.LogList.Items.Clear()
            }.GetNewClosure()

            # Excluding a preview row must be reversible, and reversing it has
            # to leave no trace - not the strikethrough, not the footer count.
            & $try 'preview rows exclude and re-add' {
                & $addRowL 'Removed' 'harness X' 'detail' 'harness-x'
                $tag = $logRowsL[$logRowsL.Count - 1].Element.Tag
                & $exclL $tag $true
                if (-not $stateL.Excluded.Contains('harness-x')) { throw 'was not excluded' }
                if ($tag.Label.Text -notmatch 'excluded')        { throw "label reads '$($tag.Label.Text)'" }
                if (-not $tag.Label.TextDecorations.Count)       { throw 'no strikethrough' }
                if ($uiL.TxtRunNote.Text -notmatch '1 item')     { throw "footer reads '$($uiL.TxtRunNote.Text)'" }
                & $exclL $tag $false
                if ($stateL.Excluded.Contains('harness-x'))      { throw 'still excluded' }
                if ($tag.Label.Text -ne 'harness X')             { throw "label reads '$($tag.Label.Text)'" }
                if ($tag.Label.TextDecorations.Count)            { throw 'strikethrough survived' }
                if ($uiL.TxtRunNote.Text -match 'excluded')      { throw "footer reads '$($uiL.TxtRunNote.Text)'" }
                $logRowsL.Clear(); $uiL.LogList.Items.Clear(); $stateL.Excluded.Clear()
            }.GetNewClosure()

            # The three buttons a mode card carries, at the narrowest the window
            # goes. They replaced a footer whose six controls shared one
            # DockPanel row, where an extra one did not wrap but silently
            # overlapped the tally on its left; the failure here is the other
            # shape of the same thing - a column is 190px at its minimum and a
            # button wider than that is drawn straight off the card, which WPF
            # reports as nothing at all.
            & $try 'a mode card fits its three buttons at minimum width' {
                & $clickBtn $uiL.BtnBackModes
                $wasW = $winL.Width
                $winL.Width = $winL.MinWidth
                $winL.UpdateLayout()
                $uiL.ModeGrid.UpdateLayout()
                $col = $colsL[[string]$stateL.Preset]
                if ([string]$col.Acts.Visibility -ne 'Visible') { throw 'the selected card offers nothing' }
                if ([string]$col.Go.Visibility -ne 'Visible') { throw 'the selected card has no Preview' }
                $room = [double]$col.Panel.ActualWidth
                if (-not $room) {
                    Write-Host '        (mode grid not laid out yet, geometry unchecked)'
                } else {
                    foreach ($b in @($col.Open, $col.Cmp, $col.Go)) {
                        $w = [double]$b.ActualWidth
                        if (-not $w) { throw "'$($b.Content)' was not laid out at all" }
                        if ($w -gt $room + 0.5) {
                            throw "'$($b.Content)' wants $([Math]::Round($w))px in a $([Math]::Round($room))px card"
                        }
                    }
                    # Stacked, so each has to start below the one above it - and
                    # measured against the card rather than against one of the
                    # two panels, since Preview is in a row of its own now.
                    $ys = @($col.Open, $col.Cmp, $col.Go) | ForEach-Object {
                        [double]$_.TranslatePoint((New-Object Windows.Point 0, 0), $col.Panel).Y
                    }
                    for ($i = 1; $i -lt $ys.Count; $i++) {
                        if ($ys[$i] -le $ys[$i - 1]) { throw 'the card buttons are not stacked' }
                    }
                    # Preview is the leftmost thing on its row and Save and Reset
                    # are at the far end of it. They are Collapsed with nothing
                    # edited, so this is about the row rather than the pair: the
                    # star column beside Preview has to be the one that grew.
                    $pv = [double]$col.Go.TranslatePoint((New-Object Windows.Point 0, 0), $col.GoRow).X
                    if ($pv -gt 1) { throw "Preview starts $([Math]::Round($pv))px into its own row" }
                    # And NOT the width of the card. Stretched, all three ran the
                    # full column and it read as three slabs rather than three
                    # buttons.
                    foreach ($b in @($col.Open, $col.Cmp, $col.Go)) {
                        if ([double]$b.ActualWidth -gt $room - 12) {
                            throw "'$($b.Content)' is $([Math]::Round($b.ActualWidth))px of a $([Math]::Round($room))px card"
                        }
                    }
                }
                # EVERY CARD PUTS THEM IN THE SAME PLACE. Custom has no bullet
                # list and a shorter description, so stacked from the top its
                # three landed a third of the way up the card while the other
                # four had theirs near the foot - five cards with their controls
                # at five heights, which reads as one card being broken. The
                # foot is docked to the bottom now, so this is measured rather
                # than argued about. With no preset edited, since Save and Reset
                # appear above them and only on an edited one.
                & $clrOvL
                $uiL.ModeGrid.UpdateLayout()
                $feet = @{}
                foreach ($p in $shippedL) {
                    $cc = $colsL[$p]
                    if (-not [double]$cc.Panel.ActualHeight) { continue }
                    $feet[$p] = [Math]::Round(
                        [double]$cc.Acts.TranslatePoint((New-Object Windows.Point 0, 0), $cc.Panel).Y, 0)
                }
                if ($feet.Count -gt 1) {
                    $spread = ($feet.Values | Measure-Object -Maximum).Maximum -
                              ($feet.Values | Measure-Object -Minimum).Minimum
                    if ($spread -gt 1) {
                        throw ('the buttons sit at different heights across the cards: ' +
                               (($feet.Keys | ForEach-Object { "$_ $($feet[$_])" }) -join ', '))
                    }
                }
                $winL.Width = $wasW
                $winL.UpdateLayout()
            }.GetNewClosure()
            & $try 'run footer keeps note, estimate and buttons apart' {
                $uiL.PageRun.Visibility       = 'Visible'
                $uiL.TxtRunNote.Text          = 'Simulation only, nothing was changed. Click any line for detail, then Apply.'
                $uiL.TxtRunEstimate.Text      = 'Apply time estimate: 7-21 minutes'
                $uiL.TxtRunEstimate.Visibility = 'Visible'
                $uiL.BtnApplyNow.Visibility   = 'Visible'
                $uiL.RunFooter.UpdateLayout()
                $bar  = $uiL.RunFooter.Child
                $edge = {
                    param($el)
                    $o = $el.TranslatePoint((New-Object Windows.Point 0, 0), $bar)
                    @{ L = [double]$o.X; R = [double]$o.X + $el.ActualWidth; W = [double]$el.ActualWidth }
                }
                $note = & $edge $uiL.TxtRunNote
                $est  = & $edge $uiL.TxtRunEstimate
                $btn  = & $edge $uiL.BtnCancel
                if (-not ($note.W -and $est.W -and $btn.W)) {
                    Write-Host '        (footer not laid out yet, geometry unchecked)'
                } else {
                    if ($est.L -lt $note.R) { throw "estimate starts at $($est.L), note ends at $($note.R)" }
                    if ($btn.L -lt $est.R)  { throw "Cancel starts at $($btn.L), estimate ends at $($est.R)" }
                }
                $uiL.PageRun.Visibility        = 'Collapsed'
                $uiL.BtnApplyNow.Visibility    = 'Collapsed'
                $uiL.TxtRunEstimate.Visibility = 'Collapsed'
                $uiL.TxtRunNote.Text = ''; $uiL.TxtRunEstimate.Text = ''
            }.GetNewClosure()

            # The apply used to open on the simulation's heading and the
            # simulation's counters, because the only code that writes a counter
            # runs when a result arrives and there are no results yet. That is
            # not a cosmetic complaint: it is the difference between "this has
            # started" and "this has finished", shown wrong.
            & $try 'the apply page opens clean, and says what it is doing before the first item' {
                & $enterRunL $true 'PageAdvanced'
                $uiL.LogList.Items.Clear()
                # Fake a simulation that got somewhere.
                $stateL.Counts['Removed'] = 56
                $stateL.Counts['Blocked'] = 3
                foreach ($sk in @($statsL.Keys)) {
                    $statsL[$sk].Text.Text = "$($statsL[$sk].Label) $($stateL.Counts[$sk])"
                }
                $uiL.TxtPhase.Text = 'Simulation complete'
                $uiL.BarOverall.Maximum = 139

                # Now enter it again as the real thing, exactly as Apply does.
                & $enterRunL $false 'PageAdvanced'
                if ($uiL.TxtPhase.Text -match 'complete') { throw "heading still reads '$($uiL.TxtPhase.Text)'" }
                if ($statsL['Removed'].Text.Text -notmatch '\b0$') { throw "counter still reads '$($statsL['Removed'].Text.Text)'" }
                if ($statsL['Blocked'].Text.Text -notmatch '\b0$') { throw "counter still reads '$($statsL['Blocked'].Text.Text)'" }
                if (-not $uiL.BarOverall.IsIndeterminate) { throw 'the bar claims a total it does not have yet' }
                if ($stateL.Acknowledged) { throw 'a real run started already acknowledged' }

                # A stage event before the plan exists.
                $null = $stateL.Sync.Queue.Add(@{ Phase='Stage'; Text='Creating a system restore point.'; Timed=$true })
                & $pumpL
                if ($uiL.NowCard.Visibility -ne 'Visible') { throw 'the bottom card is not showing' }
                if ($uiL.TxtNowItem.Text -notmatch 'restore point') { throw "bottom card reads '$($uiL.TxtNowItem.Text)'" }
                if ($uiL.TxtPhase.Text -match 'complete') { throw 'the heading went stale again' }

                # Then a plan, an item in flight, and its result.
                $null = $stateL.Sync.Queue.Add(@{ Phase='Start'; Index=0; Total=3 })
                $null = $stateL.Sync.Queue.Add(@{ Phase='Item'; Index=1; Total=3; ItemName='Vendor support suites'; Result=$null })
                & $pumpL
                if ($uiL.BarOverall.IsIndeterminate) { throw 'the bar is still indeterminate after Start' }
                if ($uiL.TxtNowItem.Text -ne 'Vendor support suites') { throw "bottom card reads '$($uiL.TxtNowItem.Text)'" }
                if (-not $stateL.NowSince) { throw 'the clock did not start on an item' }
                if ($statsL['Removed'].Text.Text -notmatch '\b0$') { throw 'an item in flight already counted' }

                $null = $stateL.Sync.Queue.Add(@{ Phase='Item'; Index=1; Total=3; Types=@('uninstall')
                    Result=[pscustomobject]@{ Status='Removed'; Name='Vendor support suites'; Message='1 removed'; Detail=''; Id='oem-support' } })
                & $pumpL
                if ($statsL['Removed'].Text.Text -notmatch '\b1$') { throw "counter reads '$($statsL['Removed'].Text.Text)' after one result" }

                # Finishing has to leave something to acknowledge.
                $stateL.Sync.Reboot = $true
                $stateL.Sync.Done = $true
                & $pumpL
                if ($stateL.Acknowledged) { throw 'a finished apply acknowledged itself' }
                if ($uiL.TxtRunNote.Text -notmatch 'restart') { throw "footer does not mention the restart: '$($uiL.TxtRunNote.Text)'" }
                if ($uiL.TxtNowHead.Text -ne 'Finished') { throw "bottom card reads '$($uiL.TxtNowHead.Text)' at the end" }
                if ($stateL.NowSince) { throw 'the clock is still running after the end' }

                # Back is the acknowledgement.
                & $clickBtn $uiL.BtnBackRun
                if (-not $stateL.Acknowledged) { throw 'leaving the page did not acknowledge the run' }

                $stateL.Sync.Done = $false; $stateL.Sync.Reboot = $false
                $stateL.Counts = @{ Removed=0; Changed=0; AlreadySet=0; NotPresent=0; Skipped=0; Obstruction=0; Partial=0; Blocked=0; Failed=0 }
                $uiL.PageRun.Visibility = 'Collapsed'; $uiL.NowCard.Visibility = 'Collapsed'
                $uiL.LogList.Items.Clear(); $logRowsL.Clear()
                $uiL.TxtRunNote.Text = ''
            }.GetNewClosure()

            # Following the tail is right only while the operator is reading the
            # tail. Scrolling up to look at a Blocked line and being dragged
            # back down by the next result is what this stops, so the check has
            # to be a real scroll on a real viewport, not a flag.
            & $try 'the log follows the tail only when it is already there' {
                $uiL.PageRun.Visibility = 'Visible'
                for ($i = 0; $i -lt 60; $i++) { & $addRowL 'Removed' "filler $i" 'detail' $null }
                $uiL.LogList.UpdateLayout()
                $sv = Get-WDChildScrollViewer $uiL.LogList
                if (-not $sv -or $sv.ScrollableHeight -le 0) {
                    Write-Host '        (log list not scrollable yet, autoscroll unchecked)'
                } else {
                    $sv.ScrollToTop(); $uiL.LogList.UpdateLayout()
                    $top = $sv.VerticalOffset
                    & $addRowL 'Removed' 'arrives while reading' 'detail' $null
                    $uiL.LogList.UpdateLayout()
                    if ($sv.VerticalOffset -ne $top) {
                        throw "scrolled from $top to $($sv.VerticalOffset) while parked at the top"
                    }

                    $sv.ScrollToBottom(); $uiL.LogList.UpdateLayout()
                    & $addRowL 'Removed' 'arrives while at the tail' 'detail' $null
                    $uiL.LogList.UpdateLayout()
                    if ($sv.VerticalOffset -lt ($sv.ScrollableHeight - 1.001)) {
                        throw "did not follow: offset $($sv.VerticalOffset) of $($sv.ScrollableHeight)"
                    }
                }
                $uiL.PageRun.Visibility = 'Collapsed'
                $logRowsL.Clear(); $uiL.LogList.Items.Clear()
            }.GetNewClosure()

            # Last, because it repaints everything the tests above just looked
            # at: a real theme switch, driven the way a person drives it - one
            # click on the button, then read the colors back off the page.
            #
            # Read off elements, not out of the dictionary. The dictionary
            # holding new brushes proves nothing on its own; what matters is
            # that a TextBlock built two thousand lines ago is now painted from
            # The bug this catches is invisible at the size this window opens
            # at, which is why it was found by eye on somebody's screen rather
            # than here: a horizontal StackPanel measures every child with
            # INFINITE width, so a TextBlock set to wrap never wraps, and
            # whatever follows it is pushed past the panel's own edge and
            # clipped. A long item name ate its own Details chip that way on a
            # window that was not maximized.
            #
            # Asked of the panels rather than of the pixels, and asked of the
            # children rather than of the panel: what a StackPanel stacks is its
            # children's DesiredSize, margins included, and if those add up to
            # more than the panel was given then the tail of it is somewhere
            # nobody can see. A WrapPanel cannot fail this, which is the whole
            # reason the name lines are WrapPanels.
            & $try 'nothing on any page is cut off at the narrowest window' {
                $bad  = New-Object System.Collections.Generic.List[string]
                $seen = @{ N = 0 }
                # Measured against the parent, and that is the whole subtlety.
                # The first version of this asked whether a panel's children
                # needed more room than the panel had, which never fires: a
                # horizontal StackPanel that wants more than it was offered is
                # ARRANGED at the width it wanted, not clipped to the width it
                # was given. The real reading, taken off the page that showed
                # this, was a name line 481px wide sitting inside a 223px parent
                # in a 366px card, with its last chip's right edge at 494. So the
                # question is not what a panel wanted, it is whether what it got
                # fits inside the thing it is in.
                $scan = {
                    param($El, [double]$Avail)
                    if (-not ($El -is [Windows.FrameworkElement]) -or -not $El.IsVisible) { return }
                    # A row inside something that scrolls sideways is MEANT to
                    # overflow: the preset pickers have no ceiling on how many
                    # buttons they hold, and scrolling is the answer they were
                    # given rather than a defect.
                    if ($El -is [Windows.Controls.ScrollViewer] -and
                        [string]$El.HorizontalScrollBarVisibility -ne 'Disabled') { return }
                    $w = [double]$El.ActualWidth
                    if ($w -gt 0 -and $Avail -gt 0) {
                        $seen.N++
                        if ($w -gt $Avail + 1) {
                            $what = [string]$El.Name
                            if (-not $what) {
                                foreach ($k in @([Windows.LogicalTreeHelper]::GetChildren($El))) {
                                    if ($k -is [Windows.Controls.TextBlock] -and "$($k.Text)") { $what = [string]$k.Text; break }
                                    if ($k -is [Windows.Controls.ContentControl] -and "$($k.Content)") { $what = [string]$k.Content; break }
                                }
                            }
                            if (-not $what) { $what = $El.GetType().Name }
                            if ($what.Length -gt 44) { $what = $what.Substring(0, 44) }
                            $bad.Add("'$what' is $([int]$w)px inside $([int]$Avail)px")
                        }
                    }
                    # The overflowing element's own width is what its children
                    # were laid out in, so only the first offender in a chain is
                    # named rather than everything under it.
                    $next = $(if ($w -gt 0) { $w } else { $Avail })
                    foreach ($k in @([Windows.LogicalTreeHelper]::GetChildren($El))) { & $scan $k $next }
                }
                $wasW = $winL.Width; $wasH = $winL.Height
                try {
                    $winL.Width = $winL.MinWidth; $winL.Height = $winL.MinHeight
                    # Each page walked while it is actually on screen: a
                    # collapsed element has no layout and reports itself
                    # invisible, so nothing inside it can be measured at all.
                    foreach ($p in @(@{ Open = { & $clickBtn $uiL.BtnDebloat };  Page = $uiL.PageHome;     Back = $null },
                                     @{ Open = { & $clickBtn $uiL.BtnDebloat };  Page = $uiL.PageModes;    Back = $uiL.BtnModesBack },
                                     @{ Open = { & $clickBtn $uiL.BtnAdvanced }; Page = $uiL.PageAdvanced; Back = $uiL.BtnBackModes },
                                     @{ Open = $goCompare;                       Page = $uiL.PageCompare;  Back = $uiL.BtnCompareBack },
                                     @{ Open = { & $clickBtn $uiL.BtnRevert };   Page = $uiL.PageRevertHome; Back = $uiL.BtnRevHomeBack },
                                     @{ Open = { & $clickBtn $uiL.BtnUnattend }; Page = $uiL.PageUnattend; Back = $uiL.BtnUaBack })) {
                        # The home page is walked too - it is the first thing
                        # anybody sees and its three cards are the widest fixed
                        # things in the window, so it is exactly where a wrapping
                        # fault at the minimum width would show first.
                        if ([string]$p.Page.Name -eq 'PageHome') { & $clickBtn $uiL.BtnModesBack }
                        else { & $p.Open }
                        $winL.UpdateLayout()
                        & $scan $p.Page ([double]$p.Page.ActualWidth)
                        if ($p.Back) { & $clickBtn $p.Back }
                    }
                    & $clickBtn $uiL.BtnDebloat
                    $winL.UpdateLayout()
                    foreach ($root in @($uiL.PageModes, $uiL.HeaderBar)) {
                        & $scan $root ([double]$root.ActualWidth)
                    }
                } finally {
                    $winL.Width = $wasW; $winL.Height = $wasH; $winL.UpdateLayout()
                }
                if ($bad.Count) {
                    throw "$($bad.Count) of $($seen.N) element(s) run past what holds them, e.g. $($bad[0])"
                }
                Write-Host "  narrow window : $($seen.N) element(s) at $([int]$winL.MinWidth)px, none past its container"
            }.GetNewClosure()

            # it, and every kind of thing that carries a color is checked -
            # a page brush, a control's foreground, a Run inside a TextBlock,
            # and something built by a paint closure long after the window
            # opened.
            & $try 'the theme switches in place, and the whole page follows' {
                & $clickBtn $uiL.BtnAdvanced
                $was = [string]$stateL.Theme
                $sample = @{
                    'header'   = @($uiL.HeaderTitle,  'Foreground')
                    'footer'   = @($uiL.AdvFooter,    'Background')
                    'checkbox' = @($uiL.ChkOwnership, 'Foreground')
                    'a row'    = @($rowsL[0].Name,    'Foreground')
                    'the rail' = @($idxEntriesL[0].Label, 'Foreground')
                }
                $before = @{}
                foreach ($k in $sample.Keys) { $before[$k] = "$($sample[$k][0].($sample[$k][1]))" }

                $sw = [Diagnostics.Stopwatch]::StartNew()
                & $clickBtn $uiL.BtnTheme
                $ms = $sw.ElapsedMilliseconds

                if ([string]$stateL.Theme -eq $was) { throw "the theme stayed on '$was'" }
                foreach ($k in $sample.Keys) {
                    $now = "$($sample[$k][0].($sample[$k][1]))"
                    if ($now -eq $before[$k]) { throw "$k kept $now across the switch" }
                }
                # The window is the thing that must NOT have been replaced -
                # that is the whole difference from the rebuild this replaced.
                if (-not $winL.IsVisible) { throw 'the switch closed the window' }
                if ($uiL.PageAdvanced.Visibility -ne 'Visible') { throw 'the switch threw away the open page' }
                if ($null -eq $rowsL[0].Panel.Parent) { throw 'the switch detached the rows' }
                $want = $(if ($stateL.Theme -eq 'dark') { 'light' } else { 'dark' })
                if ("$($uiL.BtnTheme.Content)" -notmatch $want) {
                    throw "the button still offers '$($uiL.BtnTheme.Content)'"
                }
                # Not a benchmark, a regression guard: the old switch took about
                # three seconds behind an overlay, and anything near that means
                # something is being rebuilt again.
                #
                # 1200, not 500. The ceiling was set at 500 against runs that
                # measured 433 and 457, and the same machine then produced 541
                # with nothing between the two runs that touches the repaint -
                # so it was a threshold sitting inside its own measurement's
                # noise, which is a test that fails at random and teaches
                # nothing when it does. The thing being guarded against is three
                # seconds; anything under a second is a repaint however the run
                # scattered. Same reasoning as the pre-warm ceiling below.
                if ($ms -gt 1200) { throw "the switch took ${ms} ms, which is a rebuild" }
                Write-Host ("  theme switch repainted the page in {0} ms" -f $ms)
            }.GetNewClosure()

            if ($fails.Count) {
                Write-Host "  $($fails.Count) interaction failure(s):" -ForegroundColor Red
                foreach ($f in $fails) { Write-Host "    $f" -ForegroundColor Red }
            } else {
                Write-Host "  all interactions clean" -ForegroundColor Green
            }
            # Mutating a captured hashtable works; assigning $script: here would
            # write to this closure's own module, not WD.UI's, and the caller
            # would always read back zero.
            $selfTest.Failures = $fails.Count
            $win.Close()
}

Export-ModuleMember -Function Invoke-WDInteractionTest
