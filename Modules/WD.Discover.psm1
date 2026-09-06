# Windows itself. Removing any of these breaks the shell, servicing, sign-in, or
# app deployment.
$script:ProtectedAppx = @(
    # Frameworks and runtimes every Store app links against
    'Microsoft.NET.Native.*', 'Microsoft.VCLibs.*', 'Microsoft.UI.Xaml.*'
    'Microsoft.WindowsAppRuntime.*', 'MicrosoftCorporationII.WinAppRuntime.*'
    'Microsoft.Services.Store.Engagement', 'Microsoft.DirectXRuntime'
    # Shell, sign-in, and system UI hosts
    'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost'
    'MicrosoftWindows.Client.Core', 'MicrosoftWindows.Client.CBS', 'MicrosoftWindows.Client.FileExp'
    'MicrosoftWindows.Client.Photon', 'MicrosoftWindows.Client.OOBE'
    'windows.immersivecontrolpanel', 'Windows.PrintDialog', 'Windows.CBSPreview'
    'Microsoft.Windows.CloudExperienceHost', 'Microsoft.AccountsControl'
    'Microsoft.AAD.BrokerPlugin', 'Microsoft.CredDialogHost', 'Microsoft.LockApp'
    'Microsoft.Windows.ContentDeliveryManager'   # configured, never removed
    'Microsoft.BioEnrollment', 'Microsoft.ECApp', 'Microsoft.Win32WebViewHost'
    'Microsoft.Windows.Apprep.ChxApp', 'Microsoft.Windows.AssignedAccessLockApp'
    'Microsoft.Windows.CapturePicker', 'Microsoft.Windows.NarratorQuickStart'
    'Microsoft.Windows.OOBENetwork*', 'Microsoft.Windows.ParentalControls'
    'Microsoft.Windows.PinningConfirmationDialog', 'Microsoft.Windows.PrintQueueActionCenter'
    'Microsoft.Windows.SecureAssessmentBrowser', 'Microsoft.Windows.XGpuEjectDialog'
    'Microsoft.SecHealthUI'                       # Windows Security UI
    'Microsoft.DesktopAppInstaller', 'Microsoft.Winget.Source'   # winget itself
    'Microsoft.AsyncTextService'                  # touch keyboard / text input
    'Microsoft.Ink.*'                             # handwriting recognition packs
    'Microsoft.CommandPalette', 'Microsoft.Windows.PeopleExperienceHost'
    # Media codecs - removing these silently breaks video and image playback
    'Microsoft.HEIFImageExtension', 'Microsoft.HEVCVideoExtension', 'Microsoft.VP9VideoExtensions'
    'Microsoft.WebMediaExtensions', 'Microsoft.WebpImageExtension', 'Microsoft.RawImageExtension'
    'Microsoft.AV1VideoExtension', 'Microsoft.AVCEncoderVideoExtension', 'Microsoft.MPEG2VideoExtension'
    # Obfuscated in-box accessibility packages (voice access, live captions)
    'MicrosoftWindows.5*', 'MicrosoftWindows.6*'
)

$script:ProtectedPrograms = @(
    'Microsoft Visual C++*', 'Microsoft .NET*', 'Microsoft ASP.NET*', 'Windows Driver Package*'
    'Microsoft Edge WebView2 Runtime', 'Microsoft GameInput*', 'DirectX*'
    'Intel*Chipset*', 'Intel*Management Engine*', 'Intel*Serial IO*', 'Intel*Trusted Connect*'
    'Intel*Graphics*', 'Intel Arc*', 'Intel*Wireless*', 'Intel*Bluetooth*', 'Intel*Thunderbolt*'
    'Realtek*', 'Synaptics*', 'ELAN*', 'Conexant*', 'Cirrus*', 'Waves Maxx*', 'Dolby*'
    'NVIDIA Graphics Driver*', 'NVIDIA PhysX*', 'NVIDIA Install*', 'NVIDIA Control Panel*'
    'NVIDIA*Container*', 'NVIDIA*Driver*', 'NVIDIA MessageBus*', 'NVIDIA Platform Controllers*'
    'AMD Chipset*', 'AMD Software*', 'AMD Ryzen*', 'Qualcomm*', 'MediaTek*', 'Killer*'
    'Windows Security*', 'Microsoft Defender*', 'Windows Defender*', 'Windows Assessment*'
)

# A binary that versions itself as part of Windows is part of Windows, wherever
# on disk it lives.
$script:WindowsProductNames = @(
    'Microsoft* Windows*', 'Windows* Operating System'
)

# Vendor tools that own power, thermals, firmware, or input are system
# dependencies on the hardware they ship with.
$script:ProtectedVendorTools = @{
    lenovo    = @('Lenovo Vantage*', 'Lenovo Commercial Vantage*', 'Lenovo System Interface*',
                  'Lenovo Utility*', 'Lenovo Hotkey*', 'Legion*', 'Lenovo Power*', 'Lenovo Intelligent*',
                  'LenovoVantage*', 'VantageService*')
    dell      = @('Dell Power Manager*', 'Dell Command*', 'Dell Optimizer*', 'Dell Thermal*',
                  'Dell Display Manager*', 'Dell Pair*')
    hp        = @('HP Power Manager*', 'HP Hotkey*', 'HP System Event Utility*', 'HP Firmware*',
                  'HP Programmable Key*', 'HP Thermal*', 'HP Audio*', 'HP Display*')
    asus      = @('Armoury Crate*', 'ASUS System Control Interface*', 'MyASUS Service*',
                  'ASUS Framework*', 'ASUS Smart Display*')
    acer      = @('Acer Quick Access*', 'NitroSense*', 'PredatorSense*', 'Acer Power*')
    msi       = @('MSI Center*', 'Dragon Center*', 'MSI SDK*')
    samsung   = @('Samsung Settings*', 'Samsung Device*')
    razer     = @('Razer Synapse*', 'Razer Chroma*')
    framework = @('Framework*')
    microsoft = @('Surface*')
    generic   = @()
}

# Intel XTU owns CPU voltage, turbo, and thermal limits, and the profile it last
# applied persists in firmware - remove it and an undervolt stays in force with
# nothing left that can change it.
$script:ProtectedHardwareTools = @(
    'X-Rite*', 'Portrait Displays*', 'Logitech*', 'Logi Options*', 'LGHUB*'
    'Corsair iCUE*', 'SteelSeries*', 'Elgato*', 'Wacom*', 'Focusrite*', 'ASIO*'
    '*Extreme Tuning Utility*', '*Intel*XTU*', 'XTU_*', 'Intel*Overclocking*'
)

$script:ProtectedServices = @(
    # Servicing and update - removing these strands the machine unpatched
    'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'BITS', 'CryptSvc', 'TrustedInstaller', 'msiserver'
    'DeliveryOptimization', 'DoSvc', 'sppsvc', 'ClipSVC', 'LicenseManager', 'AppXSvc', 'StateRepository'
    # Security
    'WinDefend', 'SecurityHealthService', 'wscsvc', 'mpssvc', 'BFE', 'SgrmBroker', 'EventLog'
    # Core plumbing
    'RpcSs', 'RpcEptMapper', 'DcomLaunch', 'Power', 'PlugPlay', 'Schedule', 'ProfSvc', 'UserManager'
    'Themes', 'AudioSrv', 'AudioEndpointBuilder', 'Audiosrv', 'Dhcp', 'Dnscache', 'NlaSvc', 'netprofm'
    'nsi', 'LanmanWorkstation', 'LanmanServer', 'WlanSvc', 'WwanSvc', 'BthAvctpSvc', 'bthserv'
    'DispBrokerDesktopSvc', 'DisplayEnhancementService', 'SystemEventsBroker', 'TimeBrokerSvc'
    'CoreMessagingRegistrar', 'LSM', 'Winmgmt', 'SamSs', 'KeyIso', 'VaultSvc', 'SENS', 'ShellHWDetection'
    'StorSvc', 'SysMain', 'gpsvc', 'W32Time', 'FontCache', 'DsmSvc', 'DeviceInstall', 'DevQueryBroker'
    'seclogon', 'UmRdpService', 'TermService', 'WdiServiceHost', 'WdiSystemHost', 'DPS'
)

function Test-WDPatternMatch {
    param([string]$Value, [string[]]$Patterns)
    if (-not $Value) { return $false }
    foreach ($p in $Patterns) {
        if ($Value -like $p) { return $true }
    }
    $false
}

function Get-WDTaskFacts {
    # Both come out of one walk: the COM object carries Enabled next to Path.
    $paths = New-Object System.Collections.Generic.List[string]
    $off   = New-Object System.Collections.Generic.List[string]
    $svc = $null
    try {
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect()
    } catch { return [pscustomobject]@{ Paths = @(); Disabled = @() } }

    $stack = New-Object System.Collections.Generic.Stack[object]
    try { $stack.Push($svc.GetFolder('\')) } catch { return [pscustomobject]@{ Paths = @(); Disabled = @() } }
    while ($stack.Count) {
        $f = $stack.Pop()
        try {
            foreach ($t in $f.GetTasks(1)) {
                $p = [string]$t.Path
                $paths.Add($p)
                try { if (-not $t.Enabled) { $off.Add($p) } } catch { }
            }
        } catch { }
        try { foreach ($sub in $f.GetFolders(0)) { $stack.Push($sub) } } catch { }
    }
    [pscustomobject]@{ Paths = $paths.ToArray(); Disabled = $off.ToArray() }
}

function Get-WDTaskInventory {
    (Get-WDTaskFacts).Paths
}

function Get-WDMachineInventory {
    # Built from what the scan already has where possible - re-enumerating Store
    # packages is the slowest thing this toolkit does.
    param([string[]]$AppxNames, [string[]]$ServiceNames, [string[]]$InboxNames)

    if ($null -eq $AppxNames) {
        $AppxNames = @()
        $inbox     = @()
        try {
            $all = @(Get-AppxPackage -ErrorAction SilentlyContinue)
            $AppxNames = @($all | ForEach-Object { [string]$_.Name })
            $inbox     = @($all | Where-Object { $_.NonRemovable -eq $true } | ForEach-Object { [string]$_.Name })
        } catch { }
        if ($null -eq $InboxNames) { $InboxNames = $inbox }
    }
    if ($null -eq $ServiceNames) {
        $ServiceNames = @()
        try { $ServiceNames = @(Get-Service -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name }) } catch { }
    }
    $taskFacts = Get-WDTaskFacts
    [pscustomobject]@{
        Appx     = @($AppxNames)
        # The NonRemovable subset: in-box CBS components and shell hosts that no
        # privilege, ownership change, or policy removes.
        Inbox    = @($InboxNames)
        Services = @($ServiceNames)
        Programs = @(Get-WDInstalledPrograms)
        Tasks    = @($taskFacts.Paths)
        # The already-disabled subset, from the same walk.
        TasksOff = @($taskFacts.Disabled)
    }
}

function Get-WDItemPresence {
    # Returns id -> @{Present; Bytes; Counted; Blind}. Present is three-valued:
    # $true and $false are answers, $null is "no opinion" - which is what any
    # action type this cannot ask about forces.
    param($Categories, $Inventory, $Profile)

    if (-not $Inventory) { $Inventory = Get-WDMachineInventory }
    $appx  = @($Inventory.Appx)
    $svcs  = @($Inventory.Services)
    $progs = @($Inventory.Programs)
    $tasks = @($Inventory.Tasks)
    $tasksOff = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in @($Inventory.TasksOff)) { $null = $tasksOff.Add([string]$t) }

    # Nested loops, not pipelines, and that is why this can run at startup: as a
    # Where-Object per package with a second pipeline inside, 64 appx actions
    # against 147 packages was ~9,500 scriptblock invocations. Parameter binding
    # is the cost, never the comparison.
    $progNames = New-Object 'string[]' $progs.Count
    for ($i = 0; $i -lt $progs.Count; $i++) { $progNames[$i] = [string]$progs[$i].DisplayName }

    # Walked once each rather than once per action.
    $lnkCache = @{}

    $out = @{}
    foreach ($cat in $Categories) {
        foreach ($item in @($cat.items)) {
            $id = [string]$item.id
            $acts = @(Get-Prop $item 'actions' @())
            if (-not $acts.Count) { continue }

            $known = 0; $found = 0; $opaque = $false
            $bytes = 0L; $blind = 0
            foreach ($a in $acts) {
                # An action whose guards fail never runs here, so it can neither
                # make the item present nor keep it outstanding.
                $ag = @(Get-Prop $a 'guards' @())
                if ($ag.Count -and $Profile -and -not (Test-WDGuard -Guards $ag -Profile $Profile)) { continue }
                switch ([string]$a.type) {
                    'appx' {
                        $known++
                        $pats = @(Get-Prop $a 'names' @())
                        $hits = 0
                        foreach ($n in $appx) {
                            foreach ($p in $pats) {
                                if ($p -and $n -like $p) { $hits++; break }
                            }
                        }
                        if ($hits) { $found++; $blind += $hits }
                    }
                    'appxPolicy' {
                        $known++
                        foreach ($p in @(Get-Prop $a 'packages' @())) {
                            if (-not $p) { continue }
                            $hit = $false
                            foreach ($n in $appx) { if ($n -like $p) { $hit = $true; break } }
                            if ($hit) { $found++; break }
                        }
                    }
                    'service' {
                        $known++
                        foreach ($p in @(Get-Prop $a 'names' @())) {
                            if (-not $p) { continue }
                            $hit = $false
                            foreach ($n in $svcs) { if ($n -like $p) { $hit = $true; break } }
                            if ($hit) { $found++; break }
                        }
                    }
                    'uninstall' {
                        $known++
                        $skip = @(Get-Prop $a 'exclude' @())
                        $pat  = @(Get-Prop $a 'match' @())
                        $any  = $false
                        # $pi rather than $i: variable names are
                        # case-insensitive, and this file has already paid for a
                        # collision between a loop counter and something above
                        # it.
                        for ($pi = 0; $pi -lt $progNames.Length; $pi++) {
                            $nm = $progNames[$pi]
                            $ok = $false
                            foreach ($p in $pat) { if ($p -and $nm -like $p) { $ok = $true; break } }
                            if (-not $ok) { continue }
                            foreach ($p in $skip) { if ($p -and $nm -like $p) { $ok = $false; break } }
                            if (-not $ok) { continue }
                            $any = $true
                            $bytes += [int64]$progs[$pi].Bytes
                        }
                        if ($any) { $found++ }
                    }
                    'task' {
                        $known++
                        foreach ($p in @(Get-Prop $a 'tasks' @())) {
                            if (-not $p) { continue }
                            $hit = $false
                            foreach ($n in $tasks) { if ($n -like $p) { $hit = $true; break } }
                            if ($hit) { $found++; break }
                        }
                    }
                    'file' {
                        $known++
                        foreach ($p in @(Get-Prop $a 'paths' @())) {
                            $x = [Environment]::ExpandEnvironmentVariables([string]$p)
                            if ($x -and (Test-Path -LiteralPath $x -ErrorAction SilentlyContinue)) { $found++; break }
                        }
                    }
                    'shortcut' {
                        # A shortcut sweep with no matches is a no-op the same
                        # way a missing package is.
                        $known++
                        $names = @(Get-Prop $a 'names' @())
                        foreach ($loc in @(Get-Prop $a 'locations' @('desktop'))) {
                            $dir = switch ([string]$loc) {
                                'desktop'    { [Environment]::GetFolderPath('Desktop') }
                                'commondesktop' { [Environment]::GetFolderPath('CommonDesktopDirectory') }
                                'startmenu'  { [Environment]::GetFolderPath('StartMenu') }
                                'commonstartmenu' { [Environment]::GetFolderPath('CommonStartMenu') }
                                default      { '' }
                            }
                            if (-not $dir) { continue }
                            if (-not $lnkCache.ContainsKey($dir)) {
                                if (Test-Path -LiteralPath $dir -ErrorAction SilentlyContinue) {
                                    $lnkCache[$dir] = @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
                                                        ForEach-Object { [string]$_.BaseName })
                                } else {
                                    $lnkCache[$dir] = $null
                                }
                            }
                            $lnks = $lnkCache[$dir]
                            if ($null -eq $lnks) { continue }
                            $hit = $false
                            foreach ($p in $names) {
                                if (-not $p) { continue }
                                foreach ($n in $lnks) { if ($n -like $p) { $hit = $true; break } }
                                if ($hit) { break }
                            }
                            if ($hit) { $found++; break }
                        }
                    }
                    default {
                        # registry, registryKey, and script apply whatever is
                        # installed; feature, capability, and winget cost a DISM
                        # call or a network round trip, which is not worth
                        # paying to gray out five rows.
                        $opaque = $true
                    }
                }
            }

            $present = $null
            if (-not $opaque -and $known -gt 0) { $present = ($found -gt 0) }
            $out[$id] = [pscustomobject]@{
                Present = $present
                Bytes   = $bytes
                Blind   = $blind
            }
        }
    }
    $out
}

function Get-WDProtectedPrograms {
    param($Profile)
    if (-not $Profile) { $Profile = Get-WDSystemProfile }

    $list = @($script:ProtectedPrograms) + @($script:ProtectedHardwareTools)
    if ($script:ProtectedVendorTools.ContainsKey($Profile.Vendor)) {
        $list += $script:ProtectedVendorTools[$Profile.Vendor]
    }
    # A machine can carry another brand's peripheral suite; keep them all.
    foreach ($v in $script:ProtectedVendorTools.Keys) {
        if ($v -eq $Profile.Vendor) { continue }
        $list += $script:ProtectedVendorTools[$v]
    }
    $list | Sort-Object -Unique
}

function Get-WDManifestPatterns {
    param($Categories)

    # Only action types whose names identify software. Harvesting the others
    # cost the whole scan once: "Remove desktop shortcuts" sweeps names "*",
    # that "*" landed here, and every installed program then matched as already
    # covered.
    $identityTypes = @('appx', 'appxPolicy', 'service', 'winget')

    $pat = New-Object System.Collections.Generic.List[string]
    $add = {
        param([string]$Pattern)
        # A pattern of nothing but wildcards matches everything, so it can only
        # be a mistake however it arrived.
        if (-not $Pattern) { return }
        if (-not ($Pattern -replace '[\*\?\s]', '')) {
            Write-WDLog "Ignoring manifest pattern '$Pattern' - it would match every installed program." -Level Warn
            return
        }
        $pat.Add($Pattern)
    }

    foreach ($c in $Categories) {
        foreach ($i in @($c.items)) {
            foreach ($a in @(Get-Prop $i 'actions' @())) {
                if ([string](Get-Prop $a 'type' '') -in $identityTypes) {
                    foreach ($n in @(Get-Prop $a 'names' @()))    { & $add ([string]$n) }
                    foreach ($n in @(Get-Prop $a 'packages' @())) { & $add ([string]$n) }
                }
                # 'match' only appears on uninstall and always names a program.
                foreach ($n in @(Get-Prop $a 'match' @())) { & $add ([string]$n) }
            }
            # Script-handler items carry no match patterns, so without this the
            # scanner re-offers what they already remove.
            foreach ($n in @(Get-Prop $i 'covers' @())) { & $add ([string]$n) }
        }
    }
    $pat | Sort-Object -Unique
}

function Get-WDServiceImagePath {
    # PathName is not a path: it can be quoted with arguments after it, or
    # unquoted with spaces in the middle. $null means nothing on disk matched,
    # which is itself information.
    param([string]$PathName)
    if (-not $PathName) { return $null }
    $p = $PathName.Trim()
    if ($p -match '^"([^"]+)"') { return $Matches[1] }

    # Walk back from the longest prefix, so a path with spaces beats the first
    # token.
    $parts = @($p -split '\s+')
    for ($i = $parts.Count; $i -ge 1; $i--) {
        $cand = ($parts[0..($i - 1)] -join ' ')
        if ($cand -match '\.(exe|sys)$' -and (Test-Path -LiteralPath $cand -PathType Leaf)) { return $cand }
    }
    if ($p -match '^(.*?\.(?:exe|sys))(\s|$)') { return $Matches[1] }
    $null
}

$script:FileIdentityCache = @{}

function Get-WDFileIdentity {
    # The only reliable way to tell whose software a service is: the service
    # name and display name are chosen by whoever registered it and frequently
    # match nothing.
    param([string]$Path)
    if (-not $Path) { return $null }
    if ($script:FileIdentityCache.ContainsKey($Path)) { return $script:FileIdentityCache[$Path] }

    $id = $null
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $vi = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo
            $id = [pscustomobject]@{
                Company     = [string]$vi.CompanyName
                Product     = [string]$vi.ProductName
                Description = [string]$vi.FileDescription
            }
        }
    } catch { }
    $script:FileIdentityCache[$Path] = $id
    $id
}

function Get-WDInstallPathSegments {
    # Version folders identify nothing, and so does anything one or two
    # characters long - x64 and bin.
    param([string]$Path)
    if (-not $Path) { return @() }
    if ($Path -notmatch '\\(?:Program Files(?: \(x86\))?|ProgramData)\\(.+)$') { return @() }
    $rest = Split-Path $Matches[1] -Parent
    if (-not $rest) { return @() }
    @($rest -split '\\' | Where-Object { $_ -and $_.Length -gt 2 -and $_ -notmatch '^[\d\.]+$' })
}

function Get-WDOwningAppxPackage {
    # A service shipping inside an Appx package is removed with the package, so
    # it must be classified as the package is.
    param([string]$Path)
    if ($Path -match '\\WindowsApps\\([^\\]+)') { return (($Matches[1] -split '_')[0]) }
    $null
}

function Get-WDAppxFacts {
    # Both read together because they cost one XML parse. Display is the name
    # the package calls itself; the registered name is a hash nobody can decide
    # about.
    param($Package)
    $facts = [pscustomobject]@{ Display = $null; Listed = $true }
    try {
        if (-not $Package.InstallLocation) { return $facts }
        $mf = Join-Path $Package.InstallLocation 'AppxManifest.xml'
        if (-not (Test-Path -LiteralPath $mf)) { return $facts }
        [xml]$x = Get-Content -LiteralPath $mf -Raw -ErrorAction Stop

        $d = [string]$x.Package.Properties.DisplayName
        if ($d -and $d -notlike 'ms-resource:*' -and $d -ne $Package.Name) { $facts.Display = $d }

        $apps = @($x.Package.Applications.Application)
        if ($apps.Count) {
            $facts.Listed = [bool](@($apps | Where-Object {
                $_.VisualElements -and $_.VisualElements.AppListEntry -ne 'none'
            }).Count)
        }
    } catch { }
    $facts
}

function Get-WDPublisherName {
    # The value is quoted whenever it contains a comma, and [^,]+ leaves a stray
    # quote plus half a name.
    param([string]$Dn)
    if ($Dn -match 'O="([^"]+)"')  { return $Matches[1].Trim() }
    if ($Dn -match 'O=([^,]+)')    { return $Matches[1].Trim(' "') }
    'unknown publisher'
}

function Get-WDSoftwareOrigin {
    # Drives wording only, never selection.
    param([string]$Publisher)
    if ($Publisher -match 'Microsoft') { 'microsoft' } else { 'thirdparty' }
}

# Opera is the odd one: under Roaming, and its profile is the base folder rather
# than a Default child.
$script:ChromiumProfiles = @(
    [pscustomobject]@{ Browser = 'Chrome';   Area = 'Local';   Rel = 'Google\Chrome\User Data' }
    [pscustomobject]@{ Browser = 'Edge';     Area = 'Local';   Rel = 'Microsoft\Edge\User Data' }
    [pscustomobject]@{ Browser = 'Brave';    Area = 'Local';   Rel = 'BraveSoftware\Brave-Browser\User Data' }
    [pscustomobject]@{ Browser = 'Vivaldi';  Area = 'Local';   Rel = 'Vivaldi\User Data' }
    [pscustomobject]@{ Browser = 'Chromium'; Area = 'Local';   Rel = 'Chromium\User Data' }
    [pscustomobject]@{ Browser = 'Opera';    Area = 'Roaming'; Rel = 'Opera Software\Opera Stable' }
    [pscustomobject]@{ Browser = 'Opera GX'; Area = 'Roaming'; Rel = 'Opera Software\Opera GX Stable' }
)

# Component extensions the browser depends on, which sit in the profile beside
# what the user chose. Bundled-but-optional ones are deliberately not here.
$script:ProtectedExtensions = @{
    'nmmhkkegccagdldgiimedpiccmgmieda' = 'Chrome Web Store Payments - the Web Store stops working without it'
    'mhjfbmdgcfjbbpaeojofohoefgiehjai' = 'Built-in PDF viewer - PDFs would download instead of opening'
    'pkedcjkdefgpdelpbcmbmeomcjbeemfm' = 'Cast support built into the browser'
    'neajdppkdcdipfabeoofebfddakdcjhd' = 'Speech recognition component the browser calls into'
    'gcmjkmgdlgnkkcocmoeiminaijmmjnii' = 'Update component the browser needs to patch itself'
}

function Get-WDChromiumExtensionName {
    # A Chromium manifest may name itself __MSG_appName__ and resolve it from
    # the locale bundle; about a third do.
    param([string]$VersionDir, $Manifest)

    $name = [string](Get-Prop $Manifest 'name' '')
    if ($name -notlike '__MSG_*__') { return $name }

    $key = $name.Trim('_')
    if ($key -like 'MSG_*') { $key = $key.Substring(4) }
    $locales = @([string](Get-Prop $Manifest 'default_locale' ''), 'en_US', 'en') |
               Where-Object { $_ } | Select-Object -Unique
    foreach ($loc in $locales) {
        $msg = Join-Path $VersionDir "_locales\$loc\messages.json"
        if (-not (Test-Path -LiteralPath $msg)) { continue }
        try {
            $m = Get-Content -LiteralPath $msg -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $m.PSObject.Properties) {
                if ($prop.Name -ieq $key) { return [string]$prop.Value.message }
            }
        } catch { }
    }
    ''
}

function Get-WDBrowserExtensions {
    # Profile-installed only. What the browser ships with lives in the
    # application directory.
    $byKey = @{}

    $userDirs = @()
    try {
        $userDirs = @(Get-ChildItem -LiteralPath (Split-Path $env:USERPROFILE -Parent) -Directory -ErrorAction Stop |
                      Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') })
    } catch { }

    $add = {
        param([string]$Browser, [string]$Id, [string]$Name, [string]$Path)
        if (-not $Name) { $Name = $Id }
        $key = "$Browser|$Id"
        if (-not $byKey.ContainsKey($key)) {
            $byKey[$key] = [pscustomobject]@{
                Browser = $Browser; Id = $Id; Name = $Name
                Paths   = New-Object System.Collections.Generic.List[string]
            }
        }
        $byKey[$key].Paths.Add($Path)
    }

    foreach ($u in $userDirs) {
        foreach ($b in $script:ChromiumProfiles) {
            $base = Join-Path $u.FullName "AppData\$($b.Area)\$($b.Rel)"
            if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }

            $profiles = @($base) + @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                                     ForEach-Object { $_.FullName })
            foreach ($prof in ($profiles | Select-Object -Unique)) {
                $extRoot = Join-Path $prof 'Extensions'
                if (-not (Test-Path -LiteralPath $extRoot -PathType Container)) { continue }
                foreach ($ext in @(Get-ChildItem -LiteralPath $extRoot -Directory -ErrorAction SilentlyContinue)) {
                    # One directory per installed version; the newest is in use.
                    $ver = @(Get-ChildItem -LiteralPath $ext.FullName -Directory -ErrorAction SilentlyContinue |
                             Sort-Object Name) | Select-Object -Last 1
                    if (-not $ver) { continue }
                    $mf = Join-Path $ver.FullName 'manifest.json'
                    if (-not (Test-Path -LiteralPath $mf)) { continue }
                    $name = ''
                    try {
                        $json = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
                        $name = Get-WDChromiumExtensionName -VersionDir $ver.FullName -Manifest $json
                    } catch { }
                    & $add $b.Browser $ext.Name $name $ext.FullName
                }
            }
        }

        # Firefox records everything in one file per profile and marks where
        # each add-on came from.
        $ffRoot = Join-Path $u.FullName 'AppData\Roaming\Mozilla\Firefox\Profiles'
        foreach ($prof in @(Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)) {
            $db = Join-Path $prof.FullName 'extensions.json'
            if (-not (Test-Path -LiteralPath $db)) { continue }
            try {
                $data = Get-Content -LiteralPath $db -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($a in @($data.addons)) {
                    if ([string]$a.type -ne 'extension') { continue }
                    if ([string]$a.location -notin @('app-profile', 'app-temporary')) { continue }
                    $nm = [string]$a.defaultLocale.name
                    $xpi = Join-Path $prof.FullName ('extensions\' + [string]$a.id + '.xpi')
                    if (-not (Test-Path -LiteralPath $xpi)) { continue }
                    & $add 'Firefox' ([string]$a.id) $nm $xpi
                }
            } catch { }
        }
    }

    @($byKey.Values | Sort-Object Browser, Name)
}

function Get-WDDiscoveredSoftware {
    param($Categories, $Profile, [scriptblock]$Progress)

    # Never let a reporting callback break the scan.
    $say = {
        param([string]$Text, [string]$Note)
        if ($Progress) { try { & $Progress $Text $Note | Out-Null } catch { } }
    }

    if (-not $Profile) { $Profile = Get-WDSystemProfile }
    $protectedProgs = Get-WDProtectedPrograms -Profile $Profile
    $knownPatterns  = Get-WDManifestPatterns -Categories $Categories

    $vendorApps  = New-Object System.Collections.Generic.List[psobject]
    $otherApps   = New-Object System.Collections.Generic.List[psobject]
    $otherSvcs   = New-Object System.Collections.Generic.List[psobject]
    $protected   = New-Object System.Collections.Generic.List[psobject]

    # Records why something was spared, so Advanced can explain rather than
    # assert.
    $keep = {
        param([string]$Name, [string]$Kind, [string]$Reason)
        $protected.Add([pscustomobject]@{ Name = $Name; Kind = $Kind; Reason = $Reason })
    }

    $vendorMatch = switch ($Profile.Vendor) {
        'hp'      { 'HP |Hewlett' }      'dell'    { 'Dell' }
        'lenovo'  { 'Lenovo' }           'asus'    { 'ASUS|ASUSTek' }
        'acer'    { 'Acer' }             'msi'     { 'Micro-Star|MSI' }
        'samsung' { 'Samsung' }          'razer'   { 'Razer' }
        'toshiba' { 'Toshiba|Dynabook' } 'vaio'    { 'Sony|VAIO' }
        'huawei'  { 'Huawei' }           'medion'  { 'Medion' }
        'fujitsu' { 'Fujitsu' }          'lg'      { 'LG Electronics' }
        'gigabyte'{ 'Gigabyte|AORUS' }   'framework' { 'Framework' }
        default   { $null }
    }

    & $say 'Reading installed programs' 'Uninstall entries, machine and per-user'
    foreach ($p in (Get-WDInstalledPrograms)) {
        if (Test-WDPatternMatch $p.DisplayName $protectedProgs) {
            & $keep $p.DisplayName 'program' (Get-WDProtectionReason -Name $p.DisplayName -Profile $Profile)
            continue
        }
        if (Test-WDPatternMatch $p.DisplayName $knownPatterns)  { continue }
        if (-not $p.UninstallString -and -not $p.QuietString)    { continue }   # nothing to run

        # Sub-features and bundle records of a product with its own visible
        # entry. Windows hides these from Add/Remove Programs; offering them put
        # Python on the list eleven times, and removing one of the eleven
        # uninstalls nothing.
        if ($p.SystemComponent -eq 1 -or $p.ParentName) {
            $owner = $(if ($p.ParentName) { $p.ParentName } else { 'the product that installed it' })
            & $keep $p.DisplayName 'program' "Part of $owner rather than a program in its own right - Windows hides it from Add/Remove Programs, and removing it separately does not uninstall anything"
            continue
        }

        $isVendor = $false
        if ($vendorMatch) {
            if ($p.Publisher -match $vendorMatch -or $p.DisplayName -match $vendorMatch) { $isVendor = $true }
        }
        $pub = $(if ($p.Publisher) { $p.Publisher } else { 'unknown publisher' })
        $entry = [pscustomobject]@{
            Name      = $p.DisplayName
            Display   = $p.DisplayName
            Publisher = $pub
            Origin    = (Get-WDSoftwareOrigin -Publisher $pub)
            Kind      = 'program'
        }
        if ($isVendor) { $vendorApps.Add($entry) } else { $otherApps.Add($entry) }
    }

    & $say 'Reading Store packages' ''
    $pkgs = @()
    try { $pkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue) } catch { }
    foreach ($pkg in $pkgs) {
        if (Test-WDPatternMatch $pkg.Name $script:ProtectedAppx) {
            & $keep $pkg.Name 'appx' 'Windows component - shell, sign-in, servicing or a media codec'
            continue
        }
        # Vendor hardware tools ship as Store packages too, so the same
        # keep-list applies.
        if (Test-WDPatternMatch $pkg.Name $protectedProgs) {
            & $keep $pkg.Name 'appx' (Get-WDProtectionReason -Name $pkg.Name -Profile $Profile)
            continue
        }
        if (Test-WDPatternMatch $pkg.Name $knownPatterns)         { continue }
        if ($pkg.IsFramework) { & $keep $pkg.Name 'appx' 'Shared framework other apps link against'; continue }
        if ($pkg.SignatureKind -eq 'System') { & $keep $pkg.Name 'appx' 'Signed as a system component by Windows'; continue }
        if ($pkg.Name -like 'Microsoft.Windows.*' -or $pkg.Name -like 'MicrosoftWindows.Client.*') {
            & $keep $pkg.Name 'appx' 'Core Windows client package'
            continue
        }

        # Only now, on what is left, is a manifest parse per package worth it.
        # The name a package registers under and the name it calls itself are
        # different strings, and the keep-list is written against the second.
        $facts = Get-WDAppxFacts -Package $pkg
        $disp  = $facts.Display
        if ($disp -and (Test-WDPatternMatch $disp $protectedProgs)) {
            & $keep $pkg.Name 'appx' (Get-WDProtectionReason -Name $disp -Profile $Profile)
            continue
        }
        if ($disp -and (Test-WDPatternMatch $disp $knownPatterns)) { continue }
        # Last, so anything the curated list names explicitly still wins -
        # Widgets has no app-list entry either and is meant to be offered.
        if (-not $facts.Listed) {
            & $keep $pkg.Name 'appx' 'Component registered by another installed app rather than an app in its own right - it goes when its owner does'
            continue
        }

        $isVendor = $false
        if ($vendorMatch -and ($pkg.Publisher -match $vendorMatch -or $pkg.Name -match $vendorMatch)) { $isVendor = $true }
        $pub = Get-WDPublisherName -Dn ([string]$pkg.Publisher)
        $entry = [pscustomobject]@{
            Name      = $pkg.Name
            Display   = $(if ($disp) { $disp } else { $pkg.Name })
            Publisher = $pub
            Origin    = (Get-WDSoftwareOrigin -Publisher $pub)
            Kind      = 'appx'
        }
        if ($isVendor) { $vendorApps.Add($entry) } else { $otherApps.Add($entry) }
    }

    # A service is not an independent thing: it belongs to a program, a package,
    # or Windows, and has to be classified as its owner is.
    & $say 'Checking background services' 'Working out what each one belongs to'
    $discoveredPkgs = @(@($otherApps) + @($vendorApps) |
                        Where-Object { $_.Kind -eq 'appx' } | ForEach-Object { $_.Name })
    $winRoot = [string]$env:SystemRoot

    $svcs = @()
    try { $svcs = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue) } catch { }
    foreach ($s in $svcs) {
        if ($script:ProtectedServices -contains $s.Name) { continue }
        if ($s.StartMode -eq 'Disabled') { continue }
        if ($s.Name -match '^(WpnUserService|CDPUserSvc|OneSyncSvc|PrintWorkflow|BluetoothUserService|CaptureService|DevicesFlow|MessagingService|PimIndex|UdkUserSvc|UnistoreSvc|UserDataSvc|WpnService)') { continue }

        $exe = Get-WDServiceImagePath ([string]$s.PathName)
        # Nothing on disk means nothing can be established, and "unidentified"
        # is the worst possible reason to offer to switch something off.
        if (-not $exe) { continue }
        if ($exe -match '\.sys$') { continue }
        if ($winRoot -and $exe -like "$winRoot\*") { continue }

        $fi        = Get-WDFileIdentity -Path $exe
        $owningPkg = Get-WDOwningAppxPackage -Path $exe
        $idents    = @($s.Name, [string]$s.DisplayName)
        if ($fi)        { $idents += @($fi.Product, $fi.Description, $fi.Company) }
        if ($owningPkg) { $idents += $owningPkg }
        # The install folder names the owner when nothing else does: Legion
        # Space registers two services from one directory, and only one of them
        # says Lenovo.
        $idents += @(Get-WDInstallPathSegments -Path $exe)
        $idents = @($idents | Where-Object { $_ })

        # Windows outside System32 - Defender for Endpoint, GameInput, Media
        # Player sharing. The binary says so itself.
        if ($fi -and (Test-WDPatternMatch $fi.Product $script:WindowsProductNames)) {
            & $keep "$($s.Name) service" 'service' 'Part of Windows - the binary versions itself as an operating system component'
            continue
        }

        $protHit = $null
        foreach ($v in $idents) {
            if (Test-WDPatternMatch $v $protectedProgs) { $protHit = $v; break }
        }
        if ($protHit) {
            & $keep "$($s.Name) service" 'service' (Get-WDProtectionReason -Name $protHit -Profile $Profile)
            continue
        }

        # The owner takes the service with it, so a separate entry is a
        # duplicate that can only be got wrong.
        $isKnown = $false
        foreach ($v in $idents) {
            if (Test-WDPatternMatch $v $knownPatterns) { $isKnown = $true; break }
        }
        if (-not $isKnown -and $owningPkg -and ($discoveredPkgs -contains $owningPkg)) { $isKnown = $true }
        if ($isKnown) { continue }

        $company = $(if ($fi -and $fi.Company) { $fi.Company } else { 'unknown publisher' })
        $otherSvcs.Add([pscustomobject]@{
            Name      = $s.Name
            Display   = "$($s.Name) service"
            Publisher = [string]$s.DisplayName
            Company   = $company
            Origin    = (Get-WDSoftwareOrigin -Publisher $company)
            Kind      = 'service'
        })
    }

    & $say 'Checking browser extensions' 'Across every profile on this machine'
    $extensions = New-Object System.Collections.Generic.List[psobject]
    try {
        foreach ($e in @(Get-WDBrowserExtensions)) {
            if ($script:ProtectedExtensions.ContainsKey($e.Id)) {
                & $keep "$($e.Name) ($($e.Browser))" 'extension' $script:ProtectedExtensions[$e.Id]
                continue
            }
            $extensions.Add($e)
        }
    } catch { }

    # Handed back so the presence pass runs off it rather than enumerating Store
    # packages a second time.
    $inventory = Get-WDMachineInventory -AppxNames @($pkgs | ForEach-Object { [string]$_.Name }) `
                                        -InboxNames @($pkgs | Where-Object { $_.NonRemovable -eq $true } |
                                                      ForEach-Object { [string]$_.Name }) `
                                        -ServiceNames @($svcs | ForEach-Object { [string]$_.Name })

    [pscustomobject]@{
        VendorApps    = @($vendorApps  | Sort-Object Name -Unique)
        OtherApps     = @($otherApps   | Sort-Object Name -Unique)
        OtherServices = @($otherSvcs   | Sort-Object Name -Unique)
        Extensions    = @($extensions)
        Protected     = @($protected   | Sort-Object Name -Unique)
        Inventory     = $inventory
        Vendor        = $Profile.Vendor
        VendorLabel   = $Profile.VendorLabel
    }
}

function Get-WDProtectionReason {
    param([string]$Name, $Profile)

    if (-not $Profile) { $Profile = Get-WDSystemProfile }

    foreach ($v in $script:ProtectedVendorTools.Keys) {
        if (Test-WDPatternMatch $Name $script:ProtectedVendorTools[$v]) {
            $own = if ($v -eq $Profile.Vendor) { "this machine's manufacturer" } else { "$v hardware" }
            return "Controls power, thermals, firmware, lighting or hotkeys for $own - removing it costs real hardware functionality"
        }
    }
    if (Test-WDPatternMatch $Name $script:ProtectedHardwareTools) {
        return 'Peripheral control software - drives a mouse, keyboard, headset, tablet or display calibration'
    }
    if (Test-WDPatternMatch $Name @('Microsoft Visual C++*','Microsoft .NET*','Microsoft ASP.NET*','DirectX*','Microsoft Edge WebView2 Runtime','Microsoft GameInput')) {
        return 'Runtime or redistributable that other installed software links against'
    }
    if (Test-WDPatternMatch $Name @('Windows Security*','Microsoft Defender*','Windows Defender*')) {
        return 'Antivirus - removing it would leave the machine unprotected'
    }
    if (Test-WDPatternMatch $Name $script:WindowsProductNames) {
        return 'Part of Windows - the binary versions itself as an operating system component'
    }
    'Driver or hardware support package'
}

$script:IconCache = @{}
# $null rather than empty, so "nobody has asked" and "there are none" stay
# different states.
$script:AppxLocations = $null

function Get-WDIconPath {
    param([string]$Kind, [string]$Name)

    $key = "$Kind|$Name"
    if ($script:IconCache.ContainsKey($key)) { return $script:IconCache[$key] }
    $result = $null

    try {
        if ($Kind -eq 'appx') {
            # One enumeration, not one Get-AppxPackage -Name per icon.
            # Break-even is about four packages and this machine finds three, so
            # it is slower here and still right: the count has no ceiling and
            # the per-name form grows without bound.
            if ($null -eq $script:AppxLocations) {
                $script:AppxLocations = @{}
                try {
                    foreach ($p in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
                        $n = [string]$p.Name
                        if ($n -and -not $script:AppxLocations.ContainsKey($n)) {
                            $script:AppxLocations[$n] = [string]$p.InstallLocation
                        }
                    }
                } catch { }
            }
            $pkg = $null
            if ($script:AppxLocations.ContainsKey([string]$Name)) {
                $pkg = [pscustomobject]@{ InstallLocation = [string]$script:AppxLocations[[string]$Name] }
            }
            if ($pkg -and $pkg.InstallLocation -and (Test-Path -LiteralPath $pkg.InstallLocation)) {
                $mf = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
                $logo = $null
                if (Test-Path -LiteralPath $mf) {
                    try {
                        [xml]$x = Get-Content -LiteralPath $mf -Raw -ErrorAction Stop
                        $logo = $x.Package.Applications.Application.VisualElements.Square44x44Logo
                        if (-not $logo) { $logo = $x.Package.Properties.Logo }
                    } catch { }
                }
                if ($logo) {
                    $base = Join-Path $pkg.InstallLocation $logo
                    if (Test-Path -LiteralPath $base) {
                        $result = $base
                    } else {
                        # Packages ship scaled variants: Logo.scale-200.png and
                        # friends.
                        $dir  = Split-Path $base -Parent
                        $stem = [IO.Path]::GetFileNameWithoutExtension($base)
                        if (Test-Path -LiteralPath $dir) {
                            $cand = Get-ChildItem -LiteralPath $dir -Filter "$stem*.png" -ErrorAction SilentlyContinue |
                                    Sort-Object Length | Select-Object -First 1
                            if ($cand) { $result = $cand.FullName }
                        }
                    }
                }
            }
        } else {
            $prog = Get-WDInstalledPrograms | Where-Object { $_.DisplayName -eq $Name } | Select-Object -First 1
            if ($prog -and $prog.DisplayIcon) {
                $icon = $prog.DisplayIcon.Trim('"')
                if ($icon -match '^(.*?),\s*-?\d+$') { $icon = $Matches[1] }   # strip ",0" index
                $icon = $icon.Trim('"')
                if ($icon -and (Test-Path -LiteralPath $icon)) { $result = $icon }
            }
        }
    } catch { }

    $script:IconCache[$key] = $result
    $result
}

function Get-WDStableId {
    # String.GetHashCode is only stable within a process, so a saved profile
    # would stop matching its own items on a later launch.
    param([string]$Text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        (($bytes[0..3] | ForEach-Object { '{0:x2}' -f $_ }) -join '')
    } finally {
        $md5.Dispose()
    }
}

function New-WDDiscoveredCategories {
    param($Scan)

    $cats = New-Object System.Collections.Generic.List[psobject]

    # The visible name and the name the action targets are not always the same
    # string: the id, icon, and uninstall key off the real one, only the label
    # uses the readable one.
    $label = { param($E) $(if ($E.PSObject.Properties['Display'] -and $E.Display) { $E.Display } else { $E.Name }) }
    # "Third-party" is a claim, and it was wrong on about half of what it was
    # printed on - Office, Gaming Services, and the Edge updaters are
    # Microsoft's.
    $found = {
        param($E, [string]$Noun)
        $who = $(if ($E.PSObject.Properties['Origin'] -and $E.Origin -eq 'microsoft') { 'Microsoft' } else { 'third-party' })
        $bits = @([string]$E.Publisher)
        if ((& $label $E) -ne $E.Name) { $bits += [string]$E.Name }
        $bits += "$who $Noun found by scan"
        $bits -join ' | '
    }

    if (@($Scan.VendorApps).Count) {
        $items = New-Object System.Collections.Generic.List[psobject]
        foreach ($a in $Scan.VendorApps) {
            $act = if ($a.Kind -eq 'appx') {
                [pscustomobject]@{ type = 'appx'; names = @($a.Name) }
            } else {
                [pscustomobject]@{ type = 'uninstall'; match = @($a.Name); timeoutSeconds = 600 }
            }
            $items.Add([pscustomobject]@{
                id      = "disc-vendor-$($(Get-WDStableId -Text $a.Name))"
                name    = (& $label $a)
                desc    = "$($a.Publisher) | found on this machine by scan"
                riskNote = 'Found by scanning this machine rather than from the curated list, so it has not been individually vetted. Check you do not need it.'
                iconKind = $a.Kind; iconName = $a.Name
                # Rated here because the scanner's finds cannot be rated in the
                # manifest; unrated they sort to the bottom as though they were
                # not removals.
                risk    = 1; tier = 4; order = 82; bloat = 3
                actions = @($act)
            })
        }
        $cats.Add([pscustomobject]@{
            id = 'discovered-vendor'
            name = "$($Scan.VendorLabel) software found"
            order = 100
            items = @($items | Sort-Object name)
        })
    }

    if (@($Scan.OtherApps).Count) {
        $items = New-Object System.Collections.Generic.List[psobject]
        foreach ($a in $Scan.OtherApps) {
            $act = if ($a.Kind -eq 'appx') {
                [pscustomobject]@{ type = 'appx'; names = @($a.Name) }
            } else {
                [pscustomobject]@{ type = 'uninstall'; match = @($a.Name); timeoutSeconds = 600 }
            }
            $items.Add([pscustomobject]@{
                id      = "disc-app-$($(Get-WDStableId -Text $a.Name))"
                name    = (& $label $a)
                desc    = (& $found $a 'software')
                riskNote = 'This is software you or the vendor installed, not bloatware the toolkit recognizes. No preset selects it - tick it yourself if you want it gone.'
                iconKind = $a.Kind; iconName = $a.Name
                # Tier 0, no preset including Extreme: the scan cannot tell a
                # program somebody depends on from one they forgot about.
                risk    = 2; tier = 0; order = 86; bloat = 3
                actions = @($act)
            })
        }
        $cats.Add([pscustomobject]@{
            id = 'discovered-apps'
            name = 'Your software'
            order = 144
            items = @($items | Sort-Object name)
        })
    }

    if (@($Scan.OtherServices).Count) {
        $items = New-Object System.Collections.Generic.List[psobject]
        foreach ($s in $Scan.OtherServices) {
            $items.Add([pscustomobject]@{
                id      = "disc-svc-$($(Get-WDStableId -Text $s.Name))"
                name    = "$($s.Name) service"
                desc    = (& $found $s 'service')
                riskNote = 'A background service belonging to installed software. Disabling it may stop that software working, though it is fully reversible from the rollback script.'
                # Tier 0 for the same reason as the software above - this
                # belongs to a program somebody installed deliberately.
                risk    = 2; tier = 0; order = 88; bloat = 4
                actions = @([pscustomobject]@{ type = 'service'; startupType = 'Disabled'; names = @($s.Name) })
            })
        }
        $cats.Add([pscustomobject]@{
            id = 'discovered-services'
            name = 'Services from installed software'
            order = 146
            items = @($items | Sort-Object name)
        })
    }

    if (@($Scan.Extensions).Count) {
        $items = New-Object System.Collections.Generic.List[psobject]
        foreach ($e in $Scan.Extensions) {
            $where = $(if (@($e.Paths).Count -gt 1) { " in $(@($e.Paths).Count) profiles" } else { '' })
            $items.Add([pscustomobject]@{
                id      = "disc-ext-$($(Get-WDStableId -Text "$($e.Browser)|$($e.Id)"))"
                name    = "$($e.Name) ($($e.Browser))"
                # A field rather than the suffix on the name, so the interface
                # can tie an extension to its browser without parsing a label it
                # also has to translate.
                browser = [string]$e.Browser
                desc    = "$($e.Id)$where | browser extension found by scan"
                riskNote = 'Extensions carry passwords, session cookies and page-blocking rules. Removing one loses whatever it was storing, and an ad or script blocker takes its filter lists with it. The folder goes to the Recycle Bin, so it can be put back, but the browser has to be closed for the removal to stick.'
                # Tier 0: an extension is something the person added, and a
                # password manager is not a thing a preset may decide about.
                risk    = 1; tier = 0; order = 87; bloat = 3
                actions = @([pscustomobject]@{ type = 'file'; recycle = $true; paths = @($e.Paths) })
            })
        }
        $cats.Add([pscustomobject]@{
            id = 'discovered-extensions'
            name = 'Browser extensions'
            order = 142
            items = @($items | Sort-Object name)
        })
    }

    ,$cats
}

Export-ModuleMember -Function Get-WDDiscoveredSoftware, New-WDDiscoveredCategories,
                              Get-WDProtectedPrograms, Get-WDManifestPatterns, Test-WDPatternMatch,
                              Get-WDProtectionReason, Get-WDIconPath, Get-WDStableId,
                              Get-WDServiceImagePath, Get-WDFileIdentity, Get-WDOwningAppxPackage,
                              Get-WDAppxFacts, Get-WDPublisherName, Get-WDSoftwareOrigin,
                              Get-WDInstallPathSegments, Get-WDBrowserExtensions,
                              Get-WDChromiumExtensionName,
                              Get-WDMachineInventory, Get-WDItemPresence, Get-WDTaskInventory, Get-WDTaskFacts
