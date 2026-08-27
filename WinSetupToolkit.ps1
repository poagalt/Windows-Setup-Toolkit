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
# still decides it, including -TakeOwnership:$false to hold a hard preset back.
$takeOwn    = if ($PSBoundParameters.ContainsKey('TakeOwnership')) { [bool]$TakeOwnership }
              else { $Preset -in @('Aggressive', 'Extreme') }

function Hide-WDConsoleWindow {
    <#
        Hides this process's console. -WindowStyle Hidden on the launcher covers
        the normal route in, but the script is also started by hand, from a
        shortcut and from the scheduled-task guards, and any of those can arrive
        with a visible console. Doing it here means there is one answer rather
        than one per launcher.

        Best effort on purpose: no console at all (hidden already, or hosted
        somewhere without one) is the desired end state, not a failure.
    #>
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
    <#
        The other half, for the one case that needs it: the GUI hides its console
        immediately, and then something refuses to start. A refusal printed into a
        hidden console is a launch that appears to do nothing at all.

        Same best-effort rule. Hide-WDConsoleWindow has already compiled the type
        on every path that could have hidden one.
    #>
    try {
        if (-not ('WD.ConsoleWindow' -as [type])) { return }
        $h = [WD.ConsoleWindow]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) { $null = [WD.ConsoleWindow]::ShowWindow($h, 5) }   # SW_SHOW
    } catch { }
}

# Every other mode writes its output to the console and needs it. The GUI does
# not: its startup chatter was the only thing on that screen, and the window it
# belongs to has a splash of its own to say the same things.
$isGui = -not ($ListItems -or $SelfTest -or $ExportUnattend -or $Console -or $SetupResult)

# ------------------------------------------------------------- elevation ---
#
# Do NOT hide the console here. A UAC prompt over an empty screen gives no clue
# what raised it; the launcher keeps its console until the prompt is answered.
# The console to hide is the one the GUI runs in afterwards - see below.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
               [Security.Principal.WindowsBuiltInRole]::Administrator)

# These four change nothing, so no UAC prompt. -SetupResult especially: it is
# started by a RunOnce entry at somebody's first sign-in, and a prompt nobody
# asked for cannot even be answered on a standard account. If they open the full
# interface from it, THAT relaunch elevates - when they asked for it.
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
        # To the console, which is still on screen at this point - this path is
        # only reached when the script was started directly rather than through
        # the launcher, and that means somebody is looking at a prompt.
        Write-Host 'Elevation was canceled or refused. Nothing has been changed.' -ForegroundColor Red
        exit 1
    }
    exit 0
}

# --------------------------------------------------------------- modules ---
# Order matters: WD.Persist registers handlers into WD.Custom's table,
# WD.Discover reads Get-Prop from WD.Actions, and WD.Preflight reads it too.
foreach ($m in @('WD.Core', 'WD.Detect', 'WD.Actions', 'WD.Preflight', 'WD.Custom', 'WD.Persist', 'WD.Discover', 'WD.Revert', 'WD.Engine', 'WD.Unattend')) {
    Import-Module (Join-Path $modulePath "$m.psm1") -Force -DisableNameChecking
    # As soon as WD.Core is in, and not a line later: this starts the one csc
    # invocation the launch cannot avoid on a runspace of its own, and the nine
    # imports below are what it runs behind. It costs this thread about 40 ms
    # and saves it 400. See the native note at the top of WD.Core.psm1.
    if ($m -eq 'WD.Core') { Start-WDNative }
}

# The build gate, off [Environment] rather than off the machine profile.
# Reading the profile is six CIM queries and about a second - the first CIM
# call in a process is most of it - and on the GUI path that second used to be
# spent with nothing whatever on screen. It happens behind the splash now, so
# the one fact needed before then comes from the cheapest source there is.
$hostBuild = [int][Environment]::OSVersion.Version.Build
if ($hostBuild -lt 19041) {
    Write-Host "This toolkit targets Windows 10 2004 (build 19041) and newer. Detected build $hostBuild." -ForegroundColor Red
    exit 1
}

# Every path but the GUI reads the profile here, where a console is what the
# operator is looking at and there is nothing to put on screen first. The GUI
# reads it below, behind its splash.
$profileInfo = $null
if (-not $isGui) { $profileInfo = Get-WDSystemProfile }
if ($PSVersionTable.PSVersion.Major -ge 6) {
    Write-Host 'Run this under Windows PowerShell 5.1, not PowerShell 7 - the Appx and DISM cmdlets misbehave under 7.' -ForegroundColor Red
    exit 1
}

# After the elevation check (see above), and before the WD.UI import so a
# hand-run does not show a console for the third of a second that takes.
if ($isGui) { Hide-WDConsoleWindow }

# --------------------------------------------------------- one at a time ---
#
# Two copies applying at once makes both journals wrong: each reads the other's
# changes as its own "previous value". Checked before the scan and the window so
# the refusal is all that appears.
#
# EXEMPT: -SetupResult (a RunOnce window at first sign-in, must never error) and
# -SelfTest (changes nothing, and is run while a second copy is open on
# purpose). -ShowRun is NOT exempt - it opens the window that can apply.
if (-not $SetupResult -and -not $SelfTest) {
    $instance = Enter-WDSingleInstance -Mode $(if ($isGui) { 'window' } else { 'console' })
    if (-not $instance.Ok) {
        $refusal = Get-WDSingleInstanceMessage -Holder $instance.Holder -Me 'The toolkit'
        if ($isGui) {
            # No theme has been published this early and there is no window to
            # own the dialog, so this is the one place the real MessageBox is
            # still the right answer - see Show-WDMessage's own fallback.
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

# ------------------------------------------------------- the GUI's long pole ---
#
# Started as early as possible, waited for at the bottom of this file. Its first
# 1.4s is its own module imports - work nobody is waiting on - so it runs behind
# the WPF load, the icon, and the settings file. WD.UI is imported here only
# because Start-WDStartupScan lives in it, and gated so no console path pays
# 340 ms for a module it never uses.
$scanJob = $null
if ($isGui) {
    Import-Module (Join-Path $modulePath 'WD.UI.psm1') -Force -DisableNameChecking
    $scanJob = Start-WDStartupScan -ModulePath $modulePath -ManifestPath $manifest `
                                   -NoScan:$NoScan -Async
}

# ------------------------------------------------- the first sign-in prompt ---
#
# Before the scan: this is a folder read and a window, with no use for an
# inventory. Best effort throughout - it was started by a RunOnce entry nobody
# asked for, the run is long over, and its report is already on the desktop. So
# every failure below exits 0 in silence.
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

# ---------------------------------------------------------- runtime scan ---
# The curated manifest cannot know what a given model ships with. This finds
# the rest, classified against the protection list in WD.Discover.
#
# Console paths scan synchronously; the GUI does it on a runspace behind the
# splash so the window appears at once.
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

# --------------------------------------------------------------- listing ---
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

# ------------------------------------------------------- selection source ---
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

# ------------------------------------------------------------- self test ---
if ($SelfTest) {
    Write-Host 'Self test - nothing on this machine will be changed.' -ForegroundColor Yellow
    $failures = 0

    Write-Host "`n[1] Manifest and scan" -ForegroundColor Cyan
    $itemCount = ($categories | ForEach-Object { @($_.items).Count } | Measure-Object -Sum).Sum
    Write-Host "  $($categories.Count) categories, $itemCount items"

    # A pattern that matches everything marks every installed program as
    # already-covered, and the scan then finds nothing and says so quietly -
    # which reads like a clean machine rather than a broken scan. That is
    # exactly how it got missed, so assert it rather than trusting the filter.
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
    # The plan is the selection plus the two steps the operator does not tick.
    # Counted apart so the line below still says how much of the manifest
    # applies here rather than that plus two.
    $autoSteps = @('close-resurrection', 'restart-explorer')
    $auto  = @($probe | Where-Object { [string]$_.Id -in $autoSteps })
    $probe = @($probe | Where-Object { [string]$_.Id -notin $autoSteps })
    Write-Host "  $(@($probe).Count) of $($allIds.Count) items apply here"
    # Leave no trace: a run that removes anything closes the paths that bring it
    # back and restarts the shell, whether or not anybody remembered to ask. If
    # this ever stops appending them the failure is silent - the run just
    # quietly stops finishing the job - so it is asserted rather than watched.
    foreach ($want in $autoSteps) {
        if (@($auto | Where-Object { [string]$_.Id -eq $want }).Count -ne 1) {
            Write-Host "  PLAN    '$want' was not appended to the plan" -ForegroundColor Red; $failures++
        }
    }
    # And they are last, after the items whose work they are finishing.
    $tail = @($probe | Where-Object { $_.Order -ge 9998 })
    if ($tail.Count) { Write-Host "  PLAN    a manifest item claims the closing orders" -ForegroundColor Red; $failures++ }
    if (@(Resolve-WDPlan -Categories $categories -Selected @('nothing-matches-this') -Profile $profileInfo).Count) {
        Write-Host "  PLAN    an empty selection still produced a plan" -ForegroundColor Red; $failures++
    }
    Write-Host "  plus $(@($auto).Count) closing step(s) the run appends itself" -ForegroundColor DarkGray
    $dropped = @($allIds | Where-Object { $_ -notin @($probe.Id) })
    if ($dropped.Count -and $dropped.Count -le 12) { Write-Host "  filtered out by guards: $($dropped -join ', ')" -ForegroundColor DarkGray }

    # An item whose every appx target is NonRemovable can only ever report
    # "Blocked, in-box", so the list does not offer it. Named rather than
    # counted: which ones those are is edition- and build-specific.
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
    # a missing rating or a miscategorized item. These two categories are exempt:
    # Recurring re-applies the selection, and Windows Update is scheduling
    # policy - neither is a degree of bloat. (wu-off is rated 6 by hand.)
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
    # A band with nothing in it is a band nobody can find, and 6 is the one that
    # has to be authored item by item rather than falling out of a default.
    if (-not [int]$bloatCount[6]) {
        Write-Host "  BLOAT no item is rated 6, so the Not recommended band never appears" -ForegroundColor Red; $failures++
    }

    # What each item does to the machine, and what it might explain afterwards.
    # The mechanics are generated from the actions, so the check is that every
    # item that acts produces a line - an item whose actions say nothing
    # readable is one the detail dialog opens on an empty page.
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
                # cannot find my camera", they type "camera not working". So all
                # this can check is that a phrase exists and is not the item's
                # own prose pasted across - which a sentence-length line is.
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
    # Nobody types the phrase that was authored, so what matters is that the
    # OTHER spellings are generated - and that is invisible by inspection: the
    # lookup file looks complete either way, right up until somebody searches
    # it with a contraction and gets nothing.
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
    # A debloat preset that quietly installs something is the single worst thing
    # this could do, so it is checked rather than trusted to the tiers. Judged on
    # what an item *does*, not which section it sits in - the Add section also
    # holds settings tweaks, and those are allowed in presets.
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
    # Every handler also needs a sentence saying what it touches and where that
    # lives. The detail dialog falls back to the function name otherwise, and
    # "Runs the ClearDeliveryOptimization step" is exactly the line this
    # replaced - it names a function to somebody who wanted a place.
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
    # later, after a feature update. Generate it and drive it through all three
    # states here rather than finding out then.
    $gp = Join-Path $env:TEMP "wd-selftest-guard-$PID"
    try {
        $null = New-Item -ItemType Directory -Path $gp -Force
        # Real paths so the shape is the one that ships, but pointed at a
        # scratch folder with a do-nothing entry script, so the runners take
        # every branch - including the one that writes the notice marker -
        # without applying anything to this machine.
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
        # a toast at every single sign-in.
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
            # signed-in user. Without it the guards run completely silently.
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

    # The leftover sweep and the extension removals are the only things here
    # that touch the file system, and both are only defensible because they go
    # to the Recycle Bin. So prove the round trip rather than trusting it: the
    # restore below is exactly what Export-WDUndoScript writes into the rollback
    # script, run against a scratch folder.
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
    # PowerShell array literal the rollback script interpolates unquoted. Both
    # halves are checked here; the handler runs in preview so nothing moves.
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
    # which JSON hands back as a PSCustomObject rather than a hashtable. Also
    # asserts there is NO overrides property: unsaved edits are deliberately not
    # persisted, and a missing property reads as $null rather than erroring.
    # Driven against a scratch path - the real settings file is never touched.
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
        # failure, which is what every file this build writes looks like.
        if ((ConvertTo-WDPresetMap $back.overrides).Count) {
            $uiBad += 'a file with no overrides came back with edits'
        }
        # The applied record survives whole. The ids are the load-bearing half:
        # the marker is shown only while the preset still selects exactly them,
        # so an id list that came back short would hide every marker there is,
        # silently and for good.
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
        # to undo nothing, which is the same bug the in-memory path guards.
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
    # Two things act on InstallLocation - the leftover sweep deletes it, the
    # uninstall executor kills what runs inside it - and installers really do
    # write bare shared roots like C:\Program Files there. A wrong answer takes
    # out every program on the machine rather than one.
    try {
        $sweepBad = @()
        foreach ($shared in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
                              $env:SystemRoot, "$env:SystemDrive\", $env:USERPROFILE,
                              $env:LOCALAPPDATA, (Join-Path $env:ProgramFiles 'WindowsApps'), '', '   ')) {
            if ($null -ne (Test-WDSweepableRoot -Path $shared)) {
                $sweepBad += "'$shared' was accepted as one program's own folder"
            }
        }
        # And a real program folder is accepted, with quotes and a trailing slash
        # taken off - the caller acts on what comes back, not on what it passed.
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
    # A saved selection carries the run options that are a decision rather than
    # an item, and the one that has to survive exactly is the account list -
    # three-valued, where null is every account and an empty list is none. Those
    # two mean opposite things to the executor, and collapsing either into the
    # other is the bug this project has already had twice.
    try {
        $selDir = Join-Path $env:TEMP ("wd-sel-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $selDir -Force -ErrorAction SilentlyContinue
        $selBad = @()

        # 1. A file with no options block at all - which is every file written by
        #    an older build. It must read as "no opinion" rather than as a set of
        #    invented values, so the caller falls back to the mode's defaults.
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

        # 3. No accounts, written as [] and read back as an empty list - NOT as
        #    null, which would write to every hive on the machine.
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
    # PowerToys keeps undocumented per-user JSON, and this writes into it before
    # PowerToys may even be installed. Merging rather than replacing is the
    # whole safety property: someone's existing module settings must survive.
    # Driven against a scratch path - the real config is never touched by a test.
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

    # Which accounts a per-user setting reaches. The rule that matters is the
    # $null one: every caller that predates this choice - the command line, the
    # re-apply guards, a saved plan - passes nothing, and nothing has to keep
    # meaning "every account" or those callers would quietly start doing less.
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

        # And the executor honours it. Previewed, so nothing is written either way.
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

    # Presence decides whether a row is grayed out before anybody reads it, so a
    # test that says "not here" too easily hides something that is. The
    # three-valued rule is the whole of it: yes, no, and no opinion.
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
        # names is missing, and that is the case graying gets wrong if the rule
        # is "any action absent" rather than "every action absent, and none of
        # them a kind I cannot ask about".
        if ($null -ne $pr['p-mixed'].Present) { $prBad += 'a part-registry item claimed an opinion' }
        # The exclusion is honoured, so the size is the one program that matches.
        if ($pr['p-uninst'].Bytes -ne 5GB) { $prBad += "the excluded program was sized in: $($pr['p-uninst'].Bytes)" }
        # Store packages are counted, never sized: Windows does not publish it.
        if ($pr['p-appx-here'].Blind -ne 1) { $prBad += "a Store package was not counted as unsizeable" }
        if ($pr['p-appx-here'].Bytes -ne 0) { $prBad += 'a Store package was given a size' }

        # And against the real machine, where the rule that matters is that this
        # never claims something is absent that the scan found and offered.
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
    # read by a build of this toolkit that predates the list.
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
            # A file written before this was a list still installs what it names.
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

    # --- [x] Edge: is Windows even willing? --------------------------------
    # Windows refuses the Edge uninstall outside the EEA. Three pieces the fix
    # stands on: the policy file parses, the machine's region resolves to a
    # two-letter code, and IE is in the policy's enabled list.
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

    # The answer file generator. Nothing here writes to the machine - the whole
    # output is a file - so the test is about what the file says, and in one case
    # about what it must never say.
    try {
        $unBad = New-Object System.Collections.Generic.List[string]
        $opt   = New-WDUnattendOptions

        # The Standard shape, with a real plan behind it. Categories carry the
        # items; $manifest is the folder they were read from, and asking it for
        # .Items answers $null, which made an earlier version of this check pass
        # over nothing at all.
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
        # the specialize pass strands the mount and every later boot carries it.
        $loads   = ([regex]::Matches($xml, 'reg load ')).Count
        $unloads = ([regex]::Matches($xml, 'reg unload ')).Count
        if ($loads -ne $unloads) { $unBad.Add("the default user hive is loaded $loads time(s) and unloaded $unloads") }

        # Disks, from both directions. The default must produce no wipe, and
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

    # The storage clean-ups and the bar above them share one path table, and the
    # bar makes a claim about proportions that nothing else here would catch
    # being wrong. Everything below is read-only: previews measure and report.
    try {
        $dkBad = @()

        if ((Format-WDBytes 1610612736) -notmatch 'GB') { $dkBad += 'gigabytes are not reported in GB' }
        if ((Format-WDBytes 5242880)    -notmatch 'MB') { $dkBad += 'megabytes are not reported in MB' }

        # diskfull is still part of the guard vocabulary - nothing ships using
        # it now that the clean-ups are always offered, and it is the only guard
        # that compares against a threshold on a measured value, so it is the
        # only cover that branch has.
        $pFull  = $profileInfo.PSObject.Copy(); $pFull.DiskUsedPercent  = 85
        $pRoomy = $profileInfo.PSObject.Copy(); $pRoomy.DiskUsedPercent = 38
        $pEdge  = $profileInfo.PSObject.Copy(); $pEdge.DiskUsedPercent  = 70
        $pDead  = $profileInfo.PSObject.Copy(); $pDead.DiskUsedPercent  = 0
        if (-not (Test-WDGuard -Guards @('diskfull:70') -Profile $pFull))  { $dkBad += 'a full drive did not pass diskfull:70' }
        if (Test-WDGuard -Guards @('diskfull:70') -Profile $pRoomy)        { $dkBad += 'a roomy drive passed diskfull:70' }
        if (-not (Test-WDGuard -Guards @('diskfull:70') -Profile $pEdge))  { $dkBad += 'exactly 70% did not pass' }
        if (Test-WDGuard -Guards @('diskfull:70') -Profile $pDead)         { $dkBad += 'an unmeasurable drive passed' }

        # One table behind the row, the bar and the deletion. A clean-up missing
        # from it shows no size and is never drawn; an entry with no item is a
        # path nothing acts on.
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

        # The walk, against a folder whose size is known exactly. The junction is
        # the point of it: C:\Users\All Users is one to C:\ProgramData, so a walk
        # that follows them counts the same bytes twice and can loop.
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

        # The arithmetic behind the bar. Pure, so it can be checked exactly, and
        # it is the half that would misrepresent a proportion if it were wrong.
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
        # Nothing walked yet: one block for everything in use, never four at zero.
        $early = New-WDStorageSnapshot -Drive 'T:' -TotalBytes 1000GB -FreeBytes 600GB
        if ($early.Complete -or $early.Priced) { $dkBad += 'an unmeasured snapshot claimed to be finished' }
        if (@($early.Segments).Count -ne 1) { $dkBad += 'an unmeasured drive was drawn as a breakdown' }
        # A reclaimable total larger than the drive is in use would draw a bar
        # running backwards, so it is clamped rather than trusted.
        $silly = New-WDStorageSnapshot -Drive 'T:' -TotalBytes 100GB -FreeBytes 90GB -Items @{ 'x' = 50GB } -Priced
        if ($silly.Reclaimable -gt $silly.UsedBytes) { $dkBad += 'more was reclaimable than was in use' }

        # The cache is an optimization, so every doubt has to answer "walk it
        # again". A stale one silently draws last month's machine.
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
        # now rather than reports, so both have to honour preview like anything
        # else - and this is the only place they are exercised without an actual
        # run behind them, which is exactly the shape the self test needs.
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
        # while this runs. The point is to catch a preview that actually frees
        # gigabytes, not to measure the noise floor.
        if ([Math]::Abs($after - $before) -gt 1GB) { $dkBad += 'previewing the clean-ups changed the free space' }

        # The bin the row is sized from and the bin the handler empties are two
        # different questions, and both answers have to exist.
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

    # "Already set" grays an option out, so a test that says yes too easily hides
    # something that was never done. The negative cases are the ones that matter
    # and they hold on any machine; the positive one is built from what this
    # machine's own config says, which proves the comparison agrees with the
    # reader rather than that PowerToys happens to be set up a particular way.
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
                # A hotkey nobody would have set has to fail even when the module
                # itself is right - the chord is half the promise of the option.
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

    # Asserted on SHAPE, never on verdicts: which options are already done is a
    # fact about the machine. That every kind of action can be asked, and that a
    # guarded-out action is not asked, are facts about the code.
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
        # And with no profile there is nothing to evaluate a guard against, so it
        # has to be asked - which is the answer that never over-claims.
        if (Test-WDItemSatisfied -Item $itemGuarded -Inventory $satInv) {
            $satBad += 'a guard was skipped with no profile to evaluate it against'
        }
        # An item with no actions is not "already applied" - there is nothing to
        # have been done, and that word is a claim.
        if (Test-WDItemSatisfied -Item ([pscustomobject]@{ id = 'e'; actions = @() }) -Inventory $satInv -Profile $profileInfo) {
            $satBad += 'an item with no actions claimed to be already applied'
        }

        # Every handler named in the state-test table has to be a handler that
        # exists, or the entry is dead and the item it was written for silently
        # goes back to never answering.
        $handlerNames = @(Get-WDHandlerNames)
        foreach ($h in @(Get-WDStateTestNames)) {
            if ($handlerNames -notcontains $h) { $satBad += "the state test for '$h' names a handler that is not registered" }
        }
        # And the manifest's own handlers, so the split between "has a state
        # test" and "cannot have one" stays a decision somebody made rather than
        # a gap. Reported, never failed: most of them genuinely cannot.
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

    # The Revert page asks "is this task registered" three times before it can
    # open, and Get-ScheduledTask answers in about a second each. The COM path
    # that replaced it has to give the same answers, or the page quietly stops
    # offering to remove a guard that is really there.
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

    # HKU: is not a default PowerShell drive, and the rollback script cannot
    # import the helper that makes one - so without its own preamble every
    # per-account restore throws DriveNotFoundException under
    # -EA SilentlyContinue and the script prints "Rollback complete" having done
    # nothing. Then: which machine this is, since a run folder is portable and
    # reverting another machine's journal writes its values over this one's.
    try {
        $miBad = @()
        $mi = Get-WDMachineIdentity
        if (-not $mi.machineGuid) { $miBad += 'this machine has no readable MachineGuid, so no run can ever be attributed to it' }
        # Three-valued, and the third value is the one that matters: everything
        # written before identities existed answers "cannot say", and folding
        # that into either of the others either hides every historical run or
        # hands back the guarantee entirely.
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

            # The index lives at the ROOT, which is the whole feature: the run
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

    # Undoing several runs at once. The dedup rule has to cross runs for the
    # same reason it exists inside one journal, and getting it wrong does not
    # look like a failure: it replays the later entry over the restored value
    # and leaves the machine holding a number nobody ever chose, with a journal
    # saying it was returned to its original state.
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
            # March moved X from 1 to 0. June moved the same X from 0 to 2, and
            # touched a value of its own. Putting both back means X = 1, and
            # only March's entry knows that.
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

            # Reverting ONE run is a different question and must keep its own
            # previous value - a step superseded in the combined view still
            # belongs to the earlier run.
            $cpJune = @($cpRuns | Where-Object { $_.Id -eq '20260601-120000' })[0]
            $cpOwn  = @((Get-WDUndoPlan -Journal $cpJune.Journal).Steps | Where-Object { $_.Name -eq 'X' })
            if ($cpOwn.Count -ne 1 -or [int]$cpOwn[0].Previous -ne 0) {
                $cpBad += 'reverting one run on its own no longer uses that run''s own previous value'
            }

            # Every step carries the key both dedups are decided on, and one
            # definition answers for every method - the four that used to be
            # spelled inline and the nine that had none.
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
            # And one value the machine ALREADY holds, so one option comes out
            # fully already-back. Without it every option on the page reads
            # outstanding, and the whole inert-row half of the checks below -
            # struck through, dimmed, no hand, no hover, refusing a click - has
            # nothing to fire on. A check that cannot fire is a false pass.
            Set-ItemProperty -Path $ugKey -Name 'Same'  -Value 5 -Type DWord -Force
            @(
                (@{ item = 'a'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Restore'; kind = 'DWord'; previous = 1; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'b'; type = 'registry'; undo = @{ method = 'registry'; path = 'HKU:\WD_DEFAULT\SOFTWARE\WinSetupToolkitUndoGen'; name = 'V'; kind = 'DWord'; previous = 1; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                # Every method the journal can write needs a case, or the entry
                # is a promise nothing keeps. 'rename' had none for its whole
                # life, so a full rollback left Edge's updater parked.
                (@{ item = 'c'; type = 'file'; undo = @{ method = 'rename'; from = 'C:\Nope\Thing.wd-disabled'; to = 'C:\Nope\Thing' } } | ConvertTo-Json -Compress -Depth 6)
                # An apostrophe in a previous value used to end the script's
                # parse at that line, because the quoting was done at journal
                # time by a string concatenation that escaped nothing.
                (@{ item = 'd'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Quote'; kind = 'String'; previous = "O'Brien"; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                # And the shape an older build wrote: the value already rendered
                # as a PowerShell literal. Journals outlive builds, so both have
                # to come out as the same value.
                (@{ item = 'd'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Old'; kind = 'String'; previous = "'before'" } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'd'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Blob'; kind = 'Binary'; previous = '@(48,0,4)' } } | ConvertTo-Json -Compress -Depth 6)
                # A key's default value, which the provider cannot delete and
                # will not even bind an empty name for. The Game Bar item writes
                # three of these to stop Windows asking for an app to open the
                # ms-gamebar links it leaves behind, so the undo has to be a
                # promise the script can keep.
                (@{ item = 'd'; type = 'registry'; undo = @{ method = 'registry'; path = "$ugKey\shell\open\command"; name = '(default)'; kind = 'String'; previous = '__ABSENT__'; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                # Two options writing one value. Only the first knows what was
                # there before the run, so replaying both restores the original
                # and then puts the first option's value straight back over it.
                (@{ item = 'e'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Restore'; kind = 'DWord'; previous = 42; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                # Its one change is already back, so the option is - and the page
                # has a row that is there only to say there is nothing left to do.
                (@{ item = 'f'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Same'; kind = 'DWord'; previous = 5; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
            ) | Set-Content -LiteralPath $ugSession.JournalFile -Encoding UTF8

            # One item carries a description and one does not, so both halves of
            # the emitter run: the table has to contain the first and leave out
            # the second, and the window has to draw a row either way.
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
            # and the flags are what have to be asserted. The old check read the
            # text for 'reg.exe load', which is a line that is now always there.
            foreach ($need in @('New-PSDrive -PSProvider Registry -Name HKU',
                                'reg.exe load "HKU\WD_DEFAULT"',
                                'reg.exe unload "HKU\WD_DEFAULT"')) {
                if ($ugText -notmatch [regex]::Escape($need)) { $undoGenBad += "the script body is missing: $need" }
            }
            if ($ugText -notmatch '(?m)^\$global:WDWantsHku\s+=\s+\$true')  { $undoGenBad += 'a run with per-account writes did not set WantsHku' }
            if ($ugText -notmatch '(?m)^\$global:WDWantsDefault\s+=\s+1')   { $undoGenBad += 'a run with one default-profile write did not count it' }
            if ($ugText -notmatch "M='rename'")                      { $undoGenBad += 'the rename step did not reach the script' }
            # Every journallable undo method needs a case in the generator, or
            # the journal carries a promise no rollback keeps. BOTH sides are
            # harvested from source: an expected-list typed in here is the copy
            # that goes stale, and it did - regfile, uninstall, and
            # unregister-task all had none.
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
            # to be in balance - the same assertion the answer file makes.
            $ugLoad   = ([regex]::Matches($ugText, 'reg\.exe load')).Count
            $ugUnload = ([regex]::Matches($ugText, 'reg\.exe unload')).Count
            if ($ugLoad -ne $ugUnload) { $undoGenBad += "$ugLoad hive load(s) against $ugUnload unload(s)" }

            # The awkward values have to survive the trip as VALUES, whichever
            # shape the journal recorded them in.
            if (([regex]::Matches($ugText, "N='Restore'")).Count -ne 1) { $undoGenBad += 'a value written twice produced two restores, and only the first one knows the original' }
            if ($ugText -notmatch "N='Restore'[^\r\n]*V=1")             { $undoGenBad += 'the surviving duplicate is not the first entry' }
            if ($ugText -notmatch "V='O''Brien'")                       { $undoGenBad += 'an apostrophe in a previous value was not escaped' }
            if ($ugText -notmatch "V='before'")                         { $undoGenBad += 'an old-shape pre-quoted string did not unwrap to a value' }
            if ($ugText -notmatch "V=\[byte\[\]\]@\(48,0,4\)")          { $undoGenBad += 'an old-shape byte blob did not unwrap to a byte array' }

            # The window, built and never shown. ShowDialog blocks the
            # dispatcher with nobody to dismiss it, and a test that puts a
            # window on screen over whatever somebody is doing is its own bug.
            $ugAll = Join-Path $ugRoot 'all.ps1'
            (Get-Content -LiteralPath $ugPath | Where-Object { $_ -notmatch '^#Requires' }) |
                Set-Content -LiteralPath $ugAll -Encoding UTF8
            $ugWin = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $ugAll -BuildOnly 2>&1
            $ugWinText = (@($ugWin) | ForEach-Object { [string]$_ }) -join "`n"
            # Four ids survive deduplication, under two categories: the two the
            # -Items list names, and the two it does not, which fall back to
            # their raw id under 'Other'. Both halves are worth pinning - a
            # window that silently lost the unnamed ones would look tidier and
            # be offering less than the run did.
            if ($ugWinText -notmatch 'options=5\b')  { $undoGenBad += "the window did not group into 5 options: $ugWinText" }
            if ($ugWinText -notmatch 'groups=2\b')   { $undoGenBad += 'the window did not raise a category for the unnamed ids' }
            if ($ugWinText -notmatch 'rail=2\b')     { $undoGenBad += 'the index rail does not have a card per category' }
            if ($ugWinText -notmatch 'steps=8\b')    { $undoGenBad += 'the window is not showing all eight changes' }
            # One option fully already back, and it must be the only one locked -
            # a page that disabled more than that would be refusing work.
            if ($ugWinText -notmatch 'locked=1\b')   { $undoGenBad += 'the page does not have exactly one already-back option' }
            # Gone, because it was not there before the run - and named as the
            # default value rather than as an empty string, which is the only
            # spelling Get-ItemProperty answers to.
            if ($ugText -notmatch "N='\(default\)'[^\r\n]*Gone=\`$true") {
                $undoGenBad += 'a default value created by the run is not marked for deletion'
            }
            if ($ugWinText -notmatch 'tally=')       { $undoGenBad += 'the window footer says nothing about what the button would do' }
            if ($ugWinText -notmatch 'Awkward values|options=') { $undoGenBad += 'the window did not build at all' }
            if (@($ugWin | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count) {
                $undoGenBad += 'building the window wrote errors to the console'
            }

            # The page says which run it is about, at the top and on the title
            # bar. "Undo a WinSetupToolkit run" is true of every one of them.
            if ($ugWinText -notmatch 'title=Revert changes from Windows Setup Toolkit run \d{8}-\d{6} applied on ') {
                $undoGenBad += 'the window does not name the run it is about, and when it was applied'
            }
            if ($ugText -notmatch 'Content="Revert selected"') { $undoGenBad += 'the button does not say what it does' }
            # Only what has already been put back wears a tag. Still in place is
            # what every row on that page is unless it says otherwise.
            if ($ugWinText -notmatch 'mistagged=0\b') { $undoGenBad += 'a row that is still in place was given a marker saying so' }
            if ($ugWinText -notmatch 'tagged=[1-9]')  { $undoGenBad += 'nothing on the page is marked as already back, so the one tag that exists is unreachable' }
            # Every grouping and every sort laid out for real. One that nothing
            # exercises is one that throws the first time somebody picks it -
            # inside a handler, where WPF hands the exception to the dispatcher
            # and the process ends.
            foreach ($ugG in @('status', 'kind', 'alpha', 'category')) {
                if ($ugWinText -notmatch "group\[$ugG\] blocks=[1-9]") { $undoGenBad += "grouping the page by $ugG laid out nothing" }
            }
            if ($ugWinText -notmatch 'sorted=ok')      { $undoGenBad += 'one of the sort orders threw' }
            if ($ugWinText -notmatch 'switched=#FF')   { $undoGenBad += 'the theme button did not repaint the palette' }
            if ($ugWinText -notmatch 'boxes=[1-9]')    { $undoGenBad += 'the filter panel offers nothing to filter by' }
            # The page-wide Select all, pressed in both directions. One press
            # from a run that reverts nothing, so the label is checked as well
            # as the effect: it must clear the page and put back the same count.
            if ($ugWinText -notmatch 'selectall=.+?/(\d+) -> Select all/0 -> Select none/\1\b') {
                $undoGenBad += 'the page-wide Select all does not clear the page and take it back'
            }

            # The standalone window and the revert page are the same interface;
            # each check below is one place they had drifted. Driven for real
            # through -BuildOnly, because these handlers live inside closures and
            # firing the event is the only thing that finds one wired to nothing.
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
            # A row with nothing left to decide refuses the click, so it must not
            # invite one either: no hover tint and no hand.
            if ($ugWinText -notmatch 'deadhover=(\S+) -> \1 cursor=Arrow struck=True opacity=0\.6 notice=Collapsed') {
                $undoGenBad += 'an already-back row still answers the pointer, or does not say four ways that it is done'
            }
            if ($ugWinText -notmatch 'deadink=WdMuted') {
                $undoGenBad += "the marking pass repainted an already-back row's name"
            }
            if ($ugWinText -notmatch 'deadclick=False -> False') {
                $undoGenBad += 'clicking an already-back row ticked it'
            }
            # Descriptions start hidden (non-verbose is the default) but the
            # elements exist either way, or turning the option on would need the
            # page rebuilt.
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
            # Only the options the journal names, and only the ones that have one.
            if ($ugText -match "(?m)^\s+'e' = ") {
                $undoGenBad += 'an id no item named got a description entry'
            }
            # Refresh, because this page is a reading of the machine and somebody
            # may have put something back by hand since it opened. It rebuilds, so
            # what matters is that the page comes back whole and the rebuilt rows
            # are wired: a rebuild that half happened leaves rows in no column on
            # a page reporting itself finished.
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

            # Get-WindowsOptionalFeature -Online enumerates everything: 12s.
            # Win32_OptionalFeature is 1s for the same answer. A per-NAME DISM
            # call (377 ms) is the fallback for names that class lacks, so what
            # is banned here is the ENUMERATION, not the cmdlet.
            $ugDism = @([regex]::Matches($ugText, '(?m)^.*Get-WindowsOptionalFeature\s+-Online.*$') |
                        Where-Object { $_.Value -notmatch '-FeatureName' })
            if ($ugDism.Count) { $undoGenBad += 'the generated script still enumerates every Windows feature through DISM' }
            if ($ugText -notmatch 'Win32_OptionalFeature') { $undoGenBad += 'the generated script does not read feature state from the CIM class' }
            if (@([regex]::Matches($ugText, 'Start-WDFeatureRead')).Count -lt 3) {
                $undoGenBad += 'the feature table is not warmed ahead of both read paths'
            }
            # An icon is never worth failing a run over, so this is only asserted
            # where one could have been drawn - which is any run with the
            # interface loaded, and the self test is one.
            if (Get-Command Get-WDAppIconBytes -ErrorAction SilentlyContinue) {
                if ($ugWinText -notmatch 'icon=True') { $undoGenBad += 'the application icon was not embedded, so the window wears the host icon' }
                if ($ugText -notmatch '(?m)^\$global:WDIconDark = @\(') { $undoGenBad += 'no dark-palette icon reached the script' }
                if ($ugText -notmatch '(?m)^\$global:WDIconLight = @\(') { $undoGenBad += 'no light-palette icon reached the script' }

                # Trimmed to <=64px: the 128 and 256 frames are 130 KB of 158,
                # which is 173 KB of base64 in a file meant to be readable, and
                # nothing here draws either size. Every offset must still land
                # inside the file or a reader mis-measures the next frame.
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
            # whatever session state the dispatcher hands it, and a
            # script-scoped function is not findable from there. The symptom is
            # 400 "term not recognized" errors and a window that opens anyway
            # with every count at zero, which is worse than not opening.
            $ugFns = @([regex]::Matches($ugText, '(?m)^function\s+(global:)?([A-Za-z]+-[A-Za-z]+)'))
            foreach ($m in $ugFns) {
                if (-not $m.Groups[1].Value) { $undoGenBad += "$($m.Groups[2].Value) in the generated script is not global" }
            }
            if ($ugFns.Count -lt 15) { $undoGenBad += "only $($ugFns.Count) functions found in the generated script" }
            foreach ($v in @('WDSteps', 'WDReinstall', 'WDOwners', 'WDWantsHku', 'WDWantsDefault')) {
                if ($ugText -match "(?m)^\`$$v\s*=") { $undoGenBad += "`$$v is emitted script-scoped rather than global" }
            }

            # The launcher, because double-clicking a .ps1 opens a text editor
            # and no amount of instruction in the .ps1 changes that.
            $ugCmd = Join-Path (Split-Path $ugPath -Parent) 'Undo-WinSetupToolkit.cmd'
            if (-not (Test-Path -LiteralPath $ugCmd)) {
                $undoGenBad += 'no launcher was written beside the rollback script'
            } else {
                $cb = [IO.File]::ReadAllBytes($ugCmd)
                # cmd.exe does not strip a byte order mark: the first line then
                # reads as the command "<BOM>@echo", which fails, so echo stays
                # on and the whole file prints itself to the screen.
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
            # The two default values ride along here rather than in the richer
            # journal above because this is the one that gets executed, and the
            # whole question about them is whether the script can perform the
            # undo it promised - not whether it can write the line.
            @(
                (@{ item = 'x'; type = 'registry'; undo = @{ method = 'registry'; path = $ugKey; name = 'Restore'; kind = 'DWord'; previous = 1; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'x'; type = 'registry'; undo = @{ method = 'registry'; path = "$ugKey\shell\open\command"; name = '(default)'; kind = 'String'; previous = '__ABSENT__'; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'x'; type = 'registry'; undo = @{ method = 'registry'; path = "$ugKey\proto"; name = '(default)'; kind = 'String'; previous = 'URL:old'; raw = $true } } | ConvertTo-Json -Compress -Depth 6)
            ) | Set-Content -LiteralPath $ugSession.JournalFile -Encoding UTF8
            $ugPlainPath = Export-WDUndoScript
            $ugPlain = Get-Content -LiteralPath $ugPlainPath -Raw
            if ($ugPlain -notmatch '(?m)^\$global:WDWantsHku\s+=\s+\$false') { $undoGenBad += 'a run with no per-account writes still asked for the HKU drive' }
            if ($ugPlain -notmatch '(?m)^\$global:WDWantsDefault\s+=\s+0')   { $undoGenBad += 'a run with no default-profile writes still counted some' }

            # Then run it. #Requires -RunAsAdministrator is right for the real
            # thing and in the way here, so the body is exercised unelevated
            # against a key under HKCU.
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
            # '(default)' and .NET spells it '' - and an undo that quietly left
            # the stub in place would read as a clean rollback either way.
            $ugDef = (Get-Item -LiteralPath "$ugKey\shell\open\command").GetValue('')
            if ($null -ne $ugDef) { $undoGenBad += "a default value the run created survived the rollback as '$ugDef'" }
            $ugBack = (Get-Item -LiteralPath "$ugKey\proto").GetValue('')
            if ($ugBack -ne 'URL:old') { $undoGenBad += "a default value the run overwrote came back as '$ugBack' rather than URL:old" }
            # Twice, because a rollback somebody runs after a partial one must
            # not report work it did not do.
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

    # "Is this run still in place" is what stops the Revert page offering a
    # rollback that has already happened. It has to be driven against a journal
    # whose answers are known, because on a real one every count is a fact about
    # the machine and nothing can be asserted about it.
    try {
        $undoBad = @()
        $jRoot = Join-Path ([IO.Path]::GetTempPath()) ("wd-undo-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $jRoot -Force
        $probeKey = 'HKCU:\SOFTWARE\WinSetupToolkitSelfTest'
        try {
            $null = New-Item -Path $probeKey -Force
            # One value put back where it was, one still carrying what a run
            # wrote, and one under a hive that is not mounted and so cannot be
            # read at all - which is a third of a real journal and must not be
            # counted as either answer.
            Set-ItemProperty -Path $probeKey -Name 'Restored'  -Value 1 -Type DWord -Force
            Set-ItemProperty -Path $probeKey -Name 'StillSet'  -Value 0 -Type DWord -Force
            $jf = Join-Path $jRoot 'journal.jsonl'
            @(
                (@{ item = 'a'; type = 'registry'; undo = @{ method = 'registry'; path = $probeKey; name = 'Restored'; kind = 'DWord'; previous = 1 } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'b'; type = 'registry'; undo = @{ method = 'registry'; path = $probeKey; name = 'StillSet'; kind = 'DWord'; previous = 1 } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'c'; type = 'registry'; undo = @{ method = 'registry'; path = $probeKey; name = 'NeverWas'; kind = 'DWord'; previous = '__ABSENT__' } } | ConvertTo-Json -Compress -Depth 6)
                # A hive nothing will ever have mounted. Naming the real
                # WD_DEFAULT made this depend on whether a run had left it
                # mounted - a fact about the machine, not about the code.
                (@{ item = 'd'; type = 'registry'; undo = @{ method = 'registry'; path = 'HKU:\WD_SELFTEST_NEVER_MOUNTED\SOFTWARE\X'; name = 'V'; kind = 'DWord'; previous = 1 } } | ConvertTo-Json -Compress -Depth 6)
                (@{ item = 'e'; type = 'appx';     undo = @{ method = 'reinstall'; name = 'Some.Package' } } | ConvertTo-Json -Compress -Depth 6)
                # Written twice by two options. Only the first entry knows what
                # was there before the run, so this must not be counted twice
                # and must not be answered from the second one's 'previous'.
                (@{ item = 'f'; type = 'registry'; undo = @{ method = 'registry'; path = $probeKey; name = 'StillSet'; kind = 'DWord'; previous = 0 } } | ConvertTo-Json -Compress -Depth 6)
            ) | Set-Content -LiteralPath $jf -Encoding UTF8

            Clear-WDRegistryProbeCache
            $st = Get-WDUndoStatus -Journal $jf
            # Four: the duplicate is dropped, and a reinstall hint is not a step.
            # Nothing puts an uninstalled program back, so counting it as work
            # the rollback might still do was always wrong - it belongs to the
            # list under the page, not to the number above it.
            if ([int]$st.Total -ne 4)       { $undoBad += "counted $($st.Total) entries, not 4" }
            # Restored is back at its previous value, and NeverWas is absent -
            # which for a value the run created IS being back where it was.
            if ([int]$st.Done -ne 2)        { $undoBad += "$($st.Done) done, expected 2 (the restored value and the one that never existed)" }
            if ([int]$st.Outstanding -ne 1) { $undoBad += "$($st.Outstanding) outstanding, expected 1" }
            # The default-profile write, and only that.
            if ([int]$st.Unknown -ne 1)     { $undoBad += "$($st.Unknown) unknown, expected 1" }

            # And once the last one is put back, the run reads as fully undone -
            # which is the state that takes the row off the page.
            Set-ItemProperty -Path $probeKey -Name 'StillSet' -Value 1 -Type DWord -Force
            Clear-WDRegistryProbeCache
            $st2 = Get-WDUndoStatus -Journal $jf
            if ([int]$st2.Outstanding -ne 0) { $undoBad += "after restoring it, $($st2.Outstanding) still outstanding" }
            # A journal that is not there answers zero rather than throwing: the
            # page asks about every past run and some of them have no journal.
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

    # Last check in this section, and it has to stay last: Set-WDIrreversible
    # latches for the life of the process on purpose, so nothing after it can be
    # allowed to delete anything. Nothing below runs the engine, and
    # Clear-WDRecycleBin is deliberately never called here - it would empty the
    # operator's own Recycle Bin. Only its binding is checked.
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

    # The document written beside the rollback script, round-tripped rather
    # than read. It has one job that nothing else in the toolkit has - being
    # searchable weeks later by somebody who does not yet know this run is the
    # answer - so the check is that the symptoms are actually in it and that
    # they name the item that could cause them.
    $notesProbe = Join-Path ([IO.Path]::GetTempPath()) "wd-notes-$([Guid]::NewGuid().ToString('N')).md"
    try {
        # Plain assignment, never @(Resolve-WDPlan ...). It returns ,$plan so
        # that assigning it does not unroll, which means wrapping the call in
        # @() produces one element holding the whole list - the trap this
        # codebase has a section about, hit here first time.
        $notePlan = Resolve-WDPlan -Categories $categories -Selected @('svc-print','svc-wsearch','store') -Profile $profileInfo
        $null = Export-WDRunNotes -Items $notePlan -PresetName 'SelfTest' -Path $notesProbe
        if (-not (Test-Path -LiteralPath $notesProbe)) {
            Write-Host '  NOTES  the run notes were not written' -ForegroundColor Red; $failures++
        } else {
            $body = Get-Content -LiteralPath $notesProbe -Raw
            foreach ($want in @('# What this run did', '## What changed, option by option',
                                '#### Print Spooler', 'services.msc', '**Undo just this:**',
                                '| What was touched | How many |',
                                # The narrowest way back has to be the first one
                                # offered. Somebody with one thing broken should
                                # not read past two paragraphs to learn they can
                                # untick the rest and press Revert.
                                'Revert past changes', 'only that option goes back',
                                # And every option is ruled off from the next.
                                '> **Why it matters.**')) {
                if ($body -notmatch [regex]::Escape($want)) {
                    Write-Host "  NOTES  the run notes never mention '$want'" -ForegroundColor Red; $failures++
                }
            }
            # Registry paths carry backslashes and wildcards, and markdown eats
            # both unless they are in a code span. Every generated change line
            # has to be one, or the document about paths mangles paths.
            foreach ($l in ($body -split "`r?`n")) {
                if ($l -notmatch '^- \*\*(Registry|Scheduled task|File|Shortcut)\*\*') { continue }
                if ($l -notmatch ' - `.+`$') {
                    Write-Host "  NOTES  a path line is not in a code span: $l" -ForegroundColor Red; $failures++
                    break
                }
            }
            # An item with no Settings page must still say something better than
            # "undo the run" - that was the whole complaint. Every option gets a
            # line, and none of them is empty.
            $undoLines = @(($body -split "`r?`n") | Where-Object { $_ -like '**Undo just this:*' })
            $heads     = @(($body -split "`r?`n") | Where-Object { $_ -like '#### *' })
            if ($undoLines.Count -ne $heads.Count) {
                Write-Host "  NOTES  $($heads.Count) option(s) but $($undoLines.Count) undo line(s)" -ForegroundColor Red; $failures++
            }
            # One rule per option, so a hundred and fifty of them read as a
            # hundred and fifty things rather than one column of text. A rule
            # is also the only separator markdown has that survives being read
            # as plain text, which half of these will be.
            $rules = @(($body -split "`r?`n") | Where-Object { $_ -eq '---' })
            if ($rules.Count -ne $heads.Count) {
                Write-Host "  NOTES  $($heads.Count) option(s) but $($rules.Count) dividing rule(s)" -ForegroundColor Red; $failures++
            }
            # -Path has to work with no session, so the run id and rollback path
            # are parameters rather than reads off $script:Session. The rollback
            # line asks the FILE, not the path - that row can be unticked.
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

        # And the other document: the lookup table somebody opens a fortnight
        # later. Written by a handler rather than by the engine, so it is driven
        # the way a run drives it - with a real context and a real plan.
        $issDir = Join-Path ([IO.Path]::GetTempPath()) "wd-iss-$([Guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $issDir -Force
        # The session names the file now, rather than a run option naming the
        # folder. One path, known to the handler that writes it and to the copy
        # step that puts it on the desktop.
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
            # The phrases have to sit above the undo steps for their own item, so
            # a search lands on the problem and reads the fix underneath it.
            if ($ib.IndexOf('cannot print') -gt $ib.IndexOf('HOW TO PUT THIS BACK', $ib.IndexOf('PRINT SPOOLER'))) {
                Write-Host '  ISSUES the undo steps come before the phrases they belong to' -ForegroundColor Red; $failures++
            }
            # Generated spellings, not just what was authored. A lookup file
            # that only answers the phrase somebody else chose is the defect
            # this expansion exists for, and it is invisible without a check:
            # the file looks complete either way.
            foreach ($want in @("can't print", 'cant print', 'printing broken', 'no printer')) {
                if ($ib -notmatch [regex]::Escape($want)) {
                    Write-Host "  ISSUES the lookup file has no generated spelling for '$want'" -ForegroundColor Red; $failures++
                }
            }
            # More than one route, numbered, and the last one is the whole run.
            # A single "TO UNDO:" line was what this replaced.
            $optCount = ([regex]::Matches($ib, '(?m)^\s+Option \d+ - ')).Count
            if ($optCount -lt 6) {
                Write-Host "  ISSUES only $optCount numbered revert route(s) across the whole file" -ForegroundColor Red; $failures++
            }
            $phraseCount = ([regex]::Matches($ib, '(?m)^  [a-z]')).Count
            Write-Host "  lookup file  : $([Math]::Round((Get-Item $issFile).Length / 1KB, 1)) KB for a 3-item plan, $phraseCount lookup phrase(s), $optCount numbered route(s)"
        }

        # And the copy that lands on the desktop after every apply. Driven with
        # a temporary desktop rather than the real one: a self test that leaves
        # "WinSetupToolkit apply ..." on somebody's desktop, describing a run that
        # never happened, is exactly the kind of artefact this whole feature
        # exists to make trustworthy.
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
            # the two come from the same function so they cannot disagree. Named
            # here because a preview promising the desktop and an apply writing
            # to ProgramData was exactly the defect.
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
        # ---- the run with no interface --------------------------------------
        #
        # SetupComplete.cmd runs in session 0 with nothing to draw on, so the run
        # page's whole content has to reach whoever signs in later through two
        # files and a prompt. All three are driven here.
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
        # The report the engine would have written. Read-WDSetupResult reads it
        # back from disk, so it has to be there rather than only in hand.
        $fakeReport | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fakeSession.ReportFile -Encoding UTF8
        $sumPath = Export-WDSetupResult -Session $fakeSession -Report $fakeReport -Label 'Balanced' `
                                        -KeepDir $deskDir -RestartCount 2 -RestorePoint 'failed'
        if (-not $sumPath -or -not (Test-Path -LiteralPath $sumPath)) {
            Write-Host '  SETUP  the setup run wrote no summary at all' -ForegroundColor Red; $failures++
        } else {
            $sb2 = Get-Content -LiteralPath $sumPath -Raw
            # Everything the GUI would have said, and the per-item list it shows
            # on the run page. The failed item in particular: a summary that
            # quietly omits what went wrong is worse than no summary.
            foreach ($want in @('WHAT THE TOOLKIT DID DURING SETUP', 'WHAT TO DO NOW',
                                '2 changes need a restart', 'Stubborn thing', 'access denied',
                                'would NOT create a system restore point')) {
                if ($sb2 -notmatch [regex]::Escape($want)) {
                    Write-Host "  SETUP  the summary never says '$want'" -ForegroundColor Red; $failures++
                }
            }
            # And the machine-readable half, which is what puts the finished run
            # back on the real page at the first sign-in.
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
            # A preview must not be offered as a finished run. This is the one
            # state where showing somebody "here is what was done" would be
            # showing them a list of things that were not.
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
        # RunOnce entry pointing at a missing script is an error message from a
        # program the user has never heard of. Z:\ covers two refusals at once -
        # not there, and on a drive that will not be attached, which is the real
        # case since the toolkit is usually run from the medium.
        if (Register-WDSetupPrompt -RunDir $issDir -ScriptPath 'Z:\WinSetupToolkit\WinSetupToolkit.ps1') {
            Write-Host '  SETUP  the first sign-in prompt was registered for a script that will not be there' -ForegroundColor Red; $failures++
        }
        if (Register-WDSetupPrompt -RunDir (Join-Path $issDir 'nowhere') -ScriptPath $PSCommandPath) {
            Write-Host '  SETUP  the prompt was registered for a run folder that does not exist' -ForegroundColor Red; $failures++
        }
        # And it never writes to the real RunOnce key from a test. Asserted
        # rather than assumed: this is the one thing in the self test that could
        # leave something behind that runs on the next sign-in.
        try {
            $leftover = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' `
                                         -Name 'WinSetupToolkitSetupResult' -ErrorAction Stop
            if ($leftover) {
                Write-Host '  SETUP  the self test left a RunOnce entry behind' -ForegroundColor Red; $failures++
            }
        } catch { }

        # A preview leaves nothing. A folder full of rollback instructions for a
        # run that changed nothing is worse than no folder.
        $fakeSession.Preview = $true
        if (Export-WDRunFolder -Session $fakeSession -Desktop $deskDir) {
            Write-Host '  KEEP   a simulation left a run folder behind' -ForegroundColor Red; $failures++
        }
        # [IO.Directory]::Delete, not Remove-Item -Recurse: the cmdlet
        # enumerates and deletes in two passes and leaves the folder behind
        # often enough on a tree just written, with -EA SilentlyContinue hiding
        # it. A self test that litters %TEMP% is not trusted about tidiness.
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

    # The tool sweep. Everything here wraps something Windows provides, and when
    # one of those refuses, its dependent items fail one at a time - which reads
    # as thirty problems rather than one cause. Asserted on shape, not verdict:
    # that they all answer, fast, without throwing, and declare what they gate.
    $healthClock = [System.Diagnostics.Stopwatch]::StartNew()
    $health = Test-WDToolHealth -Refresh
    $healthClock.Stop()
    $hBad = @()
    if (-not @($health).Count) { $hBad += 'no checks ran at all' }
    foreach ($h in @($health)) {
        if ($h.State -notin @('Ok','Degraded','Unavailable','Unknown')) { $hBad += "$($h.Id) reported the invalid state '$($h.State)'" }
        # A check that says something is wrong and does not say what to do
        # about it is half an answer, and the half nobody can act on.
        if ($h.State -ne 'Ok' -and -not $h.Reason) { $hBad += "$($h.Id) is $($h.State) with no reason" }
        if ($h.State -eq 'Unavailable' -and -not $h.Fix -and -not $h.Safety) { $hBad += "$($h.Id) is Unavailable with no suggested fix" }
        # Anything that gates work has to say WHAT it gates, or the impact
        # mapping cannot connect it to a single item and it becomes a warning
        # about nothing in particular.
        if ($h.State -eq 'Unavailable' -and -not ($h.Affects.Count -or $h.Handlers.Count -or $h.Safety)) {
            $hBad += "$($h.Id) is Unavailable but declares neither Affects, Handlers, nor Safety"
        }
    }
    # Every action type the manifest uses should be spoken for by some check,
    # or a whole class of work has no health story at all.
    $covered = New-WDStringSet @()
    foreach ($h in @($health)) { foreach ($a in $h.Affects) { $null = $covered.Add($a) } }
    foreach ($t in @('appx','winget','uninstall','registry','service','task','feature','capability','file')) {
        if (-not $covered.Contains($t)) { $hBad += "no check declares it gates '$t' actions" }
    }
    # The impact mapping is the half that makes it usable, so it is driven
    # rather than trusted: a plan of three known items must produce an answer
    # without throwing, and every row must carry its own count.
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
    # No module may Add-Type at import time. Each one is a csc run - ~400 ms for
    # the first, ~150 after - and three of them were most of the 2.5s before
    # anything appeared on screen. A top-level Add-Type reads as ordinary setup
    # and is paid by every launch forever, which is why this is checked rather
    # than remembered. Column zero only, so deferred ones inside functions pass.
    $compileBad = @()
    foreach ($f in @(Get-ChildItem -Path (Join-Path $modulePath '*.psm1'))) {
        $txt = [System.IO.File]::ReadAllText($f.FullName)
        foreach ($m in [regex]::Matches($txt, '(?m)^Add-Type\b.*$')) {
            # -AssemblyName loads an assembly that is already on disk and does
            # not invoke a compiler. WD.UI needs WPF before it can declare a
            # single XAML string, and that one is not the problem.
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

    # GetNewClosure copies the scope the closure is WRITTEN in and nothing above
    # it, so a handler built inside another scriptblock captures $null for
    # anything one scope further out. Nothing complains until it fires, and a
    # throw out of a WPF handler closes the window - which is how a rail card
    # that threw on hover shipped. Decidable from source, so decided here.
    Write-Host "`n[6] Closure captures" -ForegroundColor Cyan
    $srcFiles = @(Get-ChildItem -Path (Join-Path $modulePath '*.psm1') | ForEach-Object { $_.FullName }) + @($PSCommandPath)
    $sbAst    = [System.Management.Automation.Language.ScriptBlockAst]
    $varAst   = [System.Management.Automation.Language.VariableExpressionAst]
    # Names that are always there, whatever scope the closure copied. Matched
    # without case, because $Ui and $ui are the same variable to PowerShell and
    # a case-sensitive set here would invent failures.
    $nameSet  = { param([string[]]$From)
                  $s = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                  foreach ($x in $From) { $null = $s.Add($x) }
                  ,$s }
    # $Matches is here for the same reason as $_ and $args: PowerShell fills it
    # in whatever scope the -match ran in, so a closure that matches and then
    # reads it is reading its own, and the "cannot see it" this check exists to
    # catch cannot happen. Without it, every regex inside a closure is a failure.
    $auto     = & $nameSet @('_','this','args','PSItem','true','false','null','input','PSCmdlet',
                             'MyInvocation','Error','PSScriptRoot','PSCommandPath','Host','PID','Matches',
                             'ErrorActionPreference','ProgressPreference','LASTEXITCODE','StackTrace','?','^','$')
    # The names a scriptblock puts in its own scope: parameters, assignments
    # made directly in its body, and foreach variables. An assignment inside a
    # nested scriptblock belongs to that one, not to this.
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

        # The other half, and the one reading the block cannot catch:
        # $someBlock.GetNewClosure() binds that block to whatever scope CALLS it.
        # Right at function level; inside another closure it re-binds a block
        # full of the function's locals onto a scope that has six of them.
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
            # The scope this closure copies from. A closure written straight
            # into a function body copies the function's locals, which is the
            # whole function - there is nothing to get wrong there.
            # Not $home - that is an automatic variable, and writing to it here
            # would change where this session thinks the profile lives.
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
                # closure, then the scope it was built in. A plain scriptblock
                # nested inside a closure resolves up that chain when it is
                # called, so its reads are legal.
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

    # ---- an operator where a parameter should be ----------------------------
    #
    # `Show-WDMessage (...) -ne 'Yes'` is a COMMAND, so -ne parses as a parameter
    # name and 'Yes' as its argument. Simple functions drop unmatched named
    # parameters into $args rather than erroring, so the comparison never happens
    # and the condition is a non-empty string: always true. Nine confirmations
    # came through the MessageBox conversion like that and all nine stopped
    # asking. Wrap the whole call: `if ((Show-WDMessage (...)) -ne 'Yes')`.
    #
    # Where-Object and ForEach-Object are exempt, and only they - -eq really is
    # a parameter there, which is why the parser accepts one at all.
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

    # ---- theme keys ---------------------------------------------------------
    #
    # $paintTheme's key list IS the resource dictionary, and $Ref throws on a key
    # it cannot find - so a colour added to Get-WDPalette without a line there
    # takes the window down during the build, from a line that names no colour.
    # Shipping 'Obstruct' did exactly that. Static, because the interface pass
    # would only catch it by crashing, and a named key beats a stack trace.
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
        # actually broke, and it needs no parsing of call sites to catch.
        foreach ($pk in @((Get-WDPalette -Theme 'dark').Keys)) {
            if ($pk -eq 'Dark') { continue }
            if (-not $have.Contains([string]$pk)) { $themeBad += "the palette has '$pk' and `$paintTheme never makes a brush from it" }
        }

        # And every literal key handed to $Ref has to exist. The call is
        # `& $Ref <el> '<Prop>' <Key>`; only a bare literal or an if-expression
        # over literals can be read from here, and anything computed - a table
        # lookup, or a name built with + - is skipped rather than guessed at.
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

    Write-Host "`n[7] Interface" -ForegroundColor Cyan
    Import-Module (Join-Path $modulePath 'WD.UI.psm1') -Force -DisableNameChecking

    # Two palettes, and the chooser on first run only means anything if asking
    # for one gets it rather than whatever Windows happens to be set to.
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
    # would only ever be found by someone running this for the first time.
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

    # The application's icon is generated rather than shipped, so nothing on
    # disk can be inspected when it goes wrong - and when it goes wrong it does
    # so silently, because Get-WDAppIcon swallows its own failure rather than
    # taking a launch down over a picture. Every assertion here builds bitmaps
    # in memory and shows nothing.
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
            # Every directory entry must point inside the file. A bad offset is
            # the failure that renders as a blank tile rather than as an error.
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
        # geometry produces, and it passes every other check here.
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
        # passes every structural check. Does NOT catch a wrong SHAPE - the art
        # once shipped tilted the wrong way with coverage unchanged. Only
        # looking at it catches that.
        if ($cover -lt 0.18) { $bad += ('only {0:p0} of the largest frame is drawn' -f $cover) }
        if ($cover -gt 0.85) { $bad += ('{0:p0} of the largest frame is drawn - it is a blob' -f $cover) }

        $pick = Get-WDAppIcon
        if (-not $pick)        { $bad += 'Get-WDAppIcon handed back nothing' }
        elseif (-not $pick.IsFrozen) { $bad += 'the icon is not frozen' }

        # BYTES CROSS THREADS, DECODED FRAMES DO NOT. A BitmapFrame keeps its
        # decoder, a decoder has thread affinity, and Freeze() on the frame does
        # not freeze the decoder - so handing one across assigns cleanly and
        # throws inside Show(), which silently cost the splash its whole window.
        # EnsureHandle creates the HWND (when WPF resolves the icon) without
        # showing anything, which is what makes this testable.
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
        # runspace - and that path fails in its own ways: XAML that will not
        # parse, a storyboard that never starts, a runspace that returns
        # nothing. -Quiet drops Topmost and activation: a 90-second test must
        # not hold the foreground.
        $sp = New-WDSplash -Profile $profileInfo -Quiet
        & $sp.Status 'Self test' 'Checking the startup path'
        # Through the shared state, never off the element: the window is on
        # another runspace and touching it from here throws. The thread is
        # deliberately blocked in a sleep loop, which is what real startup does
        # to it, and the sweep still has to move.
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
        # runs, the splash cannot animate and the whole thing reads as frozen.
        $buildSw = [Diagnostics.Stopwatch]::StartNew()
        $again = Show-WDWindow -Categories $categories -Session (Get-WDSession) -Profile $profileInfo `
                               -ModulePath $modulePath -ManifestPath $manifest -Scan $scan -Presence $presence -SelfTestSeconds 3 `
                               -Theme 'dark'
        Write-Host ("  build + 3s interaction pass: {0:n1}s" -f ($buildSw.Elapsed.TotalSeconds))

        # Show-WDWindow must return NOTHING: one call, one window, one build.
        # Worth asserting rather than ignoring - it caught $win.Activate()'s
        # Boolean escaping as the return value, which was invisible for as long
        # as a Restart object sat in front of it.
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

# --------------------------------------------------------- unattend file ---
#
# Self-contained: the selected items' registry values and app removals are
# inlined, so there is no payload to copy onto the medium, nothing to go stale,
# and the file can be read to see exactly what it will do.
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
    # Disks stay untouched from the command line, with no switch to change that.
    # A flag that silently wipes disk 0 on whatever machine the medium is booted
    # on does not belong on a command line where it can be pasted from a forum.
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

# ------------------------------------------------------------ console run ---
if ($Console) {
    if (-not $Preview -and -not $Apply) {
        Write-Host 'Console mode needs either -Preview or -Apply.' -ForegroundColor Red
        exit 1
    }

    $selected = Resolve-Selection
    $session  = Initialize-WDSession -Root $LogRoot -Preview:$Preview
    $plan     = Resolve-WDPlan -Categories $categories -Selected $selected -Profile $profileInfo

    Write-Host "$(@($plan).Count) of $($selected.Count) selected items apply to this machine." -ForegroundColor Gray

    # The tool sweep, against this plan. Already in the log by now - the session
    # writes it - but the console is where somebody running this is looking, and
    # a warning only in a file is a warning nobody reads until afterwards.
    # -Deep here and nowhere else: on the command line there is no window to
    # keep responsive, so the one genuinely slow probe is worth its two seconds.
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
        # images, so this fails often enough that a silent skip would leave
        # somebody believing in a way back that does not exist.
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
    # `rollback-script` plan item, so it is previewable and can be seen on the
    # Advanced page like anything else the run does.
    $report = Export-WDReport -Results $results -Session $session -Profile $profileInfo -PresetName $Preset
    # Only on an apply. There is nothing to explain about a run that changed
    # nothing, and a file called "what this run did" describing a preview is
    # the sort of thing somebody finds three weeks later and believes.
    if (-not $Preview) { $null = Export-WDRunNotes -Items $plan -PresetName $Preset }

    # How many of the things that actually changed need a restart before they
    # take effect - counted off the results rather than the plan, so an item
    # that reported NotPresent is not counted for a restart it does not need.
    # The GUI works this out in its own runspace; this is the same sum.
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
    # finds it. Last, because it copies what the lines above wrote. -Public on a
    # setup run - session 0 has no per-user desktop, and asking as SYSTEM
    # answers with the systemprofile folder, which exists and nobody opens.
    if (-not $Preview -and $SetupRun) {
        $null = Export-WDSetupResult -Session $session -Report $report -Label $Preset `
                                     -RestartCount $needRestart -RestorePoint $restorePointState
    }
    $keep = $null
    if (-not $Preview) { $keep = Export-WDRunFolder -Session $session -Public:$SetupRun }
    # Written twice on a setup run, and the second one is the one that counts:
    # the first pass had nowhere to record where the desktop copy landed,
    # because it had not been made yet, and that path is what the prompt at
    # first sign-in opens.
    if (-not $Preview -and $SetupRun) {
        $null = Export-WDSetupResult -Session $session -Report $report -Label $Preset `
                                     -KeepDir $(if ($keep) { [string]$keep.Path } else { '' }) `
                                     -RestartCount $needRestart -RestorePoint $restorePointState
        # And the prompt itself. Last of all, and allowed to fail: everything
        # above is the promise, this is the convenience on top of it.
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

# ---------------------------------------------------------------- GUI run ---
# WD.UI is already in and the scan is already running - both were started up by
# the block above the first sign-in prompt, so that the slowest thing here has
# a head start on everything that follows.

# Before the first window of any kind - the theme chooser below is one, and a
# taskbar button keeps whatever identity it was created with. Without this the
# button shows PowerShell's icon no matter what Window.Icon says.
Set-WDTaskbarIdentity

# Asked once, before anything else is drawn: every window after this one is
# built in the answer, and there is no way to restyle them afterwards without
# building them again.
$uiState = Get-WDUiState
if (-not [string]$uiState.theme) {
    $picked = Show-WDThemeChooser
    if ($picked) {
        $uiState.theme = $picked
        $null = Save-WDUiState -State $uiState
    }
}

# Up before anything slow, so a window is on screen a moment after the launcher
# exits rather than after the scan. No -Profile: that is six CIM queries and
# about a second. The scan runspace reads it as its first act and publishes it,
# so the caption fills itself in and nothing reads the machine twice.
$splash = New-WDSplash

$startup    = Wait-WDStartupScan -Job $scanJob -Splash $splash
$categories = $startup.Categories
$scan       = $startup.Scan
$presence   = $startup.Presence

# Seeded into this runspace's cache, not just assigned: half the module surface
# takes -Profile optionally and reads it for itself when it is absent, and any
# one of those would otherwise pay the full second again on the UI thread.
$profileInfo = Import-WDSystemProfile -Profile $startup.Profile
if (-not $profileInfo) { $profileInfo = Get-WDSystemProfile }

if ($startup.Error) {
    & $splash.Status 'The scan could not finish' 'Continuing with the curated list only'
    Write-WDLog "Startup scan failed: $($startup.Error)" -Level Warn
}

& $splash.Status 'Preparing the session' 'Log folder and rollback journal'
# -QuickEnvironment on the GUI path only. This session exists to own a log
# folder while the window is open; a preview or an apply builds its own on the
# run runspace and writes the full environment record there. Reading the
# machine twice cost four seconds of every launch and produced a file
# describing a run that never happened.
$null = Initialize-WDSession -Root $LogRoot -Preview -QuickEnvironment:$isGui

$pre = $null
if ($ProfilePath -or $Select) { $pre = Resolve-Selection }

# One call, one window, one build. Colours are keyed theme resources, so a theme
# switch repaints the open window rather than returning here to be rebuilt. If
# you find yourself adding -HostWindow back, fix whatever still holds a brush.
$null = Show-WDWindow -Categories $categories -Session (Get-WDSession) -Profile $profileInfo `
                      -ModulePath $modulePath -ManifestPath $manifest -Scan $scan -Presence $presence `
                      -PreSelected $pre -ShowRun $ShowRun `
                      -Splash $splash -Theme ([string]$uiState.theme) -UiState (Get-WDUiState)
