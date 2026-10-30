# Edge Stable's EdgeUpdate application GUID. Beta/Dev/Canary are included so a
# preview channel cannot quietly take Stable's place.

$script:EdgeGuids = @{
    Stable = '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
    Beta   = '{2CD8A007-E189-409D-A2C8-9AF4EF3C72AA}'
    Dev    = '{0D50BFEC-CD6A-4F9A-964C-C7416E3ACB10}'
    Canary = '{65C35B14-6C1D-4122-AC46-7148CC9D6497}'
}

# Edge asks Windows whether it may be uninstalled at all, and Windows answers
# out of IntegratedServicesRegionPolicySet.json. This policy is disabled by
# default and enabled only in the EEA, so outside those regions setup.exe exits
# 93 and leaves the browser where it was, logging "Browser/WebView is sticky,
# uninstall not allowed".
# The region it is answered for is the device setup region, not the home
# location. This used to borrow IE as the home location for the length of the
# uninstall; on 2026-10-29 that ran three times on a US machine and was refused
# with 93 every time. The device setup region is picked once, during setup, is
# guarded from scripts by the same driver that guards the default browser, and
# takes a restart to apply - and current builds accept the uninstall only when
# Settings starts it (532 otherwise), EEA or not. Every way past that defeats a
# Windows protection: rewriting Microsoft's compliance data in System32,
# slipping past that driver, or faking the uninstaller's parent. This toolkit
# does none of them, so outside the EEA it says so and leaves Edge alone.
$script:EdgeUninstallPolicyGuid = '{1bca278a-5d11-4acf-ad2f-f9ab6d7f93a6}'

function Get-WDGeoIso2 {
    param([int]$GeoId)
    if (-not ('WDGeo.Api' -as [type])) {
        try {
            Add-Type -Namespace WDGeo -Name Api -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetGeoInfo(int Location, int GeoType, System.Text.StringBuilder lpGeoData, int cchData, int LangId);
'@ -ErrorAction Stop
        } catch { return '' }
    }
    try {
        $sb = New-Object System.Text.StringBuilder 16
        # 4 = GEO_ISO2
        if ([WDGeo.Api]::GetGeoInfo($GeoId, 4, $sb, 16, 0) -le 0) { return '' }
        $sb.ToString()
    } catch { '' }
}

function Get-WDHomeGeoId {
    $v = Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\International\Geo' -Name 'Nation' -ErrorAction SilentlyContinue
    if ($v -and $v.PSObject.Properties['Nation']) { return [int]$v.Nation }
    -1
}

function Set-WDHomeGeoId {
    # Home location only - nothing about display language or formats.
    param([Parameter(Mandatory)][int]$GeoId)
    $key = 'HKCU:\Control Panel\International\Geo'
    if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force -ErrorAction SilentlyContinue }
    Set-ItemProperty -LiteralPath $key -Name 'Nation' -Value ([string]$GeoId) -Type String -Force -ErrorAction Stop
    $iso = Get-WDGeoIso2 -GeoId $GeoId
    if ($iso) { Set-ItemProperty -LiteralPath $key -Name 'Name' -Value $iso -Type String -Force -ErrorAction SilentlyContinue }
}

function Get-WDDeviceRegionGeoId {
    # The region Windows' region policy is decided for: the device setup region,
    # shown under Settings > Time and language > Language and region. Builds
    # without the value decide it from the home location, so that is the
    # fallback.
    $v = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion' `
                          -Name 'DeviceRegion' -ErrorAction SilentlyContinue
    if ($v -and $v.PSObject.Properties['DeviceRegion']) { return [int]$v.DeviceRegion }
    Get-WDHomeGeoId
}

function Get-WDEdgeUninstallPolicy {
    $out = [pscustomobject]@{
        Known   = $false
        Allowed = $true
        Region  = ''
        GeoId   = -1
        Regions = @()
        Path    = (Join-Path ([string]$env:SystemRoot) 'System32\IntegratedServicesRegionPolicySet.json')
    }
    $out.GeoId  = Get-WDDeviceRegionGeoId
    $out.Region = Get-WDGeoIso2 -GeoId $out.GeoId

    if (-not (Test-Path -LiteralPath $out.Path -ErrorAction SilentlyContinue)) { return $out }
    try {
        $doc = Get-Content -LiteralPath $out.Path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch { return $out }

    $pol = @($doc.policies | Where-Object { [string]$_.guid -ieq $script:EdgeUninstallPolicyGuid })
    if (-not $pol.Count) {
        # The guid is the stable identifier, but a file that has been
        # reorganized should not read as "no gate".
        $pol = @($doc.policies | Where-Object { [string]$_.'$comment' -match 'Edge is uninstallable' })
    }
    if (-not $pol.Count) { return $out }

    $out.Known   = $true
    $out.Regions = @($pol[0].conditions.region.enabled)
    $out.Allowed = ([string]$pol[0].defaultState -ieq 'enabled')
    if ($out.Region -and $out.Regions -contains $out.Region) { $out.Allowed = $true }
    $out
}

function Get-WDEdgeInstallerReason {
    # Quoted verbatim rather than paraphrased: "not uninstallable for process"
    # is Edge's claim, not ours.
    #
    # Only from a log written since -Since. The 2026-10-29 run quoted a line a
    # month old as the reason it had just been refused: that attempt wrote no
    # log here, and the user TEMP copy still held the first run's refusal.
    param([datetime]$Since = [datetime]::MinValue)
    $logs = @(
        (Join-Path ([string]$env:TEMP) 'msedge_installer.log')
        (Join-Path ([string]$env:SystemRoot) 'Temp\msedge_installer.log')
        # Where a system-level setup.exe writes it on 24H2 and later - the
        # 2026-10-29 uninstall's log was here and in neither of the above.
        (Join-Path ([string]$env:SystemRoot) 'SystemTemp\msedge_installer.log')
    )
    foreach ($l in $logs) {
        if (-not (Test-Path -LiteralPath $l -ErrorAction SilentlyContinue)) { continue }
        try { if ((Get-Item -LiteralPath $l -ErrorAction Stop).LastWriteTime -lt $Since) { continue } } catch { continue }
        try {
            $hit = @(Get-Content -LiteralPath $l -Tail 400 -ErrorAction Stop |
                     Where-Object { $_ -match 'uninstallable|Uninstall allowed|uninstall not allowed' })
            if ($hit.Count) { return ([string]$hit[-1]).Trim() }
        } catch { }
    }
    ''
}

function Get-WDBrowserRegistrations {
    # Read, never assumed: Chrome uses static ProgIds, but Firefox, Brave,
    # Vivaldi, and Opera append a per-install hash.
    $out = New-Object System.Collections.Generic.List[psobject]
    foreach ($hive in @('HKLM:', 'HKCU:')) {
        $root = Join-Path $hive 'SOFTWARE\Clients\StartMenuInternet'
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $cap = Join-Path $k.PSPath 'Capabilities'
            if (-not (Test-Path -LiteralPath $cap)) { continue }
            $name = ''
            try { $name = [string](Get-ItemProperty -LiteralPath $cap -Name 'ApplicationName' -ErrorAction Stop).ApplicationName } catch { }
            if (-not $name) { $name = $k.PSChildName }

            $prog = [ordered]@{}
            foreach ($sub in @('URLAssociations', 'FileAssociations')) {
                $p = Join-Path $cap $sub
                if (-not (Test-Path -LiteralPath $p)) { continue }
                try {
                    $props = Get-ItemProperty -LiteralPath $p -ErrorAction Stop
                    foreach ($pr in $props.PSObject.Properties) {
                        if ($pr.Name -like 'PS*') { continue }
                        $prog[$pr.Name] = [string]$pr.Value
                    }
                } catch { }
            }
            if (-not $prog.Count) { continue }

            # The name Settings' deep link keys on is the RegisteredApplications
            # value whose data points at this Capabilities key, not
            # ApplicationName. The two agree for Chrome and Edge; Firefox
            # registers as Firefox-<hash>, and its friendly name finds nothing.
            $regName = ''
            $wantCap = "Software\Clients\StartMenuInternet\$($k.PSChildName)\Capabilities"
            try {
                $ra = Get-Item -LiteralPath (Join-Path $hive 'SOFTWARE\RegisteredApplications') -ErrorAction Stop
                foreach ($vn in $ra.GetValueNames()) {
                    if ([string]$ra.GetValue($vn) -ieq $wantCap) { $regName = [string]$vn; break }
                }
            } catch { }

            $out.Add([pscustomobject]@{
                Key      = $k.PSChildName
                Name     = $name
                IsEdge   = ($k.PSChildName -match 'msedge|Microsoft Edge')
                ProgIds  = $prog
                Hive     = $hive
                RegName  = $regName
            })
        }
    }
    # Unrolled, not ",@(...)": every caller pipes or wraps this, and the comma
    # form hands the pipeline one array object that renders as a single row
    # whose Name is the whole list.
    @($out | Sort-Object Key -Unique)
}

function Get-WDDefaultBrowserProgId {
    $p = 'HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice'
    try { return [string](Get-ItemProperty -LiteralPath $p -Name 'ProgId' -ErrorAction Stop).ProgId } catch { return '' }
}

function Read-WDUserChoiceMap {
    # Every protocol and file type this user has a UserChoice for, read once and
    # through the registry API. The provider route - Join-Path, Test-Path, and
    # Get-ItemProperty per key - took fifty seconds over FileExts on a machine
    # with a few hundred types, and the "already done" probe asks this.
    $map = [pscustomobject]@{
        Url  = New-Object System.Collections.Generic.List[psobject]
        File = New-Object System.Collections.Generic.List[psobject]
    }
    foreach ($r in @(
        @{ Into = 'Url';  Path = 'SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations' }
        @{ Into = 'File'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts' })) {
        $k = $null
        try { $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($r.Path) } catch { }
        if (-not $k) { continue }
        try {
            foreach ($n in $k.GetSubKeyNames()) {
                $uc = $null
                try { $uc = $k.OpenSubKey("$n\UserChoice") } catch { }
                if (-not $uc) { continue }
                $id = ''
                try { $id = [string]$uc.GetValue('ProgId', '') } catch { } finally { $uc.Close() }
                if ($id) { $map.($r.Into).Add([pscustomobject]@{ Name = [string]$n; ProgId = $id }) }
            }
        } finally { $k.Close() }
    }
    $map
}

function Get-WDHeldAssociations {
    param([string[]]$ProgIds, $Map)

    $out = [pscustomobject]@{ Url = @(); File = @() }
    if (-not $ProgIds -or -not $ProgIds.Count) { return $out }
    $want = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $ProgIds) { if ($p) { $null = $want.Add([string]$p) } }
    if (-not $Map) { $Map = Read-WDUserChoiceMap }

    $out.Url  = @($Map.Url  | Where-Object { $want.Contains([string]$_.ProgId) } | ForEach-Object { $_.Name } | Sort-Object -Unique)
    $out.File = @($Map.File | Where-Object { $want.Contains([string]$_.ProgId) } | ForEach-Object { $_.Name } | Sort-Object -Unique)
    $out
}

function Get-WDOrphanedAssociations {
    param($Map)

    $out = [pscustomobject]@{ Url = @(); File = @() }
    if (-not $Map) { $Map = Read-WDUserChoiceMap }
    # One answer per ProgId: a few hundred types point at a few dozen of them.
    $ok = @{}
    $broken = {
        param($Entry)
        $id = [string]$Entry.ProgId
        if (-not $ok.ContainsKey($id)) { $ok[$id] = [bool](Test-WDProgIdResolves -ProgId $id) }
        -not $ok[$id]
    }
    $out.Url  = @($Map.Url  | Where-Object { & $broken $_ } | ForEach-Object { $_.Name } | Sort-Object -Unique)
    $out.File = @($Map.File | Where-Object { & $broken $_ } | ForEach-Object { $_.Name } | Sort-Object -Unique)
    $out
}

function Test-WDProgIdResolves {
    param([string]$ProgId)
    if (-not $ProgId) { return $false }

    # Windows deletes the whole ProgId key when the program that registered it
    # is uninstalled. It is also the only test a Store app answers. A key that
    # cannot be read is not evidence of anything, so it counts as resolving.
    $root = $null
    try { $root = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey($ProgId) } catch { return $true }
    if (-not $root) { return $false }

    # Only a rooted path is checked: a bare command name is resolved through
    # PATH by the shell, and guessing at that would report working types as
    # broken.
    $cmd = ''
    try {
        $ck = $root.OpenSubKey('shell\open\command')
        if ($ck) { try { $cmd = [string]$ck.GetValue('') } finally { $ck.Close() } }
    } catch { } finally { $root.Close() }
    if ($cmd) {
        $exe = $cmd
        if ($cmd -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
        elseif ($cmd -match '^\s*(\S+)')  { $exe = $Matches[1] }
        if ($exe -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $exe)) { return $false }
        return $true
    }

    # A Store app activates through its AppUserModelID rather than a command, so
    # no command line says nothing. A false orphan drags a working file type
    # into the broken list.
    $true
}

function Get-WDAssociationLock {
    # Three locks, in the order they bite. All are real and they stack.
    $reasons = New-Object System.Collections.Generic.List[string]

    # Once HashVersion is 1, Windows reads UserChoiceLatest rather than
    # UserChoice, and that algorithm is not public - so even a perfect classic
    # hash is ignored. This is the decisive one.
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $k = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemProtectedUserData\$sid\AnyoneRead\AppDefaults"
        $hv = (Get-ItemProperty -LiteralPath $k -Name 'HashVersion' -ErrorAction Stop).HashVersion
        if ([int]$hv -ge 1) {
            $reasons.Add('Windows has migrated this account to UserChoiceLatest, whose signature no third-party tool can produce')
        }
    } catch { }

    # UCPD, the kernel filter driver added Feb 2024, refuses writes to the http,
    # https, and .pdf keys from a denylist that includes powershell.exe -
    # matched by image name and by PE OriginalFilename, even as SYSTEM.
    try {
        $st = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD' -Name 'Start' -ErrorAction Stop).Start
        if ([int]$st -ne 4) {
            $reasons.Add('the User Choice Protection Driver is active and blocks these keys from PowerShell')
        }
    } catch { }

    [string]($reasons -join '; ')
}

# What one press of Set default moves. Outside the EEA it is the four a browser
# is for; where the Digital Markets Act applies Windows adds ftp, read, .pdf, and
# the rest of the web types (Windows Insider Blog, 2025-06-02). Which of the two
# a machine gets is decided by Windows' own region policy file, so it is read
# from there - the same answer Settings gets - rather than from a country list.
$script:DefaultAppsExtraTypesGuid = '{8e779eeb-377c-4373-9e80-56e164fdca7e}'
$script:SetDefaultCore  = @('http', 'https', '.htm', '.html')
$script:SetDefaultExtra = @('ftp', 'read', '.pdf', '.svg', '.xht', '.xhtml', '.mht', '.mhtml', '.shtml', '.xml')

function Get-WDSetDefaultScope {
    $extended = $false
    $path = Join-Path ([string]$env:SystemRoot) 'System32\IntegratedServicesRegionPolicySet.json'
    try {
        $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        $pol = @($doc.policies | Where-Object { [string]$_.guid -ieq $script:DefaultAppsExtraTypesGuid })
        if ($pol.Count) {
            $extended = ([string]$pol[0].defaultState -ieq 'enabled')
            # Same policy file, same region: the device setup region.
            $iso = Get-WDGeoIso2 -GeoId (Get-WDDeviceRegionGeoId)
            if ($iso -and @($pol[0].conditions.region.enabled) -contains $iso) { $extended = $true }
        }
    } catch { }
    $types = @($script:SetDefaultCore)
    if ($extended) { $types += $script:SetDefaultExtra }
    [pscustomobject]@{ Extended = $extended; Types = $types }
}

function Format-WDTypeList {
    param([string[]]$Types, [int]$Max = 12)
    $t = @($Types)
    $s = (@($t | Select-Object -First $Max)) -join ', '
    if ($t.Count -gt $Max) { $s += ", and $($t.Count - $Max) more" }
    $s
}

function Get-WDDefaultBrowserPlan {
    # Everything the default-browser step decides, with nothing opened. The
    # handler, its preview, Edge removal's hand-over, and the "already done"
    # probe all ask this one question, so they cannot disagree - the probe used
    # to look at http and https alone while the handler saw .svg still with Edge
    # and reopened Settings on every run.
    param([string]$PreferName)

    $plan = [pscustomobject]@{
        Pick = $null; Current = ''; Wanted = ''; Done = $false; Extended = $false
        Moving = @(); ByHand = @(); Stranded = @()
    }
    $browsers = @(Get-WDBrowserRegistrations)
    $targets  = @($browsers | Where-Object { -not $_.IsEdge })
    if (-not $targets.Count) { return $plan }

    $current = Get-WDDefaultBrowserProgId
    $plan.Current = $current

    $pick = $null
    if ($PreferName) { $pick = $targets | Where-Object { $_.Name -like "*$PreferName*" -or $_.Key -like "*$PreferName*" } | Select-Object -First 1 }
    # Nobody said which: the browser already holding http, if it is not Edge.
    # Without this a machine on Firefox was told to move everything to whichever
    # browser happened to sort first.
    if (-not $pick -and $current) {
        $pick = $targets | Where-Object { @($_.ProgIds.Values) -contains $current } | Select-Object -First 1
    }
    if (-not $pick) { $pick = $targets[0] }
    $plan.Pick = $pick

    $wanted  = [string]$pick.ProgIds['http']
    $plan.Wanted = $wanted

    # Everything the outgoing browser holds, not just http - the complaint this
    # answers is the half-move where .pdf and .svg go on opening in the old one.
    # Intersected with what the incoming browser registered for, since Windows
    # will not point a type at a program that never claimed it.
    $mine = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($v in @($pick.ProgIds.Values)) { if ($v) { $null = $mine.Add([string]$v) } }

    $outgoing = @()
    if ($current -and -not $mine.Contains([string]$current)) { $outgoing = @([string]$current) }
    foreach ($b in $browsers) {
        if (-not $b.IsEdge) { continue }
        foreach ($v in @($b.ProgIds.Values)) { if ($v -and -not $mine.Contains([string]$v)) { $outgoing += [string]$v } }
    }
    $ucMap = Read-WDUserChoiceMap
    $held  = Get-WDHeldAssociations -ProgIds @($outgoing | Sort-Object -Unique) -Map $ucMap

    # Anything already pointing at a program that is gone is swept up too. Those
    # are worse than a wrong default - the type does not open at all - and
    # removing the mail app orphans mailto, which reading Edge's ProgIds never
    # finds.
    $orph  = Get-WDOrphanedAssociations -Map $ucMap
    $takes = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @($pick.ProgIds.Keys)) { $null = $takes.Add([string]$k) }

    $allHeld   = @(@($held.Url) + @($held.File) + @($orph.Url) + @($orph.File) | Sort-Object -Unique)
    $claimable = @($allHeld | Where-Object { $takes.Contains([string]$_) })

    # Of what the incoming browser can take, only the types Set default covers
    # here move on that one press. The rest it claims too, but each has to be
    # picked under Default apps by hand - outside the EEA that is .pdf, .svg,
    # and mailto among others.
    $scope = Get-WDSetDefaultScope
    $plan.Extended = $scope.Extended
    $inScope = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in @($scope.Types)) { $null = $inScope.Add([string]$t) }
    $plan.Moving = @($claimable | Where-Object { $inScope.Contains([string]$_) })
    $plan.ByHand = @($claimable | Where-Object { -not $inScope.Contains([string]$_) })
    # Types the outgoing browser holds that the incoming one never registered
    # for. Nothing in Default apps can move these to it, so naming them is the
    # difference between a finished job and one that looks finished.
    # Edge's own microsoft-edge: protocols are left out: no other browser claims
    # them, and telling somebody to point them elsewhere is advice nobody can
    # follow.
    $plan.Stranded = @(@($held.Url) + @($held.File) | Where-Object { -not $takes.Contains([string]$_) -and [string]$_ -notlike 'microsoft-edge*' })

    # Done when the press would move nothing: http is already the pick's, and
    # nothing Set default covers is left with the outgoing browser. Not "nothing
    # held anywhere" - that asked for a button that cannot move .svg, and on a
    # US machine reopened Settings at every run.
    $plan.Done = [bool]($wanted -and $current -and $current -eq $wanted -and -not @($plan.Moving).Count)
    $plan
}

function Get-WDDefaultBrowserLeftovers {
    # The two sentences every outcome ends with, when they apply.
    param($Plan)
    $name = [string]$Plan.Pick.Name
    $s = ''
    if (@($Plan.ByHand).Count) {
        $s += " Set default does not move these here, so pick $name for each under Settings > Apps > Default apps > $name" +
              ": $(Format-WDTypeList -Types $Plan.ByHand)."
    }
    if (@($Plan.Stranded).Count) {
        $s += " These stay with the old browser because $name has not registered for them, so they have to be" +
              " pointed at another program by hand: $(Format-WDTypeList -Types $Plan.Stranded)."
    }
    $s
}

function Set-WDDefaultBrowserBestEffort {
    # There is no silent path on current Windows, and this does not pretend
    # otherwise: it reads the plan and hands it to the operator with the
    # Settings page already open.
    param($Context, [string]$PreferName)

    $plan = Get-WDDefaultBrowserPlan -PreferName $PreferName
    if (-not $plan.Pick) {
        return [pscustomobject]@{ Ok = $false; Message = 'no replacement browser is installed yet'; Opened = $false
                                  Pick = ''; Moving = @(); ByHand = @(); Stranded = @() }
    }
    $pick = $plan.Pick
    $rest = Get-WDDefaultBrowserLeftovers -Plan $plan

    if ($plan.Done) {
        return [pscustomobject]@{
            Ok = $true; Opened = $false; Pick = $pick.Name
            Moving = @(); ByHand = $plan.ByHand; Stranded = $plan.Stranded
            Message = "$($pick.Name) already holds everything Set default moves.$rest".Trim()
        }
    }

    $what = $(if (@($plan.Moving).Count) { "$(@($plan.Moving).Count) association(s) - $(Format-WDTypeList -Types $plan.Moving)" }
              else { 'http, https, .htm, and .html' })

    $lock = Get-WDAssociationLock
    $why = $(if ($lock) { " Windows will not allow this silently: $lock." } else { ' Windows will not let any program do this silently.' })
    if ($Context.Preview) {
        return [pscustomobject]@{
            Ok = $false; Opened = $false; Pick = $pick.Name
            Moving = $plan.Moving; ByHand = $plan.ByHand; Stranded = $plan.Stranded
            Message = "Would hand $what to $($pick.Name).$why$rest"
        }
    }

    # registeredAppMachine for a browser registered under HKLM,
    # registeredAppUser for one under HKCU, each with its RegisteredApplications
    # name. The friendly name is the fallback for a browser that registered none.
    $opened = $false
    try {
        $param = $(if ([string]$pick.Hive -ieq 'HKCU:') { 'registeredAppUser' } else { 'registeredAppMachine' })
        $nm    = $(if ($pick.RegName) { [string]$pick.RegName } else { [string]$pick.Name })
        Start-Process "ms-settings:defaultapps?$param=$([uri]::EscapeDataString($nm))" -ErrorAction Stop
        $opened = $true
    } catch {
        try { Start-Process 'ms-settings:defaultapps' -ErrorAction Stop; $opened = $true } catch { }
    }

    [pscustomobject]@{
        Ok       = $false
        Opened   = $opened
        Pick     = $pick.Name
        Moving   = $plan.Moving
        ByHand   = $plan.ByHand
        Stranded = $plan.Stranded
        Message  = "$($pick.Name) could not be made default without your confirmation" +
                   $(if ($lock) { " - $lock" } else { '' })
    }
}

Register-WDHandler 'SetDefaultBrowser' {
    param($Action, $Context)

    # The operator's answer first. Without it this took the first non-Edge
    # browser it happened to find.
    $prefer = ''
    try { $prefer = [string](Get-WDRunOption -Root $Context.Session.Root -Name 'defaultBrowser' -Default '') } catch { }
    # Falling back to whatever is queued keeps the command line - which has no
    # picker and writes no run options - behaving as it always did.
    if (-not $prefer) {
        try {
            $picked = @(Get-WDChosenBrowsers (Get-WDBrowserChoice -Root $Context.Session.Root))
            if ($picked.Count) { $prefer = [string]$picked[0].Name }
        } catch { }
    }

    $r = Set-WDDefaultBrowserBestEffort -Context $Context -PreferName $prefer
    if (-not $r.Pick) {
        return New-WDResult -Status Skipped -Message "Nothing to hand the associations to - $($r.Message)"
    }
    if ($r.Ok) { return New-WDResult -Status AlreadySet -Message $r.Message }
    # Obstruction in preview too, because that is what apply reports. It read
    # Changed, which is the one thing this step is certain not to do on its own.
    if ($Context.Preview) {
        return New-WDResult -Status Obstruction -Message $r.Message `
                            -Detail ('Applying will open Settings > Apps > Default apps at the right browser and ' +
                                     'say which button to press.')
    }

    $tail = ''
    if (@($r.Moving).Count) {
        $tail += " That moves $(@($r.Moving).Count) association(s): $(Format-WDTypeList -Types $r.Moving -Max 20)."
    }
    $tail += Get-WDDefaultBrowserLeftovers -Plan ([pscustomobject]@{
        Pick = [pscustomobject]@{ Name = $r.Pick }; ByHand = $r.ByHand; Stranded = $r.Stranded })
    # Obstruction, not Blocked: Blocked means this run tried something and
    # Windows said no, and nothing here was refused. Windows lets no program
    # move the default browser silently, by design.
    New-WDResult -Status Obstruction -Message $r.Message -Detail (
        'Windows 11 protects the default-browser setting with a kernel driver and a signed hash that no ' +
        'third-party tool can write, so this is the one thing here that genuinely needs your click. ' +
        $(if ($r.Opened) { 'Default apps has been opened at ' + $r.Pick + ' - press Set default.' }
          else { 'Open Settings, Apps, Default apps, pick ' + $r.Pick + ' and press Set default.' }) + $tail)
}

# The Copilot app's updater id. Edge Update installs and updates it, and since
# April 2026 it ships a whole Edge engine of its own (msedge.exe and all).
$script:CopilotGuid = '{C50565E9-CCCF-44B4-BA15-5AC5C6569197}'

function Get-WDEdgeUpdateRecordPaths {
    # The updater's records of the browser channels. While any of these exist
    # it treats that channel as installed - updating, repairing, and running
    # its on-os-upgrade command - so they are what makes an uninstalled Edge
    # come back through it. WebView2's ({F3017226-...}) and the updater's own
    # ({F3C4FE00-...}) are not in $script:EdgeGuids and are never named here.
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($view in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate', 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate') {
        foreach ($sub in 'Clients', 'ClientState', 'ClientStateMedium') {
            foreach ($g in $script:EdgeGuids.Values) { $out.Add("$view\$sub\$g") }
        }
    }
    @($out)
}

function Get-WDWebView2UpdaterGap {
    # WebView2 with nothing left to patch it: Edge Update's files deleted from
    # under it - on 2026-10-29 by changes made outside the toolkit - with its
    # services still registered and pointing at nothing. Said rather than
    # repaired: putting an updater back is the operator's call.
    $wv = Test-Path -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeWebView\Application')
    $up = Test-Path -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe')
    if ($wv -and -not $up) {
        return ('WebView2 is installed but the files of Edge Update, its only updater, are gone, so WebView2 gets no ' +
                'security fixes. Reinstalling the WebView2 Runtime from Microsoft puts the updater back without the browser; ' +
                'if its installer then reports a failure, the updater repairs its own registration on its next scheduled run.')
    }
    ''
}

function Get-WDEdgeInstallerCachePaths {
    # A full Edge installer the updater kept - 199 MB of it on the 2026-10-29
    # machine, under the Stable channel's id.
    $dl = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeUpdate\Download'
    @($script:EdgeGuids.Values | ForEach-Object { Join-Path $dl $_ } | Where-Object { Test-Path -LiteralPath $_ })
}

function Block-WDEdgeReinstall {
    # What would put Edge back, short of the updater itself. Edge Update is
    # also the only thing that patches WebView2, which Windows Search and much
    # else run on, and Microsoft documents that a WebView2 update never
    # installs the browser. This used to disable its services and tasks and
    # park its folder, which left WebView2 unpatched for good; what the updater
    # would act on is removed instead - its records of Edge and its cached
    # installer, in Remove-WDEdgeLeftovers.
    param($Context)

    $blocked = New-Object System.Collections.Generic.List[string]

    # Through the registry executor, so every value is journalled. Install and
    # update off for each browser channel and for Copilot, and the updater's
    # experimentation service off, which is what drives rollouts like
    # Copilot's. The per-product browser policies bind only a machine joined to
    # a domain - "available only on Windows instances that are joined to a
    # Microsoft Active Directory domain", and the updater's log reads "Machine
    # is not Enterprise Managed" with them in place - so on most machines the
    # records are what stops it and these are a second line. Nothing here
    # names WebView2: the blanket InstallDefault, UpdateDefault, and
    # AutoUpdateCheckPeriodMinutes this used to write stop WebView2 updating
    # too wherever they do bind.
    $pol  = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
    $vals = New-Object System.Collections.Generic.List[psobject]
    $base = [ordered]@{
        'DoNotUpdateToEdgeWithChromium'                        = 1
        'CreateDesktopShortcutDefault'                         = 0
        'RemoveDesktopShortcutDefault'                         = 1
        'UpdaterExperimentationAndConfigurationServiceControl' = 0
        "Install$($script:CopilotGuid)"                        = 0
    }
    foreach ($k in $base.Keys) { $vals.Add([pscustomobject]@{ path = $pol; name = $k; kind = 'DWord'; value = $base[$k] }) }
    foreach ($g in $script:EdgeGuids.Values) {
        $vals.Add([pscustomobject]@{ path = $pol; name = "Install$g"; kind = 'DWord'; value = 0 })
        $vals.Add([pscustomobject]@{ path = $pol; name = "Update$g";  kind = 'DWord'; value = 0 })
    }
    $reg = Invoke-WDRegistryAction -Context $Context -Action ([pscustomobject]@{ type = 'registry'; scope = 'machine'; values = $vals.ToArray() })
    if ([string]$reg.Status -eq 'Changed') { $blocked.Add('install policy for Edge and Copilot') }

    # The Windows Update orchestrator's two entries for the updater. Both run
    # it update-only today, but the OOBE one put the updater back on this
    # toolkit's test machine eight days after the 2026-08-15 run (its log:
    # "/install ... brand=WAAS"), and the updater's own hourly task already
    # keeps WebView2 current without either. Exported first.
    $uso = Invoke-WDRegistryKeyAction -Context $Context -Action ([pscustomobject]@{
        type = 'registryKey'; paths = @(
            'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\EdgeUpdate',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\EdgeUpdate') })
    if ([string]$uso.Status -eq 'Removed') { $blocked.Add('Windows Update reinstall channel') }

    # The browser's own service and tasks - not the updater's. The elevation
    # service runs elevation_service.exe out of Edge\Application.
    $svc = Invoke-WDServiceAction -Action ([pscustomobject]@{
        names = @('MicrosoftEdgeElevationService', 'MicrosoftEdgeBetaElevationService', 'MicrosoftEdgeDevElevationService')
        startupType = 'Disabled'; stop = $true }) -Context $Context
    if ($svc.Status -in @('Changed','Removed')) { $blocked.Add('Edge elevation service') }
    $tsk = Invoke-WDTaskAction -Action ([pscustomobject]@{
        tasks = @('\MicrosoftEdgeUpdateBrowserReplacementTask*', '\MicrosoftEdgeShadowStackRollbackTask*'); delete = $true }) -Context $Context
    if ($tsk.Status -in @('Changed','Removed')) { $blocked.Add('Edge browser tasks') }

    @($blocked)
}

Register-WDHandler 'RemoveEdge' {
    # UNINSTALL FIRST, then block - and block only what was really uninstalled.
    #
    # This used to block every reinstall vector first, on the reasoning that
    # EdgeUpdate would otherwise notice Edge was gone and re-stage it. The cost
    # of that order showed on 2026-08-15: Windows refused the uninstall (exit
    # 93), the updater was already off, and a folder sweep then deleted Edge's
    # files anyway - leaving Installed apps, App Paths, the default-browser
    # registration and microsoft-edge: links all pointing at an msedge.exe that
    # was gone, and reporting "Removed". A refused uninstall now changes
    # nothing: Edge stays installed AND updating. The race the old order
    # guarded against is closed by stopping the updater (not disabling it)
    # for the length of the uninstall.
    param($Action, $Context)

    $edgeDirs = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $installed = { @($edgeDirs | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'msedge.exe') }) }

    # Already gone: clear what it left and shut what would bring it back.
    # msedge.exe is what makes Edge installed, not its Store package - an
    # uninstall done outside the toolkit on 2026-10-29 left that registered,
    # and keying on it sent a machine with no Edge down the uninstall path,
    # which then reported removing it.
    if (-not @(& $installed).Count) {
        $left = @(Remove-WDEdgeLeftovers -Context $Context)
        $gap  = Get-WDWebView2UpdaterGap
        if ($gap) { Write-WDLog $gap -Level Warn -Item $Context.ItemId }
        if (-not $left.Count) { return New-WDResult -Status NotPresent -Message 'Edge is not installed and nothing of it is left' -Detail $gap }
        if (-not $Context.Preview) { Set-WDRebootNeeded }
        return New-WDResult -Status Removed -Reboot:(-not $Context.Preview) `
            -Message $(if ($Context.Preview) { 'Edge is already uninstalled; would clear what it left and block its return' }
                       else { 'Edge was already uninstalled; what it left is cleared and its return blocked' }) `
            -Detail ((($left | Sort-Object -Unique) -join ', ') + $(if ($gap) { ". $gap" } else { '' }))
    }

    $policy = Get-WDEdgeUninstallPolicy

    # Refused before anything is touched, preview included: outside the EEA no
    # script can do anything Windows accepts (see the top of this file), and
    # stopping the updater and closing Edge for an attempt that cannot succeed
    # only shut the browser on whoever was using it.
    if ($policy.Known -and -not $policy.Allowed) {
        return New-WDResult -Status Blocked -Message 'Windows allows Edge to be uninstalled only on a PC set up in the EEA' `
            -Detail ("This PC's device setup region is $($policy.Region) - Settings > Time and language > Language and region " +
                     'shows it as Device setup region. It was chosen when Windows was first set up: changing Country or region ' +
                     'does not change it, and Windows does not let scripts change it, so nothing was attempted and Edge is ' +
                     'untouched and still updating. Setting Windows up again with an EEA region is the supported way past it. ' +
                     'Another browser can stay the default with Edge installed.')
    }

    if ($Context.Preview) {
        $note = 'Uninstalls Edge, and only once it is really gone blocks its updater, its update tasks, and the Windows Update channel that reinstalls it. WebView2 Runtime is kept, but stops receiving updates with the updater off. Where Windows accepts the uninstall only from Settings, Installed apps is opened for one click.'
        $handover = Set-WDDefaultBrowserBestEffort -Context $Context
        $note = "$($handover.Message) " + $note
        return New-WDResult -Status Removed `
            -Message 'Would uninstall Edge and block every reinstall vector' -Detail $note
    }

    $steps = New-Object System.Collections.Generic.List[string]

    # A replacement was picked and is not here, which means its install failed
    # earlier in this run - on 2026-10-29 Chrome's did, and this went on to try
    # the uninstall anyway; only Windows refusing it kept the machine from
    # being left with no browser. Declining the offer is a choice to go
    # without, and that path is unchanged.
    $picked = @()
    try { $picked = @(Get-WDChosenBrowsers (Get-WDBrowserChoice -Root $Context.Session.Root)) } catch { }
    if ($picked.Count -and -not @(Get-WDBrowserRegistrations | Where-Object { -not $_.IsEdge }).Count) {
        $names = (@($picked | ForEach-Object { $_.Name })) -join ', '
        return New-WDResult -Status Skipped -Message "Edge kept: $names was chosen to replace it and is not installed" `
            -Detail "Removing Edge now would leave this machine with no browser at all. Install $names, then run this option again."
    }

    # 0. Hand over the associations first, while Edge is still here to hold
    # them. Afterwards, nothing owns http and every web link answers "You'll
    # need an app to open this".
    $prefer = ''
    if ($picked.Count) { $prefer = [string]$picked[0].Name }
    $assoc = Set-WDDefaultBrowserBestEffort -Context $Context -PreferName $prefer
    if ($assoc.Ok) {
        $steps.Add('default browser already handed over')
    } elseif ($assoc.Pick) {
        $steps.Add("Default apps opened at $($assoc.Pick) - it needs one click")
        Write-WDLog ("Edge is being removed. $($assoc.Message). Windows requires a click for this one; " +
                     'Default apps has been opened at the right browser.') -Level Warn -Item $Context.ItemId
    } else {
        Write-WDLog ('No replacement browser is installed, so nothing can take over the web file types. ' +
                     'Links will have no handler until one is installed.') -Level Warn -Item $Context.ItemId
    }

    # 1. Stop the updater and anything holding files open. Stopped, not
    # disabled: if Windows refuses the uninstall, the updater carries on as it
    # was.
    $wasRunning = @(Get-Service -Name 'edgeupdate', 'edgeupdatem' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
    foreach ($s in $wasRunning) { try { Stop-Service -Name $s.Name -Force -ErrorAction Stop } catch { } }
    Get-Process -Name 'msedge', 'MicrosoftEdgeUpdate' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600

    # 2. Run every setup.exe there is. Version folders move between updates, so
    # search rather than assume a path.
    $exits = New-Object System.Collections.Generic.List[string]
    $tried = Get-Date
    foreach ($dir in $edgeDirs) {
        $setups = @(Get-ChildItem -LiteralPath $dir -Recurse -Filter 'setup.exe' -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -match '\\Installer\\setup\.exe$' })
        foreach ($s in $setups) {
            $r = Invoke-WDProcess -FilePath $s.FullName -TimeoutSeconds 600 -ArgumentList @(
                '--uninstall', '--system-level', '--verbose-logging', '--force-uninstall')
            $exits.Add([string]$r.ExitCode)
        }
    }

    # 3. Did it work? Asked of the disk, not of the exit code, which has no
    # documented meaning - and BEFORE anything is swept, because a sweep after
    # a refusal is what turned "Windows said no" into a half-deleted browser.
    $stillThere = @(& $installed)
    if ($stillThere.Count) {
        foreach ($s in $wasRunning) { try { Start-Service -Name $s.Name -ErrorAction Stop } catch { } }
        $why = Get-WDEdgeInstallerReason -Since $tried
        $detail = "Edge is still installed at $($stillThere -join ', ') (uninstaller exit $($exits -join ', ')). " +
                  'Nothing else was changed: Edge keeps updating, and its updater is untouched.'
        if ($why) { $detail += " Edge's own log says: $why" }
        # 93 is the region refusal. Anything else here, where the region allows
        # it, is on current builds 532: the uninstall was not started by
        # Settings, the one caller Windows accepts. So Settings gets the click -
        # unless this is a guard run as SYSTEM, with nobody at the screen.
        $sys = $false
        try { $sys = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem } catch { }
        if ($exits -notcontains '93' -and -not $sys) {
            $opened = $false
            try { Start-Process 'ms-settings:appsfeatures' -ErrorAction Stop; $opened = $true } catch { }
            return New-WDResult -Status Obstruction -Message 'Windows accepts the Edge uninstall only from Settings' -Detail (
                "$detail $(if ($opened) { 'Installed apps has been opened:' } else { 'Open Settings > Apps > Installed apps:' }) " +
                'find Microsoft Edge, press the three dots next to it, and choose Uninstall. Then run this option again, ' +
                'which switches off the updater so it cannot come back.')
        }
        return New-WDResult -Status Blocked -Message 'Windows refused to uninstall Edge' `
                            -Detail "$detail Exit 93 is Windows refusing it for this PC's region."
    }
    $steps.Add('uninstaller removed Edge')

    # 4. Gone, so now everything it left.
    foreach ($b in (Remove-WDEdgeLeftovers -Context $Context)) { $steps.Add($b) }

    Set-WDRebootNeeded
    New-WDResult -Status Removed -Message 'Edge removed and reinstall blocked' `
                 -Detail (($steps | Sort-Object -Unique) -join ', ') -Reboot
}

Register-WDHandler 'RemoveEdgeProfileData' {
    # Edge's own data - history, saved sign-ins, cookies, caches - which its
    # uninstaller keeps unless told --delete-profile and nothing else here
    # touches. Only once Edge is gone: while it is installed this is its live
    # profile. Per account in scope, through the file executor, to the Recycle
    # Bin unless the run is irreversible - so it is the operator's to empty.
    param($Action, $Context)

    $live = @((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
              (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')) | Where-Object { Test-Path -LiteralPath $_ }
    if ($live) {
        return New-WDResult -Status Skipped -Message 'Edge is still installed, so this is its live profile' `
                            -Detail 'Uninstall Edge first, then run this option again.'
    }

    $hives = @(Select-WDAccountHives -Hives (Get-WDUserHives) -Default $Context.DefaultHive -Accounts (Get-WDContextAccounts $Context))
    if (-not $hives.Count) {
        return New-WDResult -Status Skipped -Message 'No account selected to delete it for' `
                            -Detail 'Tick an account under "which accounts per-user settings are written to", then run this option again.'
    }
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($h in $hives) {
        # A hive is named by its SID, or CurrentUser for this account; the
        # default profile's is the mounted one.
        $dir = ''
        if ([bool](Get-Prop $h 'Mounted' $false)) {
            $dir = Join-Path $env:SystemDrive 'Users\Default'
        } else {
            $sid = [string]$h.Name
            if ($sid -eq 'CurrentUser') { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
            try {
                $dir = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -ErrorAction Stop `
                    -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath)
            } catch { }
        }
        if (-not $dir) { continue }
        foreach ($ch in 'Edge', 'Edge Beta', 'Edge Dev', 'Edge SxS') { $paths.Add((Join-Path $dir "AppData\Local\Microsoft\$ch")) }
    }

    $present = @($paths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
    if (-not $present.Count) { return New-WDResult -Status NotPresent -Message 'No Edge data left in the accounts in scope' }
    $r = Invoke-WDFileAction -Context $Context -Action ([pscustomobject]@{ type = 'file'; paths = $present; recycle = $true })
    if ([string]$r.Status -eq 'Blocked' -and -not $Context.Preview) {
        # A folder can refuse to move while everything in it goes: on
        # 2026-10-29 the shell answered 120 for ...\Microsoft\Edge and then
        # moved its User Data at once - most likely a watcher holding the
        # directory itself. So what is left goes a level down, and a folder
        # that ends up empty is removed; restoring its contents from the bin
        # puts it back.
        $kids = @($present | Where-Object { Test-Path -LiteralPath $_ } |
                  ForEach-Object { Get-ChildItem -LiteralPath $_ -Force -ErrorAction SilentlyContinue } | ForEach-Object { $_.FullName })
        if ($kids.Count) {
            $r = Invoke-WDFileAction -Context $Context -Action ([pscustomobject]@{ type = 'file'; paths = $kids; recycle = $true })
        }
        foreach ($p in $present) {
            if ((Test-Path -LiteralPath $p) -and -not @(Get-ChildItem -LiteralPath $p -Force -Recurse -ErrorAction SilentlyContinue).Count) {
                try { [IO.Directory]::Delete($p) } catch { }
            }
        }
    }
    $gone = @($present | Where-Object { $Context.Preview -or -not (Test-Path -LiteralPath $_) })
    $left = @($present | Where-Object { $gone -notcontains $_ })
    if (-not $gone.Count) { return $r }
    $where = $(if (Test-WDIrreversible) { 'deleted' } else { 'moved to the Recycle Bin' })
    if ($left.Count) {
        return New-WDResult -Status Partial -Message "$($gone.Count) Edge data folder(s) $where, $($left.Count) not" `
                            -Detail "Done: $($gone -join ', ') | Left: $($left -join ', ') - $($r.Detail)"
    }
    New-WDResult -Status Removed -Detail ($gone -join ', ') `
                 -Message $(if ($Context.Preview) { "Would move $($gone.Count) Edge data folder(s) to the Recycle Bin" }
                            else { "$($gone.Count) Edge data folder(s) $where" })
}

function Remove-WDEdgeLeftovers {
    # What an uninstall leaves that would bring Edge back or point at it. Shared
    # by a run that uninstalled Edge and one that found it already gone - which
    # used to block the updater and nothing else, so an uninstall done outside
    # the toolkit kept its Store package, the updater's records of it, and its
    # leftover folder. Returns what it did, one phrase each.
    param($Context)
    $steps = New-Object System.Collections.Generic.List[string]

    # 1. The updater and every channel that would reinstall it.
    foreach ($b in (Block-WDEdgeReinstall -Context $Context)) { $steps.Add($b) }

    # 2. The Store-delivered packages, for all users and provisioned. Game
    # Assist is "a special version of Microsoft Edge" that Edge 137 and later
    # installs as a package of its own, here for SYSTEM only - none of the
    # Edge removers' patterns match its name. DevToolsClient is not here: it is
    # a Windows component that SFC puts back.
    $ax = Invoke-WDAppxAction -Action ([pscustomobject]@{
        names = @('Microsoft.MicrosoftEdge.Stable', 'Microsoft.MicrosoftEdge.Beta', 'Microsoft.MicrosoftEdge.Dev',
                  'Microsoft.MicrosoftEdge.Canary', 'Microsoft.Edge.GameAssist') }) -Context $Context
    if ($ax.Status -eq 'Removed') { $steps.Add('Edge and Game Assist packages removed') }

    # 3. The updater's records of the browser - Clients alone used to be
    # cleared, and ClientState and ClientStateMedium are enough on their own
    # for it to treat Edge as installed - then the browser's registrations.
    # Exported before deletion, through the key executor, so each is journalled.
    $cr = Invoke-WDRegistryKeyAction -Context $Context -Action ([pscustomobject]@{ type = 'registryKey'; paths = @(Get-WDEdgeUpdateRecordPaths) })
    if ([string]$cr.Status -eq 'Removed') { $steps.Add('updater record of Edge cleared') }

    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($view in 'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node') {
        foreach ($ch in '', ' Beta', ' Dev') {
            $keys.Add("$view\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge$ch")
            $keys.Add("$view\Clients\StartMenuInternet\Microsoft Edge$ch")
        }
        # Runs at every new account's first sign-in.
        $keys.Add("$view\Microsoft\Active Setup\Installed Components\{9459C573-B17A-45AE-9F64-1857B5D58CEE}")
        # The IE-to-Edge redirect add-on, which lives in Edge's own folder.
        $keys.Add("$view\Microsoft\Windows\CurrentVersion\Explorer\Browser Helper Objects\{1FD49718-1D00-4B19-AF5F-070AF6D5D54C}")
        $keys.Add("$view\Classes\CLSID\{1FD49718-1D00-4B19-AF5F-070AF6D5D54C}")
        $keys.Add("$view\Microsoft\Edge")
    }
    $keys.Add('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe')
    $keys.Add('HKLM:\SOFTWARE\Microsoft\Internet Explorer\EdgeIntegration')
    $keys.Add('HKLM:\SOFTWARE\Microsoft\Internet Explorer\EdgeDebugActivation')
    # The same per account, and in the profile new accounts are copied from.
    # microsoft-edge: is what Search, Widgets, and Settings open links with;
    # after an uninstall it points at a pwahelper.exe whose only job is the
    # Store page that reinstalls Edge.
    $perUser = @('SOFTWARE\Microsoft\Edge', 'SOFTWARE\Microsoft\Edge Beta', 'SOFTWARE\Microsoft\Edge Dev', 'SOFTWARE\Microsoft\Edge SxS',
                 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
                 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
                 'SOFTWARE\Clients\StartMenuInternet\Microsoft Edge',
                 'SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\microsoft-edge',
                 'SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\microsoft-edge-holographic')
    # The per-account updater records Edge writes while it runs (its logon
    # launch command, usage ids), which outlive it. Edge's channels only:
    # WebView2 keeps a ClientState of its own beside them.
    foreach ($sub in 'Clients', 'ClientState', 'ClientStateMedium') {
        foreach ($g in $script:EdgeGuids.Values) { $perUser += "SOFTWARE\Microsoft\EdgeUpdate\$sub\$g" }
    }
    $classes =@('MSEdgeHTM', 'MSEdgePDF', 'MSEdgeMHT', 'MSEdgeBHTML', 'MSEdgeDHTML', 'microsoft-edge', 'microsoft-edge-holographic')
    foreach ($c in $classes) { $keys.Add("HKLM:\SOFTWARE\Classes\$c") }
    $hives = @(Select-WDAccountHives -Hives (Get-WDUserHives) -Default $Context.DefaultHive -Accounts (Get-WDContextAccounts $Context))
    foreach ($h in $hives) {
        foreach ($p in $perUser) { $keys.Add("$($h.Path)\$p") }
        foreach ($c in $classes) { $keys.Add("$($h.Path)\SOFTWARE\Classes\$c") }
    }
    $kr = Invoke-WDRegistryKeyAction -Context $Context -Action ([pscustomobject]@{ type = 'registryKey'; paths = $keys.ToArray() })
    if ([string]$kr.Status -eq 'Removed') { $steps.Add("$([regex]::Match([string]$kr.Message, '^\d+').Value) of Edge's registry keys removed") }
    elseif ([string]$kr.Status -eq 'Blocked') { Write-WDLog "Some of Edge's registrations could not be removed: $($kr.Detail)" -Level Warn -Item $Context.ItemId }

    # Values rather than keys: Edge's name in the registered-browsers list, the
    # add-on's entry in the IE add-on policy list, and Startup Boost.
    $vals = New-Object System.Collections.Generic.List[psobject]
    $vals.Add([pscustomobject]@{ path = 'HKLM:\SOFTWARE\RegisteredApplications'; name = 'Microsoft Edge'; delete = $true })
    $vals.Add([pscustomobject]@{ path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Ext\CLSID'; name = '{1FD49718-1D00-4B19-AF5F-070AF6D5D54C}'; delete = $true })
    $mr = Invoke-WDRegistryAction -Context $Context -Action ([pscustomobject]@{ type = 'registry'; scope = 'machine'; values = $vals.ToArray() })
    $uvals = New-Object System.Collections.Generic.List[psobject]
    $uvals.Add([pscustomobject]@{ path = 'SOFTWARE\RegisteredApplications'; name = 'Microsoft Edge'; delete = $true })
    foreach ($h in $hives) {
        foreach ($r in 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run') {
            $k = $null
            try { $k = Get-Item -LiteralPath "$($h.Path)\$r" -ErrorAction Stop } catch { }
            if (-not $k) { continue }
            foreach ($n in $k.GetValueNames()) {
                if ($n -like 'MicrosoftEdgeAutoLaunch_*' -and -not @($uvals | Where-Object { $_.path -eq $r -and $_.name -eq $n }).Count) {
                    $uvals.Add([pscustomobject]@{ path = $r; name = $n; delete = $true })
                }
            }
        }
    }
    $ur = Invoke-WDRegistryAction -Context $Context -Action ([pscustomobject]@{ type = 'registry'; scope = 'allusers'; values = $uvals.ToArray() })
    if ('Changed' -in @([string]$mr.Status, [string]$ur.Status)) { $steps.Add('Edge registered-browser and startup entries removed') }

    # 4. What the uninstaller left of Edge's own folder. Only Edge's: EdgeCore
    # is WebView2's servicing copy (its msedge.dll is a hardlink of the one in
    # EdgeWebView), EdgeWebView is WebView2, EdgeUpdate is parked above, and the
    # Copilot folders were never Edge's to take. The old ^(Edge|Copilot) sweep
    # deleted all of those but EdgeWebView. Not in a preview: nothing here has
    # a preview of its own.
    if ($Context.Preview) { return @($steps) }
    $sweepRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { $_ } | ForEach-Object { Join-Path $_ 'Microsoft' }
    $edgeProcs = @('msedge', 'MicrosoftEdgeUpdate', 'identity_helper',
                   'msedge_proxy', 'cookie_exporter', 'elevation_service')
    $swept  = 0
    $queued = 0
    foreach ($root in $sweepRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $doomed = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^Edge( Beta| Dev| SxS)?$' })
        foreach ($d in $doomed) {
            $r = Remove-WDStubbornDirectory -Path $d.FullName -ProcessNames $edgeProcs
            if ($r.Gone) {
                $swept++
                Write-WDLog "$($d.Name): $($r.Note)." -Level Info -Item $Context.ItemId
            } elseif ($r.Pending) {
                $queued++
                Write-WDLog "$($d.Name): $($r.Note)." -Level Warn -Item $Context.ItemId
            } else {
                Write-WDLog ("$($d.Name) could not be removed - $($r.Note). Left: " +
                             (($r.Left | Select-Object -First 3) -join ', ')) -Level Warn -Item $Context.ItemId
            }
            # Not journalled: nothing can put a program's files back, and an
            # undo entry claiming otherwise is a lie the rollback script
            # repeats. The program itself is already uninstalled by now.
            if ($r.Killed.Count) { $steps.Add("stopped $($r.Killed -join ', ')") }
        }
    }
    if ($swept)  { $steps.Add("$swept leftover folder$(if ($swept -ne 1) { 's' }) deleted") }
    if ($queued) { $steps.Add("$queued leftover folder$(if ($queued -ne 1) { 's' }) queued for deletion at restart") }

    # 5. The installer the updater cached for the browser channels. Not
    # WebView2's or the updater's own, which sit beside it under their ids.
    foreach ($c in (Get-WDEdgeInstallerCachePaths)) {
        $r = Remove-WDStubbornDirectory -Path $c -ProcessNames @('MicrosoftEdgeUpdate')
        if ($r.Gone) { $steps.Add('cached Edge installer deleted') }
        elseif ($r.Pending) { $steps.Add('cached Edge installer queued for deletion at restart') }
        else { Write-WDLog "The cached Edge installer at $c could not be removed - $($r.Note)." -Level Warn -Item $Context.ItemId }
    }

    # 6. Firewall rules for Edge's own program, which an uninstall leaves - by
    # program path, so WebView2's rules beside them are kept. Not journalled
    # for the same reason as the folders: an Edge install writes them again.
    try {
        foreach ($f in @(Get-NetFirewallApplicationFilter -ErrorAction Stop | Where-Object { [string]$_.Program -match '\\Microsoft\\Edge( Beta| Dev)?\\Application\\' })) {
            $rule = $f | Get-NetFirewallRule -ErrorAction SilentlyContinue
            if (-not $rule) { continue }
            $rule | Remove-NetFirewallRule -ErrorAction Stop
            $steps.Add("firewall rule '$($rule.DisplayName)' removed")
        }
    } catch {
        Write-WDLog "Edge's firewall rules could not be read or removed: $($_.Exception.Message)" -Level Warn -Item $Context.ItemId
    }
    @($steps)
}

Register-WDHandler 'CloseResurrectionPaths' {
    param($Action, $Context)

    $did  = New-Object System.Collections.Generic.List[string]
    $shut = New-Object System.Collections.Generic.List[string]
    $left = New-Object System.Collections.Generic.List[string]
    $verb = $(if ($Context.Preview) { 'would close' } else { 'closed' })

    # Each vector narrates itself: "the tool quietly disabled my Edge updater"
    # is a thing the log has to be able to answer.
    $say = {
        param([string]$Text)
        Write-WDLog $Text -Level Info -Item $Context.ItemId
    }

    # 1. Packages removed per-user but still provisioned - re-staged at every
    # new sign-in and after every feature update, so a per-user removal alone
    # has a shelf life.
    $removedNames = New-Object System.Collections.Generic.List[string]
    # A run always has a session; the self test previews this without one, and
    # Test-Path on $null is a binding error rather than a false.
    $journal = [string](Get-Prop $Context.Session 'JournalFile' '')
    if ($journal -and (Test-Path -LiteralPath $journal)) {
        foreach ($line in (Get-Content -LiteralPath $journal -ErrorAction SilentlyContinue)) {
            if (-not $line.Trim()) { continue }
            try {
                $e = $line | ConvertFrom-Json
                if ($e.type -eq 'appx' -and $e.undo -and $e.undo.name) { $removedNames.Add([string]$e.undo.name) }
            } catch { }
        }
    }
    if ($removedNames.Count) {
        $prov = @()
        try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) } catch { }
        foreach ($n in ($removedNames | Sort-Object -Unique)) {
            foreach ($p in @($prov | Where-Object { $_.DisplayName -eq $n })) {
                if ($Context.Preview) { $shut.Add("$n would stop being re-staged for new sign-ins"); continue }
                & $say "$n was removed but is still provisioned - deprovisioning it so it cannot come back."
                try {
                    $null = Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop
                    Clear-WDProvisionedCache
                    Add-WDJournal -ItemId $Context.ItemId -Type 'appx-provisioned' -Target $p.PackageName `
                                  -Status 'Removed' -Undo @{ method = 'reinstall'; name = $n }
                    $shut.Add("$n deprovisioned")
                } catch {
                    $left.Add("$n is still provisioned and will return at the next sign-in: $($_.Exception.Message)")
                }
            }
        }
    }

    # 2. ContentDeliveryManager re-push. Delegated to the registry executor so
    # it honours the account scope, backs the key up, and lands in the journal.
    $cdmValues = @('SilentInstalledAppsEnabled','PreInstalledAppsEnabled',
                   'OemPreInstalledAppsEnabled','ContentDeliveryAllowed')
    $cdmOpen = @($cdmValues | Where-Object {
        $cur = (Get-ItemProperty -LiteralPath 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
                                 -Name $_ -ErrorAction SilentlyContinue).$_
        $null -eq $cur -or $cur -ne 0
    })
    if ($cdmOpen.Count) {
        & $say "ContentDeliveryManager can still install apps on its own ($($cdmOpen -join ', ')) - $verb it."
        $r = Invoke-WDRegistryAction -Context $Context -Action ([pscustomobject]@{
            type = 'registry'; scope = 'allusers'
            values = @($cdmOpen | ForEach-Object {
                [pscustomobject]@{
                    path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                    name = $_; kind = 'DWord'; value = 0 } })
        })
        if ($r.Status -in @('Changed','Removed')) { $shut.Add('ContentDeliveryManager silent installs') }
        elseif ($r.Status -ne 'NotPresent')       { $left.Add("ContentDeliveryManager: $($r.Message)") }
    } else { $did.Add('ContentDeliveryManager was already shut') }

    # 3. Consumer features policy - Enterprise and Education only. Its own ADML
    # says "This setting only applies to Enterprise and Education SKUs" and the
    # Policy CSP lists Pro as unsupported, so on Pro and Home writing it closed
    # nothing while this step counted it as a path closed (the 2026-08-15 run
    # on Pro reported exactly that, and nothing else). Not written there now.
    $cc = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
                            -Name 'DisableWindowsConsumerFeatures' -ErrorAction SilentlyContinue).DisableWindowsConsumerFeatures
    if (-not [bool](Get-Prop $Context.Profile 'IsEnterprise' $false)) {
        $did.Add('the consumer features policy works only on Enterprise and Education, so it is not written on this edition; the content-delivery values above are what closes that path here')
    } elseif ($cc -ne 1) {
        & $say "Windows can still deliver bundled apps to this machine - $verb the consumer features policy."
        $r = Invoke-WDRegistryAction -Context $Context -Action ([pscustomobject]@{
            type = 'registry'; scope = 'machine'
            values = @([pscustomobject]@{
                path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
                name = 'DisableWindowsConsumerFeatures'; kind = 'DWord'; value = 1 })
        })
        if ($r.Status -in @('Changed','Removed')) { $shut.Add('bundled app delivery') }
        elseif ($r.Status -ne 'NotPresent')       { $left.Add("consumer features policy: $($r.Message)") }
    } else { $did.Add('bundled app delivery was already blocked') }

    # 4. Edge's way back through its updater, once Edge is gone: the updater's
    # records of it and the installer it cached. Never the updater itself, which
    # is WebView2's only updater too - this used to disable it, leaving WebView2
    # unpatched, and InstallDefault, which it also wrote, binds only on a
    # domain.
    if (-not (Test-Path (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'))) {
        $rec   = @(Get-WDEdgeUpdateRecordPaths | Where-Object { Test-Path -LiteralPath $_ })
        $cache = @(Get-WDEdgeInstallerCachePaths)
        if ($rec.Count -or $cache.Count) {
            & $say "Edge is gone but its updater still has $(if ($rec.Count) { 'a record of it' } else { 'its installer cached' }) and would put it back - $verb that."
            if ($rec.Count) {
                $r = Invoke-WDRegistryKeyAction -Context $Context -Action ([pscustomobject]@{ type = 'registryKey'; paths = $rec })
                if ($r.Status -notin @('Removed','NotPresent')) { $left.Add("the updater's record of Edge: $($r.Message)") }
            }
            if ($cache.Count -and -not $Context.Preview) {
                foreach ($c in $cache) {
                    $d = Remove-WDStubbornDirectory -Path $c -ProcessNames @('MicrosoftEdgeUpdate')
                    if (-not $d.Gone -and -not $d.Pending) { $left.Add("the cached Edge installer: $($d.Note)") }
                }
            }
            $shut.Add("the updater's way back to Edge")
        } else { $did.Add('Edge cannot reinstall itself through its updater') }
    }

    # 5. PushToInstall re-adding removed in-box apps.
    $tasks = @()
    try {
        $tasks = @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\PushToInstall\' -ErrorAction SilentlyContinue |
                   Where-Object { $_.State -ne 'Disabled' })
    } catch { }
    if ($tasks.Count) {
        & $say "PushToInstall can still deliver apps to this machine - $verb its $($tasks.Count) task(s)."
        $r = Invoke-WDTaskAction -Context $Context -Action ([pscustomobject]@{
            type = 'task'; tasks = @('\Microsoft\Windows\PushToInstall\*') })
        if ($r.Status -in @('Changed','Removed')) { $shut.Add('PushToInstall') }
        elseif ($r.Status -ne 'NotPresent')       { $left.Add("PushToInstall: $($r.Message)") }
    } else { $did.Add('PushToInstall was already disabled') }

    # A vector this could not close means something the operator removed is
    # coming back and the toolkit knows it. Partial rather than Blocked when
    # some of it worked.
    if ($left.Count) {
        return New-WDResult -Status $(if ($shut.Count) { 'Partial' } else { 'Blocked' }) `
            -Message "$($left.Count) path(s) could not be closed - some of what you removed will come back" `
            -Detail (($left -join ' | ') + $(if ($shut.Count) { ' | Closed: ' + ($shut -join ', ') } else { '' }))
    }
    if ($shut.Count) {
        return New-WDResult -Status Changed `
            -Message "$($shut.Count) path(s) $verb, so nothing removed can come back" -Detail ($shut -join ', ')
    }
    New-WDResult -Status NotPresent -Message 'Nothing removed this run can come back' `
                 -Detail $(if ($did.Count) { ($did -join ' | ') } else { 'every resurrection path was already shut' })
}

# Guards live in the data root rather than a run folder, so "Delete old run
# logs" cannot pull the ground from under a registered task.
function Get-WDGuardPaths {
    # Entry is a copy under Root, not the running toolkit: pointed at the live
    # one, a guard installed from a USB stick fails its own Test-Path at every
    # boot, silently.
    param($Context, [string]$Root)
    if (-not $Root) { $Root = $Context.Session.Root }
    [pscustomobject]@{
        Root    = $Root
        Source  = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        Toolkit = Join-Path $Root 'toolkit'
        Entry   = Join-Path $Root 'toolkit\WinSetupToolkit.ps1'
        Profile = Join-Path $Root 'guard-profile.json'
        Stamp   = Join-Path $Root 'guard-build.txt'
        Runner  = Join-Path $Root 'Invoke-WDUpdateGuard.ps1'
        Logon   = Join-Path $Root 'Invoke-WDLogonGuard.ps1'
        Notice  = Join-Path $Root 'Show-WDGuardNotice.ps1'
        Marker  = Join-Path $Root 'guard-last-run.json'
    }
}

function Copy-WDToolkitForGuard {
    # Answers $true only when Entry exists afterwards, and nothing may register
    # a guard until it does - a task pointing at a file nobody wrote is a
    # failure this has already had once.
    param([Parameter(Mandatory)]$Paths)

    # 'Run logs' is every past run's output, which grows without bound and is
    # the guard's business least of all - it is carried for the person holding
    # the stick, and this copy is for a scheduled task.
    $skip = @('.git', '.gitignore', 'profile_saves', 'Run logs')
    try {
        if (Test-Path -LiteralPath $Paths.Toolkit) {
            Remove-Item -LiteralPath $Paths.Toolkit -Recurse -Force -ErrorAction Stop
        }
        $null = New-Item -ItemType Directory -Path $Paths.Toolkit -Force -ErrorAction Stop
        foreach ($item in @(Get-ChildItem -LiteralPath $Paths.Source -Force -ErrorAction Stop)) {
            if ($item.Name -in $skip) { continue }
            Copy-Item -LiteralPath $item.FullName -Destination $Paths.Toolkit `
                      -Recurse -Force -ErrorAction Stop
        }
    } catch {
        Write-WDLog "Could not copy the toolkit for the guard: $($_.Exception.Message)" -Level Warn
        return $false
    }
    if (-not (Test-Path -LiteralPath $Paths.Entry)) {
        Write-WDLog "The toolkit copy is missing its entry script at $($Paths.Entry)." -Level Warn
        return $false
    }
    Write-WDLog "Toolkit copied to $($Paths.Toolkit) so the guard survives the medium going away." -Level Info
    $true
}

$script:NoticeTaskName = 'Windows Setup Toolkit Guard Notice'

function New-WDGuardNoticeRunner {
    # Both guards run as SYSTEM, which has no desktop, so the notification
    # cannot come from the guard. This runs at logon in the signed-in user's own
    # context.
    param($Paths)
    @"
# Generated by the Windows Setup Toolkit. Tells the signed-in user when a
# guard has re-applied their selection. Safe to delete along with the
# '$script:NoticeTaskName' scheduled task.
`$ErrorActionPreference = 'SilentlyContinue'
`$marker = '$($Paths.Marker)'
if (-not (Test-Path -LiteralPath `$marker)) { exit 0 }
try { `$m = Get-Content -LiteralPath `$marker -Raw | ConvertFrom-Json } catch { exit 0 }
if (-not `$m.when) { exit 0 }

`$mine = Join-Path `$env:LOCALAPPDATA 'WinSetupToolkit'
`$seen = Join-Path `$mine 'last-notice.txt'
`$last = ''
if (Test-Path -LiteralPath `$seen) { `$last = (Get-Content -LiteralPath `$seen -Raw).Trim() }
if (`$last -eq [string]`$m.when) { exit 0 }

`$title = 'Windows Setup Toolkit'
`$body  = switch ([string]`$m.kind) {
    'update' { "Windows updated to build `$(`$m.build), so your saved cleanup was re-applied. `$(`$m.items) item(s) were checked." }
    'logon'  { "Your saved cleanup was re-applied at sign-in. `$(`$m.items) item(s) were checked." }
    default  { "Your saved cleanup was re-applied. `$(`$m.items) item(s) were checked." }
}
`$body += ' Remove this from Revert past changes if you no longer want it.'

`$shown = `$false
try {
    `$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    `$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]
    `$app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    `$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
                [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    `$t = `$xml.GetElementsByTagName('text')
    `$null = `$t.Item(0).AppendChild(`$xml.CreateTextNode(`$title))
    `$null = `$t.Item(1).AppendChild(`$xml.CreateTextNode(`$body))
    # SILENT. A toast plays the system notification sound unless it is told not
    # to, and nothing in this toolkit makes a noise - see Show-WDMessage for the
    # whole of that argument. This one arrives unbidden at somebody's sign-in,
    # which is the last place a chime is wanted.
    `$aud = `$xml.CreateElement('audio')
    `$aud.SetAttribute('silent', 'true')
    `$null = `$xml.GetElementsByTagName('toast').Item(0).AppendChild(`$aud)
    `$toast = [Windows.UI.Notifications.ToastNotification]::new(`$xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(`$app).Show(`$toast)
    `$shown = `$true
} catch { }
if (-not `$shown) {
    # Older or stripped-down builds where the toast stack is unavailable.
    try {
        Add-Type -AssemblyName System.Windows.Forms
        `$n = New-Object System.Windows.Forms.NotifyIcon
        `$n.Icon = [System.Drawing.SystemIcons]::Information
        `$n.Visible = `$true
        # 'None', not 'Info'. A balloon plays a sound chosen by its icon, and
        # None is the only value that plays nothing.
        `$n.ShowBalloonTip(15000, `$title, `$body, 'None')
        Start-Sleep -Seconds 12
        `$n.Dispose()
        `$shown = `$true
    } catch { }
}
if (`$shown) {
    `$null = New-Item -ItemType Directory -Path `$mine -Force
    Set-Content -LiteralPath `$seen -Value ([string]`$m.when) -Encoding ASCII
}
exit 0
"@
}

function New-WDLogonGuardRunner {
    param($Paths)
    @"
# Generated by the Windows Setup Toolkit. Re-applies the saved selection at
# sign-in. Safe to delete along with the 'Windows Setup Toolkit Persistence Guard' task.
`$ErrorActionPreference = 'SilentlyContinue'
`$savedPlan = '$($Paths.Profile)'
`$entry     = '$($Paths.Entry)'
`$marker    = '$($Paths.Marker)'
if (-not ((Test-Path -LiteralPath `$entry) -and (Test-Path -LiteralPath `$savedPlan))) { exit 0 }
`$count = 0
try { `$count = @((Get-Content -LiteralPath `$savedPlan -Raw | ConvertFrom-Json).selected).Count } catch { }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$entry -Console -Apply -GuardRun -ProfilePath `$savedPlan
`$rc = `$LASTEXITCODE
# ONLY WHEN IT ACTUALLY CHANGED SOMETHING. This marker is what raises the toast
# telling somebody their selection was re-applied at sign-in, and it was written
# regardless of how the run above went - so a sign-in where the toolkit happened
# to be open (exit 4, the single-instance interlock refusing) still claimed the
# work had been done. 0 is applied cleanly and 2 is applied with some items
# failing; both are runs that changed something. 6 is a guard run that found
# nothing back, and 1 and 4 never got as far as the plan.
if (`$rc -eq 0 -or `$rc -eq 2) {
    ([pscustomobject]@{ when = (Get-Date).ToString('o'); kind = 'logon'; items = `$count; build = '' } |
        ConvertTo-Json) | Set-Content -LiteralPath `$marker -Encoding UTF8
}
exit 0
"@
}

function Install-WDGuardNotice {
    # Idempotent: either guard installs it, and both share it.
    param($Paths)
    Set-Content -LiteralPath $Paths.Notice -Value (New-WDGuardNoticeRunner -Paths $Paths) -Encoding UTF8
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($Paths.Notice)`"")
    $trg = New-ScheduledTaskTrigger -AtLogOn
    $trg.Delay = 'PT1M'
    # A group principal, so it runs for whoever signs in rather than for the one
    # account that ran the toolkit.
    $pri = New-ScheduledTaskPrincipal -GroupId 'Users' -RunLevel Limited
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $null = Register-ScheduledTask -TaskName $script:NoticeTaskName -Action $act -Trigger $trg `
                                   -Principal $pri -Settings $set -Force -ErrorAction Stop
}

# The current OS build as one comparable string: anything a feature update
# changes shows up here, with no per-version event log knowledge. CurrentBuild
# and DisplayVersion only - it held UBR as well, which every monthly cumulative
# update moves (this machine went 26200.9168 to .9457 in eight weeks), so a
# guard named for feature updates fired every month.
function Get-WDBuildStamp {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
    '{0}.{1}' -f $p.CurrentBuild, $p.DisplayVersion
}

# Extras are dropped: re-installing the guard from inside the guard is noise,
# and re-running the log cleaner unattended is not a thing to do behind
# somebody's back.
function Save-WDGuardProfile {
    # The run's removals, and nothing else. Re-running the Add section
    # unattended would reinstall software somebody deliberately removed months
    # earlier.
    param($Context, [string]$Path)
    # Section comes off the plan. Absent - an older plan, or no plan at all -
    # falls back to the id list, because a guard that saves nothing is worse
    # than one that saves too much.
    $section = @{}
    foreach ($p in @($Context.Plan)) {
        $s = [string](Get-Prop $p 'Section' '')
        if ($s) { $section[[string]$p.Id] = $s }
    }
    $ids = @($Context.PlannedIds | Where-Object {
        $_ -notin @('persistence-guard', 'update-guard', 'clear-logs') -and
        (-not $section.ContainsKey([string]$_) -or $section[[string]$_] -eq 'remove')
    })
    if (-not $ids.Count) { return 0 }
    # The run's own choices go with it, in the same options block a saved
    # selection carries: a guard re-applying without them seized nothing it had
    # needed ownership for and wrote to every account when the operator had
    # narrowed the run to one.
    $null = Save-WDSelection -Selected $ids -Path $Path -Options ([pscustomobject]@{
        TakeOwnership   = [bool](Get-Prop $Context 'AllowOwnership' $false)
        VendorDownloads = [bool](Get-Prop $Context 'AllowDownloads' $true)
        Accounts        = (Get-WDContextAccounts $Context)
    })
    $ids.Count
}

# The GUI writes the choice here before the run starts: the engine is on a
# background runspace and a file is the only thing that reliably crosses. One
# item rather than one per browser, so preset counts do not move.
$script:BrowserCatalog = [ordered]@{
    'Mozilla Firefox' = 'Mozilla.Firefox'
    'Google Chrome'   = 'Google.Chrome'
    'Brave'           = 'Brave.Brave'
    'Vivaldi'         = 'Vivaldi.Vivaldi'
    'Opera'           = 'Opera.Opera'
    'LibreWolf'       = 'LibreWolf.LibreWolf'
    'Zen Browser'     = 'Zen-Team.Zen-Browser'
}
function Get-WDBrowserCatalog { $script:BrowserCatalog }

# The vendor's own installer, for a browser whose winget package points at a
# fixed address. The manifest pins the hash of whatever was there when it was
# written, so from a vendor release until winget-pkgs catches up the download
# no longer matches and winget refuses it - INSTALLER_HASH_MISMATCH, which an
# elevated winget will not override. On 2026-10-29 Google served Chrome
# 156.0.8078.74 at that address against a manifest written for .48. The same
# file is fetched from the vendor instead, and its signature stands in for the
# stale hash. Keyed by catalog name, then by processor.
$script:BrowserVendorInstaller = @{
    'Google Chrome' = @{
        Signer = 'O=Google LLC'
        Urls   = @{
            AMD64 = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
            ARM64 = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise_arm64.msi'
            x86   = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise.msi'
        }
    }
}

function Install-WDBrowserFromVendor {
    # $null when there is no vendor route, so the caller keeps winget's own
    # failure rather than one about a download nobody asked for.
    param([string]$Name, [string]$Id, $Context, [string]$WingetFailure = '')
    if (-not $script:BrowserVendorInstaller.ContainsKey($Name)) { return $null }
    if (-not $Context.AllowDownloads) { return $null }

    $v   = $script:BrowserVendorInstaller[$Name]
    $cpu = [string]$env:PROCESSOR_ARCHITECTURE
    if (-not $v.Urls.ContainsKey($cpu)) { $cpu = 'x86' }
    $url = [string]$v.Urls[$cpu]
    $dst = Join-Path $Context.Session.RunDir ([IO.Path]::GetFileName(([uri]$url).AbsolutePath))
    Write-WDLog "winget's package for $Name is behind the vendor's installer, so it is being fetched from $url instead." -Level Info -Item $Context.ItemId

    try {
        # The progress bar alone makes a 160 MB download several times slower
        # on PowerShell 5.1.
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -TimeoutSec 900
        # The hash winget had was the only thing pinning this file, so nothing
        # runs elevated without a valid signature from the vendor.
        $sig = Get-AuthenticodeSignature -FilePath $dst -ErrorAction Stop
        if ([string]$sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or
            [string]$sig.SignerCertificate.Subject -notmatch [regex]::Escape($v.Signer)) {
            return New-WDResult -Status Failed -Message "the $Name installer from the vendor was not validly signed, so it was not run" `
                                -Detail "Signature $($sig.Status), signer '$([string]$sig.SignerCertificate.Subject)'. $WingetFailure"
        }
        $res = Invoke-WDProcess -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
                                -ArgumentList @('/i', "`"$dst`"", '/qn', '/norestart') -TimeoutSeconds 900
        if ($res.TimedOut) {
            return New-WDResult -Status Failed -Message "the $Name installer from the vendor timed out" -Detail $WingetFailure
        }
        # 3010 is installed, finishing at the next restart.
        if ($res.ExitCode -ne 0 -and $res.ExitCode -ne 3010) {
            return New-WDResult -Status Failed -Message "the $Name installer from the vendor failed (msiexec exit $($res.ExitCode))" -Detail $WingetFailure
        }
        # Asked of the machine rather than of the exit code: the step after this
        # one hands it the web links, and needs it registered as a browser.
        if (-not @(Get-WDBrowserRegistrations | Where-Object { $_.Name -like "*$Name*" -or $_.Key -like "*$Name*" }).Count) {
            return New-WDResult -Status Failed -Message "$Name installed from the vendor but did not register as a browser" -Detail $WingetFailure
        }
        if ($res.ExitCode -eq 3010) { Set-WDRebootNeeded }
        # Journalled exactly as a winget install is: the manifest names the MSI's
        # UpgradeCode, so winget uninstall finds it whichever version this was.
        Add-WDJournal -ItemId $Context.ItemId -Type 'winget' -Target $Id -Status 'Changed' -Undo @{ method = 'uninstall'; name = $Id }
        New-WDResult -Status Changed -Message "1 app(s) installed from the vendor" `
                     -Detail "$Id from $url, signed by $($v.Signer -replace '^O=', '')" `
                     -Recovered "winget refused it: $WingetFailure"
    } catch {
        New-WDResult -Status Failed -Message "the $Name installer could not be fetched from the vendor" -Detail "$($_.Exception.Message) | $WingetFailure"
    } finally {
        # Windows Installer keeps its own copy for repair and uninstall.
        Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
    }
}

# Authored, not measured - nothing on a machine that has never had Firefox knows
# how big Firefox is - so every figure from these is reported as approximate.
$script:BrowserSizeMb = @{
    'Mozilla Firefox' = 250; 'Google Chrome' = 400; 'Brave' = 350; 'Vivaldi' = 400
    'Opera'           = 350; 'LibreWolf'     = 250; 'Zen Browser' = 250
}
function Get-WDBrowserSizeMb {
    param([string]$Name)
    if ($Name -and $script:BrowserSizeMb.ContainsKey($Name)) { return [int]$script:BrowserSizeMb[$Name] }
    300
}

function Get-WDUiStatePath {
    Join-Path (Join-Path $env:LOCALAPPDATA 'WinSetupToolkit') 'ui-state.json'
}

function Get-WDUiState {
    param([string]$Path)
    $blank = [pscustomobject]@{
        theme          = ''
        preset         = ''
        overrides      = [pscustomobject]@{}
        presetDefaults = [pscustomobject]@{}
        # Persisted where an override is not: an unsaved edit is something
        # somebody might not have meant to keep, and a run is a thing that
        # happened.
        applied        = [pscustomobject]@{}
        storage        = $null
        accounts       = $null
        sort           = ''
        # A preference like the theme. False is the shipped answer - in-line is
        # the default.
        detailPopup    = $false
        # Absent means non-verbose, which is the shipped default. Stored this
        # way up so a settings file written before the default changed cannot
        # hold somebody at the old behaviour.
        verbose        = $false
    }
    if (-not $Path) { $Path = Get-WDUiStatePath }
    $path = $Path
    if (-not (Test-Path -LiteralPath $path)) { return $blank }
    try {
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        foreach ($n in @('theme', 'preset', 'overrides', 'presetDefaults', 'applied', 'storage', 'accounts', 'sort', 'detailPopup', 'verbose')) {
            if (-not $j.PSObject.Properties[$n]) {
                $j | Add-Member -NotePropertyName $n -NotePropertyValue $blank.$n -Force
            }
        }
        $j
    } catch {
        Write-WDLog "Interface state at $path could not be read and was ignored: $($_.Exception.Message)" -Level Warn
        $blank
    }
}

function Save-WDUiState {
    param([Parameter(Mandatory)]$State, [string]$Path)
    if (-not $Path) { $Path = Get-WDUiStatePath }
    $path = $Path
    try {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force -ErrorAction SilentlyContinue
        ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
        $true
    } catch {
        Write-WDLog "Could not save interface state: $($_.Exception.Message)" -Level Warn
        $false
    }
}

function Get-WDStorageCache {
    param($State, [int64]$UsedBytes, [int]$MaxAgeDays = 7)

    if (-not $State -or -not $State.PSObject.Properties['storage']) { return $null }
    $v = $State.storage
    if (-not $v) { return $null }

    $raw = @{}
    foreach ($k in @('windows', 'apps', 'users')) {
        if (-not $v.PSObject.Properties[$k]) { return $null }
        try { $raw[$k] = [int64]$v.$k } catch { return $null }
    }

    $when = $null
    try {
        $when = [datetime]::Parse([string]$v.measured, [Globalization.CultureInfo]::InvariantCulture,
                                  [Globalization.DateTimeStyles]::RoundtripKind)
    } catch { return $null }
    if (((Get-Date) - $when).TotalDays -gt $MaxAgeDays) { return $null }

    $was = [int64](Get-Prop $v 'usedBytes' 0)
    if ($UsedBytes -gt 0 -and $was -gt 0) {
        if (([Math]::Abs($UsedBytes - $was) / [double]$UsedBytes) -gt 0.10) { return $null }
    }

    $reserve = [ordered]@{}
    if ($v.PSObject.Properties['reserve'] -and $v.reserve) {
        foreach ($p in $v.reserve.PSObject.Properties) {
            try { $reserve[[string]$p.Name] = [int64]$p.Value } catch { }
        }
    }
    [pscustomobject]@{ Raw = $raw; Reserve = $reserve; Denied = [int](Get-Prop $v 'denied' 0); Stopped = $false }
}

function New-WDStorageCacheEntry {
    # A walk abandoned part way is not written: half a measurement cached for a
    # week is worse than none.
    param($Buckets, [int64]$UsedBytes)
    if (-not $Buckets -or -not $Buckets.Raw) { return $null }
    if ($Buckets.Stopped) { return $null }
    foreach ($k in @('windows', 'apps', 'users')) {
        if (-not $Buckets.Raw.ContainsKey($k)) { return $null }
    }
    $o = [ordered]@{
        measured  = (Get-Date).ToString('o')
        usedBytes = [int64]$UsedBytes
        denied    = [int]$Buckets.Denied
    }
    foreach ($k in @('windows', 'apps', 'users')) { $o[$k] = [int64]$Buckets.Raw[$k] }
    $res = [ordered]@{}
    if ($Buckets.Reserve) {
        foreach ($n in $Buckets.Reserve.Keys) { $res[[string]$n] = [int64]$Buckets.Reserve[$n] }
    }
    $o['reserve'] = [pscustomobject]$res
    [pscustomobject]$o
}

function ConvertTo-WDPresetMap {
    # JSON round-trips a hashtable as a PSCustomObject, so the stored preset ->
    # @{Added;Removed} map comes back in the wrong shape.
    param($Obj)
    $out = @{}
    if (-not $Obj) { return $out }
    foreach ($p in $Obj.PSObject.Properties) {
        $v = $p.Value
        if (-not $v) { continue }
        $added   = @(Get-Prop $v 'Added' @())
        $removed = @(Get-Prop $v 'Removed' @())
        if (-not $added.Count -and -not $removed.Count) { continue }
        $out[[string]$p.Name] = @{ Added = @($added); Removed = @($removed) }
    }
    $out
}

function Get-WDBrowserChoicePath {
    param([string]$Root)
    if (-not $Root) { $Root = Join-Path $env:ProgramData 'WinSetupToolkit' }
    Join-Path $Root 'browser-choice.json'
}

function Set-WDBrowserChoice {
    # An empty $Names clears the file, which is how backing out works.
    param([string]$Root, [string[]]$Names)
    $path = Get-WDBrowserChoicePath -Root $Root
    $want = @($script:BrowserCatalog.Keys | Where-Object { $_ -in @($Names) })
    if (-not $want.Count) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        return @()
    }
    $ids = @($want | ForEach-Object { [string]$script:BrowserCatalog[$_] })
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force -ErrorAction SilentlyContinue
    ([pscustomobject]@{
        names  = $want
        ids    = $ids
        name   = $want[0]
        id     = $ids[0]
        chosen = (Get-Date).ToString('o')
    } | ConvertTo-Json) | Set-Content -LiteralPath $path -Encoding UTF8
    ,$ids
}

function Get-WDBrowserChoice {
    param([string]$Root)
    $path = Get-WDBrowserChoicePath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $null }
}

function Get-WDChosenBrowsers {
    # Whichever shape the file is in: one written before this was a list carries
    # only name/id, and a run left queued across an upgrade should still install
    # what was asked for.
    param($Choice)
    if (-not $Choice) { return @() }
    $names = @(Get-Prop $Choice 'names' @())
    $ids   = @(Get-Prop $Choice 'ids'   @())
    if (-not $ids.Count) {
        $one = [string](Get-Prop $Choice 'id' '')
        if (-not $one) { return @() }
        $ids   = @($one)
        $names = @([string](Get-Prop $Choice 'name' $one))
    }
    $out = New-Object System.Collections.Generic.List[psobject]
    for ($i = 0; $i -lt $ids.Count; $i++) {
        if (-not $ids[$i]) { continue }
        $nm = $(if ($i -lt $names.Count -and $names[$i]) { [string]$names[$i] } else { [string]$ids[$i] })
        $out.Add([pscustomobject]@{ Name = $nm; Id = [string]$ids[$i] })
    }
    $out.ToArray()
}

function Get-WDRunOptionsPath {
    param([string]$Root)
    if (-not $Root) { $Root = Join-Path $env:ProgramData 'WinSetupToolkit' }
    Join-Path $Root 'run-options.json'
}

function Set-WDRunOptions {
    param([string]$Root, [hashtable]$Values)
    $path = Get-WDRunOptionsPath -Root $Root
    if (-not $Values -or -not $Values.Count) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        return $null
    }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force -ErrorAction SilentlyContinue
    $obj = [pscustomobject]@{}
    foreach ($k in $Values.Keys) { $obj | Add-Member -NotePropertyName ([string]$k) -NotePropertyValue $Values[$k] -Force }
    ($obj | ConvertTo-Json) | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

function Get-WDRunOption {
    # Never throws and never returns $null for a missing file - a handler run
    # from the command line has no GUI to have written one, and the manifest
    # default is right there.
    param([string]$Root, [string]$Name, $Default = $null)
    $path = Get-WDRunOptionsPath -Root $Root
    if (-not (Test-Path -LiteralPath $path)) { return $Default }
    try {
        $o = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $v = Get-Prop $o $Name $null
        if ($null -eq $v) { return $Default }
        $v
    } catch { $Default }
}

Register-WDHandler 'InstallChosenBrowser' {
    # No choice on disk means the offer was declined or withdrawn, which is
    # Skipped rather than a failure.
    param($Action, $Context)

    $picked = @(Get-WDChosenBrowsers (Get-WDBrowserChoice -Root $Context.Session.Root))
    if (-not $picked.Count) {
        return New-WDResult -Status Skipped -Message 'No replacement browser was chosen'
    }
    $names = @($picked | ForEach-Object { $_.Name })
    if (-not $Context.Profile.HasWinget) {
        return New-WDResult -Status Blocked -Message "Cannot install $($names -join ', ') without winget" `
                            -Detail 'winget is missing on this machine, so there is no unattended way to fetch a browser.'
    }

    $done = New-Object System.Collections.Generic.List[string]
    $here = New-Object System.Collections.Generic.List[string]
    $bad  = New-Object System.Collections.Generic.List[string]
    $detail = New-Object System.Collections.Generic.List[string]
    $recovered = New-Object System.Collections.Generic.List[string]
    foreach ($b in $picked) {
        $r = Invoke-WDWingetInstall -Action $Action -Context $Context -Ids @([string]$b.Id)
        # 0x8A150011, the hash mismatch: the vendor has moved on and the winget
        # manifest has not.
        if ([string]$r.Status -eq 'Failed' -and [string]$r.Detail -match '0x8A150011') {
            $v = Install-WDBrowserFromVendor -Name ([string]$b.Name) -Id ([string]$b.Id) -Context $Context -WingetFailure ([string]$r.Detail)
            if ($v) {
                $r = $v
                if ($v.Recovered) { $recovered.Add("$($b.Name): $($v.Recovered)") }
            }
        }
        switch ([string]$r.Status) {
            'Changed'    { $done.Add($b.Name) }
            'NotPresent' { $here.Add($b.Name) }
            default      { $bad.Add($b.Name); $detail.Add("$($b.Name): $($r.Message)") }
        }
        if ($r.Detail) { $detail.Add("$($b.Name): $($r.Detail)") }
    }

    # These were picked by name, so the report says which. Anything that did not
    # install is named on its own, because "3 of 4" is not something anybody can
    # act on.
    $said = New-Object System.Collections.Generic.List[string]
    if ($done.Count) { $said.Add($(if ($Context.Preview) { "Would install $($done -join ', ')" } else { "$($done -join ', ') installed" })) }
    if ($here.Count) { $said.Add("$($here -join ', ') already installed") }
    if ($bad.Count)  { $said.Add("could not install $($bad -join ', ')") }
    $msg = ($said -join '; ')
    $dt  = $(if ($detail.Count) { $detail -join "`n" } else { $null })

    if ($bad.Count -and -not $done.Count) { return New-WDResult -Status Failed  -Message $msg -Detail $dt }
    $rec = ($recovered -join '; ')
    if ($bad.Count)                       { return New-WDResult -Status Partial -Message $msg -Detail $dt -Recovered $rec }
    if (-not $done.Count)                 { return New-WDResult -Status NotPresent -Message $msg -Detail $dt }
    New-WDResult -Status Changed -Message $msg -Detail $dt -Recovered $rec
}

# A file, not a -Command one-liner: the quoting to nest this inside a scheduled
# task argument is exactly where this breaks. A function so the self test can
# generate it and run it.
function New-WDUpdateGuardRunner {
    param($Paths)
    @"
# Generated by the Windows Setup Toolkit. Re-applies the saved selection when
# the OS build changes, then records the new build. Safe to delete along with
# the 'Windows Setup Toolkit Update Guard' scheduled task.
`$ErrorActionPreference = 'Stop'
`$stampFile = '$($Paths.Stamp)'
`$savedPlan = '$($Paths.Profile)'
`$entry     = '$($Paths.Entry)'
`$k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
`$p = Get-ItemProperty -LiteralPath `$k -ErrorAction SilentlyContinue
`$now = '{0}.{1}' -f `$p.CurrentBuild, `$p.DisplayVersion
`$marker    = '$($Paths.Marker)'
`$was = ''
if (Test-Path -LiteralPath `$stampFile) { `$was = (Get-Content -LiteralPath `$stampFile -Raw).Trim() }
if (`$now -eq `$was) { exit 0 }
if ((Test-Path -LiteralPath `$entry) -and (Test-Path -LiteralPath `$savedPlan)) {
    `$count = 0
    try { `$count = @((Get-Content -LiteralPath `$savedPlan -Raw | ConvertFrom-Json).selected).Count } catch { }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$entry -Console -Apply -GuardRun -ProfilePath `$savedPlan
    `$rc = `$LASTEXITCODE
    # Left for the notice task, which runs in the signed-in user's session and
    # is the only thing here that can actually put something on screen - so it
    # is written only when the run above changed something. 0 applied cleanly,
    # 2 applied with failures; 6 found nothing back to remove; 4 is the
    # interlock refusing because the toolkit was open, and telling somebody
    # their selection was re-applied when it was not is worse than saying
    # nothing.
    if (`$rc -eq 0 -or `$rc -eq 2) {
        ([pscustomobject]@{ when = (Get-Date).ToString('o'); kind = 'update'; items = `$count; build = `$now } |
            ConvertTo-Json) | Set-Content -LiteralPath `$marker -Encoding UTF8
    }
}
# Stamped even if the re-apply failed, so a broken run cannot loop every boot.
Set-Content -LiteralPath `$stampFile -Value `$now -Encoding ASCII
exit 0
"@
}

Register-WDHandler 'InstallPersistenceGuard' {
    param($Action, $Context)

    $g        = Get-WDGuardPaths -Context $Context
    $taskName = 'Windows Setup Toolkit Persistence Guard'

    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message 'Would register a logon task that re-applies this selection'
    }
    # Copied first, and nothing registered if it fails. Entry names the copy
    # rather than the running toolkit, so this is what makes the path
    # resolvable.
    if (-not (Copy-WDToolkitForGuard -Paths $g)) {
        return New-WDResult -Status Failed -Message 'Could not copy the toolkit; guard not installed' `
                            -Detail ('A guard runs as SYSTEM long after this run, so it needs its own copy of ' +
                                     'the toolkit under ProgramData - the folder this was started from may be ' +
                                     'a USB stick that is gone by then. Nothing was registered, because a task ' +
                                     'pointing at a file that is not there would fail silently at every sign-in.')
    }

    try {
        $n = Save-WDGuardProfile -Context $Context -Path $g.Profile
        if (-not $n) { return New-WDResult -Status Skipped -Message 'Nothing in this run for the guard to re-apply' }
        Set-Content -LiteralPath $g.Logon -Value (New-WDLogonGuardRunner -Paths $g) -Encoding UTF8
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($g.Logon)`"")
        $trg = New-ScheduledTaskTrigger -AtLogOn
        $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        $null = Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Principal $pri `
                                       -Settings $set -Force -ErrorAction Stop
        Install-WDGuardNotice -Paths $g
        Add-WDJournal -ItemId $Context.ItemId -Type 'task' -Target $taskName -Status 'Changed' `
                      -Undo @{ method = 'unregister-task'; name = $taskName }
        New-WDResult -Status Changed -Message 'Persistence guard installed' `
                     -Detail ("Re-applies $n item(s) from $($g.Profile) at logon, and tells you afterwards. " +
                              "Remove with: Unregister-ScheduledTask -TaskName '$taskName'")
    } catch {
        New-WDResult -Status Failed -Message 'Could not register the persistence guard' -Detail $_.Exception.Message
    }
}

Register-WDHandler 'InstallUpdateGuard' {
    param($Action, $Context)

    $g        = Get-WDGuardPaths -Context $Context
    $taskName = 'Windows Setup Toolkit Update Guard'

    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message 'Would register a task that re-applies this selection after a feature update'
    }
    # Copied first, and it matters more here: this guard stamps every new build
    # as handled whether or not the re-apply ran, so one pointing at a toolkit
    # that has gone ticks off the single event it exists for.
    if (-not (Copy-WDToolkitForGuard -Paths $g)) {
        return New-WDResult -Status Failed -Message 'Could not copy the toolkit; guard not installed' `
                            -Detail ('This guard runs as SYSTEM after a feature update, possibly months from ' +
                                     'now, so it needs its own copy of the toolkit under ProgramData rather ' +
                                     'than the folder this was started from. Nothing was registered.')
    }

    try {
        $n = Save-WDGuardProfile -Context $Context -Path $g.Profile
        if (-not $n) { return New-WDResult -Status Skipped -Message 'Nothing in this run for the guard to re-apply' }
        Set-Content -LiteralPath $g.Stamp -Value (Get-WDBuildStamp) -Encoding ASCII

        Set-Content -LiteralPath $g.Runner -Value (New-WDUpdateGuardRunner -Paths $g) -Encoding UTF8

        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($g.Runner)`"")
        # At sign-in rather than at boot: per-account changes reach only the
        # registry hives that are loaded, and at boot nobody's is - so an
        # at-startup re-apply reached the default profile and no real account.
        # Five minutes in, so a post-update first sign-in finishes its own
        # servicing before this starts uninstalling underneath it.
        $trg = New-ScheduledTaskTrigger -AtLogOn
        $trg.Delay = 'PT5M'
        $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        $null = Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Principal $pri `
                                       -Settings $set -Force -ErrorAction Stop
        Install-WDGuardNotice -Paths $g
        Add-WDJournal -ItemId $Context.ItemId -Type 'task' -Target $taskName -Status 'Changed' `
                      -Undo @{ method = 'unregister-task'; name = $taskName }
        New-WDResult -Status Changed -Message 'Update guard installed' `
                     -Detail ("Checks the build at each sign-in and re-applies $n item(s) only when a feature update has changed it, " +
                              "then tells you it did. Build recorded as $(Get-WDBuildStamp). " +
                              "Remove with: Unregister-ScheduledTask -TaskName '$taskName'")
    } catch {
        New-WDResult -Status Failed -Message 'Could not register the update guard' -Detail $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# Holding update restarts while somebody is signed in.
#
# Windows has a policy for exactly this, NoAutoRebootWithLoggedOnUsers, and it
# does not do it. It applies only under AUOptions = 4, Microsoft's own page says
# it "doesn't work exactly as per description", and a 25H2 machine with both set
# was seen logging a signed-in session off at 03:18 and restarting at 03:20.
# AUOptions = 4 is worse than no help: it is the scheduled-install mode, which
# restarts on a fifteen-minute timer whatever the active hours say.
#
# What Windows does honour is active hours - no automatic restart inside them.
# So the hold keeps them around the current hour for as long as anybody is
# signed in, and moves them off it when nobody is. Windows' own mechanism,
# positioned by a task, and no policy involved: it works on Home, and Settings
# never says the machine is managed.
# ---------------------------------------------------------------------------
$script:RestartHoldTask = 'Windows Setup Toolkit Restart Hold'
$script:RestartHoldUx   = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$script:RestartHoldId   = 'wu-no-restart-signed-in'

function Get-WDRestartHoldPaths {
    # The data root rather than a run folder, for the reason the guards live
    # there: "Delete old run logs" must not pull the ground from under a task.
    param($Context, [string]$Root)
    if (-not $Root) { $Root = $Context.Session.Root }
    [pscustomobject]@{
        Root   = $Root
        Runner = Join-Path $Root 'Invoke-WDRestartHold.ps1'
        State  = Join-Path $Root 'restart-hold-state.json'
        Anyway = Join-Path $Root 'restart-hold-anyway.json'
        Only   = Join-Path $Root 'restart-hold-only.json'
    }
}

function Get-WDRestartHoldWindow {
    # The whole decision. The generated runner carries this function's own text
    # rather than a second spelling of it, and the self test asks it every case
    # without needing a clock or a session. Hours are [From, To) on a 24-hour
    # clock and wrap past midnight; From = To is no hours at all.
    param([int]$Hour, [bool]$SignedIn, $Anyway, $Only)
    $inside = {
        param($Rule)
        if (-not $Rule) { return $false }
        $f = [int]$Rule.From; $t = [int]$Rule.To
        if ($f -eq $t) { return $false }
        if ($f -lt $t) { return ($Hour -ge $f -and $Hour -lt $t) }
        ($Hour -ge $f -or $Hour -lt $t)
    }
    if ($SignedIn) {
        $hold = -not (& $inside $Anyway)
        $why  = $(if ($hold) { 'someone is signed in' }
                  else { 'someone is signed in, but restarts are allowed anyway at this hour' })
    } elseif ($Only) {
        $hold = -not (& $inside $Only)
        $why  = $(if ($hold) { 'nobody is signed in, but restarts wait for the allowed hours' }
                  else { 'nobody is signed in, and this is inside the allowed hours' })
    } else {
        $hold = $false
        $why  = 'nobody is signed in'
    }
    # Eighteen hours is the longest active hours Windows accepts. Held, they
    # start an hour ago, so this hour is inside with sixteen to spare - which is
    # what covers a sleep the task could not see. Released, they start three
    # hours from now, and the three is not arbitrary: the update engine's own
    # "Attempt reboot" rule (MoUsoCoreWorker.exe on 26200) refuses a restart
    # when the next active hours start is less than 65 minutes away, so a
    # window starting next hour would block the very restart it was moved to
    # allow. Three keeps it over two hours away at any minute of this hour.
    if ($hold) { $start = ($Hour + 23) % 24; $end = ($Hour + 17) % 24 }
    else       { $start = ($Hour + 3) % 24;  $end = ($Hour + 21) % 24 }
    [pscustomobject]@{ Hold = [bool]$hold; Start = [int]$start; End = [int]$end; Why = [string]$why }
}

function Get-WDSignedInSessions {
    # Every signed-in session runs a shell host - on screen, locked, or
    # disconnected - and none runs before somebody signs in, so the process
    # list answers this without parsing anything localized. Two names, because
    # a replacement shell has no explorer and sihost is still there.
    @(Get-Process -Name 'explorer', 'sihost' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -gt 0 } | ForEach-Object { [int]$_.SessionId } | Sort-Object -Unique)
}

function Test-WDRestartHoldTask {
    # Schedule.Service rather than Get-ScheduledTask, which costs a second a
    # question - and not Test-WDTaskPresent, which lives in WD.Revert, a module
    # the satisfied scan's runspace does not import.
    try {
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect()
        try { [bool]$svc.GetFolder('\').GetTask($script:RestartHoldTask) } catch { $false }
    } catch {
        try { [bool](Get-ScheduledTask -TaskName $script:RestartHoldTask -ErrorAction SilentlyContinue) } catch { $false }
    }
}

function Format-WDHour {
    # The machine's own clock format, so it reads 3:00 AM or 03:00 as the
    # taskbar does.
    param([int]$Hour)
    [datetime]::Today.AddHours((($Hour % 24) + 24) % 24).ToString('t')
}

# A file, not a -Command one-liner, for the reason the update guard's is one.
function New-WDRestartHoldRunner {
    param($Paths, [string]$UxPath = $script:RestartHoldUx)
    $q = { param([string]$s) ConvertTo-WDQuotedBody $s }
    $body = @'
# Generated by the Windows Setup Toolkit. While anyone is signed in, keeps
# Windows Update's active hours around the current hour, so an update cannot
# restart the computer under them; when nobody is, moves them off it.
# Safe to delete along with the scheduled task that runs it:
#   __TASK__
# Undoing the toolkit run does both and puts your own active hours back.
$ErrorActionPreference = 'Stop'
$ux     = '__UX__'
$state  = '__STATE__'
$anyway = '__ANYWAY__'
$only   = '__ONLY__'

__WINDOW__

__SESSIONS__

function Read-WDHoldRule {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        [pscustomobject]@{ From = [int]$o.from; To = [int]$o.to }
    } catch { $null }
}

$now      = Get-Date
$sessions = @(Get-WDSignedInSessions)
$w = Get-WDRestartHoldWindow -Hour $now.Hour -SignedIn ($sessions.Count -gt 0) `
                             -Anyway (Read-WDHoldRule $anyway) -Only (Read-WDHoldRule $only)

if (-not (Test-Path -LiteralPath $ux)) { $null = New-Item -Path $ux -Force }
$cur = Get-ItemProperty -LiteralPath $ux -ErrorAction SilentlyContinue
# Written only when they move: every write is a change notification the update
# orchestrator re-reads, and most runs change nothing. IsExpedited is "Get me up
# to date", which restarts even inside active hours - switched back on, it would
# walk straight past the hold, so it is held off on every pass like the hours.
$want = [ordered]@{ ActiveHoursStart = $w.Start; ActiveHoursEnd = $w.End; SmartActiveHoursState = 0; IsExpedited = 0 }
foreach ($n in $want.Keys) {
    if ($cur -and $cur.PSObject.Properties[$n] -and [int]$cur.$n -eq [int]$want[$n]) { continue }
    Set-ItemProperty -LiteralPath $ux -Name $n -Value $want[$n] -Type DWord
}

# What it decided and why, for whoever asks why the computer did or did not
# restart. Overwritten every time: a reading, not a history.
try {
    $pending = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    ([pscustomobject]@{
        when             = $now.ToString('o')
        sessions         = $sessions.Count
        hold             = $w.Hold
        why              = $w.Why
        activeHoursStart = $w.Start
        activeHoursEnd   = $w.End
        restartPending   = [bool]$pending
    } | ConvertTo-Json) | Set-Content -LiteralPath $state -Encoding UTF8
} catch { }
exit 0
'@
    $fill = [ordered]@{
        '__TASK__'     = $script:RestartHoldTask
        '__UX__'       = (& $q $UxPath)
        '__STATE__'    = (& $q ([string]$Paths.State))
        '__ANYWAY__'   = (& $q ([string]$Paths.Anyway))
        '__ONLY__'     = (& $q ([string]$Paths.Only))
        # Last, so nothing inside the two function bodies is taken for a
        # placeholder.
        '__WINDOW__'   = "function Get-WDRestartHoldWindow {$((Get-Command Get-WDRestartHoldWindow).Definition)}"
        '__SESSIONS__' = "function Get-WDSignedInSessions {$((Get-Command Get-WDSignedInSessions).Definition)}"
    }
    foreach ($k in $fill.Keys) { $body = $body.Replace($k, [string]$fill[$k]) }
    $body
}

function New-WDRestartHoldTaskXml {
    # XML because the ScheduledTasks cmdlets cannot make an event trigger, and
    # waking from sleep is the moment a held restart is most exposed: a laptop
    # asleep past the end of its window wakes outside active hours. The
    # repeating trigger starts two minutes out so nothing fires while the
    # handler is still journalling what it is about to change.
    param([string]$Runner, [datetime]$Start = (Get-Date).AddMinutes(2))
    $sb  = $Start.ToString('yyyy-MM-ddTHH:mm:ss')
    $arg = [Security.SecurityElement]::Escape(
        "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Runner`"")
    $resume = [Security.SecurityElement]::Escape(
        "<QueryList><Query Id=`"0`" Path=`"System`"><Select Path=`"System`">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select></Query></QueryList>")
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>Windows Setup Toolkit</Author>
    <Description>Keeps Windows Update from restarting this computer while anyone is signed in, by moving its active hours. Undo the toolkit run to remove it.</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>
    <SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>SessionUnlock</StateChange></SessionStateChangeTrigger>
    <EventTrigger><Enabled>true</Enabled><Subscription>$resume</Subscription></EventTrigger>
    <TimeTrigger>
      <Repetition><Interval>PT15M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <StartBoundary>$sb</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>powershell.exe</Command><Arguments>$arg</Arguments></Exec>
  </Actions>
</Task>
"@
}

function Read-WDRestartHoldRule {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        [pscustomobject]@{ From = [int]$o.from; To = [int]$o.to }
    } catch { $null }
}

function Write-WDRestartHoldFile {
    # One of the hold's own files, journalled so the rollback script takes it
    # back: restored from a copy when it was already there, deleted when this
    # run made it. The PowerToys config is handled the same way.
    # -Discard is for a file the task writes and nothing needs back: undo
    # deletes it whatever was there before.
    param([string]$Path, [string]$Text, $Context, [string]$Kind = 'file', [switch]$Discard)
    $bak = $null
    if (-not $Discard -and (Test-Path -LiteralPath $Path)) {
        $bak = "$Path.wdbak"
        Copy-Item -LiteralPath $Path -Destination $bak -Force -ErrorAction Stop
    }
    if ($Text) { Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8 -ErrorAction Stop }
    Add-WDJournal -ItemId $Context.ItemId -Type $Kind -Target $Path -Status 'Changed' `
                  -Undo @{ method = 'file-restore'; file = $bak; target = $Path }
}

function Start-WDRestartHoldNow {
    # Runs the task once and waits for its reading, so the result can say what
    # the hold actually did rather than what it was asked to do.
    param($Paths, [int]$Seconds = 20)
    $before = $(if (Test-Path -LiteralPath $Paths.State) { (Get-Item -LiteralPath $Paths.State).LastWriteTimeUtc } else { [datetime]::MinValue })
    try { Start-ScheduledTask -TaskName $script:RestartHoldTask -ErrorAction Stop } catch { return $null }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        Start-Sleep -Milliseconds 400
        if ((Test-Path -LiteralPath $Paths.State) -and (Get-Item -LiteralPath $Paths.State).LastWriteTimeUtc -gt $before) {
            try { return (Get-Content -LiteralPath $Paths.State -Raw | ConvertFrom-Json) } catch { return $null }
        }
    }
    $null
}

Register-WDHandler 'HoldUpdateRestarts' {
    param($Action, $Context)

    $p       = Get-WDRestartHoldPaths -Context $Context
    $runner  = New-WDRestartHoldRunner -Paths $p
    $present = Test-WDRestartHoldTask
    $onDisk  = $(if (Test-Path -LiteralPath $p.Runner) { [string](Get-Content -LiteralPath $p.Runner -Raw) } else { '' })
    $same    = ($onDisk.Trim() -eq $runner.Trim())

    # Active hours set by policy are the one thing that outranks the values the
    # task moves, so on such a machine it would move numbers nothing reads.
    $wuPol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
    if ($wuPol -and $wuPol.PSObject.Properties['SetActiveHours'] -and [int]$wuPol.SetActiveHours -eq 1) {
        return New-WDResult -Status Obstruction -Message 'Active hours are set by policy here, so the hold cannot move them' `
                            -Detail ('SetActiveHours = 1 under HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate fixes active hours ' +
                                     "at $(Format-WDHour ([int]$wuPol.ActiveHoursStart)) to $(Format-WDHour ([int]$wuPol.ActiveHoursEnd)), " +
                                     'and Windows reads that before anything a task can write. Nothing was installed.')
    }
    # Not this option's to change, but it decides whether the option can work:
    # the scheduled-install mode restarts on a timer of its own.
    $au = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
    $auNote = ''
    if ($au -and $au.PSObject.Properties['AUOptions'] -and [int]$au.AUOptions -eq 4) {
        $auNote = ' AUOptions is 4 here (download and schedule the install), which restarts on a fifteen-minute timer whatever the active hours say. It did not come from this option and was left alone - remove it if restarts still happen.'
    }

    if ($present -and $same) {
        return New-WDResult -Status AlreadySet -Message 'Restarts are already held while anyone is signed in' -Detail $auNote.Trim()
    }
    if ($Context.Preview) {
        if ($present) { return New-WDResult -Status Changed -Message "Would update the restart hold's script" }
        return New-WDResult -Status Changed -Message 'Would register a task that holds update restarts while anyone is signed in' -Detail $auNote.Trim()
    }

    try {
        $null = New-Item -ItemType Directory -Path $p.Root -Force -ErrorAction SilentlyContinue

        # Already registered by an earlier run: only the script is this run's
        # to change, and the active hours it has been moving are not an
        # original worth recording.
        if ($present) {
            Write-WDRestartHoldFile -Path $p.Runner -Text $runner -Context $Context
            $r = Start-WDRestartHoldNow -Paths $p
            return New-WDResult -Status Changed -Message "Restart hold's script updated" `
                                -Detail $(if ($r) { "It ran: $($r.why), active hours $(Format-WDHour $r.activeHoursStart) to $(Format-WDHour $r.activeHoursEnd).$auNote" }
                                          else { "The task is registered but did not report back within 20 seconds.$auNote" })
        }

        # Journalled in the order the rollback must undo it: the task first, so
        # nothing moves the active hours again while they are being put back.
        $null = Register-ScheduledTask -TaskName $script:RestartHoldTask -Xml (New-WDRestartHoldTaskXml -Runner $p.Runner) -Force -ErrorAction Stop
        Add-WDJournal -ItemId $Context.ItemId -Type 'task' -Target $script:RestartHoldTask -Status 'Changed' `
                      -Undo @{ method = 'unregister-task'; name = $script:RestartHoldTask }
        # Discarded on undo even if one was lying here: without its task it was
        # a leftover, and putting a leftover back is not restoring anything.
        Write-WDRestartHoldFile -Path $p.Runner -Text $runner -Context $Context -Discard
        # Not written yet - the task writes it - but it is this option's file
        # and the rollback should take it with the rest.
        Write-WDRestartHoldFile -Path $p.State -Text '' -Context $Context -Discard

        # Through the ordinary executor, so your own active hours are what the
        # journal records and what undoing this puts back.
        $sess = @(Get-WDSignedInSessions)
        $w = Get-WDRestartHoldWindow -Hour (Get-Date).Hour -SignedIn ($sess.Count -gt 0) `
                                     -Anyway (Read-WDRestartHoldRule $p.Anyway) -Only (Read-WDRestartHoldRule $p.Only)
        $ux  = $script:RestartHoldUx
        $was = Get-ItemProperty -LiteralPath $ux -ErrorAction SilentlyContinue
        $vals = @(
            [pscustomobject]@{ path = $ux; name = 'ActiveHoursStart';      kind = 'DWord'; value = $w.Start }
            [pscustomobject]@{ path = $ux; name = 'ActiveHoursEnd';        kind = 'DWord'; value = $w.End }
            [pscustomobject]@{ path = $ux; name = 'SmartActiveHoursState'; kind = 'DWord'; value = 0 }
            # "Get me up to date" - restart as soon as possible, even during
            # active hours. Left on, it walks straight past the hold.
            [pscustomobject]@{ path = $ux; name = 'IsExpedited';           kind = 'DWord'; value = 0 }
            # The policy this option used to be. Off because it does not do the
            # job, and because Microsoft documents it switching the active hours
            # policy off when it is on.
            [pscustomobject]@{ path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
                               name = 'NoAutoRebootWithLoggedOnUsers'; kind = 'DWord'; value = 0; delete = $true }
        )
        $reg = Invoke-WDRegistryAction -Action ([pscustomobject]@{ type = 'registry'; scope = 'machine'; values = $vals }) -Context $Context
        if ([string]$reg.Status -notin @('Changed', 'AlreadySet', 'Removed')) {
            return New-WDResult -Status Partial -Message 'Restart hold registered, but active hours could not be set' `
                                -Detail "$($reg.Message). The task will try again within 15 minutes."
        }

        $own = ''
        if ($was -and $was.PSObject.Properties['ActiveHoursStart'] -and $was.PSObject.Properties['ActiveHoursEnd']) {
            $own = " Your own active hours, $(Format-WDHour ([int]$was.ActiveHoursStart)) to $(Format-WDHour ([int]$was.ActiveHoursEnd)), come back when this is undone."
        }
        $r = Start-WDRestartHoldNow -Paths $p
        $now = $(if ($r) { "It ran once: $($r.why), so active hours are $(Format-WDHour $r.activeHoursStart) to $(Format-WDHour $r.activeHoursEnd)." }
                 else { 'It did not report back within 20 seconds, so it has not been seen to run yet.' })
        New-WDResult -Status Changed -Message 'Update restarts held while anyone is signed in' `
                     -Detail ("$now It runs every 15 minutes, and at sign-in, unlock, and wake.$own$auNote " +
                              "Remove with: Unregister-ScheduledTask -TaskName '$($script:RestartHoldTask)'")
    } catch {
        New-WDResult -Status Failed -Message 'Could not set up the restart hold' -Detail $_.Exception.Message
    }
}

# The two answers that refine the hold. Each is a file of its own beside the
# runner, so undoing one leaves the other - and the hold - exactly as it was.
$script:WDHoldRules = @{
    'anyway' = @{ File = 'Anyway'; From = 'restartAnywayFrom'; To = 'restartAnywayTo'
                  Say = 'Restarts allowed anyway, signed in or not' }
    'only'   = @{ File = 'Only';   From = 'restartOnlyFrom';   To = 'restartOnlyTo'
                  Say = 'With nobody signed in, restarts wait for' }
}

Register-WDHandler 'SetRestartHoldHours' {
    param($Action, $Context)

    $rule = [string](Get-Prop $Action 'rule' '')
    if (-not $script:WDHoldRules.ContainsKey($rule)) {
        return New-WDResult -Status Failed -Message "Unknown restart hold rule '$rule'"
    }
    $spec = $script:WDHoldRules[$rule]
    $p    = Get-WDRestartHoldPaths -Context $Context
    $path = [string]$p.($spec.File)

    $root = ''
    try { $root = [string]$Context.Session.Root } catch { }
    $from = [int](Get-Prop $Action 'from' 0)
    $to   = [int](Get-Prop $Action 'to' 0)
    $c = Get-WDRunOption -Root $root -Name ([string]$spec.From) -Default $null
    if ($null -ne $c) { $from = [int]$c }
    $c = Get-WDRunOption -Root $root -Name ([string]$spec.To) -Default $null
    if ($null -ne $c) { $to = [int]$c }
    # Clamped rather than trusted: the file is editable. Equal ends would be no
    # hours at all, which nobody means by picking a range.
    $from = (($from % 24) + 24) % 24
    $to   = (($to % 24) + 24) % 24
    if ($from -eq $to) { $to = ($from + 1) % 24 }
    $range = "$(Format-WDHour $from) and $(Format-WDHour $to)"

    $planned = Get-Prop $Context 'PlannedIds' $null
    $coming  = [bool]($planned -and $planned.Contains($script:RestartHoldId))
    if (-not (Test-WDRestartHoldTask) -and -not ($Context.Preview -and $coming)) {
        return New-WDResult -Status Skipped -Message 'Needs "Never restart while someone is signed in", which is not set up here' `
                            -Detail 'These hours only change what the hold does, so on their own there is nothing for them to change.'
    }

    $cur = Read-WDRestartHoldRule $path
    if ($cur -and [int]$cur.From -eq $from -and [int]$cur.To -eq $to) {
        return New-WDResult -Status AlreadySet -Message "$($spec.Say) between $range already"
    }
    if ($Context.Preview) { return New-WDResult -Status Changed -Message "$($spec.Say) between $range" }

    try {
        Write-WDRestartHoldFile -Path $path -Text (([pscustomobject]@{ from = $from; to = $to }) | ConvertTo-Json) -Context $Context
        $r = Start-WDRestartHoldNow -Paths $p
        New-WDResult -Status Changed -Message "$($spec.Say) between $range" `
                     -Detail $(if ($r) { "The hold re-read it: $($r.why), active hours $(Format-WDHour $r.activeHoursStart) to $(Format-WDHour $r.activeHoursEnd)." }
                               else { 'The hold picks it up within 15 minutes.' })
    } catch {
        New-WDResult -Status Failed -Message 'Could not record the hours' -Detail $_.Exception.Message
    }
}

Export-ModuleMember -Function Get-WDBrowserRegistrations, Get-WDDefaultBrowserProgId,
                              Get-WDAssociationLock, Set-WDDefaultBrowserBestEffort,
                              Get-WDDefaultBrowserPlan, Get-WDSetDefaultScope,
                              Get-WDHeldAssociations, Get-WDOrphanedAssociations, Test-WDProgIdResolves,
                              Block-WDEdgeReinstall, Get-WDGuardPaths, Copy-WDToolkitForGuard,
                              Get-WDBuildStamp,
                              Save-WDGuardProfile, New-WDUpdateGuardRunner,
                              New-WDLogonGuardRunner, New-WDGuardNoticeRunner, Install-WDGuardNotice,
                              Get-WDBrowserCatalog, Get-WDBrowserSizeMb, Get-WDBrowserChoicePath,
                              Set-WDBrowserChoice, Get-WDBrowserChoice, Get-WDChosenBrowsers,
                              Get-WDRunOptionsPath, Set-WDRunOptions, Get-WDRunOption,
                              Get-WDUiStatePath, Get-WDUiState, Save-WDUiState, ConvertTo-WDPresetMap,
                              Get-WDStorageCache, New-WDStorageCacheEntry,
                              Get-WDEdgeUninstallPolicy, Get-WDEdgeInstallerReason,
                              Get-WDHomeGeoId, Set-WDHomeGeoId, Get-WDDeviceRegionGeoId, Get-WDGeoIso2,
                              Get-WDRestartHoldPaths, Get-WDRestartHoldWindow, Get-WDSignedInSessions,
                              Test-WDRestartHoldTask, Format-WDHour, New-WDRestartHoldRunner,
                              New-WDRestartHoldTaskXml, Read-WDRestartHoldRule
