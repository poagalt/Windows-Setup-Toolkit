<#
    Reads a run's trace.jsonl back into something a person can act on.

    trace.jsonl is one JSON object per line and is written for completeness
    rather than for reading - which is the right trade for a flight recorder
    and the wrong one at the moment somebody is trying to find out what went
    wrong. This is the reader.

    Ordered worst first: what threw, what failed, what was refused, what was
    skipped before it ever reached the plan, then where the time went. The
    environment block is printed at the top whatever else happened, because
    about half of all "why did nothing work" questions are answered by the
    three lines about elevation, safe mode, and a pending restart.

        .\Tools\Show-WDRunTrace.ps1                       # the newest run
        .\Tools\Show-WDRunTrace.ps1 -RunDir <path>
        .\Tools\Show-WDRunTrace.ps1 -All                  # every action, not just the interesting ones
#>
[CmdletBinding()]
param(
    [string]$RunDir,
    [switch]$All,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

if (-not $RunDir) {
    $root = Join-Path $env:ProgramData 'WinSetupToolkit'
    if (-not (Test-Path -LiteralPath $root)) { throw "No run data under '$root'. Pass -RunDir." }
    $newest = Get-ChildItem -LiteralPath $root -Directory -Filter 'run-*' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newest) { throw "No run-* folders under '$root'. Pass -RunDir." }
    $RunDir = $newest.FullName
}
$tracePath = Join-Path $RunDir 'trace.jsonl'
if (-not (Test-Path -LiteralPath $tracePath)) {
    throw "No trace.jsonl in '$RunDir'. That run predates the flight recorder, or it never started."
}

$rows = @()
$badLines = 0
foreach ($line in (Get-Content -LiteralPath $tracePath)) {
    if (-not $line.Trim()) { continue }
    try { $rows += ($line | ConvertFrom-Json) } catch { $badLines++ }
}

$out = New-Object System.Collections.Generic.List[string]
function Emit { param([string]$T = '') $out.Add($T) }
function Head {
    param([string]$T)
    Emit ''
    Emit ('-' * 78)
    Emit $T
    Emit ('-' * 78)
}

$byKind = @{}
foreach ($r in $rows) {
    $k = [string]$r.kind
    if (-not $byKind.ContainsKey($k)) { $byKind[$k] = New-Object System.Collections.Generic.List[object] }
    $byKind[$k].Add($r)
}
function Kind { param([string]$K) if ($byKind.ContainsKey($K)) { $byKind[$K] } else { @() } }

$start = @(Kind 'run-start')[0]
$end   = @(Kind 'run-end')[0]
$envr  = @(Kind 'environment')[0]

Emit 'Windows Setup Toolkit run trace'
Emit ('=' * 78)
Emit "Run folder : $RunDir"
Emit "Trace      : $($rows.Count) entries$(if ($badLines) { ", $badLines unreadable line(s)" } else { '' })"

# --------------------------------------------------------- did it finish? ---

if (-not $end) {
    Emit ''
    Emit '  THIS RUN DID NOT FINISH.'
    Emit '  There is no run-end entry, which is written even when a run is cancelled or'
    Emit '  throws. The machine was switched off, the process was killed, or PowerShell'
    Emit '  itself died. Everything already done is in journal.jsonl and is reversible.'
    if ($start) {
        $doneIds = @((Kind 'item') | ForEach-Object { [string]$_.item })
        $planned = @($start.items | ForEach-Object { [string]$_.id })
        $missed  = @($planned | Where-Object { $_ -notin $doneIds })
        Emit ''
        Emit "  Planned $($planned.Count), reached $($doneIds.Count), never started $($missed.Count)."
        if ($missed.Count) {
            Emit '  Never started:'
            foreach ($m in ($missed | Select-Object -First 40)) { Emit "    $m" }
            if ($missed.Count -gt 40) { Emit "    ... and $($missed.Count - 40) more" }
        }
    }
} else {
    Emit ("Result     : reached {0} of {1} in {2}s, canceled={3}, reboot needed={4}" -f `
          $end.reached, $end.of, $end.seconds, $end.canceled, $end.reboot)
    Emit "Counts     : $($end.counts)"
}
if ($start) {
    Emit ("Mode       : preview={0}, downloads={1}, ownership={2}, accounts={3}" -f `
          $start.preview, $start.allowDownloads, $start.allowOwnership, ($start.accounts -join ','))
}

# ------------------------------------------------------------ environment ---

if ($envr -and $envr.env) {
    $e = $envr.env
    Head 'Machine, as it was before anything was touched'
    Emit "  $($e.manufacturer) $($e.model)   $($e.osCaption) $($e.displayVersion) build $($e.build).$($e.ubr) $($e.edition)"
    Emit "  $($e.user)   elevated=$($e.elevated)   PowerShell $($e.psVersion)   policy $($e.executionPolicy)"
    Emit "  up $($e.uptimeHours)h   $($e.freeGb) GB free of $($e.totalGb) GB   battery=$($e.hasBattery) mains=$($e.onMains) $($e.batteryPct)%"
    Emit ''
    # The five that make a run do less than it says, called out by name
    # whichever way they read, so a clean line is as informative as a bad one.
    $flags = New-Object System.Collections.Generic.List[string]
    if (-not $e.elevated)   { $flags.Add('NOT ELEVATED - most removals report Blocked') }
    if ($e.safeBoot)        { $flags.Add("SAFE MODE (OptionValue=$($e.safeBoot))") }
    if ($e.rebootPending.cbs -or $e.rebootPending.wu) {
        $flags.Add("RESTART ALREADY PENDING (cbs=$($e.rebootPending.cbs) wu=$($e.rebootPending.wu)) - DISM refuses every feature and capability")
    }
    if ($null -ne $e.freeGb -and $e.freeGb -lt 5) { $flags.Add("ONLY $($e.freeGb) GB FREE") }
    if ($e.hasBattery -and -not $e.onMains)       { $flags.Add("ON BATTERY at $($e.batteryPct)%") }
    if ($e.restorePointsError)                    { $flags.Add("restore point list unreadable: $($e.restorePointsError)") }
    elseif ($e.restorePoints -eq 0)               { $flags.Add('NO RESTORE POINTS - the rollback script is the only way back') }
    # Count the entries that actually name a process, never the container. An
    # empty result reaches the file as {} rather than [] - ConvertTo-Json writes
    # a null hashtable value that way - and {} reads back truthy with a Count of
    # 1, so a bare Count test raised this on every run that ever ran, with a
    # blank pid after it. Which is the alarm nobody can check, about the one
    # thing this file exists to be trusted on.
    $others = @($e.otherInstances | Where-Object { $_ -and $_.pid })
    if ($others.Count) {
        $flags.Add("ANOTHER TOOLKIT PROCESS was running (pid $(($others | ForEach-Object { $_.pid }) -join ', '))")
    }
    if ($flags.Count) {
        Emit '  Conditions that limit what this run could do:'
        foreach ($f in $flags) { Emit "    * $f" }
    } else {
        Emit '  Nothing about the machine limited this run.'
    }
    if ($e.rebootPending.renames) {
        Emit "  $($e.rebootPending.renames) file operation(s) were already queued for the next restart BEFORE this run."
    }
}

# ------------------------------------------------------------- the damage ---

$acts = @(Kind 'action')
$threw = @($acts | Where-Object { $_.threw })
Head "Actions that THREW   ($($threw.Count))"
if (-not $threw.Count) { Emit '  none - no executor hit an unhandled error' }
foreach ($t in $threw) {
    Emit "  [$($t.item)] action $($t.index)/$($t.of)  type=$($t.type)  handler=$($t.handler)"
    Emit "      target : $($t.target)"
    Emit "      $($t.threw.type): $($t.threw.message)"
    if ($t.threw.hresult) { Emit "      hresult: $($t.threw.hresult)   category: $($t.threw.category)" }
    if ($t.threw.script)  { Emit "      at     : $($t.threw.script):$($t.threw.line)" }
    foreach ($i in @($t.threw.inner)) { Emit "      inner  : $($i.type): $($i.message)" }
    if ($t.threw.stack) {
        foreach ($s in (@($t.threw.stack -split "`r?`n") | Select-Object -First 6)) { Emit "      | $s" }
    }
}

foreach ($grp in @(
    @{ Status = 'Failed';  Title = 'Actions that FAILED' },
    @{ Status = 'Blocked'; Title = 'Actions that were BLOCKED (Windows refused)' },
    @{ Status = 'Partial'; Title = 'Actions that only PARTLY succeeded' },
    @{ Status = 'Skipped'; Title = 'Actions SKIPPED' }
)) {
    $set = @($acts | Where-Object { [string]$_.status -eq $grp.Status })
    Head "$($grp.Title)   ($($set.Count))"
    if (-not $set.Count) { Emit '  none' }
    foreach ($s in $set) {
        Emit "  [$($s.item)] $($s.type)  $($s.ms)ms"
        Emit "      target : $($s.target)"
        Emit "      says   : $($s.message)"
        if ($s.detail) { Emit "      detail : $($s.detail)" }
    }
}

# ------------------------------------------------- never reached the plan ---

$skips = @(Kind 'plan-skip')
Head "Ticked but never planned   ($($skips.Count))"
if (-not $skips.Count) {
    Emit '  none - every selected option reached the plan'
} else {
    Emit '  These were selected and then dropped before the run. They produce no'
    Emit '  result row, so this is the only place they are accounted for.'
    Emit ''
}
foreach ($s in $skips) {
    Emit "  $($s.item)  ($($s.name))"
    Emit "      $($s.reason)"
    if ($s.why)     { Emit "      $($s.why)" }
    if ($s.guards)  { Emit "      guards: $(@($s.guards) -join ', ')" }
}

# -------------------------------------------------------------- the items ---

$items = @(Kind 'item')
$bad = @($items | Where-Object { [string]$_.status -in @('Failed', 'Blocked', 'Partial') })
Head "Items that did not come out clean   ($($bad.Count) of $($items.Count))"
if (-not $bad.Count) { Emit '  none' }
foreach ($b in $bad) {
    Emit ("  {0,-11} [{1}] {2}" -f $b.status, $b.item, $b.name)
    Emit "      $($b.message)"
    if ($b.detail)  { Emit "      $($b.detail)" }
    Emit "      per-action: $(@($b.actions) -join ', ')"
}

# ---------------------------------------------------------------- timings ---

Head 'Where the time went'
$slow = @($acts | Sort-Object { [int]$_.ms } -Descending | Select-Object -First 15)
foreach ($s in $slow) {
    if ([int]$s.ms -lt 100) { continue }
    Emit ("  {0,7}ms  [{1}] {2}  {3}" -f $s.ms, $s.item, $s.type, $s.target)
}
$totalMs = (@($acts | ForEach-Object { [int]$_.ms }) | Measure-Object -Sum).Sum
Emit ''
Emit "  $($acts.Count) actions, $([Math]::Round($totalMs / 1000.0, 1))s inside executors."

# ------------------------------------------------------------ everything ----

if ($All) {
    Head "Every action, in order   ($($acts.Count))"
    foreach ($a in $acts) {
        Emit ("  {0,-11} {1,7}ms  [{2}] {3}/{4} {5}" -f $a.status, $a.ms, $a.item, $a.index, $a.of, $a.type)
        Emit "        $($a.target)"
        if ($a.message) { Emit "        $($a.message)" }
    }
}

$text = $out -join "`r`n"
if ($OutFile) {
    $text | Set-Content -LiteralPath $OutFile -Encoding UTF8
    Write-Host "Written to $OutFile" -ForegroundColor Green
} else {
    $text
}
