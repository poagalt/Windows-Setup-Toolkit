<#
.SYNOPSIS
    Windows Setup Toolkit - removes AI, OneDrive, OEM and consumer bloat
    from a freshly installed Windows 10/11 machine.

.DESCRIPTION
    Manifest-driven, so the curated removal list is data rather than code, and
    augmented at runtime by a scan that finds whatever this particular machine
    happens to carry. Everything about the host - edition, build, manufacturer,
    chassis, GPU - is detected when it starts, which is what makes one copy work
    across brands and Windows editions.

    Default behavior is a GUI. Console mode exists for imaging pipelines.

.PARAMETER Preset
    Conservative, Balanced, Aggressive or Extreme. Defaults to Balanced.

.PARAMETER Console
    Skip the GUI. Requires -Preview or -Apply.

.PARAMETER Preview
    Report what would change without changing anything.

.PARAMETER Apply
    Actually make the changes. Creates a restore point first.

.PARAMETER ProfilePath
    A selection JSON saved from the GUI. Overrides -Preset.

.PARAMETER Select
    Explicit item ids. Overrides -Preset and -ProfilePath.

.PARAMETER NoDownloads
    Refuse to fetch vendor cleanup utilities such as McAfee's MCPR scrubber.
    Downloads are permitted by default.

.PARAMETER NoScan
    Skip the runtime software scan and use only the curated manifest.

.PARAMETER TakeOwnership
    When Windows refuses a registry write because TrustedInstaller owns the key,
    seize it and retry. A real change to system ACLs. On by default at
    Aggressive and Extreme; -TakeOwnership:$false holds it back at any preset.
    No effect on non-removable Appx packages - those are refused by the
    deployment stack, not by an ACL.

.PARAMETER SelfTest
    Verify the toolkit works here. Changes nothing, needs no elevation.

.PARAMETER ListItems
    Print every item that applies to this machine, with its preset tier.

.PARAMETER ExportUnattend
    Write a self-contained autounattend.xml for the selected items, then exit.
    Registry values and app removals are inlined, so there is no payload to copy
    onto the medium. Creates a local account (which is what skips the Microsoft
    account requirement), skips the network requirement, bypasses the
    TPM/Secure Boot/RAM checks, and turns data collection off. Disks are never
    touched: Setup still asks where to install.

.PARAMETER UnattendAccount
    The local account the answer file creates. Defaults to "User".

.PARAMETER UnattendComputer
    Computer name for the answer file. Empty lets Windows generate one.

.PARAMETER UnattendLocale
    Language and locale for the answer file, e.g. en-GB. Defaults to en-US.

.PARAMETER SetupRun
    Started by SetupComplete.cmd, as Local System, before anybody signed in.
    Session 0 has no desktop, so the report goes to the PUBLIC desktop, a text
    version of everything the interface would have shown is written beside it,
    and Windows is asked to prompt whoever signs in first. Needs -Console -Apply.

.PARAMETER SetupResult
    Show the prompt for a finished setup run, given its run folder. Started by
    the RunOnce entry -SetupRun leaves behind, in the signing-in user's own
    context. Changes nothing and needs no elevation.

.PARAMETER ShowRun
    Open the interface on the run page, replaying a finished run from its folder
    rather than starting one.

.EXAMPLE
    .\WinSetupToolkit.ps1
    Opens the GUI on the mode-selection page.

.EXAMPLE
    .\WinSetupToolkit.ps1 -Console -Apply -Preset Aggressive
    Unattended run at the Aggressive preset.
#>
[CmdletBinding()]
param(
    [ValidateSet('Conservative','Balanced','Aggressive','Extreme')][string]$Preset = 'Balanced',
    [switch]$Console,
    [switch]$Preview,
    [switch]$Apply,
    [string]$ProfilePath,
    [string[]]$Select,
    [switch]$NoDownloads,
    [switch]$NoScan,
    [switch]$TakeOwnership,
    [switch]$SelfTest,
    [switch]$ListItems,
    [string]$ExportUnattend,
    [string]$UnattendAccount,
    [string]$UnattendComputer,
    [string]$UnattendLocale,
    [switch]$SetupRun,
    [string]$SetupResult,
    [string]$ShowRun,
    [string]$LogRoot
)

$ErrorActionPreference = 'Stop'
$root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $root 'Modules'
$manifest   = Join-Path $root 'Manifest'
$allowDl    = -not $NoDownloads      # downloads are on unless refused
# The GUI ticks this for Aggressive and Extreme, so the command line does the
# same - a preset has to mean one thing in both. Naming the switch either way
# still decides it, including -TakeOwnership:$false.
$takeOwn    = if ($PSBoundParameters.ContainsKey('TakeOwnership')) { [bool]$TakeOwnership }
              else { $Preset -in @('Aggressive', 'Extreme') }

function Hide-WDConsoleWindow {
    # -WindowStyle Hidden on the launcher covers the normal route in, but the
    # script is also started by hand.
    try {
        if (-not ('WD.ConsoleWindow' -as [type])) {
            Add-Type -Namespace 'WD' -Name 'ConsoleWindow' -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        }
        $h = [WD.ConsoleWindow]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) { $null = [WD.ConsoleWindow]::ShowWindow($h, 0) }   # SW_HIDE
    } catch { }
}

function Show-WDConsoleWindow {
    # For the one case that needs it: the GUI hides its console and then
    # something refuses to start, and a refusal printed into a hidden console is
    # a launch that appears to do nothing.
    try {
        if (-not ('WD.ConsoleWindow' -as [type])) { return }
        $h = [WD.ConsoleWindow]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) { $null = [WD.ConsoleWindow]::ShowWindow($h, 5) }   # SW_SHOW
    } catch { }
}

# Every other mode writes to the console and needs it. The GUI does not: the
# window has a splash to say the same things.
$isGui = -not ($ListItems -or $SelfTest -or $ExportUnattend -or $Console -or $SetupResult)

# Do not hide the console here. A UAC prompt over an empty screen gives no clue
# what asked for it, and raising it is the longest wait in the whole startup.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
               [Security.Principal.WindowsBuiltInRole]::Administrator)

# These four change nothing, so no UAC prompt. -SetupResult especially: it is
# started by a RunOnce entry at somebody's first sign-in, and a prompt nobody
# asked for cannot be answered on a standard account.
if (-not $isAdmin -and ($SelfTest -or $ListItems -or $ExportUnattend -or $SetupResult)) {
    if (-not $SetupResult) {
        Write-Host 'Running unelevated: provisioned-package and DISM detail will be incomplete.' -ForegroundColor Yellow
    }
} elseif (-not $isAdmin) {
    Write-Host 'Administrator rights are required. Relaunching elevated...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
                 '-File', "`"$($MyInvocation.MyCommand.Path)`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
        } elseif ($kv.Value -is [array]) {
            $argList += "-$($kv.Key)"; $argList += ($kv.Value -join ',')
        } else {
            $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`""
        }
    }
    try {
        Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -ErrorAction Stop
    } catch {
        # To the console, which is still on screen here: this path is only
        # reached when the script was started directly rather than through the
        # launcher.
        Write-Host 'Elevation was canceled or refused. Nothing has been changed.' -ForegroundColor Red
        exit 1
    }
    exit 0
}

# One ordering constraint, and only one: WD.Persist registers handlers into
# WD.Custom's table at import time, so Custom has to be in first.
foreach ($m in @('WD.Core', 'WD.Detect', 'WD.Actions', 'WD.Preflight', 'WD.Custom', 'WD.Persist', 'WD.Discover', 'WD.Revert', 'WD.Engine', 'WD.Unattend')) {
    Import-Module (Join-Path $modulePath "$m.psm1") -Force -DisableNameChecking
    # As soon as WD.Core is in and not a line later: this starts the one csc
    # invocation the launch cannot avoid, on a runspace of its own, and the
    # imports below are what it runs behind.
    if ($m -eq 'WD.Core') { Start-WDNative }
}

# Off [Environment] rather than the machine profile: reading the profile is six
# CIM queries and about a second, and on the GUI path that second was spent
# before anything could be drawn.
$hostBuild = [int][Environment]::OSVersion.Version.Build
if ($hostBuild -lt 19041) {
    Write-Host "This toolkit targets Windows 10 2004 (build 19041) and newer. Detected build $hostBuild." -ForegroundColor Red
    exit 1
}

# Every path but the GUI reads the profile here, where a console is what the
# operator is looking at. The GUI reads it below, behind its splash.
$profileInfo = $null
if (-not $isGui) { $profileInfo = Get-WDSystemProfile }
if ($PSVersionTable.PSVersion.Major -ge 6) {
    Write-Host 'Run this under Windows PowerShell 5.1, not PowerShell 7 - the Appx and DISM cmdlets misbehave under 7.' -ForegroundColor Red
    exit 1
}

# After the elevation check, and before the WD.UI import so a hand-run does not
# show a console for the third of a second that takes.
if ($isGui) { Hide-WDConsoleWindow }

# Two copies applying at once makes both journals wrong: each reads the other's
# changes as the previous value for its own, and both rollbacks then restore the
# wrong thing.
if (-not $SetupResult -and -not $SelfTest) {
    $instance = Enter-WDSingleInstance -Mode $(if ($isGui) { 'window' } else { 'console' })
    if (-not $instance.Ok) {
        $refusal = Get-WDSingleInstanceMessage -Holder $instance.Holder -Me 'The toolkit'
        if ($isGui) {
            # No theme has been published this early and there is no window to
            # own the dialog, so this is the one place the real MessageBox is
            # still right.
            $shown = $false
            try {
                Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
                $box = [Windows.MessageBox]
                $null = $box::Show($refusal, 'Windows Setup Toolkit', 'OK', 'Warning')
                $shown = $true
            } catch { }
            if (-not $shown) {
                # A refusal printed into a console this script hid a moment ago
                # is a launch that appears to do nothing at all.
                Show-WDConsoleWindow
                Write-Host ''
                Write-Host $refusal -ForegroundColor Yellow
                Write-Host ''
            }
        } else {
            Write-Host ''
            Write-Host $refusal -ForegroundColor Yellow
            Write-Host ''
        }
        exit 4
    }
}

# Started as early as possible, waited for at the bottom of this file. Its first
# 1.4 seconds are its own module imports, which nobody is waiting on.
$scanJob = $null
if ($isGui) {
    Import-Module (Join-Path $modulePath 'WD.UI.psm1') -Force -DisableNameChecking
    $scanJob = Start-WDStartupScan -ModulePath $modulePath -ManifestPath $manifest `
                                   -NoScan:$NoScan -Async
}

# Before the scan: this is a folder read and a window, with no use for an
# inventory nobody is going to look at.
if ($SetupResult) {
    Hide-WDConsoleWindow
    try {
        Import-Module (Join-Path $modulePath 'WD.UI.psm1') -Force -DisableNameChecking
        Set-WDTaskbarIdentity
        Show-WDSetupResult -RunDir $SetupResult -ScriptPath $MyInvocation.MyCommand.Path `
                           -Theme ([string](Get-WDUiState).theme)
    } catch { }
    exit 0
}

if (-not $isGui) {
    Write-Host ''
    Write-Host '  Windows Setup Toolkit' -ForegroundColor Cyan
    Write-Host "  $($profileInfo.Caption) $($profileInfo.DisplayVersion) (build $($profileInfo.Build).$($profileInfo.UBR)), $($profileInfo.Edition)" -ForegroundColor Gray
    Write-Host "  $($profileInfo.Manufacturer) $($profileInfo.Model) - $(if ($profileInfo.IsPortable) { 'laptop' } else { 'desktop' }), vendor profile '$($profileInfo.Vendor)'" -ForegroundColor Gray
    Write-Host ''
}

# The curated manifest cannot know what a given model ships with. This finds the
# rest, classified against the protection list in WD.Discover.
$categories = $null
$scan       = $null
$presence   = $null
if (-not $isGui) {
    $categories = Import-WDManifest -Path $manifest
    if (-not $NoScan) {
        Write-Host 'Scanning installed software...' -ForegroundColor Gray
        try {
            $scan = Get-WDDiscoveredSoftware -Categories $categories -Profile $profileInfo
            $disc = New-WDDiscoveredCategories -Scan $scan
            if (@($disc).Count) {
                $categories = Add-WDDiscoveredCategories -Categories $categories -Discovered $disc
            }
            $presence = Get-WDItemPresence -Categories $categories -Inventory $scan.Inventory -Profile $profileInfo
            Write-Host ("  found {0} {1} app(s), {2} other app(s), {3} service(s), {4} browser extension(s); {5} protected item(s) will never be offered" -f
                        @($scan.VendorApps).Count, $profileInfo.Vendor, @($scan.OtherApps).Count,
                        @($scan.OtherServices).Count, @($scan.Extensions).Count, @($scan.Protected).Count) -ForegroundColor Gray
        } catch {
            Write-Host "  scan failed, continuing with the curated list only: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Write-Host ''
}

if ($ListItems) {
    $tierName = @{ 0 = 'opt-in only'; 1 = 'conservative'; 2 = 'balanced'; 3 = 'aggressive'; 4 = 'extreme' }
    foreach ($cat in $categories) {
        $applicable = @($cat.items | Where-Object { Test-WDGuard -Guards @(Get-Prop $_ 'guards' @()) -Profile $profileInfo })
        if (-not $applicable.Count) { continue }
        Write-Host "`n$($cat.name)" -ForegroundColor Cyan
        foreach ($i in ($applicable | Sort-Object { [string](Get-Prop $_ 'name' $_.id) })) {
            $t = Get-WDItemTier -Item $i
            Write-Host ("  [{0,-12}] {1,-30} {2}" -f $tierName[$t], $i.id, (Get-Prop $i 'name' $i.id))
        }
    }
    Write-Host ''
    exit 0
}

function Resolve-Selection {
    if ($Select)      { return @($Select) }
    if ($ProfilePath) {
        $loaded = Import-WDSelection -Path $ProfilePath
        if (-not $loaded) { throw "Could not read a selection from $ProfilePath" }
        Write-Host "Loaded $($loaded.Count) selections from $ProfilePath" -ForegroundColor Gray
        return $loaded
    }
    @(Resolve-WDPresetSelection -Categories $categories -Preset $Preset -Profile $profileInfo `
                                -Inventory $(if ($scan) { $scan.Inventory } else { $null }))
}

if ($SelfTest) {
    Write-Host 'Self test - nothing on this machine will be changed.' -ForegroundColor Yellow
    $failures = 0

    Write-Host "`n[1] Manifest and scan" -ForegroundColor Cyan
    $itemCount = ($categories | ForEach-Object { @($_.items).Count } | Measure-Object -Sum).Sum
    Write-Host "  $($categories.Count) categories, $itemCount items"

    # A pattern matching everything marks every installed program as
    # already-covered, and the scan then finds nothing and says so quietly -
    # which reads like a clean machine rather than a broken scan.
    $pats  = @(Get-WDManifestPatterns -Categories $categories)
    $broad = @($pats | Where-Object { 'Zzz Totally Unrelated Program 1.0' -like $_ })
    if ($broad.Count) {
        Write-Host "  PATTERN too broad, would suppress the whole scan: $($broad -join ', ')" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "  OK      patterns   $($pats.Count) coverage patterns, none match everything"
    }
    if (-not $NoScan -and $scan) {
        # An empty scan on a real machine is the symptom that bug produced.
        $seen = @($scan.OtherApps).Count + @($scan.VendorApps).Count + @($scan.OtherServices).Count
        if ($seen -eq 0) {
            Write-Host '  SCAN found no programs, packages or services at all - that is almost certainly a bug, not a clean machine' -ForegroundColor Red
            $failures++
        }
    }

    Write-Host "`n[2] Applicable to this machine" -ForegroundColor Cyan
    $allIds = @(); foreach ($c in $categories) { foreach ($i in $c.items) { $allIds += [string]$i.id } }
    $probe = Resolve-WDPlan -Categories $categories -Selected $allIds -Profile $profileInfo
    # The plan is the selection plus the two steps nobody ticks, counted apart
    # so the line below still says how much of the manifest applies here.
    $autoSteps = @('close-resurrection', 'restart-explorer')
    $auto  = @($probe | Where-Object { [string]$_.Id -in $autoSteps })
    $probe = @($probe | Where-Object { [string]$_.Id -notin $autoSteps })
    Write-Host "  $(@($probe).Count) of $($allIds.Count) items apply here"
    # If this ever stops appending them the failure is silent - the run simply
    # stops finishing the job.
    foreach ($want in $autoSteps) {
        if (@($auto | Where-Object { [string]$_.Id -eq $want }).Count -ne 1) {
            Write-Host "  PLAN    '$want' was not appended to the plan" -ForegroundColor Red; $failures++
        }
    }
    # And they are last, after the items whose work they finish.
    $tail = @($probe | Where-Object { $_.Order -ge 9998 })
    if ($tail.Count) { Write-Host "  PLAN    a manifest item claims the closing orders" -ForegroundColor Red; $failures++ }
    if (@(Resolve-WDPlan -Categories $categories -Selected @('nothing-matches-this') -Profile $profileInfo).Count) {
        Write-Host "  PLAN    an empty selection still produced a plan" -ForegroundColor Red; $failures++
    }
    Write-Host "  plus $(@($auto).Count) closing step(s) the run appends itself" -ForegroundColor DarkGray
    $dropped = @($allIds | Where-Object { $_ -notin @($probe.Id) })
    if ($dropped.Count -and $dropped.Count -le 12) { Write-Host "  filtered out by guards: $($dropped -join ', ')" -ForegroundColor DarkGray }

    # An item whose every appx target is NonRemovable can only ever report
    # "Blocked, in-box". Named rather than counted: which ones those are is
    # edition- and build-specific.
    $inert = @()
    foreach ($c in $categories) {
        foreach ($i in @($c.items)) {
            if (-not (Test-WDItemApplies -Item $i -Profile $profileInfo)) { continue }
            if (Test-WDItemApplies -Item $i -Profile $profileInfo -Inventory $scan.Inventory) { continue }
            $inert += [string]$i.id
        }
    }
    if ($inert.Count) {
        Write-Host "  not offered, in-box and unremovable here: $($inert -join ', ')" -ForegroundColor DarkGray
    }

    # An unrated item claims it is not a removal, so an unrated one in Remove is
    # a missing rating or a miscategorized item. Recurring re-applies the
    # selection and Windows Update is scheduling policy, so both are exempt.
    $notRemovalCats = @('extras', 'update')
    $bloatCount = @{}
    $unratedRemovals = @()
    foreach ($c in $categories) {
        foreach ($i in @(Get-Prop $c 'items' @())) {
            $b = [int](Get-Prop $i 'bloat' 0)
            if ($b -lt 0 -or $b -gt 6) { Write-Host "  BLOAT $($i.id) is rated $b, outside 1-6" -ForegroundColor Red; $failures++ }
            $bloatCount[$b] = 1 + [int]$bloatCount[$b]
            if ($b -eq 0 -and [string]$c.id -notin $notRemovalCats -and
                (Get-WDItemSection -Item $i -Category $c) -eq 'remove') { $unratedRemovals += [string]$i.id }
        }
    }
    Write-Host ("  bloat ratings: " + (@(1..6 | ForEach-Object { "$_=$([int]$bloatCount[$_])" }) -join ' ') + " unrated=$([int]$bloatCount[0])")
    # A band with nothing in it is a band nobody can find, and 6 has to be
    # authored item by item.
    if (-not [int]$bloatCount[6]) {
        Write-Host "  BLOAT no item is rated 6, so the Not recommended band never appears" -ForegroundColor Red; $failures++
    }

    # The mechanics are generated from the actions, so the check is that every
    # item that acts produces a line.
    $noMech  = @()
    $symptom = 0
    $paths   = 0
    $badSym  = @()
    foreach ($c in $categories) {
        foreach ($i in @(Get-Prop $c 'items' @())) {
            $m = Get-WDItemMechanics -Item $i
            if (@(Get-Prop $i 'actions' @()).Count -and -not @($m.Lines).Count) { $noMech += [string]$i.id }
            if (@($m.Symptoms).Count) { $symptom++ }
            if ($m.Settings) { $paths++ }
            foreach ($s in @($m.Symptoms)) {
                # Lookup phrases, not sentences: nobody types "a Store app
                # cannot find my camera", they type "camera not working".
                $txt = [string]$s
                if ($txt.Length -lt 4) { $badSym += "$($i.id): '$txt' is too short to be a phrase"; continue }
                if ($txt.Length -gt 70) { $badSym += "$($i.id): '$($txt.Substring(0,40))...' is a sentence, not a lookup phrase" }
                if ($txt -eq [string](Get-Prop $i 'desc' '') -or $txt -eq [string](Get-Prop $i 'riskNote' '')) {
                    $badSym += "$($i.id): the description pasted in"
                }
            }
        }
    }
    if ($noMech.Count) {
        Write-Host "  MECH   $($noMech.Count) item(s) act but describe nothing: $(@($noMech | Select-Object -First 6) -join ', ')" -ForegroundColor Red
        $failures++
    }
    if ($badSym.Count) {
        Write-Host "  MECH   $($badSym.Count) symptom line(s) are not written as a complaint: $(@($badSym | Select-Object -First 4) -join '; ')" -ForegroundColor Red
        $failures++
    }
    # The synonym expansion, pinned against the phrasings it exists to catch.
    # That the other spellings are generated is invisible by inspection - the
    # file looks complete either way.
    $expBad = @()
    $expPairs = @(
        @{ Seed = @('app cannot see my name')
           Want = @("app can't see my name", 'app cant see my name', 'app does not see my name',
                    "app doesn't see my name", 'app does not have my name') }
        @{ Seed = @('account info blocked')
           Want = @('cannot access account info', 'account info access denied',
                    'cannot view account info', "can't access account info") }
        @{ Seed = @('cannot print')
           Want = @("can't print", 'cant print', 'unable to print') }
        @{ Seed = @('printer missing')
           Want = @('no printer', 'printer gone', 'where is printer', 'printer not there') }
        @{ Seed = @('search not working')
           Want = @('search broken', 'search stopped working', "search doesn't work", 'search doesnt work') }
    )
    foreach ($p in $expPairs) {
        $got = @(Expand-WDSymptoms -Phrases $p.Seed)
        foreach ($want in $p.Want) {
            if ($got -notcontains $want) { $expBad += "'$($p.Seed[0])' did not produce '$want'" }
        }
        # The authored phrase is never dropped and always comes first.
        if (@($got).Count -eq 0 -or [string]$got[0] -ne [string]$p.Seed[0]) {
            $expBad += "'$($p.Seed[0])' is not the first phrase of its own expansion"
        }
    }
    # Nothing generated may break the rules the authored phrases are held to.
    $expAll = @(Expand-WDSymptoms -Phrases @('cannot print', 'printer missing', 'account info blocked',
                                             'app cannot see my name', 'search not working'))
    foreach ($g in $expAll) {
        if ($g.Length -lt 4 -or $g.Length -gt 70) { $expBad += "generated '$g' is outside 4-70 characters" }
    }
    if (@($expAll | Group-Object | Where-Object { $_.Count -gt 1 }).Count) {
        $expBad += 'the expansion emitted a duplicate'
    }
    if ($expBad.Count) {
        Write-Host "  SYNONYM $($expBad.Count) problem(s): $(@($expBad | Select-Object -First 4) -join '; ')" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "  synonyms    : 5 seed phrases expand to $($expAll.Count), authored first, none malformed"
    }

    Write-Host "  explanations: $symptom item(s) say what they might break, $paths say where to change it back by hand"
    if ($unratedRemovals.Count) {
        Write-Host "  unrated removals: $($unratedRemovals -join ', ')" -ForegroundColor DarkGray
    }

    Write-Host "`n[3] Presets" -ForegroundColor Cyan
    # A debloat preset that quietly installs something is the worst thing this
    # could do. Judged on what an item does, not which section it is in - the
    # Add section also holds the quality-of-life tweaks.
    $addIds = @{}
    foreach ($c in $categories) {
        foreach ($i in @(Get-Prop $c 'items' @())) {
            $installs = $false
            foreach ($a in @(Get-Prop $i 'actions' @())) {
                if ([string](Get-Prop $a 'type' '') -eq 'winget' -and [string](Get-Prop $a 'mode' '') -eq 'install') { $installs = $true }
                if ([string](Get-Prop $a 'handler' '') -eq 'InstallChosenBrowser') { $installs = $true }
            }
            if ($installs) { $addIds[[string]$i.id] = [string](Get-Prop $i 'name' $i.id) }
        }
    }
    foreach ($p in (Get-WDPresetNames)) {
        $sel = @(Resolve-WDPresetSelection -Categories $categories -Preset $p -Profile $profileInfo `
                                           -Inventory $(if ($scan) { $scan.Inventory } else { $null }))
        $bad = @($sel | Where-Object { $addIds.ContainsKey($_) })
        Write-Host ("  {0,-13} {1,4} items" -f $p, $sel.Count)
        if ($bad.Count) {
            Write-Host ("  PRESET $p installs $($bad.Count) thing(s): " + (($bad | ForEach-Object { $addIds[$_] }) -join ', ')) -ForegroundColor Red
            $failures++
        }
    }
    Write-Host ("  {0,-13} {1,4} items, none selected by any preset" -f 'Installers', $addIds.Count)

    Write-Host "`n[4] Action executors" -ForegroundColor Cyan
    $types = @{}
    foreach ($i in $probe) { foreach ($a in $i.Actions) { $t = [string](Get-Prop $a 'type' '?'); $types[$t] = [int]$types[$t] + 1 } }
    foreach ($t in ($types.Keys | Sort-Object)) {
        $fn = Get-Command ("Invoke-WD" + $t.Substring(0,1).ToUpper() + $t.Substring(1) + "Action") -ErrorAction SilentlyContinue
        if ($fn) { Write-Host ("  OK      {0,-12} {1,4} action(s)" -f $t, $types[$t]) }
        else     { Write-Host ("  MISSING {0,-12} no executor registered" -f $t) -ForegroundColor Red; $failures++ }
    }
    $registered = @(Get-WDHandlerNames)
    $referenced = @()
    foreach ($c in $categories) {
        foreach ($i in $c.items) {
            foreach ($a in @(Get-Prop $i 'actions' @())) {
                if ((Get-Prop $a 'type' '') -eq 'script') { $referenced += [string](Get-Prop $a 'handler' '') }
            }
        }
    }
    $missing = @($referenced | Sort-Object -Unique | Where-Object { $_ -notin $registered })
    if ($missing.Count) { Write-Host "  MISSING handlers: $($missing -join ', ')" -ForegroundColor Red; $failures++ }
    else { Write-Host "  OK      handlers   $(@($referenced | Sort-Object -Unique).Count) referenced, all registered" }
    # Every handler needs a sentence saying what it touches. The detail dialog
    # falls back to the function name otherwise.
    $noNote = @($registered | Where-Object { -not (Get-WDHandlerNote -Name $_) })
    if ($noNote.Count) {
        Write-Host "  HANDLER $($noNote.Count) handler(s) have no plain description: $($noNote -join ', ')" -ForegroundColor Red
        $failures++
    }
    $orphan = @((Get-WDHandlerNoteNames) | Where-Object { $_ -notin $registered })
    if ($orphan.Count) {
        Write-Host "  HANDLER description(s) for handlers that no longer exist: $($orphan -join ', ')" -ForegroundColor DarkGray
    }

    # The update guard writes a script that only ever runs unattended, months
    # later. Drive it through all three states here rather than finding out
    # then.
    $gp = Join-Path $env:TEMP "wd-selftest-guard-$PID"
    try {
        $null = New-Item -ItemType Directory -Path $gp -Force
        # Real paths so the shape is the one that ships, pointed at a scratch
        # folder with a do-nothing entry script, so the runners take every
        # branch.
        $paths = Get-WDGuardPaths -Root $gp
        $paths.Entry = Join-Path $gp 'stub-entry.ps1'
        Set-Content -LiteralPath $paths.Entry -Value 'exit 0' -Encoding UTF8
        $ids = New-WDStringSet @('copilot', 'onedrive', 'persistence-guard', 'update-guard', 'clear-logs')
        $kept = Save-WDGuardProfile -Path $paths.Profile -Context ([pscustomobject]@{
                    PlannedIds = $ids; Session = [pscustomobject]@{ Root = $gp } })
        $roundTrip = @(Import-WDSelection -Path $paths.Profile)
        if ($kept -ne 2 -or @($roundTrip | Where-Object { $_ -match 'guard|clear-logs' }).Count) {
            Write-Host "  GUARD   profile kept $kept item(s): $($roundTrip -join ', ') - extras were not filtered" -ForegroundColor Red
            $failures++
        }

        # All three generated scripts, because none of them ever runs where
        # anyone would see it fail.
        $gen = @{
            $paths.Runner = (New-WDUpdateGuardRunner -Paths $paths)
            $paths.Logon  = (New-WDLogonGuardRunner  -Paths $paths)
            $paths.Notice = (New-WDGuardNoticeRunner -Paths $paths)
        }
        $rerr = $null
        foreach ($f in $gen.Keys) {
            Set-Content -LiteralPath $f -Value $gen[$f] -Encoding UTF8
            $e = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e)
            if ($e -and $e.Count) {
                Write-Host "  GUARD   $(Split-Path $f -Leaf) does not parse: $($e[0].Message)" -ForegroundColor Red
                $rerr = $e; $failures++
            }
        }
        # The notice must stay quiet when there is nothing to report, or it pops
        # a toast at every sign-in.
        $noticeOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $paths.Notice 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  GUARD   notice runner errored with no marker present: $noticeOut" -ForegroundColor Red
            $failures++
        }
        if ($rerr) { } else {
            $build = Get-WDBuildStamp
            $run = { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $paths.Runner | Out-Null }

            Set-Content -LiteralPath $paths.Stamp -Value $build -Encoding ASCII
            $t0 = (Get-Item $paths.Stamp).LastWriteTimeUtc
            Start-Sleep -Milliseconds 1100
            & $run
            $noop = ((Get-Item $paths.Stamp).LastWriteTimeUtc -eq $t0)

            Set-Content -LiteralPath $paths.Stamp -Value '1.0.stale' -Encoding ASCII
            & $run
            $restamped = ((Get-Content -LiteralPath $paths.Stamp -Raw).Trim() -eq $build)

            # And the boot after that must be quiet again, or it re-applies
            # forever instead of once.
            $t1 = (Get-Item $paths.Stamp).LastWriteTimeUtc
            Start-Sleep -Milliseconds 1100
            & $run
            $settled = ((Get-Item $paths.Stamp).LastWriteTimeUtc -eq $t1)

            # Firing writes a marker, which is the only thing that reaches the
            # signed-in user.
            $marked = (Test-Path -LiteralPath $paths.Marker)
            if ($noop -and $restamped -and $settled -and $marked) {
                Write-Host "  OK      guard      update runner idle at $build, fires once on change, leaves a notice"
            } else {
                Write-Host "  GUARD   runner misbehaved: no-op=$noop restamped=$restamped settled=$settled marker=$marked" -ForegroundColor Red
                $failures++
            }
        }
    } catch {
        Write-Host "  GUARD   update guard check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    } finally {
        if (Test-Path -LiteralPath $gp) { Remove-Item -LiteralPath $gp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # The leftover sweep and the extension removals are only defensible because
    # they go to the Recycle Bin, so prove the round trip rather than trusting
    # it.
    $probe = Join-Path ([IO.Path]::GetTempPath()) ('wd-recycle-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -Path (Join-Path $probe 'sub') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $probe 'sub\canary.txt') -Value 'payload' -Encoding UTF8

        $available = Test-WDRecycleAvailable -Path $probe
        $recycled  = $false; $restored = $false; $intact = $false
        if ($available) {
            $recycled = (Remove-WDToRecycleBin -Path $probe) -and -not (Test-Path -LiteralPath $probe)
            if ($recycled) {
                $bin = (New-Object -ComObject Shell.Application).NameSpace(0xA)
                $hit = $bin.Items() | Where-Object {
                    (Join-Path $_.ExtendedProperty('System.Recycle.DeletedFrom') $_.Name) -eq $probe
                } | Select-Object -First 1
                if ($hit) {
                    (New-Object -ComObject Shell.Application).NameSpace((Split-Path $probe -Parent)).MoveHere($hit)
                    Start-Sleep -Milliseconds 700
                }
                $restored = Test-Path -LiteralPath $probe
                $intact   = Test-Path -LiteralPath (Join-Path $probe 'sub\canary.txt')
            }
        }

        if (-not $available) {
            Write-Host "  SKIP    recycle    no Recycle Bin on $([IO.Path]::GetPathRoot($probe)) - the leftover sweep will refuse rather than hard delete"
        } elseif ($recycled -and $restored -and $intact) {
            Write-Host '  OK      recycle    deletes to the bin and the rollback restores it with contents intact'
        } else {
            Write-Host "  RECYCLE round trip broke: recycled=$recycled restored=$restored intact=$intact" -ForegroundColor Red
            $failures++
        }
    } catch {
        Write-Host "  RECYCLE check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    } finally {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Auto-hide is a read-modify-write on a binary blob, and its undo is a
    # PowerShell array literal the rollback script interpolates unquoted.
    try {
        $srKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
        $sr = Get-ItemProperty -LiteralPath $srKey -Name 'Settings' -ErrorAction SilentlyContinue
        if (-not $sr -or -not $sr.Settings) {
            Write-Host '  SKIP    taskbar    no StuckRects3 layout on this profile yet'
        } else {
            $was = [byte[]]$sr.Settings
            $null = Invoke-WDScriptAction -Action ([pscustomobject]@{ handler = 'SetTaskbarAutoHide' }) `
                                          -Context ([pscustomobject]@{ Preview = $true; ItemId = 'taskbar-autohide'; DefaultHive = $null })
            $now = [byte[]](Get-ItemProperty -LiteralPath $srKey -Name 'Settings').Settings
            $untouched = -not (Compare-Object $was $now)

            $literal = '@(' + (($was | ForEach-Object { $_ }) -join ',') + ')'
            $errs = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput(
                        "Set-ItemProperty -Path 'x' -Name 'Settings' -Value $literal -Type Binary -Force", [ref]$null, [ref]$errs)
            $roundTrips = (-not (Compare-Object $was ([byte[]](Invoke-Expression $literal)))) -and @($errs).Count -eq 0

            if ($untouched -and $roundTrips) {
                Write-Host '  OK      taskbar    auto-hide previews without writing, and its undo round-trips'
            } else {
                Write-Host "  TASKBAR auto-hide wrong: untouched=$untouched undoRoundTrips=$roundTrips" -ForegroundColor Red
                $failures++
            }
        }
    } catch {
        Write-Host "  TASKBAR auto-hide check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # The settings file has to survive a round trip, including preset -> edits,
    # which JSON hands back as a PSCustomObject. Also asserts there is no
    # overrides property.
    try {
        $uiFile = Join-Path $env:TEMP ("wd-ui-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".json")
        $uiBad  = @()

        $fresh = Get-WDUiState -Path $uiFile
        if ([string]$fresh.theme) { $uiBad += 'a first run came back with a theme already chosen' }
        if ((ConvertTo-WDPresetMap $fresh.presetDefaults).Count) { $uiBad += 'a first run came back with redefined modes' }
        if (-not $fresh.PSObject.Properties['applied']) { $uiBad += 'a first run has no applied map at all' }
        if (@($fresh.applied.PSObject.Properties).Count) { $uiBad += 'a first run came back having applied something' }

        # The shape the application now writes: no overrides at all.
        $null = Save-WDUiState -Path $uiFile -State ([pscustomobject]@{
            theme     = 'light'
            preset    = 'Aggressive'
            presetDefaults = [pscustomobject]@{
                Extreme  = [pscustomobject]@{ Added = @('d'); Removed = @() }
                Balanced = [pscustomobject]@{ Added = @('a', 'b'); Removed = @('c') }
            }
            # Which presets have been run here. Persisted, unlike an override.
            applied = [pscustomobject]@{
                Balanced = [pscustomobject]@{ When = '2026-08-15T22:30:39.0000000+00:00'
                                              Folder = 'C:\Users\x\Desktop\WinSetupToolkit apply 2026-08-15 22-30'
                                              Ids = @('a', 'b', 'c') }
            }
        })
        $back = Get-WDUiState -Path $uiFile
        if ($back.theme -ne 'light')       { $uiBad += "theme came back as '$($back.theme)'" }
        if ($back.preset -ne 'Aggressive') { $uiBad += "preset came back as '$($back.preset)'" }
        $df = ConvertTo-WDPresetMap $back.presetDefaults
        if (-not $df.ContainsKey('Extreme')) { $uiBad += 'the redefined preset was lost' }
        if (-not $df.ContainsKey('Balanced'))     { $uiBad += 'the second redefined preset was lost' }
        elseif (@($df['Balanced'].Added).Count -ne 2 -or @($df['Balanced'].Removed).Count -ne 1) {
            $uiBad += 'a redefined preset came back the wrong shape'
        }
        # A file with no overrides property reads as no edits rather than as a
        # failure.
        if ((ConvertTo-WDPresetMap $back.overrides).Count) {
            $uiBad += 'a file with no overrides came back with edits'
        }
        # The ids are the load-bearing half: the marker is shown only while the
        # preset still selects exactly them.
        $ap = $back.applied
        if (-not $ap.PSObject.Properties['Balanced']) {
            $uiBad += 'the applied run was lost'
        } else {
            if (@($ap.Balanced.Ids).Count -ne 3)   { $uiBad += "the applied ids came back as $(@($ap.Balanced.Ids).Count) of 3" }
            if (-not [string]$ap.Balanced.When)    { $uiBad += 'the applied timestamp was lost' }
            if ([string]$ap.Balanced.Folder -notmatch 'WinSetupToolkit apply') { $uiBad += 'the applied run folder was lost' }
            try { $null = [datetime][string]$ap.Balanced.When } catch { $uiBad += 'the applied timestamp does not parse back to a date' }
        }

        # An empty entry is not an entry: it would leave Reset preset offering
        # to undo nothing.
        $hollow = ConvertTo-WDPresetMap ([pscustomobject]@{ Balanced = [pscustomobject]@{ Added = @(); Removed = @() } })
        if ($hollow.Count) { $uiBad += 'an empty edit survived the round trip' }

        # Unreadable is a first run, not a crash.
        Set-Content -LiteralPath $uiFile -Value 'not json at all' -Encoding UTF8
        $junk = Get-WDUiState -Path $uiFile
        if ([string]$junk.theme) { $uiBad += 'a corrupt file was believed' }

        Remove-Item -LiteralPath $uiFile -Force -ErrorAction SilentlyContinue
        if ($uiBad.Count) {
            foreach ($b in $uiBad) { Write-Host "  UI STATE $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host '  OK      ui state   theme and redefined modes survive a restart; unsaved edits are not written; junk reads as a first run'
        }
    } catch {
        Write-Host "  UI STATE check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }
    # Two things act on InstallLocation, and installers really do write bare
    # shared roots like C:\Program Files there.
    try {
        $sweepBad = @()
        foreach ($shared in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
                              $env:SystemRoot, "$env:SystemDrive\", $env:USERPROFILE,
                              $env:LOCALAPPDATA, (Join-Path $env:ProgramFiles 'WindowsApps'), '', '   ')) {
            if ($null -ne (Test-WDSweepableRoot -Path $shared)) {
                $sweepBad += "'$shared' was accepted as one program's own folder"
            }
        }
        # And a real program folder is accepted, with quotes and a trailing
        # slash taken off - the caller acts on what comes back.
        $one = Test-WDSweepableRoot -Path ('"' + (Join-Path $env:ProgramFiles 'Vendor\Thing') + '\"')
        if (-not $one) { $sweepBad += "a program's own folder was refused" }
        elseif ($one -match '"' -or $one.EndsWith('\')) { $sweepBad += "the path came back unnormalized as '$one'" }

        if ($sweepBad.Count) {
            foreach ($b in $sweepBad) { Write-Host "  SWEEP ROOT $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host '  OK      sweep root shared roots are refused, a program folder is accepted and normalized'
        }
    } catch {
        Write-Host "  SWEEP ROOT check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }
    # The one that has to survive exactly is the account list: three-valued,
    # where null is every account and an empty list is none.
    try {
        $selDir = Join-Path $env:TEMP ("wd-sel-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $selDir -Force -ErrorAction SilentlyContinue
        $selBad = @()

        # 1. No options block at all - every file written by an older build. It
        # must read as "no opinion" rather than as invented values.
        $plain = Join-Path $selDir 'plain.json'
        $null = Save-WDSelection -Selected @('a', 'b') -Path $plain
        if (@(Import-WDSelection -Path $plain).Count -ne 2) { $selBad += 'a plain selection lost its ids' }
        if ($null -ne (Get-WDSelectionOptions -Path $plain)) {
            $selBad += 'a file with no options block came back with options'
        }

        # 2. Every account, written as null and read back as null.
        $allAcct = Join-Path $selDir 'all.json'
        $null = Save-WDSelection -Selected @('a') -Path $allAcct -Options @{
            TakeOwnership = $true; VendorDownloads = $false; Accounts = $null }
        $back = Get-WDSelectionOptions -Path $allAcct
        if (-not $back)                        { $selBad += 'the options block was not written' }
        elseif (-not $back.TakeOwnership)      { $selBad += 'take ownership came back off' }
        elseif ($back.VendorDownloads)         { $selBad += 'vendor downloads came back on' }
        elseif ($null -ne $back.Accounts)      { $selBad += '"every account" came back as a list' }

        # 3. No accounts, written as [] and read back as an empty list - not
        # null, which would write to every hive.
        $noAcct = Join-Path $selDir 'none.json'
        $null = Save-WDSelection -Selected @('a') -Path $noAcct -Options @{
            TakeOwnership = $false; VendorDownloads = $true; Accounts = @() }
        $back = Get-WDSelectionOptions -Path $noAcct
        if ($null -eq $back)              { $selBad += 'the empty-account options block was not written' }
        elseif ($null -eq $back.Accounts) { $selBad += '"no accounts" came back as "every account"' }
        elseif (@($back.Accounts).Count)  { $selBad += '"no accounts" came back holding names' }

        # 4. Named accounts survive as themselves.
        $someAcct = Join-Path $selDir 'some.json'
        $null = Save-WDSelection -Selected @('a') -Path $someAcct -Options @{
            TakeOwnership = $false; VendorDownloads = $true; Accounts = @('alice', '.DEFAULT') }
        $back = Get-WDSelectionOptions -Path $someAcct
        if (@($back.Accounts).Count -ne 2)         { $selBad += 'a named account list came back the wrong length' }
        elseif ($back.Accounts -notcontains 'alice') { $selBad += 'a named account was lost' }

        # 5. Junk is no opinion, not a crash.
        $junkSel = Join-Path $selDir 'junk.json'
        Set-Content -LiteralPath $junkSel -Value 'not json' -Encoding UTF8
        if ($null -ne (Get-WDSelectionOptions -Path $junkSel)) { $selBad += 'a corrupt selection was believed' }

        Remove-Item -LiteralPath $selDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($selBad.Count) {
            foreach ($b in $selBad) { Write-Host "  SELECTION $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host '  OK      selection  run options round-trip, and "every account" and "no accounts" stay apart'
        }
    } catch {
        Write-Host "  SELECTION options check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }
    # PowerToys keeps undocumented per-user JSON and this writes into it before
    # PowerToys may even be installed. Merging rather than replacing is the
    # whole safety property.
    try {
        $ptDir  = Join-Path $env:TEMP ("wd-pt-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $ptFile = Join-Path $ptDir 'settings.json'
        $ptCtx  = [pscustomobject]@{ ItemId = 'selftest-pt'; Preview = $false }
        $ptBad  = @()

        # 1. no file yet: it is created, and the undo is to delete it again.
        Set-WDPowerToysJson -Path $ptFile -Context $ptCtx -Seed ([pscustomobject]@{ enabled = [pscustomobject]@{} }) -Edit {
            param($j) $j.enabled | Add-Member -NotePropertyName 'PowerToys Run' -NotePropertyValue $true -Force
        }
        if (-not (Test-Path -LiteralPath $ptFile)) { $ptBad += 'the file was not created' }
        $ptJson = Get-Content -LiteralPath $ptFile -Raw | ConvertFrom-Json
        if (-not $ptJson.enabled.'PowerToys Run') { $ptBad += 'the module was not switched on' }
        if (Test-Path -LiteralPath "$ptFile.wdbak") { $ptBad += 'a backup was invented for a file that did not exist' }

        # 2. file exists: the second write must leave the first setting alone.
        Set-WDPowerToysJson -Path $ptFile -Context $ptCtx -Seed ([pscustomobject]@{ enabled = [pscustomobject]@{} }) -Edit {
            param($j) $j.enabled | Add-Member -NotePropertyName 'FancyZones' -NotePropertyValue $true -Force
        }
        $ptJson = Get-Content -LiteralPath $ptFile -Raw | ConvertFrom-Json
        if (-not $ptJson.enabled.'FancyZones')    { $ptBad += 'the second module was not written' }
        if (-not $ptJson.enabled.'PowerToys Run') { $ptBad += 'the second write clobbered the first' }
        if (-not (Test-Path -LiteralPath "$ptFile.wdbak")) { $ptBad += 'an existing file was replaced without a backup' }

        # 3. preview writes nothing at all.
        $ptPrev = Join-Path $ptDir 'preview-only.json'
        $null = Invoke-WDScriptAction -Action ([pscustomobject]@{
                    handler = 'SetPowerToysModule'; module = 'Peek'; enable = $true }) `
                -Context ([pscustomobject]@{ Preview = $true; ItemId = 'selftest-pt'; DefaultHive = $null })
        if (Test-Path -LiteralPath $ptPrev) { $ptBad += 'preview created a file' }

        Remove-Item -LiteralPath $ptDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($ptBad.Count) {
            foreach ($b in $ptBad) { Write-Host "  POWERTOYS config $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host '  OK      powertoys  module config merges into existing settings and previews without writing'
        }
    } catch {
        Write-Host "  POWERTOYS config check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # The rule that matters is $null: every caller that predates this choice
    # passes nothing, and nothing has to keep meaning every account.
    try {
        $acBad = @()
        $accts = @(Get-WDUserAccounts)
        if (-not $accts.Count) { $acBad += 'no accounts at all were reported' }
        if (@($accts | Where-Object { $_.Key -eq 'CurrentUser' }).Count -ne 1) { $acBad += 'the running account is not on the list' }
        $fut = @($accts | Where-Object { $_.Kind -eq 'future' })
        if ($fut.Count -ne 1) { $acBad += 'the default profile is not offered exactly once' }
        foreach ($a in $accts) {
            if (-not $a.Key -or -not $a.Name) { $acBad += 'an account came back without a key or a name' }
        }
        # Keys have to be the names Get-WDUserHives uses, or the interface and
        # the executor are talking about different things.
        $hiveNames = @(Get-WDUserHives | ForEach-Object { [string]$_.Name })
        foreach ($a in @($accts | Where-Object { $_.Kind -eq 'account' })) {
            if ([string]$a.Key -notin $hiveNames) { $acBad += "account key '$($a.Key)' matches no hive" }
        }

        $fakeHives = @([pscustomobject]@{ Name = 'CurrentUser'; Path = 'HKCU:' },
                       [pscustomobject]@{ Name = 'S-1-5-21-x'; Path = 'HKU:\S-1-5-21-x' })
        $fakeDef   = [pscustomobject]@{ Name = 'DefaultProfile'; Path = 'HKU:\WD_DEFAULT' }
        $named = { param($r) (@($r | ForEach-Object { [string]$_.Name }) -join ',') }

        $all = & $named (Select-WDAccountHives -Hives $fakeHives -Default $fakeDef -Accounts $null)
        if ($all -ne 'CurrentUser,S-1-5-21-x,DefaultProfile') { $acBad += "no selection gave '$all', expected everything" }
        $one = & $named (Select-WDAccountHives -Hives $fakeHives -Default $fakeDef -Accounts @('CurrentUser'))
        if ($one -ne 'CurrentUser') { $acBad += "one account gave '$one'" }
        $noFut = & $named (Select-WDAccountHives -Hives $fakeHives -Default $fakeDef -Accounts @('CurrentUser', 'S-1-5-21-x'))
        if ($noFut -ne 'CurrentUser,S-1-5-21-x') { $acBad += "dropping the default profile gave '$noFut'" }
        $futOnly = & $named (Select-WDAccountHives -Hives $fakeHives -Default $fakeDef -Accounts @('DefaultProfile'))
        if ($futOnly -ne 'DefaultProfile') { $acBad += "future-only gave '$futOnly'" }
        # An empty list is an answer - nowhere to write - and must not fall back
        # to everything the way $null does.
        $none = @(Select-WDAccountHives -Hives $fakeHives -Default $fakeDef -Accounts @())
        if ($none.Count) { $acBad += "an empty selection still wrote to $($none.Count) hive(s)" }
        # An account that has since gone is simply not there, not an error.
        $ghost = & $named (Select-WDAccountHives -Hives $fakeHives -Default $fakeDef -Accounts @('CurrentUser', 'S-1-5-21-gone'))
        if ($ghost -ne 'CurrentUser') { $acBad += "a stale account key gave '$ghost'" }

        # And the executor honours it. Previewed, so nothing is written either
        # way.
        $act = [pscustomobject]@{ type = 'registry'; scope = 'allusers'
                                  values = @([pscustomobject]@{ path = 'Software\WinSetupToolkitSelfTest'; name = 'x'; kind = 'DWord'; value = 1 }) }
        $ctxAll  = [pscustomobject]@{ Preview = $true; ItemId = 'selftest-acc'; DefaultHive = $null; Accounts = $null }
        $ctxNone = [pscustomobject]@{ Preview = $true; ItemId = 'selftest-acc'; DefaultHive = $null; Accounts = @() }
        $rAll  = Invoke-WDRegistryAction -Action $act -Context $ctxAll
        $rNone = Invoke-WDRegistryAction -Action $act -Context $ctxNone
        if ($rAll.Status -eq 'NotPresent') { $acBad += 'an unrestricted per-user write reached no hive' }
        if ($rNone.Status -ne 'NotPresent') { $acBad += "restricting to no accounts still reported '$($rNone.Status)'" }

        if ($acBad.Count) {
            foreach ($b in $acBad) { Write-Host "  ACCOUNTS $b" -ForegroundColor Red }
            $failures++
        } else {
            $shown = @($accts | Where-Object { $_.Kind -eq 'account' } | ForEach-Object { $_.Name })
            Write-Host "  OK      accounts   per-user writes follow the choice, and no choice still means all ($($shown.Count): $($shown -join ', '))"
        }
    } catch {
        Write-Host "  ACCOUNTS check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # Presence grays a row out before anybody reads it, so a test saying "not
    # here" too easily hides something that is. The three-valued rule is the
    # whole of it.
    try {
        $prBad = @()
        $inv = [pscustomobject]@{
            Appx     = @('Contoso.Thing', 'Fabrikam.Other')
            Services = @('ContosoSvc')
            Programs = @([pscustomobject]@{ DisplayName = 'Contoso Suite'; Bytes = 5GB },
                         [pscustomobject]@{ DisplayName = 'Contoso Suite Business'; Bytes = 9GB })
            Tasks    = @('\Microsoft\Windows\Contoso\Refresh')
        }
        $fake = @(, [pscustomobject]@{ id = 'c'; name = 'c'; items = @(
            [pscustomobject]@{ id = 'p-appx-here';  actions = @([pscustomobject]@{ type = 'appx'; names = @('Contoso.*') }) }
            [pscustomobject]@{ id = 'p-appx-gone';  actions = @([pscustomobject]@{ type = 'appx'; names = @('Nothing.Like.This') }) }
            [pscustomobject]@{ id = 'p-svc-here';   actions = @([pscustomobject]@{ type = 'service'; names = @('ContosoSvc') }) }
            [pscustomobject]@{ id = 'p-svc-gone';   actions = @([pscustomobject]@{ type = 'service'; names = @('NoSuchSvc') }) }
            [pscustomobject]@{ id = 'p-task-here';  actions = @([pscustomobject]@{ type = 'task'; tasks = @('\Microsoft\Windows\Contoso\*') }) }
            [pscustomobject]@{ id = 'p-task-gone';  actions = @([pscustomobject]@{ type = 'task'; tasks = @('\Nope\*') }) }
            [pscustomobject]@{ id = 'p-uninst';     actions = @([pscustomobject]@{ type = 'uninstall'; match = @('Contoso*'); exclude = @('*Business*') }) }
            [pscustomobject]@{ id = 'p-mixed';      actions = @([pscustomobject]@{ type = 'appx'; names = @('Nothing.Like.This') },
                                                                [pscustomobject]@{ type = 'registry'; values = @() }) }
            [pscustomobject]@{ id = 'p-opaque';     actions = @([pscustomobject]@{ type = 'script'; handler = 'X' }) }
            [pscustomobject]@{ id = 'p-both-gone';  actions = @([pscustomobject]@{ type = 'appx'; names = @('No.Such') },
                                                                [pscustomobject]@{ type = 'service'; names = @('NoSuchSvc') }) }
        ) })
        $pr = Get-WDItemPresence -Categories $fake -Inventory $inv
        $want = @{ 'p-appx-here' = $true; 'p-appx-gone' = $false; 'p-svc-here' = $true; 'p-svc-gone' = $false
                   'p-task-here' = $true; 'p-task-gone' = $false; 'p-uninst' = $true
                   'p-mixed' = $null; 'p-opaque' = $null; 'p-both-gone' = $false }
        foreach ($k in $want.Keys) {
            if (-not $pr.ContainsKey($k)) { $prBad += "$k was never answered"; continue }
            $got = $pr[$k].Present
            if ($got -ne $want[$k] -or ($null -eq $want[$k]) -ne ($null -eq $got)) {
                $prBad += "$k answered '$got', expected '$($want[$k])'"
            }
        }
        # An item that is half policy is not a no-op because the package it also
        # names is missing.
        if ($null -ne $pr['p-mixed'].Present) { $prBad += 'a part-registry item claimed an opinion' }
        # The exclusion is honoured, so the size is the one program that
        # matches.
        if ($pr['p-uninst'].Bytes -ne 5GB) { $prBad += "the excluded program was sized in: $($pr['p-uninst'].Bytes)" }
        # Store packages are counted, never sized: Windows does not publish it.
        if ($pr['p-appx-here'].Blind -ne 1) { $prBad += "a Store package was not counted as unsizeable" }
        if ($pr['p-appx-here'].Bytes -ne 0) { $prBad += 'a Store package was given a size' }

        # And against the real machine, where the rule is that this never claims
        # something is absent that the scan found and offered.
        $live = Get-WDItemPresence -Categories $categories -Inventory $scan.Inventory -Profile $profileInfo
        $ghost = @($categories | Where-Object { $_.id -like 'discovered-*' } | ForEach-Object { $_.items } |
                   Where-Object { $live.ContainsKey([string]$_.id) -and $live[[string]$_.id].Present -eq $false })
        if ($ghost.Count) {
            $prBad += "$($ghost.Count) item(s) the scan found on this machine were reported absent, e.g. $($ghost[0].id)"
        }

        if ($prBad.Count) {
            foreach ($b in $prBad) { Write-Host "  PRESENCE $b" -ForegroundColor Red }
            $failures++
        } else {
            $here = @($live.Keys | Where-Object { $live[$_].Present -eq $false }).Count
            $mute = @($live.Keys | Where-Object { $null -eq $live[$_].Present }).Count
            Write-Host "  OK      presence   yes/no/no-opinion, and the scan's own finds are never called absent ($here absent, $mute no opinion of $($live.Count))"
        }
    } catch {
        Write-Host "  PRESENCE check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # One choice, several browsers, and a file shape that has to survive being
    # read by a build that predates the list.
    try {
        $bwBad = @()
        $bwRoot = Join-Path ([IO.Path]::GetTempPath()) ("wd-brow-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            $null = New-Item -ItemType Directory -Path $bwRoot -Force
            $null = Set-WDBrowserChoice -Root $bwRoot -Names @('Brave', 'Mozilla Firefox', 'not a browser')
            $got = @(Get-WDChosenBrowsers (Get-WDBrowserChoice -Root $bwRoot))
            if ($got.Count -ne 2) { $bwBad += "$($got.Count) browser(s) came back, expected 2" }
            if (@($got | ForEach-Object { $_.Name }) -join ',' -ne 'Mozilla Firefox,Brave') {
                $bwBad += "came back as '$(@($got | ForEach-Object { $_.Name }) -join ', ')' rather than in catalog order"
            }
            if (@($got | Where-Object { $_.Name -eq 'not a browser' }).Count) { $bwBad += 'an unknown name was accepted' }
            # A file written before this was a list still installs what it
            # names.
            $old = @(Get-WDChosenBrowsers ([pscustomobject]@{ name = 'Opera'; id = 'Opera.Opera' }))
            if ($old.Count -ne 1 -or $old[0].Id -ne 'Opera.Opera') { $bwBad += 'a single-name file no longer reads' }
            if (@(Get-WDChosenBrowsers $null).Count) { $bwBad += 'nothing on disk produced a browser' }
            $null = Set-WDBrowserChoice -Root $bwRoot -Names @()
            if (Test-Path -LiteralPath (Get-WDBrowserChoicePath -Root $bwRoot)) { $bwBad += 'choosing none left the file behind' }
        } finally {
            Remove-Item -LiteralPath $bwRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($bwBad.Count) {
            foreach ($b in $bwBad) { Write-Host "  BROWSER $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host "  OK      browsers   several at once, in catalog order, and an older single-name file still reads"
        }
    } catch {
        Write-Host "  BROWSER check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # Windows refuses the Edge uninstall outside the EEA. Three pieces the fix
    # stands on: the policy file parses, the region resolves, and our verdict
    # matches the list.
    try {
        $egBad = @()
        $pol = Get-WDEdgeUninstallPolicy
        $here = Get-WDHomeGeoId
        if ($here -lt 0) { $egBad += 'this machine has no home region set' }
        $iso = Get-WDGeoIso2 -GeoId $here
        if (-not $iso) { $egBad += "geo id $here did not resolve to a region code" }
        # Ireland, the region the uninstall borrows.
        $ie = Get-WDGeoIso2 -GeoId 68
        if ($ie -ne 'IE') { $egBad += "geo id 68 resolved to '$ie', not IE" }
        if ($pol.Known) {
            if (-not @($pol.Regions).Count) { $egBad += 'the policy was found but lists no regions' }
            elseif ($pol.Regions -notcontains 'IE') { $egBad += 'IE is not in the policy list the workaround relies on' }
            $expect = ($pol.Regions -contains $iso)
            if ($pol.Allowed -ne $expect) { $egBad += "policy says allowed=$($pol.Allowed) for $iso, list says $expect" }
        }
        if ($egBad.Count) {
            foreach ($b in $egBad) { Write-Host "  EDGE    $b" -ForegroundColor Red }
            $failures++
        } else {
            $verdict = if (-not $pol.Known) { 'no regional gate on this build' }
                       elseif ($pol.Allowed) { "permitted in $iso" }
                       else { "refused in $iso, so the run borrows IE and puts it back" }
            Write-Host "  OK      edge       Windows' own answer on whether Edge may be uninstalled ($verdict)"
        }
    } catch {
        Write-Host "  EDGE check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # Nothing here writes to the machine - the whole output is a file - so the
    # test is about what the file says, and in one case about what it must never
    # say.
    try {
        $unBad = New-Object System.Collections.Generic.List[string]
        $opt   = New-WDUnattendOptions

        # Categories carry the items. Asking the manifest folder for .Items
        # answers $null, which made an earlier version of this pass vacuously.
        $unItems = @()
        foreach ($c in $categories) {
            foreach ($i in @($c.items)) {
                $t = Get-WDItemTier -Item $i
                if ($t -ge 1 -and $t -le 2) { $unItems += $i }
            }
        }
        if (-not $unItems.Count) { throw 'no items to build an answer file from' }
        $pay = Get-WDUnattendPayload -Items $unItems
        $xml = New-WDUnattendXml -Options $opt -Payload $pay
        $chk = Test-WDUnattendXml -Xml $xml -Options $opt
        foreach ($p in @($chk.Problems)) { $unBad.Add($p) }

        # The payload split has to be exhaustive: nothing may vanish between the
        # item list and the two piles.
        $seen = New-WDStringSet @()
        foreach ($p in @('Registry', 'Service', 'Task', 'Feature', 'Capability')) {
            foreach ($r in @($pay.$p)) { $null = $seen.Add($r.ItemId) }
        }
        foreach ($s in @($pay.Skipped))  { $null = $seen.Add($s.Id) }
        $lost = @($unItems | Where-Object {
            -not $seen.Contains([string]$_.id) -and
            -not @(@(Get-Prop $_ 'actions' @()) | Where-Object { [string](Get-Prop $_ 'type' '') -eq 'appx' }).Count
        })
        if ($lost.Count) { $unBad.Add("$($lost.Count) item(s) neither carried nor reported: $(($lost | Select-Object -First 3 | ForEach-Object { $_.id }) -join ', ')") }

        # The default hive must be unloaded exactly as often as it is loaded, or
        # the specialize pass strands the mount.
        $loads   = ([regex]::Matches($xml, 'reg load ')).Count
        $unloads = ([regex]::Matches($xml, 'reg unload ')).Count
        if ($loads -ne $unloads) { $unBad.Add("the default user hive is loaded $loads time(s) and unloaded $unloads") }

        # Disks, from both directions: the default must produce no wipe, and
        # asking for one must produce exactly one.
        if ($xml -match '<WillWipeDisk>') { $unBad.Add('the default options wipe a disk') }
        $wipeOpt = New-WDUnattendOptions
        $wipeOpt.DiskLayout = 'wipe-gpt'
        $wipeXml = New-WDUnattendXml -Options $wipeOpt
        if (([regex]::Matches($wipeXml, '<WillWipeDisk>true</WillWipeDisk>')).Count -ne 1) {
            $unBad.Add('asking for a disk layout did not produce exactly one wipe')
        }
        # ...and the guard that catches a mismatch between the two must fire.
        $liar = Test-WDUnattendXml -Xml $wipeXml -Options $opt
        if ($liar.Ok) { $unBad.Add('a file that wipes a disk passed a check that said to leave disks alone') }

        if ($unBad.Count) {
            foreach ($b in $unBad) { Write-Host "  UNATTEND $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host ("  OK      unattend   answer file carries $(@($pay.Registry).Count) settings, " +
                        "$(@($pay.Appx).Count) app removals, $(@($pay.Service).Count) service and " +
                        "$(@($pay.Task).Count + @($pay.Feature).Count) task/feature changes; " +
                        "names $(@($pay.Skipped).Count) it cannot carry, wipes nothing")
        }
    } catch {
        Write-Host "  UNATTEND check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # The clean-ups and the bar share one path table, and the bar makes a claim
    # about proportions nothing else here would catch being wrong.
    try {
        $dkBad = @()

        if ((Format-WDBytes 1610612736) -notmatch 'GB') { $dkBad += 'gigabytes are not reported in GB' }
        if ((Format-WDBytes 5242880)    -notmatch 'MB') { $dkBad += 'megabytes are not reported in MB' }

        # diskfull is still part of the guard vocabulary and nothing ships using
        # it, so this is the only cover that branch has - and it is the only
        # guard comparing a measured value against a threshold.
        $pFull  = $profileInfo.PSObject.Copy(); $pFull.DiskUsedPercent  = 85
        $pRoomy = $profileInfo.PSObject.Copy(); $pRoomy.DiskUsedPercent = 38
        $pEdge  = $profileInfo.PSObject.Copy(); $pEdge.DiskUsedPercent  = 70
        $pDead  = $profileInfo.PSObject.Copy(); $pDead.DiskUsedPercent  = 0
        if (-not (Test-WDGuard -Guards @('diskfull:70') -Profile $pFull))  { $dkBad += 'a full drive did not pass diskfull:70' }
        if (Test-WDGuard -Guards @('diskfull:70') -Profile $pRoomy)        { $dkBad += 'a roomy drive passed diskfull:70' }
        if (-not (Test-WDGuard -Guards @('diskfull:70') -Profile $pEdge))  { $dkBad += 'exactly 70% did not pass' }
        if (Test-WDGuard -Guards @('diskfull:70') -Profile $pDead)         { $dkBad += 'an unmeasurable drive passed' }

        # One table behind the row, the bar, and the deletion. A clean-up
        # missing from it shows no size; an entry with no item is a path nothing
        # acts on.
        $srcTable = Get-WDStorageSources
        $stItems  = @(@($categories | Where-Object { $_.id -eq 'storage' }) | ForEach-Object { $_.items } | ForEach-Object { [string]$_.id })
        if (-not $stItems.Count) { $dkBad += 'the storage category has no items' }
        foreach ($id in $stItems) {
            if (-not $srcTable.Contains($id)) { $dkBad += "$id has no entry in the storage source table" }
        }
        foreach ($id in $srcTable.Keys) {
            if ($id -notin $stItems) { $dkBad += "the source table names $id, which is not a manifest item" }
        }
        $sysRoot = ([string]$profileInfo.SystemDrive).TrimEnd('\')
        foreach ($id in $srcTable.Keys) {
            foreach ($p in @($srcTable[$id].Paths)) {
                if (-not ([string]$p.Path).StartsWith($sysRoot, 'OrdinalIgnoreCase')) {
                    $dkBad += "$id names $($p.Path), which is not on the system drive the bar draws"
                }
                if ([string]$p.Bucket -notin @('windows', 'apps', 'users', 'other')) {
                    $dkBad += "$id puts $($p.Path) in an unknown bucket '$($p.Bucket)'"
                }
            }
        }

        # The junction is the point: C:\Users\All Users is one to
        # C:\ProgramData, so a walk that follows it counts the same bytes twice.
        $walkRoot = Join-Path ([IO.Path]::GetTempPath()) ("wd-walk-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $walkRoot 'sub')  -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $walkRoot 'away') -Force
            [IO.File]::WriteAllBytes((Join-Path $walkRoot 'a.bin'),        (New-Object byte[] 1000))
            [IO.File]::WriteAllBytes((Join-Path $walkRoot 'sub\b.bin'),    (New-Object byte[] 2000))
            [IO.File]::WriteAllBytes((Join-Path $walkRoot 'away\big.bin'), (New-Object byte[] 5000))
            $d = Measure-WDFolderDetail -Path (Join-Path $walkRoot 'sub')
            if ($d.Bytes -ne 2000) { $dkBad += "a two-thousand byte folder measured $($d.Bytes)" }
            $null = & cmd.exe /c mklink /J "$walkRoot\link" "$walkRoot\away" 2>&1
            if (Test-Path -LiteralPath (Join-Path $walkRoot 'link')) {
                $d = Measure-WDFolderDetail -Path $walkRoot
                if ($d.Bytes -ne 8000) { $dkBad += "a junction was followed: 8000 bytes measured as $($d.Bytes)" }
            } else {
                Write-Host '  note    storage    no junction could be created, so the reparse-point skip is untested here'
            }
            $d = Measure-WDFolderDetail -Path (Join-Path $walkRoot 'nothing-here')
            if ($d.Present -or $d.Bytes -ne 0) { $dkBad += 'a missing folder did not measure as absent' }
        } finally {
            Remove-Item -LiteralPath $walkRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        # The arithmetic behind the bar. Pure, so it can be checked exactly.
        $mk = {
            param($raw, $items, $overlap)
            New-WDStorageSnapshot -Drive 'T:' -TotalBytes 1000GB -FreeBytes 600GB `
                                  -Items $items -Overlap $overlap -Raw $raw -Priced
        }
        $sums = {
            param($s)
            $t = 0L
            foreach ($seg in $s.Segments) { $t += [int64]$seg.Bytes }
            $t + $s.Reclaimable + $s.FreeBytes
        }
        # Buckets that leave room: Other takes the remainder and nothing scales.
        $loose = & $mk @{ windows = 40GB; apps = 60GB; users = 100GB } @{ 'x' = 10GB } @{ users = 5GB }
        if ($loose.Scaled) { $dkBad += 'buckets that fit were scaled anyway' }
        if ((& $sums $loose) -ne $loose.TotalBytes) { $dkBad += 'the loose snapshot does not add up to the drive' }
        if (@($loose.Segments | Where-Object { $_.Key -eq 'users' }).Bytes -ne 95GB) { $dkBad += 'the overlap was not taken out of its bucket' }
        # Buckets that overflow - the hardlink case, and the usual one.
        $tight = & $mk @{ windows = 200GB; apps = 200GB; users = 200GB } @{ 'x' = 10GB } @{}
        if (-not $tight.Scaled) { $dkBad += 'buckets that overflowed the drive were not scaled' }
        if ((& $sums $tight) -gt $tight.TotalBytes) { $dkBad += 'the scaled snapshot overflows the drive' }
        if ([Math]::Abs((& $sums $tight) - $tight.TotalBytes) -gt 8) { $dkBad += 'the scaled snapshot does not add up to the drive' }
        # Nothing walked yet: one block for everything in use, never four at
        # zero.
        $early = New-WDStorageSnapshot -Drive 'T:' -TotalBytes 1000GB -FreeBytes 600GB
        if ($early.Complete -or $early.Priced) { $dkBad += 'an unmeasured snapshot claimed to be finished' }
        if (@($early.Segments).Count -ne 1) { $dkBad += 'an unmeasured drive was drawn as a breakdown' }
        # A reclaimable total larger than the drive is in use would draw a bar
        # running backwards.
        $silly = New-WDStorageSnapshot -Drive 'T:' -TotalBytes 100GB -FreeBytes 90GB -Items @{ 'x' = 50GB } -Priced
        if ($silly.Reclaimable -gt $silly.UsedBytes) { $dkBad += 'more was reclaimable than was in use' }

        # The cache is an optimization, so every doubt has to answer "walk it
        # again".
        $fakeBuckets = [pscustomobject]@{ Raw = @{ windows = 1GB; apps = 2GB; users = 3GB }
                                          Reserve = ([ordered]@{ 'pagefile.sys' = 4GB }); Denied = 7; Stopped = $false }
        $entry = New-WDStorageCacheEntry -Buckets $fakeBuckets -UsedBytes 100GB
        if (-not $entry) { $dkBad += 'a finished walk produced no cache entry' }
        $wrap  = [pscustomobject]@{ storage = $entry }
        $back  = Get-WDStorageCache -State $wrap -UsedBytes 100GB
        if (-not $back -or $back.Raw['users'] -ne 3GB -or $back.Denied -ne 7) { $dkBad += 'the cache did not round-trip' }
        if (Get-WDStorageCache -State $wrap -UsedBytes 100GB -MaxAgeDays 0) { $dkBad += 'an expired cache was believed' }
        if (Get-WDStorageCache -State $wrap -UsedBytes 130GB) { $dkBad += 'a cache from a drive 30% different was believed' }
        if (Get-WDStorageCache -State ([pscustomobject]@{ storage = $null }) -UsedBytes 100GB) { $dkBad += 'an empty cache was believed' }
        if (New-WDStorageCacheEntry -Buckets ([pscustomobject]@{ Raw = @{ windows = 1GB }; Stopped = $true }) -UsedBytes 1GB) {
            $dkBad += 'an abandoned walk was cached'
        }

        # Each handler, previewed. A preview must report and change nothing.
        $before = (Get-WDSystemProfile -Refresh).DiskFreeBytes
        foreach ($h in @('ClearTempFiles', 'ClearUpdateCache', 'ClearDeliveryOptimization',
                         'EmptyRecycleBin', 'RemoveWindowsOld')) {
            $r = Invoke-WDScriptAction -Action ([pscustomobject]@{ handler = $h }) `
                                       -Context ([pscustomobject]@{ Preview = $true; ItemId = "selftest-$h"; DefaultHive = $null })
            if ($r.Status -notin @('Removed', 'NotPresent')) { $dkBad += "$h previewed as $($r.Status): $($r.Message)" }
            if ($r.Status -eq 'Removed' -and $r.Message -notmatch '\d') { $dkBad += "$h promised a clean-up without a size" }
        }
        # The two closing steps the run appends for itself. Both are removals
        # now rather than reports, so both have to honour preview.
        foreach ($h in @('CloseResurrectionPaths', 'RemoveUninstallResidue', 'RestartExplorer')) {
            $r = Invoke-WDScriptAction -Action ([pscustomobject]@{ handler = $h }) `
                                       -Context ([pscustomobject]@{ Preview = $true; ItemId = "selftest-$h"
                                                                    DefaultHive = $null; Session = $null })
            if (-not $r) { $dkBad += "$h previewed as nothing at all" }
            elseif ($r.Status -in @('Failed')) { $dkBad += "$h previewed as $($r.Status): $($r.Message)" }
        }
        if (Get-Process -Name explorer -ErrorAction SilentlyContinue) {
            # And the preview of the restart did not actually restart it.
            Start-Sleep -Milliseconds 50
            if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
                $dkBad += 'previewing the Explorer restart restarted Explorer'
            }
        }
        $after = (Get-WDSystemProfile -Refresh).DiskFreeBytes
        # A wide tolerance, not equality: a live machine writes to its own disk
        # while this runs.
        if ([Math]::Abs($after - $before) -gt 1GB) { $dkBad += 'previewing the clean-ups changed the free space' }

        # The bin the row is sized from and the bin the handler empties are two
        # different questions.
        $rbHere = Measure-WDRecycleBin
        $rbAll  = Measure-WDRecycleBin -All
        if (-not $rbHere -or -not $rbAll) { $dkBad += 'the Recycle Bin could not be measured' }
        elseif ($rbAll.Bytes -lt $rbHere.Bytes) { $dkBad += 'every drive held less than the system drive alone' }

        if ($dkBad.Count) {
            foreach ($b in $dkBad) { Write-Host "  STORAGE $b" -ForegroundColor Red }
            $failures++
        } else {
            $liveSnap = Get-WDStorageReport -Quick
            Write-Host ("  OK      storage    one path table behind row, bar and deletion; the bar adds up ({0} is {1}% full, {2} reclaimable)" -f
                        $liveSnap.Drive, $liveSnap.UsedPercent, (Format-WDBytes $liveSnap.Reclaimable))
        }
    } catch {
        Write-Host "  STORAGE check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # "Already set" grays an option out, so a test that says yes too easily
    # hides something that was never done. The negative cases are the ones that
    # matter.
    try {
        $ptRoot = Get-WDPowerToysRoot
        $stBad  = @()
        $mk = { param($m, $en, $hk) $o = @{ handler = 'SetPowerToysModule'; module = $m; enable = $en }
                if ($hk) { $o.hotkey = $hk }; [pscustomobject]$o }

        if (Test-WDActionSatisfied -Action ([pscustomobject]@{ handler = 'SetPowerToysModule' })) { $stBad += 'an action with no module said yes' }
        if (Test-WDActionSatisfied -Action (& $mk 'Zzz Not A Module' $true $null)) { $stBad += 'an invented module said yes' }
        if (Test-WDActionSatisfied -Action ([pscustomobject]@{ handler = 'NoSuchHandler' })) { $stBad += 'a handler with no test said yes' }
        if (Test-WDActionSatisfied -Action ([pscustomobject]@{ type = 'registry' }))         { $stBad += 'a non-script action said yes' }

        $ptSet = Join-Path $ptRoot 'settings.json'
        if (Test-Path -LiteralPath $ptSet) {
            $sj = $null
            try { $sj = Get-Content -LiteralPath $ptSet -Raw | ConvertFrom-Json } catch { }
            $mod = $null
            if ($sj -and $sj.PSObject.Properties['enabled']) {
                $mod = @($sj.enabled.PSObject.Properties | Select-Object -First 1)[0]
            }
            if ($mod) {
                # Read back exactly what is there, then ask for it: yes.
                if (-not (Test-WDActionSatisfied -Action (& $mk $mod.Name ([bool]$mod.Value) $null))) {
                    $stBad += "'$($mod.Name)' is $([bool]$mod.Value) on disk and the test disagreed"
                }
                # And ask for the opposite: no.
                if (Test-WDActionSatisfied -Action (& $mk $mod.Name (-not [bool]$mod.Value) $null)) {
                    $stBad += "'$($mod.Name)' matched the state it is not in"
                }
                # A hotkey nobody would have set has to fail even when the
                # module is right - the chord is half the promise of the option.
                $wrongKey = [pscustomobject]@{ file = 'PowerToys Run'; property = 'open_powerlauncher'; ctrl = $true; code = 113 }
                if (Test-WDActionSatisfied -Action (& $mk 'PowerToys Run' $true $wrongKey)) {
                    $stBad += 'a shortcut that is not set matched anyway'
                }
            }
        }
        if ($stBad.Count) {
            foreach ($b in $stBad) { Write-Host "  STATE TEST $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host '  OK      already    "already set" recognizes the real config and refuses anything else'
        }
    } catch {
        Write-Host "  STATE TEST check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # Asserted on shape, never on verdicts: which options are already done is a
    # fact about the machine.
    try {
        $satBad = @()
        $satInv = [pscustomobject]@{
            Appx     = @('Contoso.Thing', 'Fabrikam.Other')
            Services = @('Spooler')
            Programs = @([pscustomobject]@{ DisplayName = 'Contoso Suite'; Bytes = 0 })
            Tasks    = @('\Vendor\Nag', '\Vendor\Quiet')
            TasksOff = @('\Vendor\Quiet')
        }
        $act = { param($h) [pscustomobject]$h }

        # Absence, in both directions, for every type the arm covers.
        if (Test-WDActionSatisfied -Action (& $act @{ type = 'appx'; names = @('Contoso.*') }) -Inventory $satInv) {
            $satBad += 'an appx action matching an installed package said there was nothing to do'
        }
        if (-not (Test-WDActionSatisfied -Action (& $act @{ type = 'appx'; names = @('Nothing.Here') }) -Inventory $satInv)) {
            $satBad += 'an appx action matching nothing did not report itself as done'
        }
        # Without an inventory it must answer no rather than guess.
        if (Test-WDActionSatisfied -Action (& $act @{ type = 'appx'; names = @('Nothing.Here') })) {
            $satBad += 'an appx action answered without an inventory to answer from'
        }
        if (Test-WDActionSatisfied -Action (& $act @{ type = 'uninstall'; match = @('Contoso*') }) -Inventory $satInv) {
            $satBad += 'an uninstall action matching an installed program said there was nothing to do'
        }
        if (-not (Test-WDActionSatisfied -Action (& $act @{ type = 'uninstall'; match = @('Contoso*'); exclude = @('Contoso Suite') }) -Inventory $satInv)) {
            $satBad += 'an excluded program still counted as something to uninstall'
        }
        # A task a run disables stays registered, so presence is the wrong test
        # and Enabled is the right one.
        if (Test-WDActionSatisfied -Action (& $act @{ type = 'task'; tasks = @('\Vendor\Nag') }) -Inventory $satInv) {
            $satBad += 'an enabled task said there was nothing to disable'
        }
        if (-not (Test-WDActionSatisfied -Action (& $act @{ type = 'task'; tasks = @('\Vendor\Quiet') }) -Inventory $satInv)) {
            $satBad += 'a task that is already disabled still counted as work'
        }
        if (Test-WDActionSatisfied -Action (& $act @{ type = 'task'; tasks = @('\Vendor\Quiet'); delete = $true }) -Inventory $satInv) {
            $satBad += 'a task that has to be DELETED counted as done because it was merely disabled'
        }
        if (-not (Test-WDActionSatisfied -Action (& $act @{ type = 'file'; paths = @('C:\Nope\NotHere\x.dat') }))) {
            $satBad += 'a file action naming nothing that exists did not report itself as done'
        }
        if (Test-WDActionSatisfied -Action (& $act @{ type = 'file'; paths = @($env:SystemRoot) })) {
            $satBad += 'a file action naming a folder that exists said there was nothing to delete'
        }

        # A guarded-out action must not be asked at all. Built to be impossible
        # to satisfy, so the item can only come back done by being skipped.
        $bogus = @{ type = 'registry'; scope = 'machine'; values = @(
                        [pscustomobject]@{ path = 'HKLM:\SOFTWARE\WinSetupToolkitNoSuchKey'; name = 'V'; kind = 'DWord'; value = 1 }) }
        $itemGuarded = [pscustomobject]@{ id = 'g'; actions = @(
            [pscustomobject]($bogus + @{ guards = @('oem:nosuchvendor') })
            [pscustomobject]@{ type = 'file'; paths = @('C:\Nope\NotHere\x.dat') }) }
        if (-not (Test-WDItemSatisfied -Item $itemGuarded -Inventory $satInv -Profile $profileInfo)) {
            $satBad += 'an action whose guards fail on this machine was still counted against the item'
        }
        # And with no profile there is nothing to evaluate a guard against, so
        # it has to be asked - the answer that never over-claims.
        if (Test-WDItemSatisfied -Item $itemGuarded -Inventory $satInv) {
            $satBad += 'a guard was skipped with no profile to evaluate it against'
        }
        # An item with no actions is not "already applied": there is nothing to
        # have been done, and that word is a claim.
        if (Test-WDItemSatisfied -Item ([pscustomobject]@{ id = 'e'; actions = @() }) -Inventory $satInv -Profile $profileInfo) {
            $satBad += 'an item with no actions claimed to be already applied'
        }

        # Every handler named in the state-test table has to exist, or the entry
        # is dead.
        $handlerNames = @(Get-WDHandlerNames)
        foreach ($h in @(Get-WDStateTestNames)) {
            if ($handlerNames -notcontains $h) { $satBad += "the state test for '$h' names a handler that is not registered" }
        }
        # And the manifest's own handlers, so the split between "has a state
        # test" and "cannot have one" stays a decision somebody made.
        $noTest = @()
        foreach ($c in $categories) {
            foreach ($i in $c.items) {
                foreach ($a in @(Get-Prop $i 'actions' @())) {
                    $h = [string](Get-Prop $a 'handler' '')
                    if ($h -and (Get-WDStateTestNames) -notcontains $h -and $noTest -notcontains $h) { $noTest += $h }
                }
            }
        }

        if ($satBad.Count) {
            foreach ($b in $satBad) { Write-Host "  SATISFIED $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host "  OK      applied    every action type can be asked; $(@($noTest).Count) handler(s) answer nothing by design"
        }
    } catch {
        Write-Host "  SATISFIED check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # The Revert page asks this three times before it can open, and
    # Get-ScheduledTask answers in about a second each. The COM path has to keep
    # agreeing with it.
    try {
        $slowRoot = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -eq '\' })
        $slowSub  = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -ne '\' })
        $taskBad  = @()
        if (Test-WDTaskPresent 'zzz WinSetupToolkit definitely not a task') { $taskBad += 'claimed an invented task exists' }
        if ($slowRoot.Count) {
            $n = [string]$slowRoot[0].TaskName
            if (-not (Test-WDTaskPresent $n)) { $taskBad += "missed the root task '$n'" }
        }
        # Only the root folder counts - all three toolkit tasks register there,
        # and matching a subfolder task by bare name would be a false positive.
        if ($slowSub.Count) {
            $n = [string]$slowSub[0].TaskName
            if (Test-WDTaskPresent $n) { $taskBad += "matched '$n' from a subfolder" }
        }
        if ($taskBad.Count) {
            foreach ($b in $taskBad) { Write-Host "  TASK lookup $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host "  OK      tasks      fast lookup agrees with Get-ScheduledTask, root folder only"
        }
    } catch {
        Write-Host "  TASK lookup check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # HKU: is not a default PowerShell drive and the rollback script cannot
    # import the helper that makes one.
    try {
        $miBad = @()
        $mi = Get-WDMachineIdentity
        if (-not $mi.machineGuid) { $miBad += 'this machine has no readable MachineGuid, so no run can ever be attributed to it' }
        # Three-valued, and the third value matters: everything written before
        # identities existed answers "cannot say".
        if ((Test-WDSameMachine $mi) -ne $true)  { $miBad += 'this machine does not match its own identity' }
        if ((Test-WDSameMachine ([pscustomobject]@{ machineGuid = '11111111-2222-3333-4444-555555555555' })) -ne $false) {
            $miBad += 'a different machine was not recognised as different'
        }
        foreach ($blind in @($null, ([pscustomobject]@{ computer = 'X' }))) {
            if ($null -ne (Test-WDSameMachine $blind)) { $miBad += 'a record carrying no id answered something other than "cannot say"' }
        }

        $miRoot = Join-Path ([IO.Path]::GetTempPath()) ("wd-mi-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $miRoot -Force
        $miSaved = Get-WDSession
        try {
            $null = Initialize-WDSession -Root $miRoot -QuickEnvironment
            $miSess = Get-WDSession
            'x' | Set-Content -LiteralPath $miSess.JournalFile -Encoding UTF8
            ([pscustomobject]@{ preview = $false; started = (Get-Date).ToString('o')
                                counts = [pscustomobject]@{ removed = 3; changed = 7 } } | ConvertTo-Json -Depth 5) |
                Set-Content -LiteralPath $miSess.ReportFile -Encoding UTF8
            $null = Register-WDRunRecord -Report ([pscustomobject]@{ counts = [pscustomobject]@{ removed = 3; changed = 7 } })

            # The index lives at the root, which is the whole feature: the run
            # folders are what "Delete old run logs" removes.
            if (-not (Test-Path -LiteralPath (Get-WDRunIndexPath -Root $miRoot))) { $miBad += 'no standing index was written' }
            $one = @(Get-WDPastRuns -Root $miRoot)
            if ($one.Count -ne 1) { $miBad += "a run with both a folder and an index entry produced $($one.Count) rows rather than 1" }
            elseif ($one[0].Source -ne 'folder' -or -not $one[0].LogPresent) {
                $miBad += 'the folder was not preferred over the index while it was still there'
            }

            Get-ChildItem $miRoot -Directory -Filter 'run-*' | ForEach-Object { [IO.Directory]::Delete($_.FullName, $true) }
            $gone = @(Get-WDPastRuns -Root $miRoot)
            if ($gone.Count -ne 1)          { $miBad += 'deleting the run folder lost the record of the run entirely' }
            elseif ($gone[0].LogPresent)    { $miBad += 'a run whose folder is gone still claims to have its log' }
            elseif ($gone[0].Removed -ne 3) { $miBad += 'the standing index did not keep what the run did' }

            # A folder carried here from another computer must not be offered.
            $miIdx = Get-WDRunIndexPath -Root $miRoot
            ((Get-Content -LiteralPath $miIdx -Raw) -replace [regex]::Escape($mi.machineGuid), '99999999-8888-7777-6666-555555555555' `
                                                    -replace '20\d{6}-\d{6}', '19990101-000000').Trim() |
                Add-Content -LiteralPath $miIdx -Encoding UTF8
            if (@(Get-WDPastRuns -Root $miRoot).Count -ne 1)              { $miBad += 'a run from another machine was offered for reverting' }
            if (@(Get-WDPastRuns -Root $miRoot -AllMachines).Count -ne 2) { $miBad += '-AllMachines did not show the run from the other machine' }
        } finally {
            Remove-Item -LiteralPath $miRoot -Recurse -Force -ErrorAction SilentlyContinue
            if ($miSaved) { $null = Initialize-WDSession -Root $miSaved.Root -Preview -QuickEnvironment }
        }

        if ($miBad.Count) {
            foreach ($b in $miBad) { Write-Host "  MACHINE $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host '  OK      this machine is identified, and its own runs are told apart from other machines'
        }
    } catch {
        Write-Host "  MACHINE identity check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # The dedup rule has to cross runs for the same reason it exists inside one
    # journal.
    try {
        $cpBad = @()
        $cpRoot = Join-Path ([IO.Path]::GetTempPath()) ("wd-comb-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        try {
            $cpMake = {
                param([string]$Id, [string]$When, $Prev, [string]$Extra)
                $d = Join-Path $cpRoot "run-$Id"
                $null = New-Item -ItemType Directory -Path $d -Force
                ([pscustomobject]@{ preview = $false; started = $When
                                    counts = [pscustomobject]@{ removed = 0; changed = 1 } } | ConvertTo-Json -Depth 5) |
                    Set-Content -LiteralPath (Join-Path $d 'report.json') -Encoding UTF8
                $lines = @('{"item":"a","undo":{"method":"registry","path":"HKCU:\\Software\\Shared","name":"X","kind":"DWord","previous":' +
                           $Prev + ',"raw":true}}')
                if ($Extra) { $lines += $Extra }
                $lines | Set-Content -LiteralPath (Join-Path $d 'journal.jsonl') -Encoding UTF8
            }
            # March moved X from 1 to 0, June moved the same X from 0 to 2.
            # Putting both back means X = 1, which only March's entry knows.
            & $cpMake '20260301-120000' '2026-03-01T12:00:00' 1 ''
            & $cpMake '20260601-120000' '2026-06-01T12:00:00' 0 `
                '{"item":"b","undo":{"method":"registry","path":"HKCU:\\Software\\Only","name":"Y","kind":"DWord","previous":9,"raw":true}}'

            $cpRuns = @(Get-WDPastRuns -Root $cpRoot)
            if ($cpRuns.Count -ne 2) { $cpBad += "two runs were written and $($cpRuns.Count) were found" }
            $cp = Get-WDCombinedUndoPlan -Runs $cpRuns
            $cpX = @($cp.Steps | Where-Object { $_.Name -eq 'X' })
            if ($cpX.Count -ne 1) {
                $cpBad += "the value both runs wrote produced $($cpX.Count) steps rather than one"
            } else {
                if ([int]$cpX[0].Previous -ne 1)             { $cpBad += "it would be put back to $($cpX[0].Previous) rather than to the value it held before either run" }
                if ([string]$cpX[0].Run -ne '20260301-120000') { $cpBad += 'the surviving step is not the older run''s' }
            }
            if (@($cp.Steps | Where-Object { $_.Name -eq 'Y' }).Count -ne 1) { $cpBad += 'a value only one run touched went missing' }
            if ([int]$cp.Dropped -lt 1) { $cpBad += 'the superseded entry was not counted as dropped' }
            if (@($cp.Runs).Count -ne 2) { $cpBad += 'the per-run breakdown does not cover both runs' }
            # Newest first, because that is the order a picker reads in.
            if (@($cp.Runs)[0].Id -ne '20260601-120000') { $cpBad += 'the per-run breakdown is not newest first' }

            # Reverting one run is a different question and must keep its own
            # previous value.
            $cpJune = @($cpRuns | Where-Object { $_.Id -eq '20260601-120000' })[0]
            $cpOwn  = @((Get-WDUndoPlan -Journal $cpJune.Journal).Steps | Where-Object { $_.Name -eq 'X' })
            if ($cpOwn.Count -ne 1 -or [int]$cpOwn[0].Previous -ne 0) {
                $cpBad += 'reverting one run on its own no longer uses that run''s own previous value'
            }

            # Every step carries the key both dedups are decided on, and one
            # definition answers for every method.
            foreach ($s in @($cp.Steps)) {
                if (-not [string]$s.Key) { $cpBad += "a $($s.Method) step carries no key, so nothing can tell it from another" }
            }
            if ((Get-WDUndoStepKey ([pscustomobject]@{ Method = 'feature'; Name = 'X' })) -eq
                (Get-WDUndoStepKey ([pscustomobject]@{ Method = 'feature-off'; Name = 'X' }))) {
                $cpBad += 'turning a feature on and turning it off share a key'
            }
        } finally {
            Remove-Item -LiteralPath $cpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($cpBad.Count) {
            foreach ($b in $cpBad) { Write-Host "  COMBINED $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host '  OK      undoing several runs together restores what was there before the earliest of them'
        }
    } catch {
        Write-Host "  COMBINED plan check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # Driven against a fabricated journal and then actually executed, because
    # "it looks right" is what the broken version also looked like.
    try {
        $undoGenBad = @()
        $ugRoot = Join-Path ([IO.Path]::GetTempPath()) ("wd-undogen-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $ugRoot -Force
        $ugKey = 'HKCU:\SOFTWARE\WinSetupToolkitUndoGen'
        $ugSaved = Get-WDSession
        try {
            $null = Initialize-WDSession -Root $ugRoot -QuickEnvironment
            $ugSession = Get-WDSession
            $null = New-Item -Path $ugKey -Force
            Set-ItemProperty -Path $ugKey -Name 'Restore' -Value 9 -Type DWord -Force
            Set-ItemProperty -Path $ugKey -Name 'Quote' -Value 'after' -Type String -Force
            Set-ItemProperty -Path $ugKey -Name 'Old'   -Value 'after' -Type String -Force
            Set-ItemProperty -Path $ugKey -Name 'Blob'  -Value ([byte[]]@(9, 9, 9)) -Type Binary -Force
            # And one value the machine already holds, so one option comes out
            # fully already-back.
            Set-ItemProperty -Path $ugKey -Name 'Same'  -Value 5 -Type DWord -Force
            @(
                (@{ item = 'a'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Restore'; kind = 'DWord'; previous = 1; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'b'; type = 'registry'; undo = @{ method = 'registry'; path = 'HKU:\WD_DEFAULT\SOFTWARE\WinSetupToolkitUndoGen'; name = 'V'; kind = 'DWord'; previous = 1; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                # Every method the journal can write needs a case, or the entry
                # is a promise nothing keeps.
                (@{ item = 'c'; type = 'file'; undo = @{ method = 'rename'; from = 'C:\Nope\Thing.wd-disabled'; to = 'C:\Nope\Thing' } } | ConvertTo-Json -Compress -Depth 6)
                # An apostrophe in a previous value used to end the script's
                # parse at that line, because the quoting was done at journal
                # time.
                (@{ item = 'd'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Quote'; kind = 'String'; previous = "O'Brien"; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                # And the shape an older build wrote: the value already rendered
                # as a PowerShell literal. Journals outlive builds.
                (@{ item = 'd'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Old'; kind = 'String'; previous = "'before'" } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'd'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Blob'; kind = 'Binary'; previous = '@(48,0,4)' } } | ConvertTo-Json -Compress -Depth 6)
                # A key's default value, which the provider cannot delete and
                # will not bind an empty name for.
                (@{ item = 'd'; type = 'registry'; undo = @{ method = 'registry'; path = "$ugKey\shell\open\command"; name = '(default)'; kind = 'String'; previous = '__ABSENT__'; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                # Two options writing one value: only the first knows what was
                # there before the run.
                (@{ item = 'e'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Restore'; kind = 'DWord'; previous = 42; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                # Its one change is already back, so the option is - and the
                # page has a row there only to say there is nothing left to do.
                (@{ item = 'f'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Same'; kind = 'DWord'; previous = 5; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
            ) | Set-Content -LiteralPath $ugSession.JournalFile -Encoding UTF8

            # One item carries a description and one does not, so both halves of
            # the emitter run.
            $ugPath = Export-WDUndoScript -Items @(
                [pscustomobject]@{ Id = 'a'; Name = 'One number'; Category = 'Test'
                                   Desc = 'Stops one number from being one.' }
                [pscustomobject]@{ Id = 'd'; Name = 'Awkward values'; Category = 'Test' })
            $ugText = ''
            if ($ugPath -and (Test-Path -LiteralPath $ugPath)) { $ugText = Get-Content -LiteralPath $ugPath -Raw }
            if (-not $ugText) { $undoGenBad += 'no script was written' }
            $ugErr = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($ugText, [ref]$null, [ref]$ugErr)
            if ($ugErr) { $undoGenBad += "it does not parse: $($ugErr[0].Message)" }
            # The hive preamble is in the body of every script now and does
            # nothing unless the data says to, so its presence proves nothing
            # and the flags are what have to be asserted.
            foreach ($need in @('New-PSDrive -PSProvider Registry -Name HKU',
                                'reg.exe load "HKU\WD_DEFAULT"',
                                'reg.exe unload "HKU\WD_DEFAULT"')) {
                if ($ugText -notmatch [regex]::Escape($need)) { $undoGenBad += "the script body is missing: $need" }
            }
            if ($ugText -notmatch '(?m)^\$global:WDWantsHku\s+=\s+\$true')  { $undoGenBad += 'a run with per-account writes did not set WantsHku' }
            if ($ugText -notmatch '(?m)^\$global:WDWantsDefault\s+=\s+1')   { $undoGenBad += 'a run with one default-profile write did not count it' }
            if ($ugText -notmatch "M='rename'")                      { $undoGenBad += 'the rename step did not reach the script' }
            # Both sides harvested from source, or the copy that goes stale is
            # the expectations rather than the code.
            $ugWritten = @()
            foreach ($f in @(Get-ChildItem -LiteralPath $modulePath -Filter '*.psm1')) {
                $src = Get-Content -LiteralPath $f.FullName -Raw
                $ugWritten += @([regex]::Matches($src, "method\s*=\s*'([a-z\-]+)'") | ForEach-Object { $_.Groups[1].Value })
            }
            $ugWritten = @($ugWritten | Sort-Object -Unique)
            $ugRevSrc  = Get-Content (Join-Path $modulePath 'WD.Revert.psm1') -Raw
            $ugHandled = @([regex]::Matches($ugRevSrc, "(?m)^\s{12}'([a-z\-]+)'\s*\{") | ForEach-Object { $_.Groups[1].Value })
            foreach ($m in $ugWritten) {
                if ($ugHandled -notcontains $m) { $undoGenBad += "the rollback generator has no case for undo method '$m'" }
            }
            if (@($ugWritten).Count -lt 12) { $undoGenBad += "only $(@($ugWritten).Count) undo methods were found in the modules, so the sweep is not finding them" }
            # A stranded mount rides along in every later boot, so the two have
            # to balance.
            $ugLoad   = ([regex]::Matches($ugText, 'reg\.exe load')).Count
            $ugUnload = ([regex]::Matches($ugText, 'reg\.exe unload')).Count
            if ($ugLoad -ne $ugUnload) { $undoGenBad += "$ugLoad hive load(s) against $ugUnload unload(s)" }

            # The awkward values have to survive the trip as values, whichever
            # shape the journal recorded them in.
            if (([regex]::Matches($ugText, "N='Restore'")).Count -ne 1) { $undoGenBad += 'a value written twice produced two restores, and only the first one knows the original' }
            if ($ugText -notmatch "N='Restore'[^\r\n]*V=1")             { $undoGenBad += 'the surviving duplicate is not the first entry' }
            if ($ugText -notmatch "V='O''Brien'")                       { $undoGenBad += 'an apostrophe in a previous value was not escaped' }
            if ($ugText -notmatch "V='before'")                         { $undoGenBad += 'an old-shape pre-quoted string did not unwrap to a value' }
            if ($ugText -notmatch "V=\[byte\[\]\]@\(48,0,4\)")          { $undoGenBad += 'an old-shape byte blob did not unwrap to a byte array' }

            # The window, built and never shown: ShowDialog blocks the
            # dispatcher with nobody to dismiss it.
            $ugAll = Join-Path $ugRoot 'all.ps1'
            (Get-Content -LiteralPath $ugPath | Where-Object { $_ -notmatch '^#Requires' }) |
                Set-Content -LiteralPath $ugAll -Encoding UTF8
            $ugWin = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $ugAll -BuildOnly 2>&1
            $ugWinText = (@($ugWin) | ForEach-Object { [string]$_ }) -join "`n"
            # Four ids survive deduplication, under two categories - the ones
            # -Items names and the ones it does not.
            if ($ugWinText -notmatch 'options=5\b')  { $undoGenBad += "the window did not group into 5 options: $ugWinText" }
            if ($ugWinText -notmatch 'groups=2\b')   { $undoGenBad += 'the window did not raise a category for the unnamed ids' }
            if ($ugWinText -notmatch 'rail=2\b')     { $undoGenBad += 'the index rail does not have a card per category' }
            if ($ugWinText -notmatch 'steps=8\b')    { $undoGenBad += 'the window is not showing all eight changes' }
            # One option fully already back, and it must be the only one locked:
            # a page disabling more than that would be refusing work.
            if ($ugWinText -notmatch 'locked=1\b')   { $undoGenBad += 'the page does not have exactly one already-back option' }
            # Gone, because it was not there before the run - and named as the
            # default value rather than as an empty string.
            if ($ugText -notmatch "N='\(default\)'[^\r\n]*Gone=\`$true") {
                $undoGenBad += 'a default value created by the run is not marked for deletion'
            }
            if ($ugWinText -notmatch 'tally=')       { $undoGenBad += 'the window footer says nothing about what the button would do' }
            if ($ugWinText -notmatch 'Awkward values|options=') { $undoGenBad += 'the window did not build at all' }
            if (@($ugWin | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count) {
                $undoGenBad += 'building the window wrote errors to the console'
            }

            # The page says which run it is about. "Undo a WinSetupToolkit run"
            # is true of every one of them.
            if ($ugWinText -notmatch 'title=Revert changes from Windows Setup Toolkit run \d{8}-\d{6} applied on ') {
                $undoGenBad += 'the window does not name the run it is about, and when it was applied'
            }
            if ($ugText -notmatch 'Content="Revert selected"') { $undoGenBad += 'the button does not say what it does' }
            # Only what has already been put back wears a tag.
            if ($ugWinText -notmatch 'mistagged=0\b') { $undoGenBad += 'a row that is still in place was given a marker saying so' }
            if ($ugWinText -notmatch 'tagged=[1-9]')  { $undoGenBad += 'nothing on the page is marked as already back, so the one tag that exists is unreachable' }
            # Every grouping and every sort laid out for real: one nothing
            # exercises throws the first time somebody picks it.
            foreach ($ugG in @('status', 'kind', 'alpha', 'category')) {
                if ($ugWinText -notmatch "group\[$ugG\] blocks=[1-9]") { $undoGenBad += "grouping the page by $ugG laid out nothing" }
            }
            if ($ugWinText -notmatch 'sorted=ok')      { $undoGenBad += 'one of the sort orders threw' }
            if ($ugWinText -notmatch 'switched=#FF')   { $undoGenBad += 'the theme button did not repaint the palette' }
            if ($ugWinText -notmatch 'boxes=[1-9]')    { $undoGenBad += 'the filter panel offers nothing to filter by' }
            # Pressed in both directions. One press from a run that reverts
            # nothing, so the label is checked as well as the count.
            if ($ugWinText -notmatch 'selectall=.+?/(\d+) -> Select all/0 -> Select none/\1\b') {
                $undoGenBad += 'the page-wide Select all does not clear the page and take it back'
            }

            # The standalone window and the Revert page are the same interface,
            # and each check below is one place they had drifted.
            if ($ugWinText -notmatch 'unticked=WdText/Collapsed -> WdBad/Visible/Bold -> WdText/Collapsed/SemiBold') {
                $undoGenBad += 'unticking an option does not mark it, or re-ticking does not put it back'
            }
            if ($ugWinText -notmatch 'notice=Option will not be reverted') {
                $undoGenBad += 'an unticked option does not say that it will not be reverted'
            }
            # Clicking anywhere on the row, because the box is a 13px target in
            # the corner of a row the width of a column.
            if ($ugWinText -notmatch 'rowclick=True -> False -> True') {
                $undoGenBad += 'clicking the row does not tick it, or twice does not put it back'
            }
            if ($ugWinText -notmatch 'livecursor=Hand\b') {
                $undoGenBad += 'a live row offers no hand cursor, so nothing says it can be clicked'
            }
            # A row with nothing left to decide refuses the click, so it must
            # not invite one either.
            if ($ugWinText -notmatch 'deadhover=(\S+) -> \1 cursor=Arrow struck=True opacity=0\.6 notice=Collapsed') {
                $undoGenBad += 'an already-back row still answers the pointer, or does not say four ways that it is done'
            }
            if ($ugWinText -notmatch 'deadink=WdMuted') {
                $undoGenBad += "the marking pass repainted an already-back row's name"
            }
            if ($ugWinText -notmatch 'deadclick=False -> False') {
                $undoGenBad += 'clicking an already-back row ticked it'
            }
            # Descriptions start hidden, but the elements exist either way.
            if ($ugWinText -notmatch 'described=1 of 1 elements, visible 0 -> 1 -> 0') {
                $undoGenBad += 'the description did not arrive, or does not turn on and off'
            }
            if ($ugText -notmatch "(?m)^\`$global:WDDesc = @\{") {
                $undoGenBad += 'no description table was emitted'
            }
            # Past tense, because this page lists what has already happened.
            if ($ugText -notmatch "'a' = 'Stopped one number from being one\.'") {
                $undoGenBad += 'the description did not reach the script in the past tense'
            }
            # Only the options the journal names, and only the ones that have
            # one.
            if ($ugText -match "(?m)^\s+'e' = ") {
                $undoGenBad += 'an id no item named got a description entry'
            }
            # Refresh rebuilds, so what matters is that the page comes back
            # whole.
            if ($ugWinText -notmatch '(?m)^refresh=(.+?) -> \1$') {
                $undoGenBad += 'Refresh did not rebuild the page to the same shape'
            }
            if ($ugWinText -notmatch 'refreshsaid=.*Read again just now') {
                $undoGenBad += 'Refresh does not say that it read the machine again'
            }
            if ($ugWinText -notmatch 'afterrefresh=the tally followed the tick') {
                $undoGenBad += 'a row rebuilt by Refresh no longer answers a click'
            }
            if ($ugWinText -notmatch 'refreshbtn=True') {
                $undoGenBad += 'the Refresh button did not come back out of its own handler'
            }

            # Get-WindowsOptionalFeature -Online enumerates everything at 12s
            # where the CIM class is 1s. A per-name DISM call is fine; an
            # unfiltered -Online one is not.
            $ugDism = @([regex]::Matches($ugText, '(?m)^.*Get-WindowsOptionalFeature\s+-Online.*$') |
                        Where-Object { $_.Value -notmatch '-FeatureName' })
            if ($ugDism.Count) { $undoGenBad += 'the generated script still enumerates every Windows feature through DISM' }
            if ($ugText -notmatch 'Win32_OptionalFeature') { $undoGenBad += 'the generated script does not read feature state from the CIM class' }
            if (@([regex]::Matches($ugText, 'Start-WDFeatureRead')).Count -lt 3) {
                $undoGenBad += 'the feature table is not warmed ahead of both read paths'
            }
            # An icon is never worth failing a run over, so this is only
            # asserted where one could have been drawn.
            if (Get-Command Get-WDAppIconBytes -ErrorAction SilentlyContinue) {
                if ($ugWinText -notmatch 'icon=True') { $undoGenBad += 'the application icon was not embedded, so the window wears the host icon' }
                if ($ugText -notmatch '(?m)^\$global:WDIconDark = @\(') { $undoGenBad += 'no dark-palette icon reached the script' }
                if ($ugText -notmatch '(?m)^\$global:WDIconLight = @\(') { $undoGenBad += 'no light-palette icon reached the script' }

                # Trimmed to <=64px: the 128 and 256 frames are 130 KB of 158,
                # and nothing on that page draws at either size.
                $ugFull = Get-WDAppIconBytes -Theme 'dark'
                $ugCut  = Get-WDIcoSubset -Bytes $ugFull -MaxSize 64
                if ($ugCut.Length -ge $ugFull.Length) { $undoGenBad += 'trimming the icon did not make it any smaller' }
                $ugN = [BitConverter]::ToUInt16($ugCut, 4)
                if ($ugN -lt 4) { $undoGenBad += "the trimmed icon has only $ugN frame(s)" }
                for ($ugI = 0; $ugI -lt $ugN; $ugI++) {
                    $ugO = 6 + 16 * $ugI
                    $ugW = [int]$ugCut[$ugO]
                    if ($ugW -eq 0) { $ugW = 256 }
                    $ugLen = [int][BitConverter]::ToUInt32($ugCut, $ugO + 8)
                    $ugOff = [int][BitConverter]::ToUInt32($ugCut, $ugO + 12)
                    if ($ugW -gt 64) { $undoGenBad += "the trimmed icon kept a ${ugW}px frame" }
                    if ($ugOff -lt 6 -or $ugOff + $ugLen -gt $ugCut.Length) {
                        $undoGenBad += "frame $ugI of the trimmed icon runs past the end of the file"
                    }
                }
            }

            # Every function in the generated script must be global:, and every
            # shared variable $global:. Not style - a WPF callback runs in
            # whatever session state the dispatcher hands it.
            $ugFns = @([regex]::Matches($ugText, '(?m)^function\s+(global:)?([A-Za-z]+-[A-Za-z]+)'))
            foreach ($m in $ugFns) {
                if (-not $m.Groups[1].Value) { $undoGenBad += "$($m.Groups[2].Value) in the generated script is not global" }
            }
            if ($ugFns.Count -lt 15) { $undoGenBad += "only $($ugFns.Count) functions found in the generated script" }
            foreach ($v in @('WDSteps', 'WDReinstall', 'WDOwners', 'WDWantsHku', 'WDWantsDefault')) {
                if ($ugText -match "(?m)^\`$$v\s*=") { $undoGenBad += "`$$v is emitted script-scoped rather than global" }
            }

            # The launcher, because double-clicking a .ps1 opens a text editor
            # and no instruction inside the .ps1 changes that.
            $ugCmd = Join-Path (Split-Path $ugPath -Parent) 'Undo-WinSetupToolkit.cmd'
            if (-not (Test-Path -LiteralPath $ugCmd)) {
                $undoGenBad += 'no launcher was written beside the rollback script'
            } else {
                $cb = [IO.File]::ReadAllBytes($ugCmd)
                # cmd.exe does not strip a byte order mark: the first line then
                # reads as "<BOM>@echo", which fails, so echo stays on for the
                # whole run.
                if ($cb.Length -gt 3 -and $cb[0] -eq 0xEF -and $cb[1] -eq 0xBB -and $cb[2] -eq 0xBF) {
                    $undoGenBad += 'the launcher was written with a byte order mark'
                }
                $ct = [IO.File]::ReadAllText($ugCmd)
                if ($ct -notmatch "`r`n")            { $undoGenBad += 'the launcher has bare LF line endings' }
                if ($ct -notmatch '-STA')            { $undoGenBad += 'the launcher does not ask for an STA host, so the window cannot open' }
                if ($ct -notmatch 'reg query HKU')   { $undoGenBad += 'the launcher does not probe for administrator rights' }
                if ($ct -match '[^\x00-\x7F]')       { $undoGenBad += 'the launcher is not pure ASCII' }
            }

            # And a run that wrote nothing per-account must not grow any of it.
            @(
                (@{ item = 'x'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Restore'; kind = 'DWord'; previous = 1; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'x'; type = 'registry'; undo = @{ method = 'registry'; path = "$ugKey\shell\open\command"; name = '(default)'; kind = 'String'; previous = '__ABSENT__'; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'x'; type = 'registry'; undo = @{ method = 'registry'; path = "$ugKey\proto"; name = '(default)'; kind = 'String'; previous = 'URL:old'; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
            ) | Set-Content -LiteralPath $ugSession.JournalFile -Encoding UTF8
            $ugPlainPath = Export-WDUndoScript
            $ugPlain = Get-Content -LiteralPath $ugPlainPath -Raw
            if ($ugPlain -notmatch '(?m)^\$global:WDWantsHku\s+=\s+\$false') { $undoGenBad += 'a run with no per-account writes still asked for the HKU drive' }
            if ($ugPlain -notmatch '(?m)^\$global:WDWantsDefault\s+=\s+0')   { $undoGenBad += 'a run with no default-profile writes still counted some' }

            # #Requires -RunAsAdministrator is right for the real thing and in
            # the way here, so the body is exercised unelevated with it
            # stripped.
            Set-ItemProperty -Path $ugKey -Name 'Restore' -Value 9 -Type DWord -Force
            # The state that run would have left: a default value it created
            # from nothing, and one it wrote over something.
            $null = New-Item -Path "$ugKey\shell\open\command" -Force
            Set-ItemProperty -Path "$ugKey\shell\open\command" -Name '(default)' -Value 'systray.exe' -Type String -Force
            $null = New-Item -Path "$ugKey\proto" -Force
            Set-ItemProperty -Path "$ugKey\proto" -Name '(default)' -Value 'stub' -Type String -Force
            $ugRun = Join-Path $ugRoot 'unelevated.ps1'
            (Get-Content -LiteralPath $ugPlainPath | Where-Object { $_ -notmatch '^#Requires' }) |
                Set-Content -LiteralPath $ugRun -Encoding UTF8
            $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ugRun -Console 2>&1
            $ugNow = (Get-ItemProperty -LiteralPath $ugKey -Name 'Restore' -ErrorAction SilentlyContinue).Restore
            if ([int]$ugNow -ne 1) { $undoGenBad += "running it left the value at $ugNow rather than 1" }
            # Read raw, because Get-ItemProperty spells the default value
            # '(default)' and .NET spells it ''.
            $ugDef = (Get-Item -LiteralPath "$ugKey\shell\open\command").GetValue('')
            if ($null -ne $ugDef) { $undoGenBad += "a default value the run created survived the rollback as '$ugDef'" }
            $ugBack = (Get-Item -LiteralPath "$ugKey\proto").GetValue('')
            if ($ugBack -ne 'URL:old') { $undoGenBad += "a default value the run overwrote came back as '$ugBack' rather than URL:old" }
            # Twice, because a rollback run after a partial one must not report
            # work it did not do.
            $ugAgain = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ugRun -Console 2>&1
            if (($ugAgain -join ' ') -notmatch '0 change\(s\) put back, 3 were already back') {
                $undoGenBad += 'running it a second time did not report the changes as already back'
            }
        } finally {
            Remove-Item -LiteralPath $ugKey -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $ugRoot -Recurse -Force -ErrorAction SilentlyContinue
            if ($ugSaved) { $null = Initialize-WDSession -Root $ugSaved.Root -Preview -QuickEnvironment }
        }
        if ($undoGenBad.Count) {
            foreach ($b in $undoGenBad) { Write-Host "  UNDO script $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host '  OK      undo script stands alone, restores a value, and unloads what it loaded'
        }
    } catch {
        Write-Host "  UNDO script check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # What stops the Revert page offering a rollback that has already happened.
    # Driven against a journal whose answers are known.
    try {
        $undoBad = @()
        $jRoot = Join-Path ([IO.Path]::GetTempPath()) ("wd-undo-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $jRoot -Force
        $probeKey = 'HKCU:\SOFTWARE\WinSetupToolkitSelfTest'
        try {
            $null = New-Item -Path $probeKey -Force
            # One value put back, one still carrying what a run wrote, and one
            # under a hive that is not mounted and so cannot be asked about.
            Set-ItemProperty -Path $probeKey -Name 'Restored'  -Value 1 -Type DWord -Force
            Set-ItemProperty -Path $probeKey -Name 'StillSet'  -Value 0 -Type DWord -Force
            $jf = Join-Path $jRoot 'journal.jsonl'
            @(
                (@{ item = 'a'; type = 'registry'; undo = @{ method = 'registry'; path = $probeKey; name = 'Restored'; kind = 'DWord'; previous = 1 } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'b'; type = 'registry'; undo = @{ method = 'registry'; path = $probeKey; name = 'StillSet'; kind = 'DWord'; previous = 1 } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'c'; type = 'registry'; undo = @{ method = 'registry'; path = $probeKey; name = 'NeverWas'; kind = 'DWord'; previous = '__ABSENT__' } } | ConvertTo-Json -Compress -Depth 6)
                # A hive nothing will ever have mounted. Naming the real
                # WD_DEFAULT made this depend on whether a run had left it
                # behind.
                (@{ item = 'd'; type = 'registry'; undo = @{ method = 'registry'; path = 'HKU:\WD_SELFTEST_NEVER_MOUNTED\SOFTWARE\X'; name = 'V'; kind = 'DWord'; previous = 1 } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'e'; type = 'appx';     undo = @{ method = 'reinstall'; name = 'Some.Package' } } | ConvertTo-Json -Compress -Depth 6)
                # Written twice by two options: only the first entry knows what
                # was there before the run.
                (@{ item = 'f'; type = 'registry'; undo = @{ method = 'registry'; path = $probeKey; name = 'StillSet'; kind = 'DWord'; previous = 0 } } | ConvertTo-Json -Compress -Depth 6)
            ) | Set-Content -LiteralPath $jf -Encoding UTF8

            Clear-WDRegistryProbeCache
            $st = Get-WDUndoStatus -Journal $jf
            # Four: the duplicate is dropped, and a reinstall hint is not a step
            # - nothing puts an uninstalled program back.
            if ([int]$st.Total -ne 4)       { $undoBad += "counted $($st.Total) entries, not 4" }
            # Restored is back at its previous value, and NeverWas is absent -
            # which for a value the run created is being back where it was.
            if ([int]$st.Done -ne 2)        { $undoBad += "$($st.Done) done, expected 2 (the restored value and the one that never existed)" }
            if ([int]$st.Outstanding -ne 1) { $undoBad += "$($st.Outstanding) outstanding, expected 1" }
            # The default-profile write, and only that.
            if ([int]$st.Unknown -ne 1)     { $undoBad += "$($st.Unknown) unknown, expected 1" }

            # And once the last one is put back, the run reads as fully undone.
            Set-ItemProperty -Path $probeKey -Name 'StillSet' -Value 1 -Type DWord -Force
            Clear-WDRegistryProbeCache
            $st2 = Get-WDUndoStatus -Journal $jf
            if ([int]$st2.Outstanding -ne 0) { $undoBad += "after restoring it, $($st2.Outstanding) still outstanding" }
            # A journal that is not there answers zero rather than throwing: the
            # page asks about every past run and some have no journal.
            $st3 = Get-WDUndoStatus -Journal (Join-Path $jRoot 'nope.jsonl')
            if ([int]$st3.Total -ne 0) { $undoBad += 'a missing journal did not answer zero' }
        } finally {
            Remove-Item -LiteralPath $probeKey -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $jRoot -Recurse -Force -ErrorAction SilentlyContinue
            Clear-WDRegistryProbeCache
        }
        if ($undoBad.Count) {
            foreach ($b in $undoBad) { Write-Host "  UNDO status $b" -ForegroundColor Red }
            $failures++
        } else {
            Write-Host '  OK      undo state outstanding, already-back and cannot-tell are counted apart'
        }
    } catch {
        Write-Host "  UNDO status check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # Residue tokens decide what gets shown as suspicious, so a bad rule here
    # either floods the report or finds nothing.
    try {
        $tokBad = @()
        foreach ($case in @(
            @{ In = 'Python 3.12.10 (64-bit)';  Want = @('python');   NotWant = @('64','bit') },
            @{ In = 'Digilent Software, Inc.';  Want = @('digilent'); NotWant = @('software','inc') },
            @{ In = 'Qt';                       Want = @();           NotWant = @('qt') })) {
            $got = @(Get-WDResidueTokens -Name $case.In)
            foreach ($w in $case.Want)    { if ($got -notcontains $w) { $tokBad += "$($case.In): lost '$w'" } }
            foreach ($n in $case.NotWant) { if ($got -contains $n)    { $tokBad += "$($case.In): kept '$n'" } }
        }
        if ($tokBad.Count) {
            Write-Host "  RESIDUE token rules wrong: $($tokBad -join '; ')" -ForegroundColor Red
            $failures++
        } else {
            Write-Host '  OK      residue    name tokens drop versions, filler and short words'
        }
    } catch {
        Write-Host "  RESIDUE token check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # Last in this section, and it has to stay last: Set-WDIrreversible latches
    # for the life of the process on purpose.
    try {
        $bound = (Initialize-WDRecycleType) -and [WD.Shell].GetMethod('SHEmptyRecycleBin')
        $wasOff = -not (Test-WDIrreversible)
        Set-WDIrreversible
        $victim = Join-Path ([IO.Path]::GetTempPath()) ('wd-irrev-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -Path $victim -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $victim 'x.txt') -Value 'gone' -Encoding UTF8
        $null = Invoke-WDFileAction -Action ([pscustomobject]@{ type = 'file'; recycle = $true; paths = @($victim) }) `
                                    -Context ([pscustomobject]@{ Preview = $false; ItemId = 'selftest-irreversible' })
        $hard = -not (Test-Path -LiteralPath $victim)
        $bin  = (New-Object -ComObject Shell.Application).NameSpace(0xA)
        $inBin = @($bin.Items() | Where-Object {
            (Join-Path $_.ExtendedProperty('System.Recycle.DeletedFrom') $_.Name) -eq $victim }).Count

        if ($bound -and $wasOff -and $hard -and $inBin -eq 0) {
            Write-Host '  OK      permanent  irreversible mode hard-deletes and bypasses the bin'
        } else {
            Write-Host "  PERMANENT mode wrong: bound=$([bool]$bound) offByDefault=$wasOff hardDeleted=$hard inBin=$inBin" -ForegroundColor Red
            $failures++
        }
        if (Test-Path -LiteralPath $victim) { Remove-Item -LiteralPath $victim -Recurse -Force -ErrorAction SilentlyContinue }
    } catch {
        Write-Host "  PERMANENT check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # Round-tripped rather than read: this document has one job nothing else in
    # the toolkit has.
    $notesProbe = Join-Path ([IO.Path]::GetTempPath()) "wd-notes-$([Guid]::NewGuid().ToString('N')).md"
    try {
        # Plain assignment, never @(Resolve-WDPlan ...). It returns ,$plan so
        # assigning does not unroll, and wrapping the call gives one element
        # holding the list.
        $notePlan = Resolve-WDPlan -Categories $categories -Selected @('svc-print','svc-wsearch','store') -Profile $profileInfo
        $null = Export-WDRunNotes -Items $notePlan -PresetName 'SelfTest' -Path $notesProbe
        if (-not (Test-Path -LiteralPath $notesProbe)) {
            Write-Host '  NOTES  the run notes were not written' -ForegroundColor Red; $failures++
        } else {
            $body = Get-Content -LiteralPath $notesProbe -Raw
            foreach ($want in @('# What this run did', '## What changed, option by option',
                                '#### Print Spooler', 'services.msc', '**Undo just this:**',
                                '| What was touched | How many |',
                                # The narrowest way back has to be offered
                                # first.
                                'Revert past changes', 'only that option goes back',
                                # And every option is ruled off from the next.
                                '> **Why it matters.**')) {
                if ($body -notmatch [regex]::Escape($want)) {
                    Write-Host "  NOTES  the run notes never mention '$want'" -ForegroundColor Red; $failures++
                }
            }
            # Registry paths carry backslashes and wildcards, and markdown eats
            # both unless they are in a code span.
            foreach ($l in ($body -split "`r?`n")) {
                if ($l -notmatch '^- \*\*(Registry|Scheduled task|File|Shortcut)\*\*') { continue }
                if ($l -notmatch ' - `.+`$') {
                    Write-Host "  NOTES  a path line is not in a code span: $l" -ForegroundColor Red; $failures++
                    break
                }
            }
            # An item with no Settings page must still say something better than
            # "undo the run".
            $undoLines = @(($body -split "`r?`n") | Where-Object { $_ -like '**Undo just this:*' })
            $heads     = @(($body -split "`r?`n") | Where-Object { $_ -like '#### *' })
            if ($undoLines.Count -ne $heads.Count) {
                Write-Host "  NOTES  $($heads.Count) option(s) but $($undoLines.Count) undo line(s)" -ForegroundColor Red; $failures++
            }
            # One rule per option, so a hundred and fifty of them read as a
            # hundred and fifty things rather than one column of text.
            $rules = @(($body -split "`r?`n") | Where-Object { $_ -eq '---' })
            if ($rules.Count -ne $heads.Count) {
                Write-Host "  NOTES  $($heads.Count) option(s) but $($rules.Count) dividing rule(s)" -ForegroundColor Red; $failures++
            }
            # -Path has to work with no session, so the run id and rollback path
            # are parameters rather than reads off the session.
            $stamp = [datetime]'2026-03-04T05:06:07'
            $fake  = Join-Path ([IO.Path]::GetTempPath()) "wd-undo-$([Guid]::NewGuid().ToString('N')).ps1"
            $null  = Export-WDRunNotes -Items $notePlan -PresetName 'SelfTest' -Path $notesProbe `
                                       -RunId 'run-9999' -UndoFile $fake -Started $stamp
            $head2 = Get-Content -LiteralPath $notesProbe -Raw
            if ($head2 -notmatch 'run-9999')                 { $failures++; Write-Host '  NOTES  -RunId was ignored' -ForegroundColor Red }
            if ($head2 -notmatch 'Applied 4 March 2026')     { $failures++; Write-Host '  NOTES  -Started was ignored' -ForegroundColor Red }
            if ($head2 -notmatch 'no rollback script')       { $failures++; Write-Host '  NOTES  a rollback script that is not there was promised anyway' -ForegroundColor Red }
            Set-Content -LiteralPath $fake -Value '# stub' -Encoding UTF8
            $null  = Export-WDRunNotes -Items $notePlan -PresetName 'SelfTest' -Path $notesProbe `
                                       -RunId 'run-9999' -UndoFile $fake -Started $stamp
            $head3 = Get-Content -LiteralPath $notesProbe -Raw
            if ($head3 -match 'no rollback script')          { $failures++; Write-Host '  NOTES  a rollback script that IS there was disowned' -ForegroundColor Red }
            Remove-Item -LiteralPath $fake -Force -ErrorAction SilentlyContinue
            Write-Host "  run notes    : $([Math]::Round((Get-Item $notesProbe).Length / 1KB, 1)) KB for a 3-item plan, $($heads.Count) option(s), all with an undo line"
        }

        # The lookup table somebody opens a fortnight later. Written by a
        # handler rather than the engine, so it is driven as one.
        $issDir = Join-Path ([IO.Path]::GetTempPath()) "wd-iss-$([Guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $issDir -Force
        # The session names the file, rather than a run option naming the
        # folder: one path, known to the handler that writes it and to the copy
        # that follows.
        $issFile = Join-Path $issDir 'Common-issues.txt'
        $ctx = [pscustomobject]@{
            ItemId = 'issues-doc'; Preview = $false
            Session = [pscustomobject]@{ Root = $issDir; RunDir = $issDir; IssuesFile = $issFile }
            Plan = $notePlan
        }
        $issRes = Invoke-WDScriptAction -Action ([pscustomobject]@{ type = 'script'; handler = 'WriteCommonIssues' }) -Context $ctx
        if ([string]$issRes.Status -eq 'Failed' -or -not (Test-Path -LiteralPath $issFile)) {
            Write-Host "  ISSUES the common issues document was not written: $($issRes.Message)" -ForegroundColor Red; $failures++
        } else {
            $ib = Get-Content -LiteralPath $issFile -Raw
            foreach ($want in @('Press ctrl+F and type what is wrong', 'cannot print', 'PRINT SPOOLER',
                                'HOW TO PUT THIS BACK', 'services.msc', 'Press Win+R')) {
                if ($ib -notmatch [regex]::Escape($want)) {
                    Write-Host "  ISSUES the lookup file never mentions '$want'" -ForegroundColor Red; $failures++
                }
            }
            # The phrases have to sit above the undo steps for their own item,
            # so a search lands on the problem and reads the fix underneath.
            if ($ib.IndexOf('cannot print') -gt $ib.IndexOf('HOW TO PUT THIS BACK', $ib.IndexOf('PRINT SPOOLER'))) {
                Write-Host '  ISSUES the undo steps come before the phrases they belong to' -ForegroundColor Red; $failures++
            }
            # Generated spellings, not just what was authored: a lookup file
            # that only answers the phrase somebody else chose is the defect
            # this exists to fix.
            foreach ($want in @("can't print", 'cant print', 'printing broken', 'no printer')) {
                if ($ib -notmatch [regex]::Escape($want)) {
                    Write-Host "  ISSUES the lookup file has no generated spelling for '$want'" -ForegroundColor Red; $failures++
                }
            }
            # More than one route, numbered, and the last one is the whole run.
            $optCount = ([regex]::Matches($ib, '(?m)^\s+Option \d+ - ')).Count
            if ($optCount -lt 6) {
                Write-Host "  ISSUES only $optCount numbered revert route(s) across the whole file" -ForegroundColor Red; $failures++
            }
            $phraseCount = ([regex]::Matches($ib, '(?m)^  [a-z]')).Count
            Write-Host "  lookup file  : $([Math]::Round((Get-Item $issFile).Length / 1KB, 1)) KB for a 3-item plan, $phraseCount lookup phrase(s), $optCount numbered route(s)"
        }

        # Driven with a temporary desktop rather than the real one: a self test
        # that leaves a folder on somebody's desktop is not one that changes
        # nothing.
        $deskDir = Join-Path ([IO.Path]::GetTempPath()) "wd-desk-$([Guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $deskDir -Force
        $undoProbe = Join-Path $issDir 'Undo-WinSetupToolkit.ps1'
        Set-Content -LiteralPath $undoProbe -Value '# rollback' -Encoding UTF8
        $fakeSession = [pscustomobject]@{
            Id = 'selftest'; Root = $issDir; RunDir = $issDir
            UndoFile = $undoProbe; NotesFile = $notesProbe; IssuesFile = $issFile
            LogFile = (Join-Path $issDir 'debloat.log'); ReportFile = (Join-Path $issDir 'report.json')
            Preview = $false; Started = (Get-Date)
        }
        $keepRes = Export-WDRunFolder -Session $fakeSession -Desktop $deskDir
        if (-not $keepRes -or -not (Test-Path -LiteralPath $keepRes.Path)) {
            Write-Host '  KEEP   the run folder was not created on the desktop' -ForegroundColor Red; $failures++
        } else {
            if ((Split-Path -Leaf $keepRes.Path) -notlike 'WinSetupToolkit apply *') {
                Write-Host "  KEEP   the folder is called '$(Split-Path -Leaf $keepRes.Path)'" -ForegroundColor Red; $failures++
            }
            # The preview quotes this path rather than the run directory, and
            # the two come from the same function so they cannot disagree.
            $peek = Get-WDDesktopRunFolder -Session $fakeSession -Desktop $deskDir
            if (-not $peek.Ok -or [string]$peek.Path -ne [string]$keepRes.Path) {
                Write-Host "  KEEP   the preview would name '$($peek.Path)' and the run made '$($keepRes.Path)'" -ForegroundColor Red; $failures++
            }
            foreach ($want in @('Undo-WinSetupToolkit.ps1', 'What this run did.md',
                                'Common issues lookup and reversion instructions.txt', 'Read me first.txt')) {
                if (-not (Test-Path -LiteralPath (Join-Path $keepRes.Path $want))) {
                    Write-Host "  KEEP   '$want' is missing from the run folder" -ForegroundColor Red; $failures++
                }
            }
            $rm = Get-Content -LiteralPath (Join-Path $keepRes.Path 'Read me first.txt') -Raw
            foreach ($want in @('ctrl+F', 'Undo-WinSetupToolkit.ps1', 'Revert past changes')) {
                if ($rm -notmatch [regex]::Escape($want)) {
                    Write-Host "  KEEP   the read-me never mentions '$want'" -ForegroundColor Red; $failures++
                }
            }
            Write-Host "  run folder   : $(@($keepRes.Files).Count) file(s) copied plus the read-me"
        }
        # The run with no interface: what SetupComplete.cmd leaves behind for
        # whoever signs in first.
        $fakeReport = [pscustomobject]@{
            preview = $false; reboot = $true
            started = (Get-Date).ToString('o')
            machine = [pscustomobject]@{ model = 'Test'; os = 'Windows' }
            counts  = [pscustomobject]@{ total = 3; removed = 1; changed = 1; notPresent = 0
                                         partial = 0; blocked = 0; skipped = 0; failed = 1 }
            items   = @(
                [pscustomobject]@{ Id = 'a'; Name = 'Print Spooler'; Status = 'Changed'; Message = 'Disabled'; Detail = '' }
                [pscustomobject]@{ Id = 'b'; Name = 'Some App'; Status = 'Removed'; Message = 'Uninstalled'; Detail = '' }
                [pscustomobject]@{ Id = 'c'; Name = 'Stubborn thing'; Status = 'Failed'; Message = 'Refused'; Detail = 'access denied' })
        }
        # Read-WDSetupResult reads it back from disk, so it has to be there
        # rather than only in hand.
        $fakeReport | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fakeSession.ReportFile -Encoding UTF8
        $sumPath = Export-WDSetupResult -Session $fakeSession -Report $fakeReport -Label 'Balanced' `
                                        -KeepDir $deskDir -RestartCount 2 -RestorePoint 'failed'
        if (-not $sumPath -or -not (Test-Path -LiteralPath $sumPath)) {
            Write-Host '  SETUP  the setup run wrote no summary at all' -ForegroundColor Red; $failures++
        } else {
            $sb2 = Get-Content -LiteralPath $sumPath -Raw
            # The failed item in particular: a summary that hides what went
            # wrong is worse than none.
            foreach ($want in @('WHAT THE TOOLKIT DID DURING SETUP', 'WHAT TO DO NOW',
                                '2 changes need a restart', 'Stubborn thing', 'access denied',
                                'would NOT create a system restore point')) {
                if ($sb2 -notmatch [regex]::Escape($want)) {
                    Write-Host "  SETUP  the summary never says '$want'" -ForegroundColor Red; $failures++
                }
            }
            # And the machine-readable half, which is what puts the finished run
            # back on the real page at first sign-in.
            $back = Read-WDSetupResult -RunDir $issDir
            if (-not $back) {
                Write-Host '  SETUP  the finished run could not be read back' -ForegroundColor Red; $failures++
            } else {
                if ([int]$back.RestartCount -ne 2)      { Write-Host "  SETUP  the restart count came back as $($back.RestartCount)" -ForegroundColor Red; $failures++ }
                if ([string]$back.Label -ne 'Balanced') { Write-Host "  SETUP  the label came back as '$($back.Label)'" -ForegroundColor Red; $failures++ }
                if (-not $back.HasUndo)                 { Write-Host '  SETUP  the rollback script was not noticed' -ForegroundColor Red; $failures++ }
                if ([int]$back.Changed -ne 2)           { Write-Host "  SETUP  it counted $($back.Changed) change(s), expected 2" -ForegroundColor Red; $failures++ }
                if (@(Get-Prop $back.Report 'items' @()).Count -ne 3) {
                    Write-Host '  SETUP  the item list did not survive the round trip' -ForegroundColor Red; $failures++
                }
            }
            # A preview must not be offered as a finished run.
            $prevReport = $fakeReport.PSObject.Copy(); $prevReport.preview = $true
            $prevReport | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fakeSession.ReportFile -Encoding UTF8
            if (Read-WDSetupResult -RunDir $issDir) {
                Write-Host '  SETUP  a simulation reads back as a finished run' -ForegroundColor Red; $failures++
            }
            if (Read-WDSetupResult -RunDir (Join-Path $issDir 'nowhere')) {
                Write-Host '  SETUP  a folder that does not exist reads back as a run' -ForegroundColor Red; $failures++
            }
            Write-Host "  setup report : $([Math]::Round((Get-Item $sumPath).Length / 1KB, 1)) KB, read back clean"
        }
        # The prompt must refuse to register whenever it could not be honest: a
        # RunOnce entry pointing at a missing script is an error from a program
        # nobody has heard of.
        if (Register-WDSetupPrompt -RunDir $issDir -ScriptPath 'Z:\WinSetupToolkit\WinSetupToolkit.ps1') {
            Write-Host '  SETUP  the first sign-in prompt was registered for a script that will not be there' -ForegroundColor Red; $failures++
        }
        if (Register-WDSetupPrompt -RunDir (Join-Path $issDir 'nowhere') -ScriptPath $PSCommandPath) {
            Write-Host '  SETUP  the prompt was registered for a run folder that does not exist' -ForegroundColor Red; $failures++
        }
        # And it never writes to the real RunOnce key from a test.
        try {
            $leftover = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' `
                                         -Name 'WinSetupToolkitSetupResult' -ErrorAction Stop
            if ($leftover) {
                Write-Host '  SETUP  the self test left a RunOnce entry behind' -ForegroundColor Red; $failures++
            }
        } catch { }

        # A preview leaves nothing: a folder of rollback instructions for a run
        # that changed nothing is worse than no folder.
        $fakeSession.Preview = $true
        if (Export-WDRunFolder -Session $fakeSession -Desktop $deskDir) {
            Write-Host '  KEEP   a simulation left a run folder behind' -ForegroundColor Red; $failures++
        }
        # [IO.Directory]::Delete, not Remove-Item -Recurse: the cmdlet
        # enumerates and deletes in two passes and leaves the folder behind.
        foreach ($d in @($deskDir, $issDir)) {
            try { [IO.Directory]::Delete($d, $true) } catch { }
            if (Test-Path -LiteralPath $d) {
                Write-Host "  KEEP   the scratch folder $d could not be removed" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "  NOTES  writing the run notes threw: $($_.Exception.Message)" -ForegroundColor Red; $failures++
    } finally {
        Remove-Item -LiteralPath $notesProbe -Force -ErrorAction SilentlyContinue
    }

    Write-Host "`n[5] Environment" -ForegroundColor Cyan
    Write-Host "  winget       : $(if ($profileInfo.HasWinget) { 'available' } else { 'MISSING - winget removals will be skipped' })"
    Write-Host "  PowerToys    : $(if ($profileInfo.HasPowerToys) { 'installed' } else { 'not installed (fetched if the Copilot key remap runs)' })"
    Write-Host "  Copilot key  : $($profileInfo.CopilotKey)"
    Write-Host "  downloads    : $(if ($allowDl) { 'permitted' } else { 'refused' })"
    Write-Host "  ownership    : $(if ($takeOwn) { 'will seize TrustedInstaller-owned keys on refusal' } else { 'off - blocked items stay blocked' })$(if ($takeOwn -and -not $PSBoundParameters.ContainsKey('TakeOwnership')) { " (implied by -Preset $Preset)" })"
    Write-Host "  privileges   : $(if (Enable-WDOwnershipPrivileges) { 'take-ownership available' } else { 'take-ownership NOT available' })"

    # When one of the tools this wraps refuses, its dependent items fail one at
    # a time, which reads as many problems rather than one cause.
    $healthClock = [System.Diagnostics.Stopwatch]::StartNew()
    $health = Test-WDToolHealth -Refresh
    $healthClock.Stop()
    $hBad = @()
    if (-not @($health).Count) { $hBad += 'no checks ran at all' }
    foreach ($h in @($health)) {
        if ($h.State -notin @('Ok','Degraded','Unavailable','Unknown')) { $hBad += "$($h.Id) reported the invalid state '$($h.State)'" }
        # A check that says something is wrong and not what to do about it is
        # half an answer.
        if ($h.State -ne 'Ok' -and -not $h.Reason) { $hBad += "$($h.Id) is $($h.State) with no reason" }
        if ($h.State -eq 'Unavailable' -and -not $h.Fix -and -not $h.Safety) { $hBad += "$($h.Id) is Unavailable with no suggested fix" }
        # Anything that gates work has to say what it gates, or the impact
        # mapping cannot connect it to an item.
        if ($h.State -eq 'Unavailable' -and -not ($h.Affects.Count -or $h.Handlers.Count -or $h.Safety)) {
            $hBad += "$($h.Id) is Unavailable but declares neither Affects, Handlers, nor Safety"
        }
    }
    # Every action type the manifest uses should be spoken for by some check.
    $covered = New-WDStringSet @()
    foreach ($h in @($health)) { foreach ($a in $h.Affects) { $null = $covered.Add($a) } }
    foreach ($t in @('appx','winget','uninstall','registry','service','task','feature','capability','file')) {
        if (-not $covered.Contains($t)) { $hBad += "no check declares it gates '$t' actions" }
    }
    # The impact mapping is the half that makes it usable, so it is driven
    # rather than trusted.
    try {
        $hPlan = Resolve-WDPlan -Categories $categories -Selected @('svc-print','store','bingnews') -Profile $profileInfo
        $hImp  = @(Get-WDHealthImpact -Plan $hPlan -Health $health)
        foreach ($im in $hImp) {
            if ($null -eq $im.Count) { $hBad += "impact row for $($im.Health.Id) has no count" }
            if ($im.Count -gt @($hPlan).Count) { $hBad += "impact row for $($im.Health.Id) claims more items than the plan holds" }
        }
        $null = Format-WDToolHealthText -Impact $hImp
        $null = Format-WDToolHealthText -Health $health -IncludeOk
    } catch {
        $hBad += "the impact mapping threw: $($_.Exception.Message)"
    }
    if ($healthClock.ElapsedMilliseconds -gt 6000) {
        $hBad += "the sweep took $([int]$healthClock.ElapsedMilliseconds)ms, which is too slow for a path every run takes"
    }
    # No module may Add-Type at import time. Each is a csc run - ~400 ms for the
    # first, ~150 after - and three of them were most of the old startup.
    $compileBad = @()
    foreach ($f in @(Get-ChildItem -Path (Join-Path $modulePath '*.psm1'))) {
        $txt = [System.IO.File]::ReadAllText($f.FullName)
        foreach ($m in [regex]::Matches($txt, '(?m)^Add-Type\b.*$')) {
            # -AssemblyName loads an assembly already on disk and invokes no
            # compiler.
            if ($m.Value -match '-AssemblyName') { continue }
            $line = ($txt.Substring(0, $m.Index) -split "`n").Count
            $compileBad += "$($f.Name):$line compiles a type at import time - defer it to first use"
        }
    }
    # And the shared one has to actually build, or the taskbar icon and the
    # touch guard both quietly stop working.
    if (-not (Use-WDNative)) { $compileBad += 'Use-WDNative could not produce [WD.Native]' }
    elseif ($null -eq ([WD.Native]::GetSystemMetrics(0))) { $compileBad += '[WD.Native] compiled but will not call' }
    if ($compileBad.Count) {
        foreach ($b in $compileBad) { Write-Host "  NATIVE  $b" -ForegroundColor Red }
        $failures += $compileBad.Count
    } else {
        Write-Host '  native       : nothing compiles at import; [WD.Native] builds and calls'
    }

    $hSum = Get-WDToolHealthSummary -Health $health
    if ($hBad.Count) {
        foreach ($b in $hBad) { Write-Host "  HEALTH  $b" -ForegroundColor Red }
        $failures += $hBad.Count
    } else {
        Write-Host ("  tools        : {0} checked in {1}ms - {2} ok, {3} limited, {4} not working, {5} unknown" -f `
                    @($health).Count, [int]$healthClock.ElapsedMilliseconds,
                    $hSum.Ok, $hSum.Degraded, $hSum.Unavailable, $hSum.Unknown)
        foreach ($h in @($health | Where-Object { $_.State -ne 'Ok' })) {
            Write-Host "                 [$($h.State)] $($h.Name): $($h.Reason)" -ForegroundColor DarkGray
        }
    }

    # GetNewClosure copies the scope the closure is written in and nothing above
    # it, so a handler built inside another scriptblock captures $null.
    Write-Host "`n[6] Closure captures" -ForegroundColor Cyan
    # .ps1 as well as .psm1, which is what puts the rollback window's lines
    # under these checks.
    $srcFiles = @(Get-ChildItem -Path $modulePath -File |
                  Where-Object { $_.Extension -in @('.psm1', '.ps1') } |
                  ForEach-Object { $_.FullName }) + @($PSCommandPath)
    $sbAst    = [System.Management.Automation.Language.ScriptBlockAst]
    $varAst   = [System.Management.Automation.Language.VariableExpressionAst]
    # Names that are always there, whatever scope the closure copied. Matched
    # without case, because $Ui and $ui are one variable.
    $nameSet  = { param([string[]]$From)
                  $s = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                  foreach ($x in $From) { $null = $s.Add($x) }
                  ,$s }
    # $Matches is here for the same reason as $_ and $args: PowerShell fills it
    # in whatever scope the -match ran in.
    $auto     = & $nameSet @('_','this','args','PSItem','true','false','null','input','PSCmdlet',
                             'MyInvocation','Error','PSScriptRoot','PSCommandPath','Host','PID','Matches',
                             'ErrorActionPreference','ProgressPreference','LASTEXITCODE','StackTrace','?','^','$')
    # The names a scriptblock puts in its own scope: parameters, assignments
    # made directly in its body, and foreach variables.
    $definedBy = {
        param($Sb)
        $out = & $nameSet @()
        $pb = $Sb.ParamBlock; if (-not $pb -and $Sb.Body) { $pb = $Sb.Body.ParamBlock }
        if ($pb) { foreach ($p in $pb.Parameters) { $null = $out.Add($p.Name.VariablePath.UserPath) } }
        foreach ($a in $Sb.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            $p = $a.Parent; $own = $true
            while ($p -and $p -ne $Sb) {
                if ($p -is [System.Management.Automation.Language.ScriptBlockAst]) { $own = $false; break }
                $p = $p.Parent
            }
            if (-not $own) { continue }
            $l = $a.Left
            if ($l -is [System.Management.Automation.Language.ConvertExpressionAst]) { $l = $l.Child }
            if ($l -is $varAst) { $null = $out.Add($l.VariablePath.UserPath) }
        }
        foreach ($f in $Sb.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
            $null = $out.Add($f.Variable.VariablePath.UserPath)
        }
        ,$out
    }
    $unreachable = @()
    $closureCount = 0
    foreach ($f in $srcFiles) {
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
        $scopes  = @{}
        $defOf   = { param($Sb) if (-not $scopes.ContainsKey($Sb)) { $scopes[$Sb] = (& $definedBy $Sb) }; ,$scopes[$Sb] }
        $bound   = @($fileAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            "$($n.Member)" -eq 'GetNewClosure'
        }, $true))
        $blocks  = @($bound |
            Where-Object { $_.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } |
            ForEach-Object { $_.Expression.ScriptBlock })
        $closureCount += $blocks.Count

        # The other half, which reading the block cannot catch:
        # $someBlock.GetNewClosure() binds that block to whatever scope calls
        # it.
        foreach ($b in @($bound | Where-Object { -not ($_.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) })) {
            $p = $b.Parent; $inClosure = $false
            while ($p) {
                if ($p -is $sbAst) {
                    if ($p.Parent -and -not ($p.Parent -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $inClosure = $true }
                    break
                }
                $p = $p.Parent
            }
            if ($inClosure) {
                $unreachable += "$(Split-Path -Leaf $f):$($b.Extent.StartLineNumber) $($b.Expression.Extent.Text).GetNewClosure() re-binds an existing block to a nested scope"
            }
        }
        foreach ($c in $blocks) {
            # The scope this closure copies from. One written straight into a
            # function body copies the function's locals.
            $outer = $null; $p = $c.Parent
            while ($p) {
                if ($p -is $sbAst) { $outer = $p; break }
                $p = $p.Parent
            }
            if (-not $outer -or -not $outer.Parent) { continue }
            if ($outer.Parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
            foreach ($v in $c.FindAll({ param($n) $n -is $varAst }, $true)) {
                $n = $v.VariablePath.UserPath
                if ($v.VariablePath.IsGlobal -or $v.VariablePath.IsScript -or $n -match ':') { continue }
                if ($auto.Contains($n)) { continue }
                # Every scope between the reference and the closure, then the
                # closure, then the scope it was built in.
                $ok = $false; $q = $v
                while ($q -and $q -ne $c) {
                    if ($q -is $sbAst -and (& $defOf $q).Contains($n)) { $ok = $true; break }
                    $q = $q.Parent
                }
                if (-not $ok -and ((& $defOf $c).Contains($n) -or (& $defOf $outer).Contains($n))) { $ok = $true }
                if ($ok) { continue }
                $unreachable += "$(Split-Path -Leaf $f):$($v.Extent.StartLineNumber) `$$n - the closure at line $($c.Extent.StartLineNumber) cannot see it"
            }
        }
    }
    if ($unreachable.Count) {
        foreach ($u in @($unreachable | Sort-Object -Unique)) {
            Write-Host "  CAPTURE $u" -ForegroundColor Red
        }
        $failures += @($unreachable | Sort-Object -Unique).Count
    } else {
        Write-Host "  OK      captures   $closureCount closure(s) across $($srcFiles.Count) file(s), every one can see what it reads"
    }

    # An operator where a parameter should be: a simple function called in
    # command form parses -ne as a parameter name, so the comparison never
    # happens and the condition is whatever string came back.
    $opNames = & $nameSet @('eq','ne','gt','ge','lt','le','like','notlike','match','notmatch',
                            'contains','notcontains','in','notin','is','isnot','replace','band','bor',
                            'bxor','shl','shr','and','or','xor','not','ceq','cne','clike','cmatch')
    $opExempt = & $nameSet @('Where-Object','ForEach-Object','where','foreach','?','%')
    $cmdAst = [System.Management.Automation.Language.CommandAst]
    $opBad = @()
    foreach ($f in $srcFiles) {
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
        foreach ($call in $fileAst.FindAll({ param($n) $n -is $cmdAst }, $true)) {
            if ($opExempt.Contains([string]$call.GetCommandName())) { continue }
            foreach ($el in $call.CommandElements) {
                if (-not ($el -is [System.Management.Automation.Language.CommandParameterAst])) { continue }
                if (-not $opNames.Contains($el.ParameterName)) { continue }
                $opBad += "$(Split-Path -Leaf $f):$($el.Extent.StartLineNumber) $($call.GetCommandName()) is handed -$($el.ParameterName) as a PARAMETER - wrap the call in parentheses"
            }
        }
    }
    if ($opBad.Count) {
        foreach ($u in @($opBad | Sort-Object -Unique)) { Write-Host "  OPERATOR $u" -ForegroundColor Red }
        $failures += @($opBad | Sort-Object -Unique).Count
    } else {
        Write-Host '  OK      operators  no command is passed a comparison operator as a parameter'
    }

    # Theme keys, both directions.
    $themeBad = @()
    try {
        $uiSrc = Get-Content (Join-Path $modulePath 'WD.UI.psm1') -Raw
        $have  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $listM = [regex]::Match($uiSrc, "(?s)foreach \(\`$k in @\('Bg','Panel'.*?\)\) \{")
        foreach ($k in [regex]::Matches($listM.Value, "'([A-Za-z0-9]+)'")) { $null = $have.Add($k.Groups[1].Value) }
        foreach ($k in @('Warn','Bad','Ok','Accent'))     { $null = $have.Add("${k}Tint") }
        foreach ($k in @('T1','T2','T3','T4','Sub'))      { $null = $have.Add("${k}Soft") }
        for ($li = 1; $li -le 8; $li++) { $null = $have.Add("L$li"); $null = $have.Add("L${li}Soft") }
        foreach ($k in @('DiskUsers','Flat'))             { $null = $have.Add($k) }

        # Every palette colour has to become a brush. This is the direction that
        # actually broke.
        foreach ($pk in @((Get-WDPalette -Theme 'dark').Keys)) {
            if ($pk -eq 'Dark') { continue }
            if (-not $have.Contains([string]$pk)) { $themeBad += "the palette has '$pk' and `$paintTheme never makes a brush from it" }
        }

        # And every literal key handed to $Ref has to exist. Only a bare literal
        # can be read; an if-expression is skipped.
        $litKeys = 0
        foreach ($mm in [regex]::Matches($uiSrc, "&\s*\`$Ref\s+\S+\s+'[A-Za-z]+'\s+([^\r\n]+)")) {
            $tail = (($mm.Groups[1].Value -split ';')[0]).Trim()
            $found = @()
            if ($tail -match "^'([A-Za-z0-9]+)'$") {
                $found = @($Matches[1])
            } elseif ($tail -like '$(if*' -and $tail -notmatch '[+\[]') {
                $found = @([regex]::Matches($tail, "'([A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value })
            }
            foreach ($k in $found) {
                $litKeys++
                if (-not $have.Contains($k)) { $themeBad += "`$Ref is handed '$k', which is not a theme key" }
            }
        }
        if (-not $themeBad.Count) {
            Write-Host "  OK      theme keys $($have.Count) brush(es), every palette colour becomes one, and all $litKeys literal reference(s) resolve"
        }
    } catch {
        $themeBad += "the theme key sweep could not run: $($_.Exception.Message)"
    }
    if ($themeBad.Count) {
        foreach ($b in @($themeBad | Sort-Object -Unique)) { Write-Host "  THEME   $b" -ForegroundColor Red }
        $failures += @($themeBad | Sort-Object -Unique).Count
    }

    # A runspace starts empty, so each imports the toolkit for itself from a
    # list written by hand, and no two of them agree.
    $listBad = @()
    try {
        # .psm1 only: a runspace imports modules, and the rollback window beside
        # them is text for the generated script.
        $modDefs = @{}; $modCalls = @{}; $modGuarded = @{}
        foreach ($f in @(Get-ChildItem -Path (Join-Path $modulePath '*.psm1'))) {
            $mn = [IO.Path]::GetFileNameWithoutExtension($f.Name)
            $ma = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($fn in $ma.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                $modDefs[$fn.Name] = $mn
                $inner = @{}
                foreach ($c in $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                    $cn = $c.GetCommandName(); if ($cn) { $inner[$cn] = 1 }
                }
                $modCalls[$fn.Name] = @($inner.Keys)
                foreach ($g in [regex]::Matches($fn.Extent.Text, 'Get-Command\s+([A-Za-z][\w-]*)')) { $modGuarded[$g.Groups[1].Value] = 1 }
            }
        }
        $uiPath = Join-Path $modulePath 'WD.UI.psm1'
        $uiAst  = [System.Management.Automation.Language.Parser]::ParseFile($uiPath, [ref]$null, [ref]$null)
        $uiText = Get-Content -LiteralPath $uiPath -Raw
        # Read out of the source, not off the loaded module: WD.UI is not
        # imported yet on this path.
        $lists = @{}
        foreach ($asn in $uiAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            if ($asn.Left.Extent.Text -ne '$script:WDRunspaceModules') { continue }
            $ht = $asn.Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
            foreach ($pair in $ht.KeyValuePairs) {
                $lists[[string]$pair.Item1.Extent.Text.Trim("'", '"')] =
                    @($pair.Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
            }
        }
        if (-not $lists.Count) { throw 'found no $script:WDRunspaceModules table to read' }
        # A runspace body is the scriptblock carrying the import loop; its list
        # is the nearest reference to the table above it.
        $bodies = @()
        foreach ($sb in $uiAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) {
            if ($sb.Extent.Text -notmatch 'foreach \(\$m in \$Modules\)') { continue }
            $nested = @($sb.FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and $n.Extent.Text -match 'foreach \(\$m in \$Modules\)' }, $true) |
                        Where-Object { $_.Extent.StartOffset -gt $sb.Extent.StartOffset })
            if ($nested.Count) { continue }
            $keyHits = [regex]::Matches($uiText.Substring(0, $sb.Extent.StartOffset), '\$script:WDRunspaceModules\.(\w+)')
            if (-not $keyHits.Count) { $listBad += "a runspace at line $($sb.Extent.StartLineNumber) imports `$Modules but names no list"; continue }
            $bodies += [pscustomobject]@{ Key = $keyHits[$keyHits.Count - 1].Groups[1].Value; Sb = $sb }
        }
        foreach ($b in $bodies) {
            if (-not $lists.ContainsKey($b.Key)) { $listBad += "line $($b.Sb.Extent.StartLineNumber) names list '$($b.Key)', which the table does not define"; continue }
            $imported = $lists[$b.Key]
            $seen = @{}; $queue = New-Object System.Collections.Generic.Queue[string]
            foreach ($c in $b.Sb.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $cn = $c.GetCommandName(); if ($cn -and $modDefs.ContainsKey($cn)) { $queue.Enqueue($cn) }
            }
            while ($queue.Count) {
                $n = $queue.Dequeue()
                if ($seen.ContainsKey($n)) { continue }
                $seen[$n] = 1
                if ($modDefs[$n] -notin $imported -and -not $modGuarded.ContainsKey($n)) {
                    $listBad += ("'{0}' (line {1}) reaches {2} in {3}, which it does not import" -f $b.Key, $b.Sb.Extent.StartLineNumber, $n, $modDefs[$n])
                }
                foreach ($c in $modCalls[$n]) { if ($modDefs.ContainsKey($c) -and -not $seen.ContainsKey($c)) { $queue.Enqueue($c) } }
            }
        }
        # And the one ordering constraint there is: WD.Persist calls
        # Register-WDHandler into WD.Custom's table at import time.
        $ownList = @()
        $selfAst = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$null, [ref]$null)
        foreach ($fe in $selfAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
            if ($fe.Condition.Extent.Text -notmatch "'WD\.Core'") { continue }
            $ownList = @($fe.Condition.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
            break
        }
        if (-not $ownList.Count) { $listBad += 'could not find this script own module import list' }
        else {
            if ($ownList.IndexOf('WD.Custom') -lt 0 -or $ownList.IndexOf('WD.Persist') -lt 0) {
                $listBad += 'the import list is missing WD.Custom or WD.Persist'
            } elseif ($ownList.IndexOf('WD.Custom') -gt $ownList.IndexOf('WD.Persist')) {
                $listBad += 'WD.Persist is imported before WD.Custom, so its Register-WDHandler calls have no table to write into'
            }
            foreach ($k in @($lists.Keys)) {
                foreach ($m in $lists[$k]) {
                    if ($m -notin $ownList) { $listBad += "list '$k' names $m, which this script never imports" }
                }
            }
        }
        if (-not $listBad.Count) {
            Write-Host ("  OK      module lists {0} runspace(s) against {1} named list(s), every reachable function imported or guarded" -f $bodies.Count, $lists.Count)
        }
    } catch {
        $listBad += "the module list sweep could not run: $($_.Exception.Message)"
    }
    if ($listBad.Count) {
        foreach ($b in @($listBad | Sort-Object -Unique)) { Write-Host "  MODULES $b" -ForegroundColor Red }
        $failures += @($listBad | Sort-Object -Unique).Count
    }

    # The harness's own interface: every field passed, every field unpacked, and
    # nothing left dangling.
    $refsBad = @()
    try {
        $tPath = Join-Path $modulePath 'WD.UITest.psm1'
        $tAst  = [System.Management.Automation.Language.Parser]::ParseFile($tPath, [ref]$null, [ref]$null)
        $hFn   = @($tAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-WDInteractionTest' }, $true))
        if (-not $hFn.Count) { throw 'WD.UITest.psm1 defines no Invoke-WDInteractionTest' }
        $unpacked = & $nameSet @()
        foreach ($mm in [regex]::Matches($hFn[0].Extent.Text, '\$Refs\.([A-Za-z_][A-Za-z0-9_]*)')) { $null = $unpacked.Add($mm.Groups[1].Value) }
        $uiAstR   = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $modulePath 'WD.UI.psm1'), [ref]$null, [ref]$null)
        $supplied = & $nameSet @()
        foreach ($asn in $uiAstR.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            if ($asn.Left.Extent.Text -ne '$refs') { continue }
            $ht = $asn.Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
            if ($ht) { foreach ($pair in $ht.KeyValuePairs) { $null = $supplied.Add([string]$pair.Item1.Extent.Text) } }
        }
        if (-not $supplied.Count) { throw 'Show-WDWindow builds no $refs object' }
        foreach ($nm in $unpacked) { if (-not $supplied.Contains($nm)) { $refsBad += "the harness unpacks `$Refs.$nm and Show-WDWindow does not pass it" } }
        foreach ($nm in $supplied) { if (-not $unpacked.Contains($nm))  { $refsBad += "Show-WDWindow passes $nm and the harness never unpacks it" } }
        # And the list is complete: nothing the harness reads is left dangling.
        $prov = & $nameSet @()
        foreach ($a in $hFn[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            if ($a.Left -is $varAst) { $null = $prov.Add($a.Left.VariablePath.UserPath) }
        }
        foreach ($fe in $hFn[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { $null = $prov.Add($fe.Variable.VariablePath.UserPath) }
        foreach ($pa in $hFn[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)) { $null = $prov.Add($pa.Name.VariablePath.UserPath) }
        $dangle = & $nameSet @()
        foreach ($v in $hFn[0].FindAll({ param($n) $n -is $varAst }, $true)) {
            $nm = $v.VariablePath.UserPath
            if ($nm -match ':' -or $v.VariablePath.IsGlobal -or $v.VariablePath.IsScript) { continue }
            if ($auto.Contains($nm) -or $prov.Contains($nm)) { continue }
            $null = $dangle.Add($nm)
        }
        foreach ($nm in $dangle) { $refsBad += "the harness reads `$$nm and neither unpacks nor assigns it" }
        # And every field names something the frame actually has. A field of
        # "foo = $foo" where the frame has no $foo passes silently as $null.
        $swFn = @($uiAstR.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-WDWindow' }, $true))
        if ($swFn.Count) {
            $frameHas = & $nameSet @()
            if ($swFn[0].Body.ParamBlock) {
                foreach ($pa in $swFn[0].Body.ParamBlock.Parameters) { $null = $frameHas.Add($pa.Name.VariablePath.UserPath) }
            }
            foreach ($a in $swFn[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                if ($a.Left -is $varAst) { $null = $frameHas.Add($a.Left.VariablePath.UserPath) }
            }
            foreach ($fe in $swFn[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { $null = $frameHas.Add($fe.Variable.VariablePath.UserPath) }
            foreach ($nm in $supplied) { if (-not $frameHas.Contains($nm)) { $refsBad += "`$refs passes $nm and Show-WDWindow has no such local" } }
        }
        if (-not $refsBad.Count) {
            Write-Host ("  OK      harness    {0} name(s) in -Refs, passed and unpacked, nothing dangling" -f $unpacked.Count)
        }
    } catch {
        $refsBad += "the harness interface sweep could not run: $($_.Exception.Message)"
    }
    if ($refsBad.Count) {
        foreach ($b in @($refsBad | Sort-Object -Unique)) { Write-Host "  REFS    $b" -ForegroundColor Red }
        $failures += @($refsBad | Sort-Object -Unique).Count
    }

    Write-Host "`n[7] Interface" -ForegroundColor Cyan
    Import-Module (Join-Path $modulePath 'WD.UI.psm1') -Force -DisableNameChecking

    # Two palettes, and the chooser on first run only means anything if asking
    # for one gets it.
    try {
        $dark = Get-WDPalette -Theme 'dark'; $light = Get-WDPalette -Theme 'light'
        $auto = Get-WDPalette
        if (-not $dark.Dark)          { Write-Host '  THEME dark palette is not dark' -ForegroundColor Red; $failures++ }
        elseif ($light.Dark)          { Write-Host '  THEME light palette is not light' -ForegroundColor Red; $failures++ }
        elseif ($null -eq $auto.Dark) { Write-Host '  THEME no palette without a choice' -ForegroundColor Red; $failures++ }
        else { Write-Host "  OK      theme      dark and light both resolve; unset follows Windows ($(if ($auto.Dark) { 'dark' } else { 'light' }))" }
    } catch {
        Write-Host "  THEME check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # Shown once, before anything else exists, and never again - so a typo in it
    # would only be found by somebody running this for the first time.
    try {
        $tw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$(
                & (Get-Module WD.UI) { $script:ThemeXaml }))))
        $miss = @('Card', 'Head', 'BtnDark', 'BtnLight' | Where-Object { -not $tw.FindName($_) })
        if ($miss.Count) {
            Write-Host "  CHOOSER missing element(s): $($miss -join ', ')" -ForegroundColor Red
            $failures++
        } else {
            Write-Host '  OK      chooser    the first-run theme window parses with both answers on it'
        }
    } catch {
        Write-Host "  CHOOSER check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    # The icon is generated rather than shipped, so nothing on disk can be
    # inspected when it goes wrong.
    try {
        $iconClock = [System.Diagnostics.Stopwatch]::StartNew()
        $raw = New-WDIconBytes
        $iconClock.Stop()
        $bad = @()

        # The .ico container, read back the way the shell reads it.
        if ($raw -isnot [byte[]]) { $bad += "the icon came back as $($raw.GetType().Name), not byte[]" }
        if ($raw.Length -lt 64) { $bad += 'the icon is empty' }
        else {
            $count = [BitConverter]::ToUInt16($raw, 4)
            if ([BitConverter]::ToUInt16($raw, 0) -ne 0) { $bad += 'reserved field is not zero' }
            if ([BitConverter]::ToUInt16($raw, 2) -ne 1) { $bad += 'type is not 1 (icon)' }
            if ($count -lt 4) { $bad += "only $count frame(s)" }
            # Every directory entry must point inside the file. A bad offset
            # renders as a blank tile rather than as an error.
            for ($e = 0; $e -lt $count; $e++) {
                $at = 6 + 16 * $e
                $len = [BitConverter]::ToUInt32($raw, $at + 8)
                $off = [BitConverter]::ToUInt32($raw, $at + 12)
                if ($off + $len -gt $raw.Length) { $bad += "frame $e runs past the end of the file" }
            }
        }

        $ms = New-Object System.IO.MemoryStream (,$raw)
        $dec = New-Object Windows.Media.Imaging.IconBitmapDecoder `
                   $ms, ([Windows.Media.Imaging.BitmapCreateOptions]::None),
                   ([Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $sizes = @($dec.Frames | ForEach-Object { $_.PixelWidth })
        foreach ($want in @(16, 32, 48)) {
            if ($sizes -notcontains $want) { $bad += "no ${want}px frame" }
        }
        # Square, and actually drawn. An all-transparent frame is what a broken
        # geometry produces.
        foreach ($fr in $dec.Frames) {
            if ($fr.PixelWidth -ne $fr.PixelHeight) { $bad += "$($fr.PixelWidth)px frame is not square" }
        }
        $big = $dec.Frames | Sort-Object PixelWidth | Select-Object -Last 1
        $px = New-Object 'byte[]' ($big.PixelWidth * $big.PixelHeight * 4)
        $big.CopyPixels($px, $big.PixelWidth * 4, 0)
        $lit = 0
        for ($p = 3; $p -lt $px.Length; $p += 4) { if ($px[$p] -gt 8) { $lit++ } }
        $cover = $lit / ($big.PixelWidth * $big.PixelHeight)
        # Catches a collapsed geometry, which renders as a thin squiggle and
        # passes every structural check. Does not catch a wrong shape.
        if ($cover -lt 0.18) { $bad += ('only {0:p0} of the largest frame is drawn' -f $cover) }
        if ($cover -gt 0.85) { $bad += ('{0:p0} of the largest frame is drawn - it is a blob' -f $cover) }

        $pick = Get-WDAppIcon
        if (-not $pick)        { $bad += 'Get-WDAppIcon handed back nothing' }
        elseif (-not $pick.IsFrozen) { $bad += 'the icon is not frozen' }

        # Bytes cross threads, decoded frames do not. A BitmapFrame keeps its
        # decoder, a decoder has thread affinity, and Freeze() on the frame does
        # not freeze the decoder.
        $iconRs = [runspacefactory]::CreateRunspace()
        $iconRs.ApartmentState = 'STA'
        $iconRs.Open()
        $iconRs.SessionStateProxy.SetVariable('IconBytes', (Get-WDAppIconBytes))
        $iconPs = [powershell]::Create()
        $iconPs.Runspace = $iconRs
        $null = $iconPs.AddScript({
            try {
                Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
                $ims = New-Object System.IO.MemoryStream (,[byte[]]$IconBytes)
                $idc = New-Object Windows.Media.Imaging.IconBitmapDecoder `
                           $ims, ([Windows.Media.Imaging.BitmapCreateOptions]::None),
                           ([Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                $ico = $idc.Frames[0]
                foreach ($fr in $idc.Frames) { if ($fr.PixelWidth -eq 32) { $ico = $fr } }
                if ($ico.CanFreeze) { $ico.Freeze() }
                $w = New-Object Windows.Window
                $w.Icon = $ico
                $null = (New-Object Windows.Interop.WindowInteropHelper $w).EnsureHandle()
                'ok'
            } catch { "threw: $($_.Exception.Message)" }
        })
        $crossed = [string](@($iconPs.Invoke()) | Select-Object -Last 1)
        try { $iconPs.Dispose(); $iconRs.Close(); $iconRs.Dispose() } catch { }
        if ($crossed -ne 'ok') { $bad += "the splash cannot take the icon - $crossed" }

        if ($bad.Count) {
            Write-Host "  ICON    $($bad -join '; ')" -ForegroundColor Red
            $failures++
        } else {
            Write-Host ("  OK      icon       {0} frames ({1}), {2:p0} of the largest drawn, crosses to a second UI thread, built in {3}ms" -f `
                        $dec.Frames.Count, ($sizes -join '/'), $cover, [int]$iconClock.ElapsedMilliseconds)
        }
    } catch {
        Write-Host "  ICON    check failed: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }

    try {
        # The GUI never reaches the code above - it splashes and scans on a
        # runspace - and that path fails in its own ways.
        $sp = New-WDSplash -Profile $profileInfo -Quiet
        & $sp.Status 'Self test' 'Checking the startup path'
        # Through the shared state, never off the element: the window is on
        # another runspace and touching it from here throws.
        $x0 = [double]$sp.State.Shift
        $spin = [Diagnostics.Stopwatch]::StartNew()
        while ($spin.ElapsedMilliseconds -lt 600) { Start-Sleep -Milliseconds 20 }
        $animating = ([double]$sp.State.Shift -ne $x0)
        if ($sp.State.Error) {
            Write-Host "  STARTUP splash failed to open: $($sp.State.Error)" -ForegroundColor Red
            $failures++
        }

        $boot = Start-WDStartupScan -ModulePath $modulePath -ManifestPath $manifest -Splash $sp -NoScan:$NoScan
        $bootOk = @($boot.Categories).Count -gt 0 -and -not $boot.Error
        $sawText = [string]$sp.State.Text
        & $sp.Close

        if ($animating -and $bootOk) {
            Write-Host "  OK      startup    splash animates, scan runs off-thread, $(@($boot.Categories).Count) categories back"
        } else {
            Write-Host "  STARTUP path wrong: animating=$animating categories=$(@($boot.Categories).Count) error=$($boot.Error)" -ForegroundColor Red
            $failures++
        }
        if (-not $sawText) {
            Write-Host '  STARTUP splash never showed a status line' -ForegroundColor Red
            $failures++
        }
        $null = Initialize-WDSession -Root $LogRoot -Preview
        # Timed because this is the stretch that blocks the dispatcher: while it
        # runs the splash cannot animate and the whole thing reads as frozen.
        $buildSw = [Diagnostics.Stopwatch]::StartNew()
        $again = Show-WDWindow -Categories $categories -Session (Get-WDSession) -Profile $profileInfo `
                               -ModulePath $modulePath -ManifestPath $manifest -Scan $scan -Presence $presence -SelfTestSeconds 3 `
                               -Theme 'dark'
        Write-Host ("  build + 3s interaction pass: {0:n1}s" -f ($buildSw.Elapsed.TotalSeconds))

        # Show-WDWindow must return nothing. Worth asserting rather than
        # ignoring - it caught $win.Activate()'s boolean escaping as a return
        # value.
        if ($null -ne $again) {
            Write-Host "  THEME the window returned $(@($again).Count) object(s) instead of nothing:" -ForegroundColor Red
            foreach ($o in @($again)) {
                Write-Host "    $(if ($null -eq $o) { '<null>' } else { "[$($o.GetType().Name)] $o" })" -ForegroundColor Red
            }
            $failures++
        }
        $uiFails = Get-WDSelfTestFailures
        if ($uiFails -gt 0) {
            Write-Host "  GUI rendered but $uiFails interaction(s) failed" -ForegroundColor Red
            $failures += $uiFails
        } else {
            Write-Host '  GUI rendered, every interaction clean' -ForegroundColor Green
        }
    } catch {
        Write-Host "  GUI FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
        $failures++
    }

    Write-Host ''
    if ($failures) { Write-Host "Self test finished with $failures problem(s)." -ForegroundColor Red; exit 3 }
    Write-Host 'Self test passed. The toolkit is ready to run on this machine.' -ForegroundColor Green
    exit 0
}

if ($ExportUnattend) {
    $sel     = Resolve-Selection
    $wanted  = New-WDStringSet $sel
    $unItems = @()
    foreach ($c in $categories) {
        foreach ($i in @($c.items)) { if ($wanted.Contains([string]$i.id)) { $unItems += $i } }
    }

    $opt = New-WDUnattendOptions
    if ($UnattendAccount)  { $opt.AccountName  = $UnattendAccount }
    if ($UnattendComputer) { $opt.ComputerName = $UnattendComputer }
    if ($UnattendLocale)   {
        $opt.UILanguage = $UnattendLocale; $opt.SystemLocale = $UnattendLocale; $opt.UserLocale = $UnattendLocale
    }
    # Disks stay untouched from the command line, with no switch to change that:
    # a flag that silently wipes disk 0 on whatever machine the medium is booted
    # on is not a flag.
    $opt.DiskLayout = 'none'

    $result = Export-WDUnattend -Path $ExportUnattend -Options $opt -Items $unItems
    if ($result.Status -eq 'Failed') {
        Write-Host $result.Message -ForegroundColor Red
        Write-Host "  $($result.Detail)" -ForegroundColor Red
        exit 2
    }

    $payload = Get-WDUnattendPayload -Items $unItems
    Write-Host $result.Message -ForegroundColor Green
    Write-Host "  from $($sel.Count) selected item(s):" -ForegroundColor Gray
    Write-Host "    $(@($payload.Registry).Count) registry value(s) inlined into the specialize pass" -ForegroundColor Gray
    Write-Host "    $(@($payload.Appx).Count) app(s) deprovisioned before any account exists" -ForegroundColor Gray
    Write-Host '  answers Setup with: a local account (which is what skips the Microsoft account),' -ForegroundColor Gray
    Write-Host '    no network requirement, the TPM/Secure Boot/RAM checks bypassed, data collection off' -ForegroundColor Gray
    Write-Host '  disks are left alone, so Setup still asks where to install' -ForegroundColor Gray

    if (@($payload.Skipped).Count) {
        Write-Host "`n  $(@($payload.Skipped).Count) selected item(s) could NOT be carried:" -ForegroundColor Yellow
        foreach ($s in @($payload.Skipped | Select-Object -First 12)) {
            Write-Host "    $($s.Name) - $($s.Why)" -ForegroundColor Yellow
        }
        if (@($payload.Skipped).Count -gt 12) {
            Write-Host "    ...and $(@($payload.Skipped).Count - 12) more" -ForegroundColor Yellow
        }
        Write-Host '  Run the toolkit normally after the install to pick those up.' -ForegroundColor Yellow
    }
    Write-Host "`n  Put this file at the root of your installation medium, named autounattend.xml." -ForegroundColor Gray
    exit 0
}

if ($Console) {
    if (-not $Preview -and -not $Apply) {
        Write-Host 'Console mode needs either -Preview or -Apply.' -ForegroundColor Red
        exit 1
    }

    $selected = Resolve-Selection
    $session  = Initialize-WDSession -Root $LogRoot -Preview:$Preview
    $plan     = Resolve-WDPlan -Categories $categories -Selected $selected -Profile $profileInfo

    Write-Host "$(@($plan).Count) of $($selected.Count) selected items apply to this machine." -ForegroundColor Gray

    # Already in the log by now, but the console is where somebody running this
    # is looking.
    try {
        $impact = @(Get-WDHealthImpact -Plan $plan -Health (Test-WDToolHealth -Refresh -Deep) |
                    Where-Object { $_.Health.State -ne 'Ok' -and ($_.Count -gt 0 -or $_.Health.Safety) })
        if ($impact.Count) {
            Write-Host ''
            Write-Host '  Before this runs, some things it depends on:' -ForegroundColor Yellow
            Write-Host (Format-WDToolHealthText -Impact $impact) -ForegroundColor Yellow
            Write-Host ''
        }
    } catch {
        Write-Host "  The tool check could not run: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $restorePointState = ''
    if ($Apply) {
        Write-Host 'Creating a system restore point before making changes...' -ForegroundColor Yellow
        # Reported, not swallowed. System Protection is off on most consumer
        # images, so this fails often enough that a silent skip would leave the
        # promise broken.
        $rp = New-WDRestorePoint
        if ([string]$rp.Status -eq 'Changed') {
            Write-Host '  Restore point created.' -ForegroundColor Green
            $restorePointState = 'ok'
        } else {
            Write-Host "  NO restore point: $($rp.Message). The rollback script is the only way back." -ForegroundColor Yellow
            $restorePointState = 'failed'
        }
    }

    $results = Invoke-WDPlan -Plan $plan -Session $session -Profile $profileInfo `
                             -AllowDownloads:$allowDl -AllowOwnership:$takeOwn -Progress {
        param($p)
        if ($p.Phase -eq 'Item' -and $p.Item) {
            Write-Progress -Activity $(if ($Preview) { 'Previewing' } else { 'Applying' }) `
                           -Status "$($p.Index)/$($p.Total)  $($p.Item.Name)" `
                           -PercentComplete ([Math]::Min(100, ($p.Index / [Math]::Max(1, $p.Total)) * 100))
        }
    }
    Write-Progress -Activity 'Done' -Completed

    # No Export-WDUndoScript here: the rollback script is written by the
    # rollback-script plan item, so it is previewable.
    $report = Export-WDReport -Results $results -Session $session -Profile $profileInfo -PresetName $Preset
    # Only on an apply. A file called "what this run did" describing a preview
    # is the sort of thing somebody finds three weeks later and believes.
    if (-not $Preview) { $null = Export-WDRunNotes -Items $plan -PresetName $Preset }

    # Counted off the results rather than the plan, so an item that changed
    # nothing does not ask for a restart.
    $needRestart = 0
    if (-not $Preview) {
        $byId = @{}
        foreach ($p in @($plan)) { $byId[[string]$p.Id] = $p }
        foreach ($r in @($results)) {
            if ([string]$r.Status -notin @('Removed','Changed','Partial')) { continue }
            $pi = $byId[[string]$r.Id]
            if ($pi -and [bool]$pi.Reboot) { $needRestart++ }
        }
    }

    # Same copy the GUI makes: the run directory is under ProgramData and nobody
    # finds it. Last, because it copies what the lines above wrote.
    if (-not $Preview -and $SetupRun) {
        $null = Export-WDSetupResult -Session $session -Report $report -Label $Preset `
                                     -RestartCount $needRestart -RestorePoint $restorePointState
    }
    $keep = $null
    if (-not $Preview) { $keep = Export-WDRunFolder -Session $session -Public:$SetupRun }
    # Written twice on a setup run, and the second is the one that counts: the
    # first had nowhere to record where the desktop copy landed.
    if (-not $Preview -and $SetupRun) {
        $null = Export-WDSetupResult -Session $session -Report $report -Label $Preset `
                                     -KeepDir $(if ($keep) { [string]$keep.Path } else { '' }) `
                                     -RestartCount $needRestart -RestorePoint $restorePointState
        # Last of all, and allowed to fail: everything above is the promise,
        # this is the convenience on top of it.
        $null = Register-WDSetupPrompt -RunDir ([string]$session.RunDir) `
                                       -ScriptPath $MyInvocation.MyCommand.Path
    }

    Write-Host ''
    Write-Host '  Summary' -ForegroundColor Cyan
    foreach ($k in $report.counts.Keys) { Write-Host ("    {0,-12} {1}" -f $k, $report.counts[$k]) }
    Write-Host ''
    Write-Host "  Log, report and rollback script: $($session.RunDir)" -ForegroundColor Gray
    if (-not $Preview) { Write-Host "  What each change was, and where to change it back: $($session.NotesFile)" -ForegroundColor Gray }
    if ($keep) { Write-Host "  A copy of all of it is on the desktop: $($keep.Path)" -ForegroundColor Gray }
    if ($session.RebootNeeded) { Write-Host '  A restart is required to finish.' -ForegroundColor Yellow }

    exit $(if ($report.counts.failed -gt 0) { 2 } else { 0 })
}

# Before the first window of any kind - the theme chooser is one - because a
# taskbar button keeps whatever identity it was created with.
Set-WDTaskbarIdentity

# Asked once, before anything is drawn: every window after this is built in the
# answer, and there is no restyling them afterwards.
$uiState = Get-WDUiState
if (-not [string]$uiState.theme) {
    $picked = Show-WDThemeChooser
    if ($picked) {
        $uiState.theme = $picked
        $null = Save-WDUiState -State $uiState
    }
}

# Up before anything slow, so a window is on screen a moment after the launcher
# exits rather than after the scan. No -Profile: that is six CIM queries.
$splash = New-WDSplash

$startup    = Wait-WDStartupScan -Job $scanJob -Splash $splash
$categories = $startup.Categories
$scan       = $startup.Scan
$presence   = $startup.Presence

# Seeded into this runspace's cache, not just assigned: half the module surface
# takes -Profile optionally and reads it for itself when absent.
$profileInfo = Import-WDSystemProfile -Profile $startup.Profile
if (-not $profileInfo) { $profileInfo = Get-WDSystemProfile }

if ($startup.Error) {
    & $splash.Status 'The scan could not finish' 'Continuing with the curated list only'
    Write-WDLog "Startup scan failed: $($startup.Error)" -Level Warn
}

& $splash.Status 'Preparing the session' 'Log folder and rollback journal'
# -QuickEnvironment on the GUI path only. This session exists to own a log
# folder while the window is open; a preview or an apply builds its own.
$null = Initialize-WDSession -Root $LogRoot -Preview -QuickEnvironment:$isGui

$pre = $null
if ($ProfilePath -or $Select) { $pre = Resolve-Selection }

# One call, one window, one build. Colours are keyed theme resources, so a theme
# switch repaints the open window rather than returning here to be rebuilt.
$null = Show-WDWindow -Categories $categories -Session (Get-WDSession) -Profile $profileInfo `
                      -ModulePath $modulePath -ManifestPath $manifest -Scan $scan -Presence $presence `
                      -PreSelected $pre -ShowRun $ShowRun `
                      -Splash $splash -Theme ([string]$uiState.theme) -UiState (Get-WDUiState)
