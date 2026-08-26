<#
    A full picture of this machine, written to disk, for comparing before and
    after a run.

    DELIBERATELY SELF-CONTAINED. It imports none of the toolkit's modules and
    calls none of its functions. The whole point of an after-snapshot is that it
    is taken on a machine somebody has just changed, possibly badly, and a
    diagnostic that depends on the thing under test is no diagnostic at all.
    The only file it reads from the repo is the manifest, and it degrades to a
    smaller registry sweep if that cannot be parsed.

    Every section is independent and wrapped. One that throws records the
    exception and the run carries on - a snapshot missing its service list is
    worth far more than no snapshot.

    Run it elevated. Unelevated works and is marked as degraded in the output,
    but roughly a fifth of what matters here needs administrator rights, and
    "the value is absent" and "I was not allowed to read the value" are
    different facts that must not collapse into one.

        .\Tools\Get-WDSystemSnapshot.ps1 -Label before
        .\Tools\Get-WDSystemSnapshot.ps1 -Label after
        .\Tools\Compare-WDSnapshot.ps1 -Before <dir> -After <dir>
#>
[CmdletBinding()]
param(
    # Where the snapshot folder is created. Defaults beside the toolkit's own
    # data, so before and after land together and survive a reboot.
    [string]$OutputRoot = (Join-Path $env:ProgramData 'WinSetupToolkit\snapshots'),

    # Goes in the folder name and into the file, so two snapshots can be told
    # apart months later without opening them.
    [string]$Label = 'snapshot',

    # Skips the DISM feature and capability enumerations, which are most of the
    # runtime. Everything else is seconds.
    [switch]$SkipSlow,

    # Adds .reg exports of the policy trees. Bulky, and the one form that can
    # answer a question this script did not think to ask.
    [switch]$IncludeRegExport,

    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------- plumbing ---

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeLbl = ($Label -replace '[^A-Za-z0-9._-]', '-')
$outDir  = Join-Path $OutputRoot "$stamp-$safeLbl"
$null    = New-Item -ItemType Directory -Path $outDir -Force -ErrorAction Stop

$snap     = [ordered]@{}
$problems = New-Object System.Collections.Generic.List[object]
$timings  = New-Object System.Collections.Generic.List[object]
$overall  = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Note {
    param([string]$Text, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
}

function Invoke-Section {
    <#  Run one capture. Records what it produced, how long it took, and the
        full exception if it failed - type and message, because "Exception"
        with a sentence is not enough to act on afterwards.  #>
    param([string]$Name, [scriptblock]$Body)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $value = $null
    $ok = $true
    try {
        $value = & $Body
    } catch {
        $ok = $false
        $problems.Add([ordered]@{
            section   = $Name
            type      = $_.Exception.GetType().FullName
            message   = $_.Exception.Message
            at        = [string]$_.InvocationInfo.PositionMessage
            inner     = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $null }
        })
    }
    $sw.Stop()
    $count = 0
    if ($null -ne $value) {
        if ($value -is [System.Collections.ICollection]) { $count = $value.Count } else { $count = 1 }
    }
    $timings.Add([ordered]@{ section = $Name; ms = [int]$sw.ElapsedMilliseconds; count = $count; ok = $ok })
    if ($ok) {
        Write-Note ("  {0,-26} {1,6} in {2,6}ms" -f $Name, $count, [int]$sw.ElapsedMilliseconds)
    } else {
        Write-Note ("  {0,-26} FAILED   {1}" -f $Name, $problems[-1].message) 'Red'
    }
    $snap[$Name] = $value
}

function Get-RegValues {
    <#  Every value under one key, as a flat map, or $null if the key is not
        there. Distinguishing "no key", "no values", and "refused" is the whole
        reason this is not a one-liner.  #>
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $k = Get-Item -LiteralPath $Path -ErrorAction Stop
        $map = [ordered]@{}
        foreach ($n in $k.GetValueNames()) {
            $shown = if ($n) { $n } else { '(default)' }
            $raw = $k.GetValue($n)
            if ($raw -is [byte[]]) {
                $raw = ($raw | ForEach-Object { $_.ToString('x2') }) -join ''
            } elseif ($raw -is [string[]]) {
                $raw = $raw -join '|'
            }
            $map[$shown] = [ordered]@{ value = $raw; kind = [string]$k.GetValueKind($n) }
        }
        return $map
    } catch {
        return [ordered]@{ '__error__' = [ordered]@{ value = $_.Exception.Message; kind = 'Error' } }
    }
}

function Get-OneRegValue {
    <#  Three-valued on purpose: the object carries 'present' separately from
        'value', so an absent value and a zero are never confused in a diff.  #>
    param([string]$Path, [string]$Name)
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            return [ordered]@{ present = $false; reason = 'no key'; value = $null; kind = $null }
        }
        $k = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($k.GetValueNames() -notcontains $Name) {
            return [ordered]@{ present = $false; reason = 'no value'; value = $null; kind = $null }
        }
        $raw = $k.GetValue($Name)
        if ($raw -is [byte[]]) { $raw = ($raw | ForEach-Object { $_.ToString('x2') }) -join '' }
        if ($raw -is [string[]]) { $raw = $raw -join '|' }
        return [ordered]@{ present = $true; reason = $null; value = $raw; kind = [string]$k.GetValueKind($Name) }
    } catch {
        return [ordered]@{ present = $null; reason = "refused: $($_.Exception.Message)"; value = $null; kind = $null }
    }
}

$isAdmin = try {
    (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $false }

Write-Note ''
Write-Note "  Windows Setup Toolkit system snapshot - $Label" 'Cyan'
Write-Note "  $outDir"
if (-not $isAdmin) {
    Write-Note '  NOT ELEVATED - services, tasks, Defender, and BitLocker will be partial.' 'Yellow'
}
Write-Note ''

# =============================================================== identity ====

Invoke-Section 'meta' {
    [ordered]@{
        label        = $Label
        taken        = (Get-Date).ToString('o')
        takenLocal   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        elevated     = $isAdmin
        user         = "$env:USERDOMAIN\$env:USERNAME"
        psVersion    = $PSVersionTable.PSVersion.ToString()
        psEdition    = [string]$PSVersionTable.PSEdition
        host         = $env:COMPUTERNAME
        scriptVer    = 1
        skipSlow     = [bool]$SkipSlow
    }
}

Invoke-Section 'os' {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [ordered]@{
        caption        = $os.Caption
        version        = $os.Version
        buildNumber    = $os.BuildNumber
        ubr            = (Get-OneRegValue $cv 'UBR').value
        displayVersion = (Get-OneRegValue $cv 'DisplayVersion').value
        editionId      = (Get-OneRegValue $cv 'EditionID').value
        productName    = (Get-OneRegValue $cv 'ProductName').value
        installDate    = if ($os.InstallDate) { $os.InstallDate.ToString('o') } else { $null }
        lastBoot       = if ($os.LastBootUpTime) { $os.LastBootUpTime.ToString('o') } else { $null }
        uptimeHours    = if ($os.LastBootUpTime) { [Math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1) } else { $null }
        locale         = $os.Locale
        osLanguage     = $os.OSLanguage
        systemDrive    = $os.SystemDrive
        windowsDir     = $os.WindowsDirectory
        # Safe mode changes what a run can even do - most services are not
        # running and DISM refuses outright - so it is recorded rather than
        # assumed. BootupState is the readable half; the SafeBoot key is what
        # is actually consulted on the next boot.
        bootupState    = $os.BootupState
        safeBootOption = (Get-OneRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option' 'OptionValue').value
        timeZone       = (Get-TimeZone -ErrorAction SilentlyContinue).Id
    }
}

Invoke-Section 'hardware' {
    $cs  = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios= Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $cpu = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)
    $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    $sb  = $null
    try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop } catch { $sb = "unavailable: $($_.Exception.Message)" }
    $tpm = $null
    try {
        $t = Get-Tpm -ErrorAction Stop
        $tpm = [ordered]@{ present = $t.TpmPresent; ready = $t.TpmReady; enabled = $t.TpmEnabled }
    } catch { $tpm = "unavailable: $($_.Exception.Message)" }
    [ordered]@{
        manufacturer = $cs.Manufacturer
        model        = $cs.Model
        systemFamily = $cs.SystemFamily
        systemSku    = $cs.SystemSKUNumber
        chassis      = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes)
        totalRamGb   = if ($cs.TotalPhysicalMemory) { [Math]::Round($cs.TotalPhysicalMemory / 1GB, 2) } else { $null }
        domain       = $cs.Domain
        partOfDomain = $cs.PartOfDomain
        biosVersion  = $bios.SMBIOSBIOSVersion
        biosDate     = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('o') } else { $null }
        biosVendor   = $bios.Manufacturer
        firmwareType = [string]$env:firmware_type
        secureBoot   = $sb
        tpm          = $tpm
        cpu          = @($cpu | ForEach-Object { $_.Name })
        batteries    = $bat.Count
        gpus         = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                         ForEach-Object { [ordered]@{ name = $_.Name; driver = $_.DriverVersion } })
    }
}

Invoke-Section 'volumes' {
    @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{
            drive     = $_.DeviceID
            label     = $_.VolumeName
            fs        = $_.FileSystem
            sizeGb    = [Math]::Round($_.Size / 1GB, 2)
            freeGb    = [Math]::Round($_.FreeSpace / 1GB, 2)
            # The number a pre-flight would gate on, recorded so a run that
            # ran out of room afterwards can be shown to have been short before.
            freePct   = if ($_.Size) { [Math]::Round(100 * $_.FreeSpace / $_.Size, 1) } else { $null }
        }
    })
}

# ================================================================ software ===

Invoke-Section 'appxPackages' {
    # -AllUsers throws a TERMINATING access-denied unelevated, so -ErrorAction
    # SilentlyContinue does not save it and the section comes back empty rather
    # than partial. Falling back to this user's own packages is worth doing,
    # but the two lists are not comparable - one is every account's packages
    # and the other is one account's - so which was used is recorded, and the
    # comparison refuses to diff across a change of scope.
    $scope = 'allusers'
    $pkgs = $null
    if ($isAdmin) {
        try { $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } catch { $pkgs = $null }
    }
    if ($null -eq $pkgs) {
        $scope = 'currentuser'
        $pkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue)
    }
    $script:appxScope = $scope
    @($pkgs | ForEach-Object {
        [ordered]@{
            name            = $_.Name
            fullName        = $_.PackageFullName
            version         = [string]$_.Version
            publisher       = $_.Publisher
            architecture    = [string]$_.Architecture
            nonRemovable    = [bool]$_.NonRemovable
            signatureKind   = [string]$_.SignatureKind
            status          = [string]$_.Status
            installLocation = $_.InstallLocation
            isFramework     = [bool]$_.IsFramework
        }
    })
}

Invoke-Section 'appxProvisioned' {
    if (-not $isAdmin) { return @('__needs_admin__') }
    @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{
            displayName = $_.DisplayName
            packageName = $_.PackageName
            version     = [string]$_.Version
        }
    })
}

Invoke-Section 'programs' {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue)) {
            $p = $null
            try { $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { continue }
            if (-not $p.DisplayName) { continue }
            $out.Add([ordered]@{
                key             = $k.PSChildName
                hive            = $r
                displayName     = [string]$p.DisplayName
                displayVersion  = [string]$p.DisplayVersion
                publisher       = [string]$p.Publisher
                installLocation = [string]$p.InstallLocation
                uninstallString = [string]$p.UninstallString
                # Both of these decide whether the GUI would have offered it,
                # so a row that disappears between snapshots can be explained.
                systemComponent = [int]$p.SystemComponent
                parentDisplay   = [string]$p.ParentDisplayName
                estimatedSizeKb = [int]$p.EstimatedSize
                installDate     = [string]$p.InstallDate
            })
        }
    }
    $out
}

Invoke-Section 'services' {
    $cim = @{}
    foreach ($s in (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) { $cim[$s.Name] = $s }
    @(Get-Service -ErrorAction SilentlyContinue | ForEach-Object {
        $w = $cim[$_.Name]
        [ordered]@{
            name         = $_.Name
            displayName  = $_.DisplayName
            status       = [string]$_.Status
            startType    = if ($w) { [string]$w.StartMode } else { [string]$_.StartType }
            pathName     = if ($w) { [string]$w.PathName } else { $null }
            serviceType  = if ($w) { [string]$w.ServiceType } else { $null }
            startName    = if ($w) { [string]$w.StartName } else { $null }
            processId    = if ($w) { [int]$w.ProcessId } else { 0 }
            delayedAuto  = (Get-OneRegValue "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.Name)" 'DelayedAutostart').value
        }
    })
}

Invoke-Section 'scheduledTasks' {
    # The COM route rather than Get-ScheduledTask: it is an order of magnitude
    # faster over a few hundred tasks, and it works when the CIM provider is
    # unhappy, which is one of the states this snapshot exists to record.
    $out = New-Object System.Collections.Generic.List[object]
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $stack = New-Object System.Collections.Stack
    $stack.Push($svc.GetFolder('\'))
    while ($stack.Count) {
        $folder = $stack.Pop()
        foreach ($sub in $folder.GetFolders(0)) { $stack.Push($sub) }
        foreach ($t in $folder.GetTasks(1)) {
            $out.Add([ordered]@{
                path       = $t.Path
                name       = $t.Name
                enabled    = [bool]$t.Enabled
                state      = [int]$t.State
                lastRun    = if ($t.LastRunTime -gt [datetime]'1900-01-01') { $t.LastRunTime.ToString('o') } else { $null }
                lastResult = [int]$t.LastTaskResult
            })
        }
    }
    $out
}

Invoke-Section 'features' {
    if ($SkipSlow) { return @('__skipped__') }
    if (-not $isAdmin) { return @('__needs_admin__') }
    @(Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{ name = $_.FeatureName; state = [string]$_.State }
    })
}

Invoke-Section 'capabilities' {
    if ($SkipSlow) { return @('__skipped__') }
    if (-not $isAdmin) { return @('__needs_admin__') }
    @(Get-WindowsCapability -Online -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{ name = $_.Name; state = [string]$_.State }
    })
}

Invoke-Section 'drivers' {
    # Third-party driver packages. A vendor uninstall that takes a driver with
    # it is the failure mode nobody expects and nobody can reconstruct later.
    $out = New-Object System.Collections.Generic.List[object]
    $raw = & pnputil.exe /enum-drivers 2>&1 | Out-String
    foreach ($blk in ($raw -split "(?m)^\s*$") ) {
        if ($blk -notmatch 'Published Name') { continue }
        $get = {
            param($label)
            if ($blk -match "(?m)^\s*$label\s*:\s*(.+?)\s*$") { $Matches[1] } else { $null }
        }
        $out.Add([ordered]@{
            published    = & $get 'Published Name'
            original     = & $get 'Original Name'
            provider     = & $get 'Provider Name'
            className    = & $get 'Class Name'
            version      = & $get 'Driver Version'
            signer       = & $get 'Signer Name'
        })
    }
    $out
}

# ================================================================ registry ===

Invoke-Section 'registryManifestTargets' {
    <#  Every registry value the manifest could write, read as it is now.

        This is the single most useful section for a before-and-after: it is
        exactly the set of values a run can move, so a diff over it is a
        complete account of the registry side of what happened - including the
        writes that were supposed to happen and did not.  #>
    $manifestDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'Manifest'
    if (-not (Test-Path -LiteralPath $manifestDir)) { return @('__no_manifest__') }

    # Which hives an 'allusers' action would reach. Loaded hives only, which is
    # the same limit the toolkit itself has.
    $userRoots = New-Object System.Collections.Generic.List[object]
    $userRoots.Add([pscustomobject]@{ name = 'HKCU'; path = 'HKCU:' })
    foreach ($sid in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        $leaf = $sid.PSChildName
        if ($leaf -notmatch '^S-1-5-21-' -or $leaf -match '_Classes$') { continue }
        $userRoots.Add([pscustomobject]@{ name = "HKU\$leaf"; path = "Registry::HKEY_USERS\$leaf" })
    }

    $seen = New-Object System.Collections.Generic.HashSet[string]
    $out  = New-Object System.Collections.Generic.List[object]

    foreach ($f in (Get-ChildItem -LiteralPath $manifestDir -Filter *.json -ErrorAction SilentlyContinue)) {
        $doc = $null
        try { $doc = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        foreach ($cat in @($doc.categories)) {
            foreach ($item in @($cat.items)) {
                foreach ($act in @($item.actions)) {
                    if ([string]$act.type -notin @('registry', 'registryKey')) { continue }
                    $scope = [string]$act.scope
                    if (-not $scope) { $scope = 'machine' }
                    $roots = @([pscustomobject]@{ name = 'HKLM'; path = 'HKLM:' })
                    if ($scope -ieq 'user') { $roots = @([pscustomobject]@{ name = 'HKCU'; path = 'HKCU:' }) }
                    if ($scope -ieq 'allusers') { $roots = $userRoots }

                    foreach ($v in @($act.values)) {
                        $rel = [string]$v.path
                        if (-not $rel) { continue }
                        foreach ($root in $roots) {
                            $full = $rel
                            if ($scope -ieq 'allusers') { $full = Join-Path $root.path $rel }
                            $name = [string]$v.name
                            $id   = "$full|$name"
                            if (-not $seen.Add($id)) { continue }
                            $cur = Get-OneRegValue $full $name
                            $out.Add([ordered]@{
                                item    = [string]$item.id
                                path    = $full
                                name    = $name
                                scope   = $scope
                                wants   = if ($v.delete) { '__delete__' } else { $v.value }
                                present = $cur.present
                                current = $cur.value
                                kind    = $cur.kind
                                reason  = $cur.reason
                            })
                        }
                    }
                }
            }
        }
    }
    $out
}

Invoke-Section 'registryTrees' {
    # Whole keys rather than named values, for the trees where what matters is
    # which values EXIST. A policy key gains and loses names; a per-value list
    # written in advance can only ever report on the ones somebody thought of.
    $trees = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender',
        'HKLM:\SOFTWARE\Policies\Microsoft\Edge',
        'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate',
        'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System',
        'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management',
        'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search',
        'HKCU:\Control Panel\Desktop',
        'HKCU:\Control Panel\International\Geo'
    )
    $map = [ordered]@{}
    foreach ($t in $trees) { $map[$t] = Get-RegValues $t }
    $map
}

Invoke-Section 'startup' {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    $map = [ordered]@{}
    foreach ($k in $keys) { $map[$k] = Get-RegValues $k }
    $folders = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
    )
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($f in $folders) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        foreach ($x in (Get-ChildItem -LiteralPath $f -File -ErrorAction SilentlyContinue)) {
            $files.Add([ordered]@{ folder = $f; name = $x.Name; size = $x.Length })
        }
    }
    [ordered]@{ registry = $map; folders = $files }
}

# ================================================================ security ===

Invoke-Section 'defender' {
    $st = $null; $pr = $null
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
        $st = [ordered]@{
            amRunning            = $s.AMServiceEnabled
            antivirusEnabled     = $s.AntivirusEnabled
            realTimeProtection   = $s.RealTimeProtectionEnabled
            tamperProtection     = $s.IsTamperProtected
            behaviorMonitor      = $s.BehaviorMonitorEnabled
            antivirusSignature   = [string]$s.AntivirusSignatureVersion
            engineVersion        = [string]$s.AMEngineVersion
        }
    } catch { $st = "unavailable: $($_.Exception.Message)" }
    try {
        $p = Get-MpPreference -ErrorAction Stop
        $pr = [ordered]@{
            disableRealtimeMonitoring = $p.DisableRealtimeMonitoring
            exclusionPath             = @($p.ExclusionPath)
            exclusionProcess          = @($p.ExclusionProcess)
            puaProtection             = [string]$p.PUAProtection
            mapsReporting             = [string]$p.MAPSReporting
        }
    } catch { $pr = "unavailable: $($_.Exception.Message)" }
    [ordered]@{ status = $st; preference = $pr }
}

Invoke-Section 'protection' {
    # System Protection and the restore points, which are the toolkit's own
    # safety net and are absent on most OEM images. If this reads zero before a
    # run, the rollback script is the only way back and that has to be known
    # in advance rather than discovered.
    $points = @()
    try {
        $points = @(Get-ComputerRestorePoint -ErrorAction Stop | ForEach-Object {
            [ordered]@{
                seq         = $_.SequenceNumber
                description = $_.Description
                type        = [string]$_.RestorePointType
                created     = [string]$_.CreationTime
            }
        })
    } catch { $points = @("unavailable: $($_.Exception.Message)") }

    $shadow = @()
    try {
        $shadow = @(& vssadmin.exe list shadowstorage 2>&1 | Out-String) -split "`r?`n" |
                  Where-Object { $_ -match '\S' }
    } catch { $shadow = @("unavailable: $($_.Exception.Message)") }

    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    [ordered]@{
        restorePoints  = $points
        restoreCount   = @($points | Where-Object { $_ -is [System.Collections.IDictionary] }).Count
        shadowStorage  = $shadow
        disableSR      = (Get-OneRegValue $srKey 'DisableSR')
        # The value the toolkit sets to 0 to defeat the 24-hour throttle, and
        # is supposed to put back. Recorded on both sides precisely so that
        # can be checked rather than trusted.
        createFreq     = (Get-OneRegValue $srKey 'SystemRestorePointCreationFrequency')
        rpSessionInt   = (Get-OneRegValue $srKey 'RPSessionInterval')
        rpLifeInterval = (Get-OneRegValue $srKey 'RPLifeInterval')
    }
}

Invoke-Section 'bitlocker' {
    try {
        @(Get-BitLockerVolume -ErrorAction Stop | ForEach-Object {
            [ordered]@{
                mount     = $_.MountPoint
                status    = [string]$_.VolumeStatus
                protection= [string]$_.ProtectionStatus
                encryption= [string]$_.EncryptionMethod
            }
        })
    } catch { @("unavailable: $($_.Exception.Message)") }
}

Invoke-Section 'firewall' {
    try {
        @(Get-NetFirewallProfile -ErrorAction Stop | ForEach-Object {
            [ordered]@{
                name           = [string]$_.Name
                enabled        = [string]$_.Enabled
                inboundDefault = [string]$_.DefaultInboundAction
                outboundDefault= [string]$_.DefaultOutboundAction
            }
        })
    } catch { @("unavailable: $($_.Exception.Message)") }
}

Invoke-Section 'uac' {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    [ordered]@{
        enableLUA                     = (Get-OneRegValue $k 'EnableLUA')
        consentPromptBehaviorAdmin    = (Get-OneRegValue $k 'ConsentPromptBehaviorAdmin')
        promptOnSecureDesktop         = (Get-OneRegValue $k 'PromptOnSecureDesktop')
        filterAdministratorToken      = (Get-OneRegValue $k 'FilterAdministratorToken')
    }
}

# ================================================================= system ====

Invoke-Section 'pendingReboot' {
    # Every indicator, separately, rather than one boolean. Which one is set
    # says what put it there, and DISM refuses to work at all while some of
    # these are outstanding.
    $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $wu  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $ren = Get-OneRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
    [ordered]@{
        cbsRebootPending   = (Test-Path -LiteralPath $cbs)
        wuRebootRequired   = (Test-Path -LiteralPath $wu)
        pendingFileRenames = $ren.present
        # The actual list, because the toolkit itself queues deletions here
        # through MOVEFILE_DELAY_UNTIL_REBOOT and this is the only record of it.
        pendingRenameCount = if ($ren.present -and $ren.value) { @([string]$ren.value -split '\|').Count } else { 0 }
        pendingRenameData  = if ($ren.present) { [string]$ren.value } else { $null }
        computerRename     = (Get-OneRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' 'ComputerName').value
    }
}

Invoke-Section 'power' {
    $active = (& powercfg.exe /getactivescheme 2>&1 | Out-String).Trim()
    [ordered]@{
        activeScheme = $active
        schemes      = @((& powercfg.exe /list 2>&1 | Out-String) -split "`r?`n" | Where-Object { $_ -match 'GUID' })
        hibernate    = (Get-OneRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled').value
    }
}

Invoke-Section 'network' {
    # try/catch is a statement in 5.1, not an expression, so these cannot be
    # written inline in the hashtable the way an @(...) subexpression can.
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostsHash = $null
    $hostsLines = @()
    try { $hostsHash = (Get-FileHash $hostsPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
    try {
        $hostsLines = @(Get-Content $hostsPath -ErrorAction Stop | Where-Object { $_ -match '^\s*[^#\s]' })
    } catch { }
    [ordered]@{
        adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
            [ordered]@{ name = $_.Name; status = [string]$_.Status; mac = $_.MacAddress; speed = [string]$_.LinkSpeed }
        })
        dns = @(Get-DnsClientServerAddress -ErrorAction SilentlyContinue |
                Where-Object { $_.ServerAddresses.Count } | ForEach-Object {
            [ordered]@{ alias = $_.InterfaceAlias; family = [string]$_.AddressFamily; servers = @($_.ServerAddresses) }
        })
        hostsHash  = $hostsHash
        hostsLines = $hostsLines
        proxy      = (Get-RegValues 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings')
    }
}

Invoke-Section 'associations' {
    # What opens a web link and the common document types. The default browser
    # is the one association a run can break outright, and UserChoice is where
    # the answer actually lives.
    #
    # THE PROGID ALONE CANNOT ANSWER THIS. An association breaks in two ways:
    # the ProgID changes, or the ProgID stays exactly as it was and the program
    # behind it is deleted. The second is the one a debloat run causes, and
    # recording only the ProgID makes it invisible - a run that removed Edge
    # left .svg and .xml still reading 'MSEdgeHTM' at both ends and the
    # comparison duly reported no change, on the run that orphaned them.
    #
    # So the resolution is part of the recorded value. An orphaning then shows
    # up as an ordinary value change and the existing NOTABLE rule fires.
    $resolves = {
        param([string]$ProgId)
        if (-not $ProgId) { return $null }
        $cmdKey = "Registry::HKEY_CLASSES_ROOT\$ProgId\shell\open\command"
        $cmd = $null
        try { if (Test-Path -LiteralPath $cmdKey) { $cmd = [string](Get-Item -LiteralPath $cmdKey).GetValue('') } } catch { }
        if (-not $cmd) { return "$ProgId (orphaned: no open command)" }
        # The command line quotes the executable when it has spaces in it.
        $exe = $cmd
        if ($cmd -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
        elseif ($cmd -match '^\s*(\S+)') { $exe = $Matches[1] }
        if ($exe -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $exe)) {
            return "$ProgId (orphaned: $exe is gone)"
        }
        $ProgId
    }
    $out = [ordered]@{}
    $urls = @('http', 'https', 'mailto')
    foreach ($u in $urls) {
        $p = "HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\$u\UserChoice"
        $out["url:$u"] = & $resolves ([string](Get-OneRegValue $p 'ProgId').value)
    }
    $exts = @('.pdf', '.htm', '.html', '.svg', '.xml', '.txt', '.jpg', '.png', '.mp4', '.zip')
    foreach ($e in $exts) {
        $p = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$e\UserChoice"
        $out["ext:$e"] = & $resolves ([string](Get-OneRegValue $p 'ProgId').value)
    }
    $out
}

Invoke-Section 'shellState' {
    $adv = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    [ordered]@{
        advanced      = (Get-RegValues $adv)
        # A blob rather than a value, and the one the toolkit edits a single
        # bit of. Recorded whole so an edit to the wrong byte is visible.
        stuckRects    = (Get-OneRegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3' 'Settings').value
        desktopIcons  = (Get-RegValues 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel')
        explorerRunning = @(Get-Process explorer -ErrorAction SilentlyContinue).Count
    }
}

Invoke-Section 'userAccounts' {
    [ordered]@{
        localUsers = @(try {
            Get-LocalUser -ErrorAction Stop | ForEach-Object {
                [ordered]@{ name = $_.Name; enabled = $_.Enabled; sid = [string]$_.SID }
            }
        } catch { @("unavailable: $($_.Exception.Message)") })
        loadedHives = @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.PSChildName })
        profiles = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
                     ForEach-Object { [ordered]@{ sid = $_.SID; path = $_.LocalPath; special = $_.Special } })
    }
}

Invoke-Section 'paths' {
    # Presence and size of the folders a run creates, empties, or removes.
    $watch = @(
        "$env:SystemRoot\Temp",
        "$env:TEMP",
        "$env:SystemRoot\SoftwareDistribution\Download",
        "$env:SystemRoot\Prefetch",
        "$env:SystemDrive\Windows.old",
        "$env:ProgramData\WinSetupToolkit",
        "${env:ProgramFiles(x86)}\Microsoft\EdgeUpdate",
        "${env:ProgramFiles(x86)}\Microsoft\Edge",
        "$env:ProgramFiles\WindowsApps"
    )
    @($watch | ForEach-Object {
        $p = $_
        $exists = Test-Path -LiteralPath $p
        $files = $null; $bytes = $null; $note = $null
        if ($exists) {
            try {
                $m = Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum
                $files = $m.Count; $bytes = [long]$m.Sum
            } catch { $note = $_.Exception.Message }
        }
        [ordered]@{ path = $p; exists = $exists; files = $files; bytes = $bytes; note = $note }
    })
}

Invoke-Section 'eventBaseline' {
    # A count of errors and warnings per source over the last week, so an
    # after-snapshot can be diffed for sources that are NEW or newly noisy.
    # This is the section that answers "something is broken and I do not know
    # what" when nothing in the run's own report looks wrong.
    $since = (Get-Date).AddDays(-7)
    $out = [ordered]@{}
    foreach ($log in @('System', 'Application')) {
        $rows = @()
        try {
            $rows = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1, 2, 3; StartTime = $since } `
                                   -ErrorAction Stop |
                      Group-Object ProviderName, Level |
                      ForEach-Object {
                          $parts = $_.Name -split ', '
                          [ordered]@{ provider = $parts[0]; level = $parts[1]; count = $_.Count }
                      })
        } catch { $rows = @("unavailable: $($_.Exception.Message)") }
        $out[$log] = $rows
    }
    $out
}

Invoke-Section 'environment' {
    [ordered]@{
        path        = @($env:PATH -split ';' | Where-Object { $_ })
        psModPath   = @($env:PSModulePath -split ';' | Where-Object { $_ })
        execPolicy  = @(Get-ExecutionPolicy -List -ErrorAction SilentlyContinue |
                        ForEach-Object { [ordered]@{ scope = [string]$_.Scope; policy = [string]$_.ExecutionPolicy } })
        wingetPresent = [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
        dotnetVersions = @(try {
            (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP' -Recurse -ErrorAction Stop |
             Get-ItemProperty -Name Version -ErrorAction SilentlyContinue).Version | Sort-Object -Unique
        } catch { @() })
    }
}

# ================================================================== output ===

$overall.Stop()

$snap['__diagnostics__'] = [ordered]@{
    totalMs  = [int]$overall.ElapsedMilliseconds
    sections = $timings
    problems = $problems
    # Which enumeration the package list actually came from. Comparing an
    # all-users list against a current-user one reads as hundreds of packages
    # having been removed, so the comparison checks this before diffing.
    appxScope = $script:appxScope
}

# The whole thing, machine-readable. Depth matters: registryTrees is a map of
# maps of maps and the default depth of 2 silently renders the inner ones as
# type names, which looks like data until somebody tries to diff it.
$jsonPath = Join-Path $outDir 'snapshot.json'
$snap | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

# Flat files for the big collections, because reading a 12MB JSON in a text
# editor to answer "is Cortana still installed" is not a thing anybody does.
function Export-Table {
    param([string]$Name, $Rows)
    if (-not $Rows) { return }
    $real = @($Rows | Where-Object { $_ -is [System.Collections.IDictionary] })
    if (-not $real.Count) { return }
    try {
        $real | ForEach-Object { [pscustomobject]$_ } |
            Export-Csv -LiteralPath (Join-Path $outDir "$Name.csv") -NoTypeInformation -Encoding UTF8
    } catch { }
}
foreach ($t in @('appxPackages','appxProvisioned','programs','services','scheduledTasks',
                 'features','capabilities','drivers','registryManifestTargets','volumes','paths')) {
    Export-Table $t $snap[$t]
}

if ($IncludeRegExport) {
    $regDir = Join-Path $outDir 'reg'
    $null = New-Item -ItemType Directory -Path $regDir -Force
    $exports = @{
        'policies-machine' = 'HKLM\SOFTWARE\Policies'
        'policies-user'    = 'HKCU\SOFTWARE\Policies'
        'cdm'              = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        'explorer-adv'     = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        'services'         = 'HKLM\SYSTEM\CurrentControlSet\Services'
    }
    foreach ($k in $exports.Keys) {
        try { & reg.exe export $exports[$k] (Join-Path $regDir "$k.reg") /y 2>&1 | Out-Null } catch { }
    }
}

# The readable summary. Deliberately short - it is the page somebody looks at
# to confirm the snapshot is sane, not the data itself.
$sum = New-Object System.Collections.Generic.List[string]
$sum.Add("Windows Setup Toolkit system snapshot")
$sum.Add("Label      : $Label")
$sum.Add("Taken      : $($snap.meta.takenLocal)")
$sum.Add("Machine    : $($snap.hardware.manufacturer) $($snap.hardware.model)")
$sum.Add("Windows    : $($snap.os.caption) $($snap.os.displayVersion) build $($snap.os.buildNumber).$($snap.os.ubr)")
$sum.Add("Elevated   : $isAdmin")
$sum.Add("Boot state : $($snap.os.bootupState)")
$sum.Add('')
$sum.Add('Counts')
foreach ($t in $timings) {
    $sum.Add(("  {0,-26} {1,6}  {2,6}ms{3}" -f $t.section, $t.count, $t.ms, $(if ($t.ok) { '' } else { '   FAILED' })))
}
$sum.Add('')
$sum.Add("Restore points        : $($snap.protection.restoreCount)")
$sum.Add("Pending reboot (CBS)  : $($snap.pendingReboot.cbsRebootPending)")
$sum.Add("Pending reboot (WU)   : $($snap.pendingReboot.wuRebootRequired)")
$sum.Add("Pending file renames  : $($snap.pendingReboot.pendingRenameCount)")
$sum.Add("Tamper protection     : $($snap.defender.status.tamperProtection)")
$sum.Add("Free space on C:      : $(@($snap.volumes | Where-Object { $_.drive -eq 'C:' })[0].freeGb) GB")
if ($problems.Count) {
    $sum.Add('')
    $sum.Add("PROBLEMS ($($problems.Count))")
    foreach ($p in $problems) { $sum.Add("  $($p.section): $($p.message)") }
}
$sum -join "`r`n" | Set-Content -LiteralPath (Join-Path $outDir 'summary.txt') -Encoding UTF8

Write-Note ''
Write-Note "  Written to $outDir" 'Green'
Write-Note ("  {0} sections, {1} problem(s), {2:n1}s, snapshot.json is {3:n0} KB" -f `
            $timings.Count, $problems.Count, ($overall.ElapsedMilliseconds / 1000),
            ((Get-Item $jsonPath).Length / 1KB)) 'Green'
Write-Note ''

# The path, so a caller can chain straight into the comparison.
$outDir
