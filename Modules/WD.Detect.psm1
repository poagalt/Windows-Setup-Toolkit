<#
    WD.Detect - everything the engine needs to know about the machine it woke
    up on. Nothing in this module writes; it only reports.

    The whole toolkit is portable across brands because this is the only place
    that knows what brand it is. Manifest entries declare guards like
    "oem:lenovo" or "chassis:laptop" and the engine asks Test-WDGuard.
#>

$script:Profile = $null

# GetSystemMetrics comes from [WD.Native], which WD.Core defines. It used to be
# compiled here, at import, which put a csc invocation on the launch path for a
# single call that answers one guard. See the native note at the top of
# WD.Core.psm1 for why every one of those was worth moving.

# Chassis types that mean "portable" per the SMBIOS spec.
$script:PortableChassis = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)

# Normalizes the wild variety of strings vendors put in SMBIOS.
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

    # How full the system drive is. Cheap, and it decides whether the storage
    # section is worth showing at all - an item that frees 8 GB is noise on a
    # drive with 400 GB spare and the point of the page on one with 20.
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
    # Virtual machines report chassis 1 but a battery is still the better tell.
    if (-not $isPortable -and $bat) { $isPortable = $true }

    # SM_DIGITIZER = 94; low byte non-zero means an integrated digitiser exists.
    # Use-WDNative is what makes sure the type is there - on the launch path it
    # was compiled in the background while the modules were loading, so this
    # costs nothing; anywhere else it compiles on the spot.
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
        # SMBIOS gives things like "LENOVO"; this is the form to put in front of
        # a person.
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
    <#
        Seeds this runspace's cache with a profile that was read somewhere else.

        The startup scan runs on a runspace of its own and reads the profile
        there because it needs one; handing that answer back is what stops the
        main thread spending another second on the same six CIM queries. The
        cache matters as much as the variable does - plenty of functions here
        take -Profile optionally and call Get-WDSystemProfile when it is absent,
        and every one of those would otherwise pay for the read again, on the UI
        thread, at whatever moment it happened to be called.

        Refuses anything that is not a profile rather than caching a wrong
        answer: a bad seed here would be believed by everything downstream.
    #>
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
    <#
        Returns Present / Absent / Unknown.

        There is no single authoritative flag for "this keyboard has a Copilot
        key". Windows only surfaces its own customization UI when one exists,
        so the presence of those settings keys is the best proxy we have. On
        Unknown we let the caller proceed - the remap is inert on a machine
        with no such key, so a false positive costs nothing.
    #>
    $probes = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell\Copilot\CopilotKey',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Copilot\CopilotKey',
        'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\WindowsAI'
    )
    foreach ($p in $probes) {
        if (Test-Path -LiteralPath $p) { return 'Present' }
    }

    # Secondary signal: Copilot keys only shipped on hardware built from 2024,
    # so anything older almost certainly does not have one.
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        if ($bios.ReleaseDate -and $bios.ReleaseDate -lt (Get-Date '2024-01-01')) { return 'Absent' }
    } catch { }

    'Unknown'
}

function Test-WDGuard {
    <#
        Evaluates a manifest guard expression against the current machine.

        Supported forms, all case-insensitive:
            oem:lenovo            vendor match (comma-separated list allowed)
            chassis:laptop        laptop | desktop
            edition:enterprise    enterprise | home | pro
            build:>=26100         numeric comparison on the OS build
            gpu:nvidia            a GPU from that vendor is present
            touch                 an integrated digitiser is present
            battery               a battery is present
            vm                    running in a virtual machine
            winget                winget is on PATH
        Prefix any guard with ! to negate it. All guards in the list must pass.
    #>
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
            # diskfull:70 - the system drive is at least 70% used. Nothing to do
            # with risk; it decides whether the storage clean-ups are worth
            # putting on screen. An unreadable drive reads as 0% and hides them,
            # which is the right way round for a guess.
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
    <#
        Which guard in a list this machine fails, said in words somebody who has
        never read the manifest can act on. Empty when they all pass.

        Test-WDGuard answers yes or no, which is all a filter needs. This is for
        the one place that has to explain itself: a selection loaded from a file
        drops the options this machine cannot run, and "12 of 48 apply here" is
        a number somebody is entitled to see the reasoning behind - especially
        when the reason is "that file was saved on a Lenovo".

        Evaluated one guard at a time through Test-WDGuard rather than
        re-implementing the comparisons, so the two can never disagree about
        which guard failed.
    #>
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
        # Two phrasings per guard: what a passing machine looks like, and what
        # this one is. The negated form swaps which of the two is the complaint.
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
    <#
        HKU: is not one of PowerShell's default drives, and New-PSDrive without
        a scope creates it in the CALLER'S scope - so a drive made inside a
        function is gone the moment that function returns, taking every
        'HKU:\<sid>' path it just handed back with it. The paths outlive the
        drive, reach Join-Path in the registry executor, and throw
        DriveNotFoundException there: 42 of the 135 items in a Balanced run,
        every one of them an allusers write, on an elevated machine.

        The failure names neither the drive's scope nor the function that made
        it, which is why it read as a permissions problem. Global, once, and
        guarded, so every per-account path resolves for the life of the process.
    #>
    if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) { return $true }
    $null = New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -Scope Global -ErrorAction SilentlyContinue
    [bool](Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)
}

function Get-WDUserHives {
    <#
        Every loaded user hive plus the default profile, so per-user tweaks can
        be applied to accounts that exist now and to accounts made later.
        Returns PS-drive style roots under a process-wide HKU: drive.

        Cached for the life of the process, because a hive cannot be loaded or
        unloaded in the middle of a run without somebody signing in or out, and
        this was being walked once per per-user action - about seventy HKU
        enumerations in a full run, all returning the same answer.
        Clear-WDUserHiveCache exists for the self test, which fabricates hives.
    #>
    if ($null -ne $script:UserHiveCache) { return $script:UserHiveCache }
    $null = Use-WDUserHiveDrive

    $hives = New-Object System.Collections.Generic.List[psobject]
    $hives.Add([pscustomobject]@{ Name = 'CurrentUser'; Path = 'HKCU:'; Mounted = $false })

    foreach ($sub in (Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue)) {
        $sid = Split-Path $sub.Name -Leaf
        # Real user SIDs only - skip machine, service and _Classes shadows.
        if ($sid -notmatch '^S-1-5-21-[\d\-]+$') { continue }
        if ($sid -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { continue }
        $hives.Add([pscustomobject]@{ Name = $sid; Path = "HKU:\$sid"; Mounted = $false })
    }
    $script:UserHiveCache = $hives
    $hives
}

$script:FUTURE_ACCOUNT = 'DefaultProfile'

function Get-WDUserAccounts {
    <#
        The accounts a run can reach, in a form a person can tick.

        Each entry's Key matches what Get-WDUserHives calls that hive, so the
        interface and the executor are naming the same thing - a list of
        display names that had to be mapped back to SIDs somewhere in between
        is how the wrong account gets written to.

        Two limits worth knowing, both reported rather than hidden. Only
        *loaded* hives can be reached, so an account nobody has signed into
        since the last boot is not on this list and never was - that is a
        pre-existing property of writing to another user's registry, not
        something this choice introduced. And the last entry is not an account
        at all: it is the default profile, which is what accounts created later
        inherit from.
    #>
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
    <#
        The account selection off a run context, read as a property rather than
        through Get-Prop.

        Get-Prop cannot return an empty list. Its result leaves the function
        through the pipeline, the pipeline unrolls an empty array to nothing at
        all, and the caller gets $null - which here means the exact opposite of
        what was asked for: "no accounts" would come back as "every account" and
        write to every hive on the machine. Property access does not unroll.
    #>
    param($Context)
    if (-not $Context) { return $null }
    $p = $Context.PSObject.Properties['Accounts']
    if (-not $p -or $null -eq $p.Value) { return $null }
    ,@($p.Value)
}

function Select-WDAccountHives {
    <#
        Narrows a hive list to the accounts a run was told to touch. A $null
        selection means every account, which is what the command line, the
        re-apply guards and every release before this one do - so the filter has
        to be opt-in or a saved plan would quietly start doing less.
    #>
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
    <#  Loads C:\Users\Default\NTUSER.DAT so new accounts inherit our settings.  #>
    $dat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $dat)) { return $null }

    # reg.exe writes its refusal straight to the console when unelevated, which
    # looks like a crash to anyone watching. Swallow both streams and let the
    # caller treat a null return as "default profile unavailable".
    $key = 'WD_DEFAULT'
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process reg.exe -ArgumentList @('load', "HKU\$key", "`"$dat`"") `
                           -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err -EA SilentlyContinue
        if ($p -and $p.ExitCode -eq 0) {
            # reg.exe loads the hive under HKEY_USERS, which says nothing about
            # whether this process has a drive named HKU to reach it through.
            # This is the path every allusers write goes down, so the drive has
            # to exist before the path is handed out rather than wherever it is
            # eventually used.
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
    <#
        Unmount the default profile, and make sure it actually went.

        A hive with an open key handle will not unload, and this run has just
        written every scope:allusers value into it through PowerShell's registry
        provider - which keeps those handles alive until they are collected. One
        collect and no check was not enough: on a real machine the mount survived
        the run and was still there days later, with nothing anywhere saying so.

        Three things the first version was missing. The PSDrive is removed first,
        which is what actually releases the provider's handles - collecting alone
        leaves them. It retries, because the first attempt can lose a race with
        the finalizer thread. And it VERIFIES, so a failure is reported instead
        of being indistinguishable from success: a stranded mount rides along in
        every later boot, and the rollback script cannot load its own copy while
        somebody else's is in the way.
    #>
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
