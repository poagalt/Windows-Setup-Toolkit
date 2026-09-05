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
        IsDomainJoined  = $(if ($cs) { [bool]$cs.PartOfDomain } else { $false })
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
            'oem'      { "machines made by $val" }
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
            default    { "'$g'" }
        }
        $here = switch ($key.ToLower()) {
            'oem'      { "this one is $([string]$Profile.Vendor)" }
            'chassis'  { "this is a $(if ($Profile.IsPortable) { 'laptop' } else { 'desktop' })" }
            'edition'  { "this is $([string]$Profile.Edition)" }
            'build'    { "this is build $([int]$Profile.Build)" }
            'diskfull' { "this one is $([int]$Profile.DiskUsedPercent)% full" }
            default    { 'this machine is not one' }
        }
        if ($negate) { return "it is not for $wants, and this machine is one" }
        return "it is for $wants, and $here"
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
        Use-WDUserHiveDrive
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
