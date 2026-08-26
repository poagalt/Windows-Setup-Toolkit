<#
    Difference between two snapshots from Get-WDSystemSnapshot.ps1.

    Also self-contained, and for the same reason.

    The output is in two halves and the order is deliberate. NOTABLE comes
    first: the handful of changes that usually mean something went wrong,
    picked out by rule rather than left for somebody to spot in nine hundred
    lines of diff. Everything else follows, in full, because the whole point
    of a snapshot pair is that nothing is summarised away.

        .\Tools\Compare-WDSnapshot.ps1 -Before <dir-or-json> -After <dir-or-json>
        .\Tools\Compare-WDSnapshot.ps1 -Before <dir> -After <dir> -Full
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Before,
    [Parameter(Mandatory)][string]$After,

    # Where to write the report. Defaults beside the after-snapshot.
    [string]$OutFile,

    # Print every changed registry value rather than a capped sample.
    [switch]$Full,

    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Resolve-Snapshot {
    param([string]$P)
    if (Test-Path -LiteralPath $P -PathType Container) { $P = Join-Path $P 'snapshot.json' }
    if (-not (Test-Path -LiteralPath $P)) { throw "No snapshot at '$P'." }
    $P
}

$beforePath = Resolve-Snapshot $Before
$afterPath  = Resolve-Snapshot $After
$b = Get-Content -LiteralPath $beforePath -Raw -Encoding UTF8 | ConvertFrom-Json
$a = Get-Content -LiteralPath $afterPath  -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $OutFile) {
    $OutFile = Join-Path (Split-Path -Parent $afterPath) 'comparison.txt'
}

$out      = New-Object System.Collections.Generic.List[string]
$notable  = New-Object System.Collections.Generic.List[string]

function Add-Line { param([string]$T = '') $out.Add($T) }
function Add-Head {
    param([string]$T)
    Add-Line ''
    Add-Line ('-' * 78)
    Add-Line $T
    Add-Line ('-' * 78)
}

function Get-Field {
    <#  ConvertFrom-Json hands back PSCustomObjects, which have no ContainsKey
        and throw nothing at all for a missing property - they return $null,
        which is indistinguishable from a property that is present and null.
        This asks the property bag instead.  #>
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $null
    }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    $null
}

function Format-Value {
    param($V)
    if ($null -eq $V) { return '<absent>' }
    if ($V -is [System.Collections.IEnumerable] -and $V -isnot [string]) {
        return '[' + (@($V) -join ', ') + ']'
    }
    [string]$V
}

# ------------------------------------------------------- collection differ ---

function Compare-Collection {
    <#
        Diff two lists of records by an identity field.

        Returns added / removed / changed, where changed carries the per-field
        before and after. Fields to watch are named rather than compared
        wholesale, because half of these records carry a timestamp or a process
        id that differs on every capture and would drown the real changes.
    #>
    param(
        [string]$Title,
        $BeforeRows,
        $AfterRows,
        [string]$Key,
        [string[]]$Watch = @(),
        [string]$Show = ''
    )
    if (-not $Show) { $Show = $Key }

    $bMap = @{}; $aMap = @{}
    foreach ($r in @($BeforeRows)) {
        if ($r -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $k = [string](Get-Field $r $Key)
        if ($k) { $bMap[$k] = $r }
    }
    foreach ($r in @($AfterRows)) {
        if ($r -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $k = [string](Get-Field $r $Key)
        if ($k) { $aMap[$k] = $r }
    }

    $removed = @($bMap.Keys | Where-Object { -not $aMap.ContainsKey($_) } | Sort-Object)
    $added   = @($aMap.Keys | Where-Object { -not $bMap.ContainsKey($_) } | Sort-Object)
    $changed = New-Object System.Collections.Generic.List[object]
    foreach ($k in ($bMap.Keys | Where-Object { $aMap.ContainsKey($_) } | Sort-Object)) {
        $diffs = New-Object System.Collections.Generic.List[string]
        foreach ($f in $Watch) {
            $bv = Format-Value (Get-Field $bMap[$k] $f)
            $av = Format-Value (Get-Field $aMap[$k] $f)
            if ($bv -ne $av) { $diffs.Add("$f : $bv -> $av") }
        }
        if ($diffs.Count) { $changed.Add([pscustomobject]@{ Key = $k; Diffs = $diffs }) }
    }

    Add-Head "$Title   (-$($removed.Count)  +$($added.Count)  ~$($changed.Count))"
    if (-not ($removed.Count -or $added.Count -or $changed.Count)) {
        Add-Line '  no change'
    }
    foreach ($k in $removed) {
        $label = [string](Get-Field $bMap[$k] $Show)
        Add-Line ("  - {0}{1}" -f $k, $(if ($label -and $label -ne $k) { "   ($label)" } else { '' }))
    }
    foreach ($k in $added) {
        $label = [string](Get-Field $aMap[$k] $Show)
        Add-Line ("  + {0}{1}" -f $k, $(if ($label -and $label -ne $k) { "   ($label)" } else { '' }))
    }
    foreach ($c in $changed) {
        Add-Line ("  ~ {0}" -f $c.Key)
        foreach ($d in $c.Diffs) { Add-Line "        $d" }
    }

    [pscustomobject]@{ Removed = $removed; Added = $added; Changed = $changed; BeforeMap = $bMap; AfterMap = $aMap }
}

function Compare-Map {
    <#  Two flat maps of name -> { value; kind }, or name -> scalar.  #>
    param([string]$Title, $BeforeMap, $AfterMap, [switch]$Quietly)
    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($o in @($BeforeMap, $AfterMap)) {
        if ($null -eq $o) { continue }
        foreach ($p in $o.PSObject.Properties) { $null = $names.Add($p.Name) }
    }
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($n in ($names | Sort-Object)) {
        $bv = Get-Field $BeforeMap $n
        $av = Get-Field $AfterMap  $n
        # A { value; kind } pair rather than a scalar, when it came from a key dump.
        if ($bv -and $bv.PSObject.Properties['value']) { $bv = $bv.value }
        if ($av -and $av.PSObject.Properties['value']) { $av = $av.value }
        $bs = Format-Value $bv
        $as = Format-Value $av
        if ($bs -ne $as) { $rows.Add(("  ~ {0,-46} {1}  ->  {2}" -f $n, $bs, $as)) }
    }
    if ($rows.Count -or -not $Quietly) {
        Add-Head "$Title   (~$($rows.Count))"
        if (-not $rows.Count) { Add-Line '  no change' }
        foreach ($r in $rows) { Add-Line $r }
    }
    $rows.Count
}

# ==================================================================== head ===

Add-Line 'Windows Setup Toolkit snapshot comparison'
Add-Line ('=' * 78)
Add-Line ("Before : {0}   {1}" -f (Get-Field (Get-Field $b 'meta') 'label'), (Get-Field (Get-Field $b 'meta') 'takenLocal'))
Add-Line ("         {0}" -f $beforePath)
Add-Line ("After  : {0}   {1}" -f (Get-Field (Get-Field $a 'meta') 'label'), (Get-Field (Get-Field $a 'meta') 'takenLocal'))
Add-Line ("         {0}" -f $afterPath)
$bElev = Get-Field (Get-Field $b 'meta') 'elevated'
$aElev = Get-Field (Get-Field $a 'meta') 'elevated'
if ($bElev -ne $aElev) {
    Add-Line ''
    Add-Line ("  WARNING  one snapshot was elevated and the other was not (before={0} after={1})." -f $bElev, $aElev)
    Add-Line '           Sections needing administrator rights will diff as though everything vanished.'
    $notable.Add("Snapshots taken at different privilege levels - before elevated=$bElev, after elevated=$aElev. Treat service, task, and Defender diffs with suspicion.")
}

# ============================================================== collections ==

$bScope = Get-Field (Get-Field $b '__diagnostics__') 'appxScope'
$aScope = Get-Field (Get-Field $a '__diagnostics__') 'appxScope'
if ($bScope -and $aScope -and $bScope -ne $aScope) {
    Add-Line ''
    Add-Line ("  WARNING  package lists were enumerated differently (before={0} after={1})." -f $bScope, $aScope)
    Add-Line '           An all-users list against a current-user one reads as mass removal. Re-take both the same way.'
    $notable.Add("Package lists are not comparable: before=$bScope, after=$aScope. Re-take both snapshots elevated.")
}
# Everything written so far is the preamble, and the NOTABLE block is spliced
# in after it. Marked here rather than by counting lines at the bottom: the
# preamble grows by a warning or two depending on the pair being compared, and
# a hardcoded index silently truncated the "After" lines off the header.
$preambleEnd = $out.Count

$appx = Compare-Collection 'Store packages' (Get-Field $b 'appxPackages') (Get-Field $a 'appxPackages') `
            -Key 'name' -Show 'fullName' -Watch @('version', 'status', 'nonRemovable')

$prov = Compare-Collection 'Provisioned packages' (Get-Field $b 'appxProvisioned') (Get-Field $a 'appxProvisioned') `
            -Key 'displayName' -Watch @('version')

$prog = Compare-Collection 'Installed programs' (Get-Field $b 'programs') (Get-Field $a 'programs') `
            -Key 'displayName' -Watch @('displayVersion', 'installLocation')

$svc = Compare-Collection 'Services' (Get-Field $b 'services') (Get-Field $a 'services') `
            -Key 'name' -Show 'displayName' -Watch @('startType', 'status', 'pathName', 'startName')

$task = Compare-Collection 'Scheduled tasks' (Get-Field $b 'scheduledTasks') (Get-Field $a 'scheduledTasks') `
            -Key 'path' -Watch @('enabled', 'state')

$feat = Compare-Collection 'Windows features' (Get-Field $b 'features') (Get-Field $a 'features') `
            -Key 'name' -Watch @('state')

$capa = Compare-Collection 'Capabilities' (Get-Field $b 'capabilities') (Get-Field $a 'capabilities') `
            -Key 'name' -Watch @('state')

$drv = Compare-Collection 'Third-party drivers' (Get-Field $b 'drivers') (Get-Field $a 'drivers') `
            -Key 'published' -Show 'original' -Watch @('version')

$vol = Compare-Collection 'Volumes' (Get-Field $b 'volumes') (Get-Field $a 'volumes') `
            -Key 'drive' -Watch @('freeGb', 'freePct')

$pth = Compare-Collection 'Watched paths' (Get-Field $b 'paths') (Get-Field $a 'paths') `
            -Key 'path' -Watch @('exists', 'files', 'bytes')

# --------------------------------------------- the manifest's own targets ----

$bReg = @{}; $aReg = @{}
foreach ($r in @(Get-Field $b 'registryManifestTargets')) {
    if ($r -isnot [System.Management.Automation.PSCustomObject]) { continue }
    $bReg["$(Get-Field $r 'path')|$(Get-Field $r 'name')"] = $r
}
foreach ($r in @(Get-Field $a 'registryManifestTargets')) {
    if ($r -isnot [System.Management.Automation.PSCustomObject]) { continue }
    $aReg["$(Get-Field $r 'path')|$(Get-Field $r 'name')"] = $r
}
$regMoved   = New-Object System.Collections.Generic.List[object]
$regWanted  = New-Object System.Collections.Generic.List[object]
foreach ($k in ($bReg.Keys | Sort-Object)) {
    if (-not $aReg.ContainsKey($k)) { continue }
    $bv = Format-Value (Get-Field $bReg[$k] 'current')
    $av = Format-Value (Get-Field $aReg[$k] 'current')
    $bp = Get-Field $bReg[$k] 'present'
    $ap = Get-Field $aReg[$k] 'present'
    if ($bv -ne $av -or $bp -ne $ap) {
        $regMoved.Add([pscustomobject]@{
            Key = $k; Item = (Get-Field $aReg[$k] 'item')
            From = $(if ($bp) { $bv } else { '<absent>' })
            To   = $(if ($ap) { $av } else { '<absent>' })
            Wants = Format-Value (Get-Field $aReg[$k] 'wants')
        })
    }
}
Add-Head "Registry values the manifest can write   (~$($regMoved.Count) moved of $($bReg.Count) tracked)"
if (-not $regMoved.Count) { Add-Line '  no change' }
$cap = if ($Full) { [int]::MaxValue } else { 120 }
$n = 0
foreach ($r in $regMoved) {
    $n++
    if ($n -gt $cap) { Add-Line "  ... and $($regMoved.Count - $cap) more (re-run with -Full)"; break }
    Add-Line ("  ~ [{0}] {1}" -f $r.Item, $r.Key)
    Add-Line ("        {0}  ->  {1}   (item wants {2})" -f $r.From, $r.To, $r.Wants)
}

# ------------------------------------------------------------- flat maps -----

$treeChanges = 0
$bTrees = Get-Field $b 'registryTrees'
$aTrees = Get-Field $a 'registryTrees'
$treeNames = New-Object System.Collections.Generic.HashSet[string]
foreach ($o in @($bTrees, $aTrees)) {
    if ($null -eq $o) { continue }
    foreach ($p in $o.PSObject.Properties) { $null = $treeNames.Add($p.Name) }
}
foreach ($t in ($treeNames | Sort-Object)) {
    $treeChanges += (Compare-Map "Registry key: $t" (Get-Field $bTrees $t) (Get-Field $aTrees $t) -Quietly)
}

$bStart = Get-Field $b 'startup'
$aStart = Get-Field $a 'startup'
$startNames = New-Object System.Collections.Generic.HashSet[string]
foreach ($o in @((Get-Field $bStart 'registry'), (Get-Field $aStart 'registry'))) {
    if ($null -eq $o) { continue }
    foreach ($p in $o.PSObject.Properties) { $null = $startNames.Add($p.Name) }
}
foreach ($t in ($startNames | Sort-Object)) {
    $null = Compare-Map "Startup: $t" (Get-Field (Get-Field $bStart 'registry') $t) `
                                      (Get-Field (Get-Field $aStart 'registry') $t) -Quietly
}

$assocChanged = Compare-Map 'File and protocol associations' (Get-Field $b 'associations') (Get-Field $a 'associations')
$null = Compare-Map 'UAC' (Get-Field $b 'uac') (Get-Field $a 'uac')
$null = Compare-Map 'Explorer advanced' (Get-Field (Get-Field $b 'shellState') 'advanced') `
                                        (Get-Field (Get-Field $a 'shellState') 'advanced')

# ------------------------------------------------------------- scalars -------

Add-Head 'System state'
foreach ($pair in @(
    @('os.buildNumber',                'os',            'buildNumber'),
    @('os.ubr',                        'os',            'ubr'),
    @('os.bootupState',                'os',            'bootupState'),
    @('os.safeBootOption',             'os',            'safeBootOption'),
    @('protection.restoreCount',       'protection',    'restoreCount'),
    @('pendingReboot.cbs',             'pendingReboot', 'cbsRebootPending'),
    @('pendingReboot.wu',              'pendingReboot', 'wuRebootRequired'),
    @('pendingReboot.fileRenames',     'pendingReboot', 'pendingRenameCount'),
    @('power.activeScheme',            'power',         'activeScheme'),
    @('shellState.stuckRects',         'shellState',    'stuckRects'),
    @('network.hostsHash',             'network',       'hostsHash')
)) {
    $bv = Format-Value (Get-Field (Get-Field $b $pair[1]) $pair[2])
    $av = Format-Value (Get-Field (Get-Field $a $pair[1]) $pair[2])
    $mark = if ($bv -eq $av) { ' ' } else { '~' }
    Add-Line ("  {0} {1,-30} {2}  ->  {3}" -f $mark, $pair[0], $bv, $av)
}

# The restore-point throttle, which the toolkit sets to zero and must put back.
$bFreq = Get-Field (Get-Field $b 'protection') 'createFreq'
$aFreq = Get-Field (Get-Field $a 'protection') 'createFreq'
Add-Line ("    {0,-30} present={1} value={2}  ->  present={3} value={4}" -f `
          'SystemRestorePointCreationFrequency', (Get-Field $bFreq 'present'), (Format-Value (Get-Field $bFreq 'value')),
          (Get-Field $aFreq 'present'), (Format-Value (Get-Field $aFreq 'value')))

# ------------------------------------------------------------ event log ------

Add-Head 'Event log: providers newly logging errors or warnings'
$bEv = @{}
foreach ($log in @('System', 'Application')) {
    foreach ($r in @(Get-Field (Get-Field $b 'eventBaseline') $log)) {
        if ($r -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $bEv["$log|$(Get-Field $r 'provider')|$(Get-Field $r 'level')"] = [int](Get-Field $r 'count')
    }
}
$evRows = New-Object System.Collections.Generic.List[string]
foreach ($log in @('System', 'Application')) {
    foreach ($r in @(Get-Field (Get-Field $a 'eventBaseline') $log)) {
        if ($r -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $k = "$log|$(Get-Field $r 'provider')|$(Get-Field $r 'level')"
        $was = if ($bEv.ContainsKey($k)) { $bEv[$k] } else { 0 }
        $now = [int](Get-Field $r 'count')
        if ($now -gt $was) {
            $evRows.Add(("  {0,-12} {1,-42} level {2}   {3} -> {4}" -f $log, (Get-Field $r 'provider'), (Get-Field $r 'level'), $was, $now))
        }
    }
}
if (-not $evRows.Count) { Add-Line '  nothing new' }
foreach ($r in ($evRows | Sort-Object)) { Add-Line $r }

# ==================================================== notable, by rule =======

# A service that was running and is now stopped WITHOUT its start type having
# been deliberately changed is the shape of collateral damage - something else
# took it down. One whose start type moved to Disabled was almost certainly
# asked for, so it is reported separately and much more quietly.
foreach ($c in $svc.Changed) {
    $bRow = $svc.BeforeMap[$c.Key]; $aRow = $svc.AfterMap[$c.Key]
    $bSt = [string](Get-Field $bRow 'status');    $aSt = [string](Get-Field $aRow 'status')
    $bTy = [string](Get-Field $bRow 'startType'); $aTy = [string](Get-Field $aRow 'startType')
    if ($bSt -eq 'Running' -and $aSt -ne 'Running' -and $bTy -eq $aTy) {
        $notable.Add("Service '$($c.Key)' ($(Get-Field $aRow 'displayName')) stopped, but its start type is unchanged ($aTy). Nothing asked for this.")
    }
}
foreach ($k in $svc.Removed) {
    $notable.Add("Service '$k' ($(Get-Field $svc.BeforeMap[$k] 'displayName')) no longer exists.")
}
if ($drv.Removed.Count) {
    $notable.Add("$($drv.Removed.Count) third-party driver package(s) were removed. Check hardware still works.")
}
foreach ($c in $vol.Changed) {
    $bFree = [double](Get-Field $vol.BeforeMap[$c.Key] 'freeGb')
    $aFree = [double](Get-Field $vol.AfterMap[$c.Key]  'freeGb')
    $delta = [Math]::Round($aFree - $bFree, 2)
    if ([Math]::Abs($delta) -ge 0.5) {
        $sign = if ($delta -gt 0) { 'freed' } else { 'consumed' }
        $notable.Add("Drive $($c.Key) $sign $([Math]::Abs($delta)) GB (was $bFree GB free, now $aFree GB).")
    }
}
$bRp = [int](Get-Field (Get-Field $b 'protection') 'restoreCount')
$aRp = [int](Get-Field (Get-Field $a 'protection') 'restoreCount')
if ($aRp -le $bRp) {
    $notable.Add("Restore points did not increase ($bRp -> $aRp). The run either made none or Windows discarded one.")
}
if ((Get-Field $aFreq 'present') -and [string](Get-Field $aFreq 'value') -eq '0' -and
    -not ((Get-Field $bFreq 'present') -and [string](Get-Field $bFreq 'value') -eq '0')) {
    $notable.Add("SystemRestorePointCreationFrequency was left at 0. Windows will now take a restore point at every trigger and churn the shadow storage cap.")
}
foreach ($f in @('cbsRebootPending', 'wuRebootRequired')) {
    $wasP = Get-Field (Get-Field $b 'pendingReboot') $f
    $nowP = Get-Field (Get-Field $a 'pendingReboot') $f
    if (-not $wasP -and $nowP) { $notable.Add("A reboot is now pending ($f). Feature and capability work will refuse until it is done.") }
}
$bRen = [int](Get-Field (Get-Field $b 'pendingReboot') 'pendingRenameCount')
$aRen = [int](Get-Field (Get-Field $a 'pendingReboot') 'pendingRenameCount')
if ($aRen -gt $bRen) {
    $notable.Add("$($aRen - $bRen) file(s) are queued for deletion or rename at the next reboot. These are the ones the run could not delete outright.")
}
if ($assocChanged -gt 0) {
    $notable.Add("$assocChanged file or protocol association(s) changed. Check that web links and PDFs still open.")
}
$bExp = [int](Get-Field (Get-Field $b 'shellState') 'explorerRunning')
$aExp = [int](Get-Field (Get-Field $a 'shellState') 'explorerRunning')
if ($bExp -gt 0 -and $aExp -eq 0) {
    $notable.Add('Explorer is not running. The shell did not come back after the restart step.')
}
$bTamper = Get-Field (Get-Field (Get-Field $b 'defender') 'status') 'tamperProtection'
$aTamper = Get-Field (Get-Field (Get-Field $a 'defender') 'status') 'tamperProtection'
if ($bTamper -ne $aTamper) { $notable.Add("Defender tamper protection changed: $bTamper -> $aTamper.") }
$bRt = Get-Field (Get-Field (Get-Field $b 'defender') 'status') 'realTimeProtection'
$aRt = Get-Field (Get-Field (Get-Field $a 'defender') 'status') 'realTimeProtection'
if ($bRt -and -not $aRt) { $notable.Add('Defender real-time protection is now OFF. Nothing in this toolkit should have done that.') }
foreach ($k in $prog.Removed) {
    $pub = [string](Get-Field $prog.BeforeMap[$k] 'publisher')
    if ($pub -match 'NVIDIA|Intel|AMD|Realtek|Synaptics|Elan|Logitech') {
        $notable.Add("Driver-adjacent program removed: '$k' by $pub. Verify the hardware it supports.")
    }
}
if ($evRows.Count -ge 5) {
    $notable.Add("$($evRows.Count) event log provider/level pairs are logging more than before. See the event log section.")
}

# ==================================================================== emit ===

$head = New-Object System.Collections.Generic.List[string]
$head.Add('')
$head.Add(('=' * 78))
$head.Add("NOTABLE   ($($notable.Count))")
$head.Add(('=' * 78))
if (-not $notable.Count) {
    $head.Add('  Nothing matched a rule for "this usually means something went wrong".')
    $head.Add('  That is not the same as nothing having changed - read the sections below.')
}
foreach ($nline in $notable) { $head.Add("  * $nline") }
$head.Add('')
$head.Add('Totals')
$head.Add(("  Store packages      -{0,-4} +{1,-4} ~{2}" -f $appx.Removed.Count, $appx.Added.Count, $appx.Changed.Count))
$head.Add(("  Provisioned         -{0,-4} +{1,-4} ~{2}" -f $prov.Removed.Count, $prov.Added.Count, $prov.Changed.Count))
$head.Add(("  Programs            -{0,-4} +{1,-4} ~{2}" -f $prog.Removed.Count, $prog.Added.Count, $prog.Changed.Count))
$head.Add(("  Services            -{0,-4} +{1,-4} ~{2}" -f $svc.Removed.Count,  $svc.Added.Count,  $svc.Changed.Count))
$head.Add(("  Scheduled tasks     -{0,-4} +{1,-4} ~{2}" -f $task.Removed.Count, $task.Added.Count, $task.Changed.Count))
$head.Add(("  Features            -{0,-4} +{1,-4} ~{2}" -f $feat.Removed.Count, $feat.Added.Count, $feat.Changed.Count))
$head.Add(("  Capabilities        -{0,-4} +{1,-4} ~{2}" -f $capa.Removed.Count, $capa.Added.Count, $capa.Changed.Count))
$head.Add(("  Drivers             -{0,-4} +{1,-4} ~{2}" -f $drv.Removed.Count,  $drv.Added.Count,  $drv.Changed.Count))
$head.Add(("  Manifest reg values ~{0} of {1} tracked" -f $regMoved.Count, $bReg.Count))
$head.Add(("  Other reg values    ~{0}" -f $treeChanges))

$preamble = @($out[0..($preambleEnd - 1)])
$body     = @($out[$preambleEnd..($out.Count - 1)])
$text = ($preamble + $head + $body) -join "`r`n"
$text | Set-Content -LiteralPath $OutFile -Encoding UTF8

if (-not $Quiet) {
    Write-Host ''
    foreach ($h in ($preamble + $head)) { Write-Host $h }
    Write-Host ''
    Write-Host "  Full report: $OutFile" -ForegroundColor Green
    Write-Host ''
}

$OutFile
