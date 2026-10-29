$script:Profile = $null

# GetSystemMetrics comes from [WD.Native], compiled once by WD.Core. No Add-Type
# here - it would put a compiler run on the launch path.

# SMBIOS chassis types that mean "portable".
$script:PortableChassis = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)

$script:VendorMap = [ordered]@{
    'hp|hewlett'                 = 'hp'
    'dell'                       = 'dell'
    'lenovo|thinkpad|ideapad'    = 'lenovo'
    'asus|asustek'               = 'asus'
    'acer'                       = 'acer'
    'micro-star|msi'             = 'msi'
    'samsung'                    = 'samsung'
    'razer'                      = 'razer'
    'framework'                  = 'framework'
    'microsoft'                  = 'microsoft'
    'toshiba|dynabook'           = 'toshiba'
    'sony|vaio'                  = 'vaio'
    'gigabyte|aorus'             = 'gigabyte'
    'lg electronics'             = 'lg'
    'huawei'                     = 'huawei'
    'medion'                     = 'medion'
    'fujitsu'                    = 'fujitsu'
}

function Get-WDSystemProfile {
    param([switch]$Refresh)

    if ($script:Profile -and -not $Refresh) { return $script:Profile }

    $cv  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $reg = Get-ItemProperty -Path $cv -ErrorAction SilentlyContinue

    $os = $null; $cs = $null; $enc = $null; $bat = $null; $gpu = @()
    try { $os  = Get-CimInstance Win32_OperatingSystem  -ErrorAction Stop } catch { }
    try { $cs  = Get-CimInstance Win32_ComputerSystem   -ErrorAction Stop } catch { }
    try { $enc = Get-CimInstance Win32_SystemEnclosure  -ErrorAction Stop } catch { }
    try { $bat = Get-CimInstance Win32_Battery          -ErrorAction Stop } catch { }
    try { $gpu = @(Get-CimInstance Win32_VideoController -ErrorAction Stop) } catch { }

    $sysDrive = [string]$env:SystemDrive
    if (-not $sysDrive) { $sysDrive = 'C:' }
    $diskTotal = 0L; $diskFree = 0L; $diskUsed = 0
    try {
        $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'" -ErrorAction Stop
        if ($ld -and $ld.Size -gt 0) {
            $diskTotal = [int64]$ld.Size
            $diskFree  = [int64]$ld.FreeSpace
            $diskUsed  = [int][Math]::Round((($diskTotal - $diskFree) / $diskTotal) * 100)
        }
    } catch { }

    $manufacturer = ''
    if ($cs -and $cs.Manufacturer) { $manufacturer = $cs.Manufacturer.Trim() }
    if (-not $manufacturer -and $reg) { $manufacturer = [string]$reg.SystemManufacturer }

    $vendor = 'generic'
    foreach ($pattern in $script:VendorMap.Keys) {
        if ($manufacturer -imatch $pattern) { $vendor = $script:VendorMap[$pattern]; break }
    }

    $chassisTypes = @()
    if ($enc) { $chassisTypes = @($enc | ForEach-Object { $_.ChassisTypes } | ForEach-Object { $_ }) }
    $isPortable = $false
    foreach ($c in $chassisTypes) {
        if ($script:PortableChassis -contains [int]$c) { $isPortable = $true; break }
    }
    # VMs report chassis 1, so a battery is the better tell.
    if (-not $isPortable -and $bat) { $isPortable = $true }

    # SM_DIGITIZER = 94; low byte non-zero means an integrated digitiser.
    $touch = $false
    try {
        if (Use-WDNative) { $touch = ([WD.Native]::GetSystemMetrics(94) -band 0xFF) -ne 0 }
    } catch { }

    $build = 0
    if ($reg) { [void][int]::TryParse([string]$reg.CurrentBuild, [ref]$build) }
    $ubr = 0
    if ($reg -and $reg.PSObject.Properties['UBR']) { $ubr = [int]$reg.UBR }

    $edition = ''
    if ($reg) { $edition = [string]$reg.EditionID }

    $isVM = $false
    if ($cs -and $cs.Model -imatch 'virtual|vmware|kvm|qemu|xen|hyper-v') { $isVM = $true }

    # Modern Standby, from the power capabilities Windows reports - $null when
    # they cannot be asked. And whether something has forced it off: with
    # PlatformAoAcOverride = 0 the capabilities read like an S3 machine, and the
    # option that set it still has to be recognisable as applying here.
    $aoac = $null
    try { if (Use-WDNative) { $v = [WD.Native]::PowerCapability(20); if ($v -ge 0) { $aoac = ($v -ne 0) } } } catch { }
    $aoacOff = $false
    try {
        $o = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'PlatformAoAcOverride' -ErrorAction Stop
        $aoacOff = ([int]$o.PlatformAoAcOverride -eq 0)
    } catch { }

    # Administrator protection (24H2 and later): with TypeOfAdminApprovalMode = 2
    # elevation goes through its own prompt policy, and ConsentPromptBehaviorAdmin
    # is not consulted at all.
    $adminProt = $false
    try {
        $t = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'TypeOfAdminApprovalMode' -ErrorAction Stop
        $adminProt = ([int]$t.TypeOfAdminApprovalMode -eq 2)
    } catch { }

    # Whether the system drive is already BitLocker-protected, read the way
    # Explorer reads it - unelevated, where Get-BitLockerVolume and
    # Win32_EncryptableVolume both need administrator rights. The property is
    # undocumented beyond 1 meaning protected, so only 1 counts; every other
    # answer, and the empty one SYSTEM gets, is $null, and a negated guard on
    # it keeps passing.
    $osEnc = $null
    try {
        $bl = (New-Object -ComObject Shell.Application).NameSpace("$sysDrive\").Self.ExtendedProperty('System.Volume.BitLockerProtection')
        if ($bl -is [int]) { $osEnc = ($bl -eq 1) }
    } catch { }

    # What the graphics kernel says the hardware can do - the facts dxdiag
    # prints as "Hardware Scheduling" and "MPO MaxPlanes". $null when it cannot
    # be asked, and a guard on an unknown passes. An overlay test mode an
    # earlier run wrote counts as overlays present, so the row that wrote it
    # stays on the page to be undone - the same rule as Modern Standby.
    $hagsOk = $null
    $mpoOk  = $null
    try {
        if (Use-WDNative) {
            $gc = [WD.Native]::GpuCaps()
            if ($gc[0] -ge 0) { $hagsOk = ($gc[0] -eq 1) }
            if ($gc[2] -ge 0) { $mpoOk  = ($gc[2] -gt 1) }
        }
    } catch { }
    try {
        $otm = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode' -ErrorAction Stop
        if ([int]$otm.OverlayTestMode -eq 5) { $mpoOk = $true }
    } catch { }

    # How far behind on Windows updates, counted in monthly security updates
    # missed. Windows 11 only: Windows 10 is out of support, so on most of those
    # machines there is nothing left to catch up on and a count would be a
    # complaint nobody can act on. $null when there is nothing to count from,
    # and a guard on an unknown passes.
    $latest = $null
    $missed = $null
    if ($build -ge 22000) {
        try { $latest = Get-WDLatestUpdate } catch { }
    }
    if ($latest) {
        # A quality-update deferral moves every release later by its days, so
        # a machine on one is not counted as missing what it has not been
        # offered yet.
        $defer = 0
        try {
            $wu = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction Stop
            if ([int](Get-Prop $wu 'DeferQualityUpdates' 0) -eq 1) { $defer = [int](Get-Prop $wu 'DeferQualityUpdatesPeriodInDays' 0) }
        } catch { }
        $missed = Get-WDUpdatesMissed -Built $latest.Built -DeferDays $defer
    }

    $script:Profile = [pscustomobject]@{
        PSTypeName      = 'WD.SystemProfile'
        ComputerName    = $env:COMPUTERNAME
        Caption         = $(if ($os) { $os.Caption } else { 'Windows' })
        DisplayVersion  = $(if ($reg -and $reg.PSObject.Properties['DisplayVersion']) { $reg.DisplayVersion } else { '' })
        Build           = $build
        UBR             = $ubr
        Edition         = $edition
        IsEnterprise    = ($edition -imatch 'Enterprise|Education|ServerRdsh')
        IsHome          = ($edition -imatch 'Core')      # Core / CoreSingleLanguage
        Architecture    = $env:PROCESSOR_ARCHITECTURE
        Manufacturer    = $manufacturer
        Vendor          = $vendor
        VendorLabel     = $(
            $labels = @{ hp='HP'; dell='Dell'; lenovo='Lenovo'; asus='ASUS'; acer='Acer'
                         msi='MSI'; samsung='Samsung'; razer='Razer'; framework='Framework'
                         microsoft='Microsoft'; toshiba='Toshiba'; vaio='VAIO'; gigabyte='Gigabyte'
                         lg='LG'; huawei='Huawei'; medion='Medion'; fujitsu='Fujitsu' }
            if ($labels.ContainsKey($vendor)) { $labels[$vendor] }
            elseif ($manufacturer) { (Get-Culture).TextInfo.ToTitleCase($manufacturer.ToLower()) }
            else { 'this manufacturer' }
        )
        Model           = $(if ($cs) { [string]$cs.Model } else { '' })
        IsPortable      = $isPortable
        HasTouch        = $touch
        HasBattery      = [bool]$bat
        IsVM            = $isVM
        ModernStandby   = $aoac
        ModernStandbyOverridden = $aoacOff
        AdminProtection = $adminProt
        OsEncrypted     = $osEnc
        GpuScheduling   = $hagsOk
        GpuOverlays     = $mpoOk
        # The newest monthly update and when Microsoft built it, as text - the
        # form the run log, the trace, and the refusal all print it in.
        LatestUpdate      =$(if ($latest) { [string]$latest.Kb } else { '' })
        LatestUpdateBuilt = $(if ($latest) { $latest.Built.ToString('yyyy-MM-dd') } else { '' })
        UpdatesMissed     = $missed
        IsDomainJoined  =$(if ($cs) { [bool]$cs.PartOfDomain } else { $false })
        GpuVendors      = @($gpu | ForEach-Object {
                              if ($_.Name -imatch 'nvidia')      { 'nvidia' }
                              elseif ($_.Name -imatch 'amd|radeon') { 'amd' }
                              elseif ($_.Name -imatch 'intel')   { 'intel' }
                           } | Sort-Object -Unique)
        PSVersion       = $PSVersionTable.PSVersion.ToString()
        SystemDrive     = $sysDrive
        DiskTotalBytes  = $diskTotal
        DiskFreeBytes   = $diskFree
        DiskUsedPercent = $diskUsed
        HasWinget       = [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
        HasPowerToys    = Test-WDPowerToys
        CopilotKey      = Test-WDCopilotKey
        IsAdmin         = $true    # entry point guarantees this
        SupportsAppxPolicy = ($build -ge 26200)   # 25H2 policy-based removal
    }

    $script:Profile
}

function Import-WDSystemProfile {
    param($Profile)
    if (-not $Profile -or -not $Profile.PSObject.Properties['Build']) { return $null }
    $script:Profile = $Profile
    $Profile
}

function Test-WDPowerToys {
    $paths = @(
        (Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'PowerToys\PowerToys.exe'),
        (Join-Path $env:LOCALAPPDATA 'PowerToys\PowerToys.exe')
    )
    foreach ($p in $paths) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $true }
    }
    $false
}

function Test-WDCopilotKey {
    # Present / Absent / Unknown. No authoritative flag exists, so the presence
    # of Windows' own customization keys is the proxy. Unknown proceeds: the
    # remap is inert without the key.
    $probes = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell\Copilot\CopilotKey',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Copilot\CopilotKey',
        'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\WindowsAI'
    )
    foreach ($p in $probes) {
        if (Test-Path -LiteralPath $p) { return 'Present' }
    }

    # Copilot keys only shipped on hardware built from 2024.
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        if ($bios.ReleaseDate -and $bios.ReleaseDate -lt (Get-Date '2024-01-01')) { return 'Absent' }
    } catch { }

    'Unknown'
}

# The newest monthly update on this machine, read from Windows' own servicing
# record rather than a table of release dates that would go stale. Every
# cumulative update is a Package_for_RollupFix package, and its manifest
# carries the time Microsoft built it: two to five days before release on every
# one checked (KB5124008 built 09-05 and out 09-08, KB5127648 built 10-10 and
# out 10-13). Only an installed package counts - CurrentState 112. A superseded
# one is 80, and one waiting on a restart is not on the machine yet. $null when
# there is no record to read.
function Get-WDLatestUpdate {
    $root = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
    $best = ''
    $bestVer = $null
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($root)
        if ($k) {
            try {
                foreach ($n in $k.GetSubKeyNames()) {
                    if (-not $n.StartsWith('Package_for_RollupFix~', [StringComparison]::OrdinalIgnoreCase)) { continue }
                    $v = $null
                    if (-not [version]::TryParse(($n -split '~')[-1], [ref]$v)) { continue }
                    $sk = $k.OpenSubKey($n)
                    if (-not $sk) { continue }
                    $st = $null
                    try { $st = $sk.GetValue('CurrentState') } finally { $sk.Close() }
                    if ($null -eq $st -or [int]$st -ne 112) { continue }
                    if ($null -eq $bestVer -or $v -gt $bestVer) { $best = $n; $bestVer = $v }
                }
            } finally { $k.Close() }
        }
    } catch { }
    if (-not $best) { return $null }

    $kb = ''
    $built = $null
    try {
        $mum  = Join-Path $env:windir "servicing\Packages\$best.mum"
        $head = (Get-Content -LiteralPath $mum -TotalCount 6 -ErrorAction Stop) -join ' '
        $m = [regex]::Match($head, 'creationTimeStamp="([^"]+)"')
        if ($m.Success) {
            $t = [datetime]::MinValue
            $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
            if ([datetime]::TryParse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$t)) { $built = $t }
        }
        $m = [regex]::Match($head, '\bKB\d+')
        if ($m.Success) { $kb = $m.Value }
    } catch { }
    if ($null -eq $built) { return $null }
    [pscustomobject]@{ Kb = $kb; Version = [string]$bestVer; Built = $built }
}

# Monthly security updates come out on Patch Tuesday, the second Tuesday of the
# month, so how many a machine is missing is a matter of the calendar: every one
# released since its own. Ten days of margin after the build, so the release of
# the update it does have is never counted against it. Out-of-band releases are
# fixes to a monthly one and are not counted.
function Get-WDUpdatesMissed {
    param(
        [Parameter(Mandatory)][datetime]$Built,
        [datetime]$Now = (Get-Date),
        [int]$DeferDays = 0
    )
    $after = $Built.Date.AddDays(10)
    $today = $Now.Date
    $n = 0
    $m = New-Object DateTime ($after.Year, $after.Month, 1)
    while ($m -le $today) {
        $pt = $m
        while ($pt.DayOfWeek -ne [DayOfWeek]::Tuesday) { $pt = $pt.AddDays(1) }
        $pt = $pt.AddDays(7)
        if ($pt -gt $after -and $pt.AddDays($DeferDays) -le $today) { $n++ }
        $m = $m.AddMonths(1)
    }
    $n
}

# Two, not one: a machine that has not installed this month's update yet, or
# one on a deferral, is one behind for part of every month and is not what this
# is about.
$script:UpdateLagLimit = 2

# The month the newest update is from, for sentences. '' when unknown.
function Format-WDUpdateMonth {
    param($Profile)
    $s = [string](Get-Prop $Profile 'LatestUpdateBuilt' '')
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($s, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$d)) { return '' }
    $d.ToString('MMMM yyyy', [Globalization.CultureInfo]::InvariantCulture)
}

function Test-WDGuard {
    param(
        [string[]]$Guards,
        $Profile
    )

    if (-not $Guards -or $Guards.Count -eq 0) { return $true }
    if (-not $Profile) { $Profile = Get-WDSystemProfile }

    foreach ($raw in $Guards) {
        if (-not $raw) { continue }
        $g = $raw.Trim()
        $negate = $false
        if ($g.StartsWith('!')) { $negate = $true; $g = $g.Substring(1) }

        $key = $g; $val = ''
        if ($g.Contains(':')) {
            $parts = $g.Split(':', 2)
            $key = $parts[0]; $val = $parts[1]
        }

        $pass = switch ($key.ToLower()) {
            'oem'     { ($val -split ',' | ForEach-Object { $_.Trim() }) -contains $Profile.Vendor }
            'chassis' { if ($val -ieq 'laptop') { $Profile.IsPortable } else { -not $Profile.IsPortable } }
            'edition' {
                switch ($val.ToLower()) {
                    'enterprise' { $Profile.IsEnterprise }
                    'home'       { $Profile.IsHome }
                    'pro'        { -not $Profile.IsHome -and -not $Profile.IsEnterprise }
                    default      { $Profile.Edition -ieq $val }
                }
            }
            'build' {
                if ($val -match '^(>=|<=|>|<|=)?\s*(\d+)$') {
                    $op = $Matches[1]; $n = [int]$Matches[2]
                    switch ($op) {
                        '>='    { $Profile.Build -ge $n }
                        '<='    { $Profile.Build -le $n }
                        '>'     { $Profile.Build -gt $n }
                        '<'     { $Profile.Build -lt $n }
                        default { $Profile.Build -eq $n }
                    }
                } else { $true }
            }
            # An unreadable drive reads as 0% and fails the guard, which is the
            # safe way round.
            'diskfull' {
                if ($val -match '^\d+$') { [int]$Profile.DiskUsedPercent -ge [int]$val } else { $true }
            }
            'gpu'     { $Profile.GpuVendors -contains $val.ToLower() }
            'touch'   { $Profile.HasTouch }
            'battery' { $Profile.HasBattery }
            'vm'      { $Profile.IsVM }
            'winget'  { $Profile.HasWinget }
            'domain'  { $Profile.IsDomainJoined }
            # standby:modern - a Modern Standby machine, including one whose
            # Modern Standby an earlier run switched off. Unknown passes, like
            # an unknown guard: a profile that could not ask, or one cached by an
            # older build, must not hide rows it knows nothing about.
            'standby' {
                $ms = $null
                if ($Profile.PSObject.Properties['ModernStandby']) { $ms = $Profile.ModernStandby }
                $off = [bool](Get-Prop $Profile 'ModernStandbyOverridden' $false)
                if ($null -eq $ms) { $true }
                elseif ($val -ieq 'modern') { [bool]$ms -or $off }
                elseif ($val -ieq 's3')     { -not [bool]$ms -and -not $off }
                else { $true }
            }
            # Read through Get-Prop, so a profile cached before this existed
            # reads as "off" and "!adminprotection" keeps passing.
            'adminprotection' { [bool](Get-Prop $Profile 'AdminProtection' $false) }
            # Unknown reads as "not encrypted", for the same reason.
            'osencrypted'     { [bool](Get-Prop $Profile 'OsEncrypted' $false) }
            # Hardware facts where unknown, or a profile cached before these
            # existed, reads as "capable": the row stays rather than vanishing
            # on a machine nothing could ask.
            'hags'    { $hv = Get-Prop $Profile 'GpuScheduling' $null; if ($null -eq $hv) { $true } else { [bool]$hv } }
            'mpo'     { $mv = Get-Prop $Profile 'GpuOverlays' $null;   if ($null -eq $mv) { $true } else { [bool]$mv } }
            # current - fewer than two monthly security updates behind. Unknown
            # passes, like every other machine fact here.
            'current' { $um = Get-Prop $Profile 'UpdatesMissed' $null; if ($null -eq $um) { $true } else { [int]$um -lt $script:UpdateLagLimit } }
            default   { $true }    # unknown guard never blocks
        }

        if ($negate) { $pass = -not $pass }
        if (-not $pass) { return $false }
    }
    $true
}

function Get-WDGuardFailure {
    param([string[]]$Guards, $Profile)

    if (-not $Guards -or $Guards.Count -eq 0) { return '' }
    if (-not $Profile) { $Profile = Get-WDSystemProfile }

    foreach ($raw in $Guards) {
        if (-not $raw) { continue }
        if (Test-WDGuard -Guards @($raw) -Profile $Profile) { continue }

        $g = ([string]$raw).Trim()
        $negate = $false
        if ($g.StartsWith('!')) { $negate = $true; $g = $g.Substring(1) }
        $key = $g; $val = ''
        if ($g.Contains(':')) {
            $parts = $g.Split(':', 2)
            $key = $parts[0]; $val = $parts[1]
        }
        # $wants is what a passing machine looks like, $here is what this one
        # is. Negation swaps which of the two is the complaint.
        $wants = switch ($key.ToLower()) {
            # 'generic' is what an unrecognised manufacturer resolves to, not a
            # company that makes anything.
            'oem'      { if ($val -ieq 'generic') { 'machines with no recognised manufacturer' } else { "machines made by $val" } }
            'chassis'  { "$($val.ToLower())s" }
            'edition'  { "Windows $val" }
            'build'    { "Windows build $val" }
            'gpu'      { "a $val graphics adapter" }
            'diskfull' { "a system drive at least $val% full" }
            'touch'    { 'a touchscreen' }
            'battery'  { 'a machine with a battery' }
            'vm'       { 'a virtual machine' }
            'winget'   { 'winget, the Windows package manager' }
            'domain'   { 'a domain-joined machine' }
            'standby'  { if ($val -ieq 'modern') { 'a machine that sleeps with Modern Standby' } else { 'a machine that sleeps in S3' } }
            'adminprotection' { 'a machine with Administrator protection turned on' }
            'osencrypted'     { 'a machine whose system drive is already BitLocker-encrypted' }
            'hags'     { 'a graphics adapter that supports hardware-accelerated GPU scheduling' }
            'mpo'      { 'a display that uses multi-plane overlays' }
            'current'  { 'a machine that is caught up on Windows updates' }
            default    { "'$g'" }
        }
        $here = switch ($key.ToLower()) {
            'oem'      { if ([string]$Profile.Vendor -ieq 'generic') { 'this one has no recognised manufacturer' } else { "this one is $([string]$Profile.Vendor)" } }
            'chassis'  { "this is a $(if ($Profile.IsPortable) { 'laptop' } else { 'desktop' })" }
            'edition'  { "this is $([string]$Profile.Edition)" }
            'build'    { "this is build $([int]$Profile.Build)" }
            'diskfull' { "this one is $([int]$Profile.DiskUsedPercent)% full" }
            'current'  { "this one's newest update is from $(Format-WDUpdateMonth $Profile), with $([int](Get-Prop $Profile 'UpdatesMissed' 0)) monthly security updates out since" }
            default    { 'this machine is not one' }
        }
        if ($negate) { return "it is not for $wants, and this machine is one" }
        return "it is for $wants, and $here"
    }
    ''
}

# An option that is offered here but refused for now, as the sentence saying
# why and what to do about it - '' when nothing stands in the way. Unlike
# guards, which take a row off a machine where it can only do nothing,
# refuseUnless is for a row that would do something and must not yet: the page
# shows it disabled with this text, and a run that names it anyway reports it
# Skipped with the same text. Both ask here, so the two cannot disagree.
function Get-WDRefusal {
    param($Item, $Profile)
    $g = @(Get-Prop $Item 'refuseUnless' @())
    if (-not $g.Count) { return '' }
    if (-not $Profile) { $Profile = Get-WDSystemProfile }
    foreach ($raw in $g) {
        if (Test-WDGuard -Guards @($raw) -Profile $Profile) { continue }
        if (([string]$raw).Trim() -ieq 'current') {
            $n = [int](Get-Prop $Profile 'UpdatesMissed' 0)
            return "Unavailable until Windows Update has caught up. This machine's newest update is from " +
                   "$(Format-WDUpdateMonth $Profile), and the $n monthly security updates since would be held back. " +
                   'Run Windows Update until it has nothing left to install, restart, and open the toolkit again.'
        }
        return "Unavailable on this machine: $(Get-WDGuardFailure -Guards @($raw) -Profile $Profile)."
    }
    ''
}

$script:UserHiveCache = $null

function Clear-WDUserHiveCache { $script:UserHiveCache = $null }

function Use-WDUserHiveDrive {
    # Global scope, or the drive dies when this function returns while the
    # HKU:\<sid> paths it handed out live on.
    if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) { return $true }
    $null = New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -Scope Global -ErrorAction SilentlyContinue
    [bool](Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)
}

function Get-WDUserHives {
    # Cached: a hive cannot load or unload mid-run without somebody signing in
    # or out, and this was walked ~70 times per run.
    if ($null -ne $script:UserHiveCache) { return $script:UserHiveCache }
    $null = Use-WDUserHiveDrive

    $hives = New-Object System.Collections.Generic.List[psobject]
    $hives.Add([pscustomobject]@{ Name = 'CurrentUser'; Path = 'HKCU:'; Mounted = $false })

    foreach ($sub in (Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue)) {
        $sid = Split-Path $sub.Name -Leaf
        # Real user SIDs only - skip machine, service, and _Classes shadows.
        if ($sid -notmatch '^S-1-5-21-[\d\-]+$') { continue }
        if ($sid -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { continue }
        $hives.Add([pscustomobject]@{ Name = $sid; Path = "HKU:\$sid"; Mounted = $false })
    }
    $script:UserHiveCache = $hives
    $hives
}

$script:FUTURE_ACCOUNT = 'DefaultProfile'

function Get-WDUserAccounts {
    # Key matches what Get-WDUserHives calls the hive, so nothing has to map
    # display names back to SIDs.
    # Only loaded hives are reachable, and the last entry is the default profile
    # rather than an account.
    $out = New-Object System.Collections.Generic.List[psobject]
    $me  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $out.Add([pscustomobject]@{
        Key = 'CurrentUser'; Name = $me.Name; Sid = $me.User.Value
        Kind = 'account'; Note = 'The account this is running as.'
    })

    $null = Use-WDUserHiveDrive
    foreach ($sub in (Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue)) {
        $sid = Split-Path $sub.Name -Leaf
        if ($sid -notmatch '^S-1-5-21-[\d\-]+$') { continue }
        if ($sid -eq $me.User.Value) { continue }
        $name = $sid
        try {
            $name = (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value
        } catch { }
        $out.Add([pscustomobject]@{
            Key = $sid; Name = $name; Sid = $sid
            Kind = 'account'; Note = 'Another account signed in on this machine.'
        })
    }

    $out.Add([pscustomobject]@{
        Key = $script:FUTURE_ACCOUNT; Name = 'Accounts created later'; Sid = ''
        Kind = 'future'
        Note = 'Written into the default profile, which is what a new account copies its settings from. Not an account that exists yet.'
    })
    $out.ToArray()
}

function Get-WDInitialAccountTicks {
    # Which account boxes start ticked: the saved choice where one names an
    # account this machine has, and every account otherwise. The property is
    # read directly, never through @(Get-Prop ...): a machine that has never
    # saved a choice stores accounts = null, Get-Prop hands that back as a
    # single $null, and @() of it is a one-element list holding nothing - which
    # read as "a choice was saved" and started every box unticked, so the first
    # run on a new machine wrote every per-user setting to no account at all.
    # An empty or stale list falls back to all too: it is what an early save
    # writes before the boxes exist, and silently skipping every per-user
    # setting is not a choice to infer.
    param($UiState, [string[]]$Keys)
    $saved = @()
    if ($UiState) {
        $p = $UiState.PSObject.Properties['accounts']
        if ($p -and $null -ne $p.Value) { $saved = @(@($p.Value) | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
    }
    $hit = @($Keys | Where-Object { $_ -in $saved })
    if (-not $hit.Count) { return @($Keys) }
    $hit
}

function Get-WDContextAccounts {
    # Read as a property, never through Get-Prop: that returns through the
    # pipeline, which unrolls an empty list to $null - and $null here means
    # every account.
    param($Context)
    if (-not $Context) { return $null }
    $p = $Context.PSObject.Properties['Accounts']
    if (-not $p -or $null -eq $p.Value) { return $null }
    ,@($p.Value)
}

function Select-WDAccountHives {
    # $null means every account, which is what the command line and the re-apply
    # guards pass.
    param($Hives, $Default, [string[]]$Accounts)

    $roots = @($Hives)
    $def   = @($Default | Where-Object { $_ })
    if ($null -eq $Accounts) { return @($roots) + $def }

    $want = @($Accounts)
    $roots = @($roots | Where-Object { [string]$_.Name -in $want })
    if ($script:FUTURE_ACCOUNT -notin $want) { $def = @() }
    @($roots) + $def
}

function Mount-WDDefaultHive {
    # Loads C:\Users\Default\NTUSER.DAT so accounts made later inherit these
    # settings.
    $dat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $dat)) { return $null }

    # Both streams redirected: unelevated, reg.exe prints its refusal to the
    # console and that reads as a crash.
    $key = 'WD_DEFAULT'
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process reg.exe -ArgumentList @('load', "HKU\$key", "`"$dat`"") `
                           -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err -EA SilentlyContinue
        if ($p -and $p.ExitCode -eq 0) {
            # reg.exe loads under HKEY_USERS, which does not create the PS
            # drive.
            $null = Use-WDUserHiveDrive
            return [pscustomobject]@{ Name = 'DefaultProfile'; Path = "HKU:\$key"; Mounted = $true; HiveKey = $key }
        }
    } catch {
    } finally {
        Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    }
    $null
}

function Dismount-WDDefaultHive {
    # Remove the PSDrive first - that is what releases the provider's key
    # handles; collecting alone leaves them and the hive will not unload.
    # Retries and then verifies: a stranded mount rides along in every later
    # boot and blocks the rollback script's own load.
    param($Hive)
    if (-not $Hive -or -not $Hive.Mounted) { return }

    $key   = [string]$Hive.HiveKey
    $last  = ''
    for ($try = 1; $try -le 3; $try++) {
        Remove-PSDrive -Name HKU -Force -ErrorAction SilentlyContinue
        [gc]::Collect(); [gc]::WaitForPendingFinalizers(); [gc]::Collect()
        $so = [IO.Path]::GetTempFileName(); $se = [IO.Path]::GetTempFileName()
        try {
            $null = Start-Process reg.exe -ArgumentList @('unload', "HKU\$key") `
                                  -NoNewWindow -Wait -RedirectStandardOutput $so -RedirectStandardError $se -EA SilentlyContinue
            $last = ((Get-Content -LiteralPath $se -Raw -EA SilentlyContinue) + (Get-Content -LiteralPath $so -Raw -EA SilentlyContinue)).Trim()
        } catch {
            $last = $_.Exception.Message
        } finally {
            Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
        }
        # $null =, because it answers a boolean: bare, that $true went out of
        # Invoke-WDPlan's finally alongside the results, and an elevated run's
        # report counted two entries - $true and the list - with every total
        # at zero. Unelevated the hive never mounts, so no test saw it.
        $null = Use-WDUserHiveDrive
        if (-not (Test-Path -LiteralPath "HKU:\$key")) {
            $Hive.Mounted = $false
            return
        }
        Start-Sleep -Milliseconds 250
    }
    Write-WDLog ("The default user profile ($key) could not be unmounted and is still loaded. " +
                 "Nothing is broken by it, but it should not be left behind - from an administrator " +
                 "prompt, run: reg unload HKU\$key. ($last)") -Level Warn
}

Export-ModuleMember -Function *-WD*
