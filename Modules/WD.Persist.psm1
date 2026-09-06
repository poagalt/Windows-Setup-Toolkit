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
# non-zero and leaves the browser where it was, logging "not uninstallable for
# process".
# The lever is the home region, an ordinary per-user value with an ordinary
# undo. Rewriting Microsoft's compliance data in System32 is the other way past
# it, and this toolkit will not do that.
$script:EdgeUninstallPolicyGuid = '{1bca278a-5d11-4acf-ad2f-f9ab6d7f93a6}'
# Ireland. English-speaking, in the enabled list, and unambiguous in a log.
$script:EdgeUninstallGeoId = 68

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

function Get-WDEdgeUninstallPolicy {
    $out = [pscustomobject]@{
        Known   = $false
        Allowed = $true
        Region  = ''
        GeoId   = -1
        Regions = @()
        Path    = (Join-Path ([string]$env:SystemRoot) 'System32\IntegratedServicesRegionPolicySet.json')
    }
    $out.GeoId  = Get-WDHomeGeoId
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
    $logs = @(
        (Join-Path ([string]$env:TEMP) 'msedge_installer.log')
        (Join-Path ([string]$env:SystemRoot) 'Temp\msedge_installer.log')
    )
    foreach ($l in $logs) {
        if (-not (Test-Path -LiteralPath $l -ErrorAction SilentlyContinue)) { continue }
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
            $out.Add([pscustomobject]@{
                Key      = $k.PSChildName
                Name     = $name
                IsEdge   = ($k.PSChildName -match 'msedge|Microsoft Edge')
                ProgIds  = $prog
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

function Get-WDHeldAssociations {
    param([string[]]$ProgIds)

    $out = [pscustomobject]@{ Url = @(); File = @() }
    if (-not $ProgIds -or -not $ProgIds.Count) { return $out }
    $want = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $ProgIds) { if ($p) { $null = $want.Add([string]$p) } }

    $urls  = New-Object System.Collections.Generic.List[string]
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($pair in @(
        @{ Root = 'HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations'; Into = $urls }
        @{ Root = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts';   Into = $files })) {
        if (-not (Test-Path -LiteralPath $pair.Root)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $pair.Root -ErrorAction SilentlyContinue)) {
            $uc = Join-Path $k.PSPath 'UserChoice'
            if (-not (Test-Path -LiteralPath $uc)) { continue }
            try {
                $id = [string](Get-ItemProperty -LiteralPath $uc -Name 'ProgId' -ErrorAction Stop).ProgId
                if ($id -and $want.Contains($id)) { $pair.Into.Add([string]$k.PSChildName) }
            } catch { }
        }
    }
    $out.Url  = @($urls  | Sort-Object -Unique)
    $out.File = @($files | Sort-Object -Unique)
    $out
}

function Get-WDOrphanedAssociations {
    $out = [pscustomobject]@{ Url = @(); File = @() }
    $urls  = New-Object System.Collections.Generic.List[string]
    $files = New-Object System.Collections.Generic.List[string]

    foreach ($pair in @(
        @{ Root = 'HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations'; Into = $urls }
        @{ Root = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts';   Into = $files })) {
        if (-not (Test-Path -LiteralPath $pair.Root)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $pair.Root -ErrorAction SilentlyContinue)) {
            $uc = Join-Path $k.PSPath 'UserChoice'
            if (-not (Test-Path -LiteralPath $uc)) { continue }
            $id = ''
            try { $id = [string](Get-ItemProperty -LiteralPath $uc -Name 'ProgId' -ErrorAction Stop).ProgId } catch { continue }
            if (-not $id) { continue }
            if (Test-WDProgIdResolves -ProgId $id) { continue }
            $pair.Into.Add([string]$k.PSChildName)
        }
    }
    $out.Url  = @($urls  | Sort-Object -Unique)
    $out.File = @($files | Sort-Object -Unique)
    $out
}

function Test-WDProgIdResolves {
    param([string]$ProgId)
    if (-not $ProgId) { return $false }
    $root = "Registry::HKEY_CLASSES_ROOT\$ProgId"

    # Windows deletes the whole ProgId key when the program that registered it
    # is uninstalled. It is also the only test a Store app answers.
    try { if (-not (Test-Path -LiteralPath $root)) { return $false } } catch { return $true }

    # Only a rooted path is checked: a bare command name is resolved through
    # PATH by the shell, and guessing at that would report working types as
    # broken.
    $cmd = ''
    try {
        $cmdKey = "$root\shell\open\command"
        if (Test-Path -LiteralPath $cmdKey) { $cmd = [string](Get-Item -LiteralPath $cmdKey).GetValue('') }
    } catch { }
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

function Set-WDDefaultBrowserBestEffort {
    # There is no silent path on current Windows, and this does not pretend
    # otherwise: it moves what it can and hands the rest to the operator with
    # the Settings page already open.
    param($Context, [string]$PreferName)

    $browsers = @(Get-WDBrowserRegistrations)
    $targets  = @($browsers | Where-Object { -not $_.IsEdge })
    if (-not $targets.Count) {
        return [pscustomobject]@{ Ok = $false; Message = 'no replacement browser is installed yet'; Opened = $false }
    }

    $pick = $null
    if ($PreferName) { $pick = $targets | Where-Object { $_.Name -like "*$PreferName*" -or $_.Key -like "*$PreferName*" } | Select-Object -First 1 }
    if (-not $pick) { $pick = $targets[0] }

    $current = Get-WDDefaultBrowserProgId
    $wanted  = [string]$pick.ProgIds['http']

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
    $held  = Get-WDHeldAssociations -ProgIds @($outgoing | Sort-Object -Unique)

    # Anything already pointing at a program that is gone is swept up too. Those
    # are worse than a wrong default - the type does not open at all - and
    # removing the mail app orphans mailto, which reading Edge's ProgIds never
    # finds.
    $orph  = Get-WDOrphanedAssociations
    $takes = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @($pick.ProgIds.Keys)) { $null = $takes.Add([string]$k) }

    $allHeld = @(@($held.Url) + @($held.File) + @($orph.Url) + @($orph.File) | Sort-Object -Unique)
    $moving  = @($allHeld | Where-Object { $takes.Contains([string]$_) })
    # Types the outgoing browser holds that the incoming one never registered
    # for. No amount of pressing Set default moves these, so naming them is the
    # difference between a finished job and one that looks finished.
    $stranded = @(@($held.Url) + @($held.File) | Where-Object { -not $takes.Contains([string]$_) })

    # A claim about the whole set, not about http: tested on http alone, a
    # machine where Chrome already held it stopped while Edge went on holding
    # .svg and mailto, and the next step uninstalled Edge.
    if ($wanted -and $current -and $current -eq $wanted -and -not $moving.Count) {
        $msg = "$($pick.Name) already holds everything it can take"
        if ($stranded.Count) {
            $msg += ". Still pointed at the browser being replaced, and $($pick.Name) has not registered for " +
                    "them so Windows will not offer them: " + ((@($stranded | Select-Object -First 8)) -join ', ') +
                    $(if ($stranded.Count -gt 8) { ", and $($stranded.Count - 8) more" } else { '' })
        }
        return [pscustomobject]@{
            Ok = $true; Opened = $false; Pick = $pick.Name
            Moving = @(); Stranded = $stranded; Message = $msg
        }
    }

    $what = $(if ($moving.Count) {
                  "$($moving.Count) association(s) - " +
                  ((@($moving | Select-Object -First 12)) -join ', ') +
                  $(if ($moving.Count -gt 12) { ", and $($moving.Count - 12) more" } else { '' })
              } else { 'http, https and the web file types' })

    $lock = Get-WDAssociationLock
    if ($Context.Preview) {
        $why = $(if ($lock) { " Windows will not allow this silently: $lock." } else { '' })
        return [pscustomobject]@{
            Ok = $false; Opened = $false; Pick = $pick.Name
            Moving = $moving; Stranded = $stranded
            Message = "Would hand $what to $($pick.Name).$why"
        }
    }

    # registeredAppMachine takes a name from
    # HKLM\SOFTWARE\RegisteredApplications, where per-machine installs land.
    $opened = $false
    try {
        $arg = [uri]::EscapeDataString($pick.Name)
        Start-Process "ms-settings:defaultapps?registeredAppMachine=$arg" -ErrorAction Stop
        $opened = $true
    } catch {
        try { Start-Process 'ms-settings:defaultapps' -ErrorAction Stop; $opened = $true } catch { }
    }

    [pscustomobject]@{
        Ok       = $false
        Opened   = $opened
        Pick     = $pick.Name
        Moving   = $moving
        Stranded = $stranded
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
    if ($r.Ok) { return New-WDResult -Status AlreadySet -Message $r.Message }
    # Obstruction in preview too, because that is what apply reports. It read
    # Changed, which is the one thing this step is certain not to do on its own.
    if ($Context.Preview) {
        return New-WDResult -Status Obstruction -Message $r.Message `
                            -Detail ('Windows will not allow this silently: the User Choice Protection Driver is ' +
                                     'active and blocks these keys. Applying will open Settings at the right ' +
                                     'browser and tell you which button to press.')
    }

    if (-not $r.Pick) {
        return New-WDResult -Status Skipped -Message "Nothing to hand the associations to - $($r.Message)"
    }
    $tail = ''
    if (@($r.Moving).Count) {
        $tail += ' That moves ' + @($r.Moving).Count + ' association(s): ' +
                 ((@($r.Moving | Select-Object -First 20)) -join ', ') +
                 $(if (@($r.Moving).Count -gt 20) { ', and ' + (@($r.Moving).Count - 20) + ' more.' } else { '.' })
    }
    if (@($r.Stranded).Count) {
        $tail += ' These stay with the old browser because ' + $r.Pick + ' has not registered for them, ' +
                 'so Set default cannot move them and they have to be pointed somewhere by hand: ' +
                 ((@($r.Stranded | Select-Object -First 20)) -join ', ') +
                 $(if (@($r.Stranded).Count -gt 20) { ', and ' + (@($r.Stranded).Count - 20) + ' more.' } else { '.' })
    }
    # Obstruction, not Blocked: Blocked means this run tried something and
    # Windows said no, and nothing here was refused. Windows lets no program
    # move the default browser silently, by design.
    New-WDResult -Status Obstruction -Message $r.Message -Detail (
        'Windows 11 protects the default-browser setting with a kernel driver and a signed hash that no ' +
        'third-party tool can write, so this is the one thing here that genuinely needs your click. ' +
        $(if ($r.Opened) { 'Default apps has been opened at ' + $r.Pick + ' - press Set default.' }
          else { 'Open Settings, Apps, Default apps, pick ' + $r.Pick + ' and press Set default.' }) + $tail)
}

function Block-WDEdgeReinstall {
    param($Context)

    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
    $blocked = New-Object System.Collections.Generic.List[string]

    if (-not $Context.Preview) {
        Backup-WDRegistryKey -Path $pol
        if (-not (Test-Path $pol)) { $null = New-Item -Path $pol -Force }

        # 0 = do not install / do not update, for every channel.
        $values = [ordered]@{
            'InstallDefault'                = 0
            'UpdateDefault'                 = 0
            'AutoUpdateCheckPeriodMinutes'  = 0
            'DoNotUpdateToEdgeWithChromium' = 1
            'CreateDesktopShortcutDefault'  = 0
            'RemoveDesktopShortcutDefault'  = 1
        }
        foreach ($g in $script:EdgeGuids.Values) {
            $values["Install$g"] = 0
            $values["Update$g"]  = 0
        }
        foreach ($k in $values.Keys) {
            try {
                Set-ItemProperty -LiteralPath $pol -Name $k -Value $values[$k] -Type DWord -Force -ErrorAction Stop
            } catch { }
        }
        Add-WDJournal -ItemId $Context.ItemId -Type 'registry' -Target $pol -Status 'Changed' `
                      -Undo @{ method = 'registry'; path = $pol; name = 'InstallDefault'; previous = '__ABSENT__'; kind = 'DWord' }
        $blocked.Add('update policy')
    }

    # The updater itself: services, then tasks, then its binaries.
    $svc = Invoke-WDServiceAction -Action ([pscustomobject]@{
        names = @('edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')
        startupType = 'Disabled'; stop = $true }) -Context $Context
    if ($svc.Status -in @('Changed','Removed')) { $blocked.Add('updater services') }

    $tsk = Invoke-WDTaskAction -Action ([pscustomobject]@{
        tasks = @('\MicrosoftEdgeUpdateTask*'); delete = $true }) -Context $Context
    if ($tsk.Status -in @('Changed','Removed')) { $blocked.Add('updater tasks') }

    # Rename rather than delete, so the rollback story stays honest.
    $updDir = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeUpdate'
    if ((Test-Path -LiteralPath $updDir) -and -not $Context.Preview) {
        try {
            $parked = "$updDir.wd-disabled"
            if (Test-Path -LiteralPath $parked) { Remove-Item -LiteralPath $parked -Recurse -Force -ErrorAction SilentlyContinue }
            Rename-Item -LiteralPath $updDir -NewName 'EdgeUpdate.wd-disabled' -Force -ErrorAction Stop
            $blocked.Add('updater binaries parked')
            Add-WDJournal -ItemId $Context.ItemId -Type 'file' -Target $updDir -Status 'Changed' `
                          -Undo @{ method = 'rename'; from = $parked; to = $updDir }
        } catch {
            # Held open by a running updater; the policy block still holds.
            Write-WDLog "EdgeUpdate folder is in use, left in place: $($_.Exception.Message)" -Level Warn -Item $Context.ItemId
        }
    } elseif ($Context.Preview -and (Test-Path -LiteralPath $updDir)) {
        $blocked.Add('updater binaries parked')
    }

    $blocked
}

Register-WDHandler 'RemoveEdge' {
    # Order matters: block the reinstall vectors first, then uninstall. The
    # other way round leaves a window where EdgeUpdate notices Edge is gone and
    # re-stages it.
    param($Action, $Context)

    $edgeDirs = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application')
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $appx = @()
    try { $appx = @(Get-AppxPackage -Name 'Microsoft.MicrosoftEdge.Stable' -ErrorAction SilentlyContinue) } catch { }

    if (-not $edgeDirs -and -not $appx) {
        # Still block the vectors, so a future servicing pass cannot install it.
        $null = Block-WDEdgeReinstall -Context $Context
        return New-WDResult -Status NotPresent -Message 'Edge is not installed; reinstall vectors blocked anyway'
    }

    $policy = Get-WDEdgeUninstallPolicy

    if ($Context.Preview) {
        $note = 'Blocks EdgeUpdate policy, services, tasks and binaries first, then uninstalls. WebView2 Runtime is kept.'
        if ($policy.Known -and -not $policy.Allowed) {
            $note = "Windows currently refuses to uninstall Edge in region $($policy.Region): the " +
                    '"Edge is uninstallable" policy in IntegratedServicesRegionPolicySet.json is enabled only in the EEA. ' +
                    'This run will set the home region to IE for the length of the uninstall and set it straight back, ' +
                    'which is what makes the uninstaller answer. ' + $note
        }
        $handover = Set-WDDefaultBrowserBestEffort -Context $Context
        $note = "$($handover.Message) " + $note
        return New-WDResult -Status Removed `
            -Message 'Would uninstall Edge and block every reinstall vector' -Detail $note
    }

    $steps = New-Object System.Collections.Generic.List[string]

    # 0. Hand over the associations first, while Edge is still here to hold
    # them. Afterwards, nothing owns http and every web link answers "You'll
    # need an app to open this".
    $prefer = ''
    try {
        $picked = @(Get-WDChosenBrowsers (Get-WDBrowserChoice -Root $Context.Session.Root))
        if ($picked.Count) { $prefer = [string]$picked[0].Name }
    } catch { }
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

    # 1. Block first.
    foreach ($b in (Block-WDEdgeReinstall -Context $Context)) { $steps.Add($b) }

    # 2. Stop anything holding files open.
    Get-Process -Name 'msedge','MicrosoftEdgeUpdate','msedgewebview2' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'msedgewebview2' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600

    # 3. Lift the regional refusal. Journalled as well as restored in the
    # finally: the finally covers an exception, the journal covers this process
    # being killed between the two.
    $geoWas = -1
    if ($policy.Known -and -not $policy.Allowed) {
        $geoWas = $policy.GeoId
        try {
            Set-WDHomeGeoId -GeoId $script:EdgeUninstallGeoId
            Add-WDJournal -ItemId $Context.ItemId -Type 'registry' -Target 'HKCU:\Control Panel\International\Geo\Nation' `
                          -Status 'Changed' -Undo @{ method = 'registry'; path = 'HKCU:\Control Panel\International\Geo'
                                                     name = 'Nation'; previous = "$geoWas"; kind = 'String'; raw = $true }
            $steps.Add("home region temporarily set to IE (was $($policy.Region))")
            Write-WDLog ("Windows does not permit uninstalling Edge in region $($policy.Region). " +
                         'Setting the home region to IE for the length of the uninstall.') -Level Warn -Item $Context.ItemId
        } catch {
            $geoWas = -1
            Write-WDLog "Could not change the home region: $($_.Exception.Message)" -Level Warn -Item $Context.ItemId
        }
    }

    try {
        # 4. Run every setup.exe there is. Version folders move between updates,
        # so search rather than assume a path.
        $lastExit = $null
        foreach ($dir in $edgeDirs) {
            $setups = @(Get-ChildItem -LiteralPath $dir -Recurse -Filter 'setup.exe' -ErrorAction SilentlyContinue |
                        Where-Object { $_.FullName -match '\\Installer\\setup\.exe$' })
            foreach ($s in $setups) {
                $r = Invoke-WDProcess -FilePath $s.FullName -TimeoutSeconds 600 -ArgumentList @(
                    '--uninstall', '--system-level', '--verbose-logging', '--force-uninstall')
                $lastExit = $r.ExitCode
                if ($r.ExitCode -eq 0) { $steps.Add('uninstaller ran') }
                else { $steps.Add("uninstaller exit $($r.ExitCode)") }
            }
        }

        # Exit 532 is the refusal, not a failure. It has no documented meaning,
        # so the log line is the evidence.
        if ($lastExit -and $lastExit -ne 0) {
            $why = Get-WDEdgeInstallerReason
            if ($why) { Write-WDLog "Edge installer said: $why" -Level Warn -Item $Context.ItemId }
        }
    } finally {
        if ($geoWas -ge 0) {
            try { Set-WDHomeGeoId -GeoId $geoWas; $steps.Add('home region restored') }
            catch { Write-WDLog ("The home region was left set to IE - set it back under Settings, " +
                                 "Time and language, Language and region.") -Level Error -Item $Context.ItemId }
        }
    }

    # 4. The Store-delivered package, for all users and provisioned.
    $ax = Invoke-WDAppxAction -Action ([pscustomobject]@{
        names = @('Microsoft.MicrosoftEdge.Stable', 'Microsoft.MicrosoftEdge.Beta', 'Microsoft.MicrosoftEdgeDevToolsClient') }) -Context $Context
    if ($ax.Status -eq 'Removed') { $steps.Add('appx package removed') }

    # 5. Clear EdgeUpdate's own record that Edge exists, or it re-stages.
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients')) {
        foreach ($g in $script:EdgeGuids.Values) {
            $k = Join-Path $root $g
            if (Test-Path -LiteralPath $k) {
                try {
                    $null = Backup-WDRegistryKey -Path $k
                    Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop
                    $steps.Add('updater client record cleared')
                } catch { }
            }
        }
    }

    # 6. Sweep the folders. The uninstaller leaves its tree behind on nearly
    # every machine, held open by processes that restart themselves.
    $sweepRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { $_ } | ForEach-Object { Join-Path $_ 'Microsoft' }
    $edgeProcs = @('msedge', 'msedgewebview2', 'MicrosoftEdgeUpdate', 'identity_helper',
                   'msedge_proxy', 'cookie_exporter', 'elevation_service')
    $swept  = 0
    $queued = 0
    foreach ($root in $sweepRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        # Nothing this run parked. Block-WDEdgeReinstall renames EdgeUpdate to
        # EdgeUpdate.wd-disabled and journals a rename back, and that name
        # matches ^Edge without being EdgeWebView - so this sweep deleted it and
        # left a journal entry promising a folder that was gone.
        $doomed = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^(Edge|Copilot)' -and
                                   $_.Name -ne 'EdgeWebView' -and
                                   $_.Name -notlike '*.wd-disabled' })
        foreach ($d in $doomed) {
            if ($Context.Preview) { $swept++; continue }
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
            # repeats.
            if ($r.Killed.Count) { $steps.Add("stopped $($r.Killed -join ', ')") }
        }
    }
    if ($swept)  { $steps.Add("$swept folder$(if ($swept -ne 1) { 's' }) deleted") }
    if ($queued) { $steps.Add("$queued folder$(if ($queued -ne 1) { 's' }) queued for deletion at restart") }

    Set-WDRebootNeeded

    # 7. Did it work? A refusal and a failure look identical from here unless
    # the reason is carried through, and one is worth re-running while the other
    # never will be.
    $stillThere = @($edgeDirs | Where-Object { Test-Path (Join-Path $_ 'msedge.exe') })
    if ($stillThere.Count) {
        $why = Get-WDEdgeInstallerReason
        $after = Get-WDEdgeUninstallPolicy
        $detail = "msedge.exe is still at $($stillThere -join ', '). Every reinstall vector is blocked, " +
                  'the updater is off and the browser will not update or come back, but it is still on the disk.'
        if ($why) { $detail += " Edge's own log says: $why" }
        if ($after.Known -and -not $after.Allowed) {
            $detail += " Windows does not permit uninstalling Edge in region $($after.Region) - the " +
                       '"Edge is uninstallable" policy in System32\IntegratedServicesRegionPolicySet.json is enabled ' +
                       'only in the EEA. Changing the home region under Settings, Time and language, Language and ' +
                       'region to an EEA country makes an Uninstall button appear next to Edge in Installed apps.'
        } else {
            $detail += ' Try again after a restart - some builds hold the files open until then.'
        }
        return New-WDResult -Status Blocked -Message 'Windows refused to uninstall Edge' -Detail $detail
    }

    New-WDResult -Status Removed -Message 'Edge removed and reinstall blocked' `
                 -Detail (($steps | Sort-Object -Unique) -join ', ') -Reboot
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

    # 3. Consumer features policy.
    $cc = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
                            -Name 'DisableWindowsConsumerFeatures' -ErrorAction SilentlyContinue).DisableWindowsConsumerFeatures
    if ($cc -ne 1) {
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

    # 4. Edge reinstall vectors, and only when Edge is actually gone: an
    # un-updating browser is a worse outcome than the one this guards against.
    if (-not (Test-Path (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'))) {
        $inst = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' `
                                  -Name 'InstallDefault' -ErrorAction SilentlyContinue).InstallDefault
        $live = @(Get-Service -Name 'edgeupdate','edgeupdatem' -ErrorAction SilentlyContinue |
                  Where-Object { $_.StartType -ne 'Disabled' })
        if ($inst -ne 0 -or $live.Count) {
            & $say "Edge is gone but its updater is still live and will put it back - $verb both halves."
            $r = Invoke-WDRegistryAction -Context $Context -Action ([pscustomobject]@{
                type = 'registry'; scope = 'machine'
                values = @([pscustomobject]@{
                    path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
                    name = 'InstallDefault'; kind = 'DWord'; value = 0 })
            })
            if ($r.Status -notin @('Changed','Removed','NotPresent')) { $left.Add("EdgeUpdate policy: $($r.Message)") }
            if ($live.Count) {
                $s = Invoke-WDServiceAction -Context $Context -Action ([pscustomobject]@{
                    type = 'service'; startupType = 'Disabled'; names = @('edgeupdate','edgeupdatem') })
                if ($s.Status -notin @('Changed','Removed','NotPresent')) { $left.Add("EdgeUpdate services: $($s.Message)") }
            }
            $shut.Add('the Edge updater')
        } else { $did.Add('Edge cannot reinstall itself') }
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

    $skip = @('.git', '.gitignore', 'profile_saves')
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
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$entry -Console -Apply -ProfilePath `$savedPlan
`$rc = `$LASTEXITCODE
# ONLY WHEN IT ACTUALLY RAN. This marker is what raises the toast telling
# somebody their selection was re-applied at sign-in, and it was written
# regardless of how the run above went - so a sign-in where the toolkit happened
# to be open (exit 4, the single-instance interlock refusing) still claimed the
# work had been done. 0 is applied cleanly and 2 is applied with some items
# failing; both are runs that happened. 1 and 4 never got as far as the plan.
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
# changes shows up here, with no per-version event log knowledge.
function Get-WDBuildStamp {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
    '{0}.{1}.{2}' -f $p.CurrentBuild, $p.UBR, $p.DisplayVersion
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
    ([pscustomobject]@{ saved = (Get-Date).ToString('o'); selected = $ids } |
        ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $Path -Encoding UTF8
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
    foreach ($b in $picked) {
        $r = Invoke-WDWingetInstall -Action $Action -Context $Context -Ids @([string]$b.Id)
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
    if ($bad.Count)                       { return New-WDResult -Status Partial -Message $msg -Detail $dt }
    if (-not $done.Count)                 { return New-WDResult -Status NotPresent -Message $msg -Detail $dt }
    New-WDResult -Status Changed -Message $msg -Detail $dt
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
`$now = '{0}.{1}.{2}' -f `$p.CurrentBuild, `$p.UBR, `$p.DisplayVersion
`$marker    = '$($Paths.Marker)'
`$was = ''
if (Test-Path -LiteralPath `$stampFile) { `$was = (Get-Content -LiteralPath `$stampFile -Raw).Trim() }
if (`$now -eq `$was) { exit 0 }
if ((Test-Path -LiteralPath `$entry) -and (Test-Path -LiteralPath `$savedPlan)) {
    `$count = 0
    try { `$count = @((Get-Content -LiteralPath `$savedPlan -Raw | ConvertFrom-Json).selected).Count } catch { }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$entry -Console -Apply -ProfilePath `$savedPlan
    `$rc = `$LASTEXITCODE
    # Left for the notice task, which runs in the signed-in user's session and
    # is the only thing here that can actually put something on screen - so it
    # is written only when the run above actually happened. 0 applied cleanly,
    # 2 applied with failures; 4 is the interlock refusing because the toolkit
    # was open, and telling somebody their selection was re-applied when it was
    # not is worse than saying nothing.
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
        # Five minutes in, so a post-update boot finishes its own servicing
        # before this starts uninstalling underneath it.
        $trg = New-ScheduledTaskTrigger -AtStartup
        $trg.Delay = 'PT5M'
        $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        $null = Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Principal $pri `
                                       -Settings $set -Force -ErrorAction Stop
        Install-WDGuardNotice -Paths $g
        Add-WDJournal -ItemId $Context.ItemId -Type 'task' -Target $taskName -Status 'Changed' `
                      -Undo @{ method = 'unregister-task'; name = $taskName }
        New-WDResult -Status Changed -Message 'Update guard installed' `
                     -Detail ("Checks the build at every boot and re-applies $n item(s) only when it has changed, " +
                              "then tells you it did. Build recorded as $(Get-WDBuildStamp). " +
                              "Remove with: Unregister-ScheduledTask -TaskName '$taskName'")
    } catch {
        New-WDResult -Status Failed -Message 'Could not register the update guard' -Detail $_.Exception.Message
    }
}

Export-ModuleMember -Function Get-WDBrowserRegistrations, Get-WDDefaultBrowserProgId,
                              Get-WDAssociationLock, Set-WDDefaultBrowserBestEffort,
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
                              Get-WDHomeGeoId, Set-WDHomeGeoId, Get-WDGeoIso2
