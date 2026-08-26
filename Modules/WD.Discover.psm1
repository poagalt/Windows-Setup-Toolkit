<#
    WD.Discover - runtime scan of everything installed, classified against a
    protection list.

    Design note. A curated removal list cannot know about a vendor app that
    ships on a model nobody has seen yet. A pure runtime scan cannot know that
    Lenovo Vantage owns battery charge thresholds while Lenovo Now is junk.
    So this inverts the problem: enumerate what must be KEPT - a small, stable,
    knowable set - and treat everything else as a candidate, surfaced with its
    publisher and install date so the operator decides.

    Nothing in the protected lists below is ever offered for removal, at any
    preset, including Extreme. That is the whole safety guarantee of this module.
#>

# --------------------------------------------------------------------------
# Protected: Windows itself. Removing any of these breaks the shell, servicing,
# sign-in, or app deployment.
# --------------------------------------------------------------------------
$script:ProtectedAppx = @(
    # Frameworks and runtimes every Store app links against
    'Microsoft.NET.Native.*', 'Microsoft.VCLibs.*', 'Microsoft.UI.Xaml.*'
    'Microsoft.WindowsAppRuntime.*', 'MicrosoftCorporationII.WinAppRuntime.*'
    'Microsoft.Services.Store.Engagement', 'Microsoft.DirectXRuntime'
    # Shell, sign-in and system UI hosts
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
    # Obfuscated in-box accessibility packages (voice access, live captions, etc.)
    'MicrosoftWindows.5*', 'MicrosoftWindows.6*'
)

# --------------------------------------------------------------------------
# Protected: drivers, runtimes and redistributables. Never candidates.
# --------------------------------------------------------------------------
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

# --------------------------------------------------------------------------
# Protected: a binary that versions itself as part of Windows is part of
# Windows, wherever on disk it happens to live. Defender for Endpoint, the
# GameInput redistributable and Media Player's sharing service all sit outside
# System32 and were being offered as "third-party" on that basis alone.
# --------------------------------------------------------------------------
$script:WindowsProductNames = @(
    'Microsoft* Windows*', 'Windows* Operating System'
)

# --------------------------------------------------------------------------
# Protected: vendor tools that own power, thermals, firmware or input.
# These are system dependencies on the hardware they ship with. Stripping them
# costs you battery charge limits, fan curves or BIOS updates, so they are not
# offered for removal at any preset.
# --------------------------------------------------------------------------
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

# Cross-vendor hardware tools that show up regardless of who built the machine.
#
# Intel's Extreme Tuning Utility is in here for the same reason the vendor power
# tools are: it owns CPU voltage, turbo and thermal limits, and the profile it
# last applied persists in firmware. Take it away and an undervolt or a raised
# power limit stays in force with nothing left on the machine that can change
# it. Several vendors rebadge it rather than shipping Intel's own installer -
# this machine has Lenovo's, registered as `Install_Intel_IPF_XTU` under
# `Program Files\Lenovo\Intel_SDK`, which matches none of the `Lenovo *` product
# patterns above and was being offered for removal.
#
# Matched narrowly and never as a bare `*XTU*`: that also matches every product
# with "texture" in its name.
$script:ProtectedHardwareTools = @(
    'X-Rite*', 'Portrait Displays*', 'Logitech*', 'Logi Options*', 'LGHUB*'
    'Corsair iCUE*', 'SteelSeries*', 'Elgato*', 'Wacom*', 'Focusrite*', 'ASIO*'
    '*Extreme Tuning Utility*', '*Intel*XTU*', 'XTU_*', 'Intel*Overclocking*'
)

# --------------------------------------------------------------------------
# Protected: services. Windows core plus anything driver-backed.
# --------------------------------------------------------------------------
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

# =========================================================== presence ======
#
# Whether each curated item has anything to act on, worked out before the list
# is drawn rather than discovered in the preview. An item that is not on this
# machine is still worth showing - it says what the toolkit covers - but it is
# not worth reading as a decision, so the row says so and steps back.
#
# The whole pass is matching against inventories the startup scan has already
# enumerated. It costs one scheduled-task walk and a handful of Test-Paths on
# top of a scan that was happening anyway.

function Get-WDTaskFacts {
    <#
        Every registered task path, walked once, and which of them are already
        disabled.

        Both come out of the one walk because the COM object carries Enabled
        beside Path and reading it costs nothing. They answer two different
        questions and the difference matters: presence asks "is there a task
        here", which stays true after a run disables it, while a run's own
        "is there anything left to do" asks whether it is still enabled. Asking
        the second with the first is how an option that has already been applied
        goes on claiming there is work in it.
    #>
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
    <#  The path list alone, for callers that only ask about presence.  #>
    (Get-WDTaskFacts).Paths
}

function Get-WDMachineInventory {
    <#
        The lists every presence question is answered from. Built from what the
        scan already has where possible - re-enumerating Store packages is the
        slowest thing this toolkit does and it is not doing it twice.
    #>
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
        # The subset Windows marks NonRemovable: in-box CBS components and shell
        # hosts, serviced by Windows Update, which no privilege, ownership change
        # or policy removes. Kept alongside the full list rather than derived
        # later because it costs nothing here - the enumeration has already
        # happened - and re-running Get-AppxPackage to ask a second question
        # about the same list is the slowest thing this toolkit does.
        Inbox    = @($InboxNames)
        Services = @($ServiceNames)
        Programs = @(Get-WDInstalledPrograms)
        Tasks    = @($taskFacts.Paths)
        # The subset already switched off, kept beside the full list for the
        # same reason Inbox is: the walk has happened and asking again would be
        # a second enumeration for a question the first one answered.
        TasksOff = @($taskFacts.Disabled)
    }
}

function Get-WDItemPresence {
    <#
        Per item: is there anything here to act on, and roughly how much disk
        does it hold. Returns a map of id -> @{Present; Bytes; Counted; Blind}.

        Present is deliberately three-valued. $true and $false are answers;
        $null is "no opinion", and it is what an item gets the moment any one of
        its actions is a kind this cannot ask about. That is not a gap to close
        later - it is the same rule the preview follows. A registry policy write
        applies whether or not the app it disables is installed, so an item that
        is half policy and half package is not a no-op just because the package
        is missing, and graying it out would be a lie.

        Bytes is what uninstalling would give back, from the size the installer
        recorded in its uninstall key. Store packages have no readable size at
        all - WindowsApps refuses administrators - so they are counted rather
        than measured, which is what Blind reports.

        This asks "is there anything HERE", and it is deliberately not the same
        question as "is there anything left to DO" - Test-WDActionSatisfied
        answers that one, per action, for every kind including these. The two
        differ on more than wording: a scheduled task a run has disabled is
        still present and has nothing left to do to it, and a service that is
        present may or may not already be at the start type the action wants.
        Keeping them apart is what lets a row say "not on this machine" and
        "already applied" as the different statements they are.
    #>
    param($Categories, $Inventory, $Profile)

    if (-not $Inventory) { $Inventory = Get-WDMachineInventory }
    $appx  = @($Inventory.Appx)
    $svcs  = @($Inventory.Services)
    $progs = @($Inventory.Programs)
    $tasks = @($Inventory.Tasks)
    $tasksOff = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in @($Inventory.TasksOff)) { $null = $tasksOff.Add([string]$t) }

    # Plain nested loops, not pipelines, and this is the whole reason the pass
    # is fast enough to run at startup. It was written as
    # $appx | Where-Object { ... @(Get-Prop $a 'names') | Where-Object ... },
    # which is a pipeline per package and a second pipeline plus a Get-Prop
    # INSIDE it - 64 appx actions against 147 packages is nine and a half
    # thousand scriptblock invocations for that one action type alone, and about
    # a second of the launch. Parameter binding and pipeline setup are the cost
    # here, never the comparison; it measures around 40 ms written this way.
    # Same lesson as the icon geometry, which went from 817 ms to 6 ms for
    # exactly this reason.
    #
    # The program names are cast once, out here, rather than per item.
    $progNames = New-Object 'string[]' $progs.Count
    for ($i = 0; $i -lt $progs.Count; $i++) { $progNames[$i] = [string]$progs[$i].DisplayName }

    # Shortcut folders, walked once each rather than once per action. Worth
    # nothing measurable today - the manifest has two shortcut actions and both
    # name the desktop - but a Start menu is a recursive Get-ChildItem over a
    # few hundred files, and nothing inside this pass changes what is in it.
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
                # An action whose guards fail never runs on this machine, so it
                # can neither make the item present nor keep it outstanding.
                # Ten items carry one - the Enterprise-only half of "Lock screen
                # Spotlight ads" among them - and counting those was enough on
                # its own to stop the item ever reading as done.
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
                        # $pi rather than $i: variable names are case-insensitive
                        # here and this file has already paid for a collision
                        # between a loop counter and something above it.
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
                        # Names are wildcards over whichever locations the action
                        # lists, and a shortcut sweep with no matches is a no-op
                        # the same way a missing package is.
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
                        # registry, registryKey, script, feature, capability,
                        # winget. The first three apply regardless of what is
                        # installed; the last three cost a DISM call or a
                        # network round trip to answer, which is not a price
                        # worth paying to gray out five rows.
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
    <#  The full keep-list for this machine, vendor tools included.  #>
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
    <#
        Every pattern the curated manifest already targets, so the scan does not
        offer the same app twice under a different name.
    #>
    param($Categories)

    # Only action types whose "names" identify a piece of software. The others
    # name something else entirely, and harvesting them cost the whole scan
    # once: "Remove desktop shortcuts" legitimately sweeps names "*", that "*"
    # landed here, and every installed program then matched as already-covered.
    # The result was a scan that found nothing and said so quietly.
    $identityTypes = @('appx', 'appxPolicy', 'service', 'winget')

    $pat = New-Object System.Collections.Generic.List[string]
    $add = {
        param([string]$Pattern)
        # A pattern of nothing but wildcards matches everything, so it can only
        # ever be a mistake here however it arrived. Belt and braces with the
        # type filter above, because the next one of these will come from an
        # action type nobody thought about.
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
                # 'match' only ever appears on uninstall, and always names a
                # program, so it needs no type check.
                foreach ($n in @(Get-Prop $a 'match' @())) { & $add ([string]$n) }
            }
            # Script-handler items carry no match patterns, so without this the
            # scanner re-offers what they already remove - OneDrive and Edge
            # were both showing up as "unknown third-party software".
            foreach ($n in @(Get-Prop $i 'covers' @())) { & $add ([string]$n) }
        }
    }
    $pat | Sort-Object -Unique
}

function Get-WDServiceImagePath {
    <#
        The executable out of a service's PathName, which is not a path: it can
        be quoted with arguments after it, or unquoted with spaces in the middle
        (Riot Vanguard registers itself that way). Returns $null when nothing on
        disk matches, which is itself information - see the caller.
    #>
    param([string]$PathName)
    if (-not $PathName) { return $null }
    $p = $PathName.Trim()
    if ($p -match '^"([^"]+)"') { return $Matches[1] }

    # Unquoted. Walk back from the longest prefix so a path with spaces wins
    # over the first token, which would be a directory that does not exist.
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
    <#
        Company, product and description off a binary's version resource. This
        is the only reliable way to tell whose software a service belongs to -
        the service name and display name are chosen by whoever registered it
        and frequently match nothing at all.
    #>
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
    <#
        The directory names between Program Files (or ProgramData) and the
        binary. Version folders are dropped - they identify nothing - and so is
        anything one or two characters long, which is where x64 and bin live.
    #>
    param([string]$Path)
    if (-not $Path) { return @() }
    if ($Path -notmatch '\\(?:Program Files(?: \(x86\))?|ProgramData)\\(.+)$') { return @() }
    $rest = Split-Path $Matches[1] -Parent
    if (-not $rest) { return @() }
    @($rest -split '\\' | Where-Object { $_ -and $_.Length -gt 2 -and $_ -notmatch '^[\d\.]+$' })
}

function Get-WDOwningAppxPackage {
    <#
        The package name for a binary under WindowsApps. A service that ships
        inside an Appx package is removed with the package, so it must be
        classified as the package is rather than on its own.
    #>
    param([string]$Path)
    if ($Path -match '\\WindowsApps\\([^\\]+)') { return (($Matches[1] -split '_')[0]) }
    $null
}

function Get-WDAppxFacts {
    <#
        Two things out of a package's own manifest, read together because they
        cost one XML parse.

        Display: the name the package calls itself. Store packages are allowed
        an opaque identity - Microsoft.4297127D64EC6 is the Minecraft Launcher -
        and offering to remove something nobody can identify is not a choice
        anyone can make. $null when the manifest adds nothing: an unresolved
        ms-resource indirection, or the package name over again.

        Listed: whether it puts anything in Start. A package that does not is
        not an app somebody installed, it is a component something else
        registered - the four PowerToys context-menu packages, VS Code's shell
        integration, Office's actions server. Removing one on its own does not
        uninstall anything, it breaks the app that owns it. $true when the
        manifest cannot be read, so an unreadable package is still offered
        rather than silently dropped.
    #>
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
    <#
        The O= field out of an Appx publisher DN. The value is quoted whenever
        it contains a comma, and taking [^,]+ from it left Anthropic showing as
        a stray double quote plus half a name.
    #>
    param([string]$Dn)
    if ($Dn -match 'O="([^"]+)"')  { return $Matches[1].Trim() }
    if ($Dn -match 'O=([^,]+)')    { return $Matches[1].Trim(' "') }
    'unknown publisher'
}

function Get-WDSoftwareOrigin {
    <#  'microsoft' or 'thirdparty' - drives wording only, never selection.  #>
    param([string]$Publisher)
    if ($Publisher -match 'Microsoft') { 'microsoft' } else { 'thirdparty' }
}

# Where each browser keeps its per-profile data, relative to a user's AppData.
# Opera is the odd one: it lives under Roaming, and its profile is the base
# folder itself rather than a Default child of it.
$script:ChromiumProfiles = @(
    [pscustomobject]@{ Browser = 'Chrome';   Area = 'Local';   Rel = 'Google\Chrome\User Data' }
    [pscustomobject]@{ Browser = 'Edge';     Area = 'Local';   Rel = 'Microsoft\Edge\User Data' }
    [pscustomobject]@{ Browser = 'Brave';    Area = 'Local';   Rel = 'BraveSoftware\Brave-Browser\User Data' }
    [pscustomobject]@{ Browser = 'Vivaldi';  Area = 'Local';   Rel = 'Vivaldi\User Data' }
    [pscustomobject]@{ Browser = 'Chromium'; Area = 'Local';   Rel = 'Chromium\User Data' }
    [pscustomobject]@{ Browser = 'Opera';    Area = 'Roaming'; Rel = 'Opera Software\Opera Stable' }
    [pscustomobject]@{ Browser = 'Opera GX'; Area = 'Roaming'; Rel = 'Opera Software\Opera GX Stable' }
)

# Component extensions the browser ships with and depends on. They sit in the
# profile alongside everything the user chose, which is the only reason they
# turn up here at all. Bundled-but-optional ones (Docs Offline, Edge's text
# suggestions) are deliberately not on this list - those are fair game.
$script:ProtectedExtensions = @{
    'nmmhkkegccagdldgiimedpiccmgmieda' = 'Chrome Web Store Payments - the Web Store stops working without it'
    'mhjfbmdgcfjbbpaeojofohoefgiehjai' = 'Built-in PDF viewer - PDFs would download instead of opening'
    'pkedcjkdefgpdelpbcmbmeomcjbeemfm' = 'Cast support built into the browser'
    'neajdppkdcdipfabeoofebfddakdcjhd' = 'Speech recognition component the browser calls into'
    'gcmjkmgdlgnkkcocmoeiminaijmmjnii' = 'Update component the browser needs to patch itself'
}

function Get-WDChromiumExtensionName {
    <#
        A Chromium manifest is allowed to name the extension indirectly, as
        __MSG_appName__, and resolve it out of the locale bundle. Roughly a
        third of what is installed does, so without this the list reads as a row
        of message keys.
    #>
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
    <#
        Every browser extension installed under any user profile on this
        machine, with a readable name and the folders that hold it.

        Extensions the browser ships with are not here: those live inside the
        application directory, and only what somebody added lands under the user
        profile. That is the whole reason this scans profiles rather than
        asking the browser.
    #>
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

            # Opera's profile is the base itself; everything else keeps one
            # folder per profile under it.
            $profiles = @($base) + @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                                     ForEach-Object { $_.FullName })
            foreach ($prof in ($profiles | Select-Object -Unique)) {
                $extRoot = Join-Path $prof 'Extensions'
                if (-not (Test-Path -LiteralPath $extRoot -PathType Container)) { continue }
                foreach ($ext in @(Get-ChildItem -LiteralPath $extRoot -Directory -ErrorAction SilentlyContinue)) {
                    # An extension folder holds one directory per installed
                    # version; the newest is the one in use.
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

        # Firefox records everything in one file per profile, names included,
        # and marks where each add-on came from. Only profile-installed ones
        # belong here - the rest ship with the browser.
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
    <#
        Scans installed Win32 programs, Appx packages and third-party services,
        classifying each as Protected, Known (manifest already covers it) or
        Discovered. Only Discovered items become removal candidates.
    #>
    param($Categories, $Profile, [scriptblock]$Progress)

    # The scan is the long part of starting up, and the splash has nothing to
    # say without this. Never let a reporting callback break the scan.
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

    # Records why something was spared, so the Advanced tab can explain itself
    # rather than just asserting "protected".
    $keep = {
        param([string]$Name, [string]$Kind, [string]$Reason)
        $protected.Add([pscustomobject]@{ Name = $Name; Kind = $Kind; Reason = $Reason })
    }

    # Publisher fragments that identify this machine's manufacturer.
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

    # ---- Win32 programs ---------------------------------------------------
    & $say 'Reading installed programs' 'Uninstall entries, machine and per-user'
    foreach ($p in (Get-WDInstalledPrograms)) {
        if (Test-WDPatternMatch $p.DisplayName $protectedProgs) {
            & $keep $p.DisplayName 'program' (Get-WDProtectionReason -Name $p.DisplayName -Profile $Profile)
            continue
        }
        if (Test-WDPatternMatch $p.DisplayName $knownPatterns)  { continue }
        if (-not $p.UninstallString -and -not $p.QuietString)    { continue }   # nothing to run

        # Sub-features and bundle records of a product that has its own visible
        # entry. Windows hides them from Add/Remove Programs, and so does every
        # uninstaller worth the name. Offering them separately put Python on the
        # list eleven times and PowerToys twice, and picking one of the eleven
        # does not uninstall Python.
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

    # ---- Appx packages ----------------------------------------------------
    & $say 'Reading Store packages' ''
    $pkgs = @()
    try { $pkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue) } catch { }
    foreach ($pkg in $pkgs) {
        if (Test-WDPatternMatch $pkg.Name $script:ProtectedAppx) {
            & $keep $pkg.Name 'appx' 'Windows component - shell, sign-in, servicing or a media codec'
            continue
        }
        # Vendor hardware tools ship as Store packages too - lighting, hotkey
        # and thermal controllers among them - so the same keep-list applies.
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

        # Only now, on what is left, is it worth opening a manifest per package.
        # The name a package registers under and the name it calls itself are
        # different strings, and the keep-list is written against the second:
        # NVIDIACorp.NVIDIAControlPanel is "NVIDIA Control Panel", and
        # AppUp.IntelArcSoftware is "Intel Graphics Software".
        $facts = Get-WDAppxFacts -Package $pkg
        $disp  = $facts.Display
        if ($disp -and (Test-WDPatternMatch $disp $protectedProgs)) {
            & $keep $pkg.Name 'appx' (Get-WDProtectionReason -Name $disp -Profile $Profile)
            continue
        }
        if ($disp -and (Test-WDPatternMatch $disp $knownPatterns)) { continue }
        # Last, so that anything the curated list names explicitly still wins:
        # Widgets is an app-list-less package too, and it is meant to be offered.
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

    # ---- services belonging to installed software -------------------------
    #
    # A service is not an independent thing: it belongs to a program, a package
    # or to Windows, and it has to be classified as its owner is. Matching only
    # the display name against the keep-list, and never against the manifest at
    # all, offered Edge's three updater services as unrecognized third-party
    # software while remove-edge was already disabling all three, and offered to
    # disable the critical service behind a Lenovo Vantage that the same scan
    # was busy protecting.
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
        # Nothing on disk to look at means nothing can be established about it.
        # NetSetupSvc reports an empty PathName, and "unidentified" is the worst
        # possible reason to offer to switch something off.
        if (-not $exe) { continue }
        if ($exe -match '\.sys$') { continue }
        if ($winRoot -and $exe -like "$winRoot\*") { continue }

        $fi        = Get-WDFileIdentity -Path $exe
        $owningPkg = Get-WDOwningAppxPackage -Path $exe
        $idents    = @($s.Name, [string]$s.DisplayName)
        if ($fi)        { $idents += @($fi.Product, $fi.Description, $fi.Company) }
        if ($owningPkg) { $idents += $owningPkg }
        # The install folder names the owner when nothing else does. Legion
        # Space registers two services: one calls itself "Legion Space" and was
        # protected, the other calls itself "Lenovo Gaming AI Service" and was
        # not, from the same directory.
        $idents += @(Get-WDInstallPathSegments -Path $exe)
        $idents = @($idents | Where-Object { $_ })

        # Windows outside System32: Defender for Endpoint, GameInput, Media
        # Player network sharing. The binary says so itself.
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

        # Already handled by the curated list, or by a package this same scan is
        # about to offer. Either way the owner takes the service with it, so a
        # separate entry is a duplicate that can only be got wrong.
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

    # Handed back so the presence pass can run off it. Enumerating Store
    # packages is the slowest thing this toolkit does, and doing it twice in one
    # startup to answer two questions about the same list would be indefensible.
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
    <#  Human-readable explanation for why an item is on the keep-list.  #>
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

# Icon lookup is cached because the Advanced tab asks for a couple of hundred
# of them and each miss costs a disk hit.
$script:IconCache = @{}
# Package name to install location, filled once by the first appx icon that asks
# and never again. Null rather than empty so "nobody has asked" and "there are
# none" stay different states - the same three-valued habit the rest of this
# codebase keeps.
$script:AppxLocations = $null

function Get-WDIconPath {
    <#
        Best-effort path to something WPF can render as an icon: an .exe/.dll
        to extract from, or a .png shipped inside an Appx package. Returns null
        when nothing sensible is available, and the caller falls back to a glyph.
    #>
    param([string]$Kind, [string]$Name)

    $key = "$Kind|$Name"
    if ($script:IconCache.ContainsKey($key)) { return $script:IconCache[$key] }
    $result = $null

    try {
        if ($Kind -eq 'appx') {
            # One enumeration for every icon, not one query per icon - and the
            # measurement here is worth recording honestly, because it does not
            # say what the same change said in Get-WDRemovedItems.
            #
            # Per-name against one-enumeration-plus-lookups, three rounds each on
            # this machine's 123 packages:
            #
            #     n= 3   per-name  305-343 ms    one enum  431-467 ms
            #     n=10   per-name 1489-1916 ms   one enum  750-895 ms
            #     n=25   per-name 2752-4578 ms   one enum  569-692 ms
            #
            # BREAK-EVEN IS ABOUT FOUR. This machine's scan turns up three appx
            # icons, so here this form is roughly 130 ms SLOWER, and it is still
            # the right one: the count is whatever the scan found and has no
            # ceiling, the per-name form grows with it without bound, and the
            # worst this costs is one enumeration. A fixed 150 ms beats a slope.
            #
            # Lazily, and cached for the process: a list with no Store apps in it
            # should not enumerate them at all, which is the case that keeps the
            # regression off machines that would only ever have paid it.
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
                        # Packages ship scaled variants: Logo.scale-200.png etc.
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
    <#
        Deterministic short id for a discovered item.

        String.GetHashCode is only guaranteed stable within a process, so using
        it here would let a saved profile stop matching its own items on a later
        run. Hand-rolled FNV is worse: PowerShell widens the multiply past
        UInt32 before the mask applies and the cast throws. MD5 sidesteps both -
        it is an identifier here, not a security primitive.
    #>
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
    <#
        Turns a scan into manifest categories the engine can execute, so
        discovered software flows through exactly the same executors, journal
        and rollback path as everything curated.

        Tiers: vendor bloat is 3 (Aggressive), general software and services
        are 4 (Extreme only) because that bucket contains the operator's own
        applications - browsers, editors, games - not just junk.
    #>
    param($Scan)

    $cats = New-Object System.Collections.Generic.List[psobject]

    # The visible name and the name the action targets are not always the same
    # string, so keep them apart: the id, the icon and the uninstall all key off
    # the real one, and only the label uses the readable one.
    $label = { param($E) $(if ($E.PSObject.Properties['Display'] -and $E.Display) { $E.Display } else { $E.Name }) }
    # "Third-party" is a claim, and it was wrong on roughly half of what it was
    # printed on - Office, Gaming Services and the Edge updaters are Microsoft's.
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
                # Vendor software the scan found: "software you did not ask
                # for" by definition, which is what band 3 says. The scanner's
                # finds cannot be rated in the manifest, so the rating is set
                # here or they arrive unrated and sort to the bottom of the
                # bloat order as though they were not removals at all.
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
                # Tier 0: no preset, Extreme included. The scan cannot tell a
                # program somebody depends on from one they forgot about, and a
                # mode that quietly uninstalls the first is the worst thing this
                # application could do. Extreme used to take the lot, which made
                # it a preset nobody could safely pick without reading 40 rows.
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
                # Tier 0, alongside the software and extensions above and for the
                # same reason: this belongs to a program somebody installed
                # deliberately, and the scan knows its name but not whether it is
                # load-bearing for the way they use it. Extreme took the lot,
                # which is a preset deciding about somebody else's software.
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
                # Which browser owns it, as a field rather than as the suffix on
                # the name. Removing a browser leaves its extensions as folders
                # in a profile nothing reads any more, so the interface ties the
                # two together - and it cannot do that by parsing a label it
                # also has to translate one day.
                browser = [string]$e.Browser
                desc    = "$($e.Id)$where | browser extension found by scan"
                riskNote = 'Extensions carry passwords, session cookies and page-blocking rules. Removing one loses whatever it was storing, and an ad or script blocker takes its filter lists with it. The folder goes to the Recycle Bin, so it can be put back, but the browser has to be closed for the removal to stick.'
                # Tier 0, for the same reason as the software above: an
                # extension is something the person deliberately added, and a
                # password manager or an ad blocker is exactly the kind of thing
                # a preset must not decide about on their behalf.
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
