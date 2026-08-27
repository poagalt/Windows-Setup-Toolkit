<#
    WD.Preflight - is each tool this toolkit stands on actually working?

    Almost everything here wraps something Windows provides: DISM, the
    deployment stack, winget, the Task Scheduler, the SCM, VSS. When one of them
    refuses - and a pending restart makes DISM refuse EVERY servicing operation
    - the items depending on it fail one at a time and the report reads as thirty
    unrelated problems rather than one cause. So the cause is found once, up
    front, and named.

    Three rules:

      1. Never throw. This is on the path to every apply. A check that cannot
         answer returns Unknown, which is a real state and not a failure.
      2. Fast. The whole sweep is under two seconds. The one slow probe - opening
         a DISM servicing session - is behind -Deep, because the cheap proxy for
         it (a pending restart) is the actual cause in real life.
      3. Say what to DO. Reason and Fix are separate fields, and the self test
         fails an Unavailable carrying no Fix.

    States: Ok, Degraded (works, less than fully), Unavailable (will not work),
    Unknown (could not be determined - usually the probe needs elevation).
    Unknown ranks BELOW Unavailable: a thing known broken outranks a thing
    nobody could ask about.
#>

Set-StrictMode -Off

$script:WDToolHealth = $null

# Ordering for display and for "what is the worst thing here". Unknown sits
# below Unavailable deliberately: a thing that is known broken outranks a thing
# nobody could ask about.
$script:WDToolRank = @{ 'Ok' = 0; 'Degraded' = 1; 'Unknown' = 2; 'Unavailable' = 3 }

function New-WDToolResult {
    <#  Uniform shape for a check, mirroring New-WDResult's role in the
        executors. Affects/Handlers/Scope are what let a broken tool be turned
        into a count of the items in front of the operator that it will
        actually break.  #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Ok','Degraded','Unavailable','Unknown')][string]$State,
        [string]$Reason   = '',
        [string]$Fix      = '',
        [string]$Detail   = '',
        [string[]]$Affects  = @(),
        [string[]]$Handlers = @(),
        [string]$Scope    = '',
        # True when this check speaks for the run's safety rather than for a
        # class of action - the restore point, the Recycle Bin, the journal.
        # Those break the way BACK rather than the way forward, so they are
        # reported even when nothing in the plan depends on them.
        [switch]$Safety
    )
    [pscustomobject]@{
        PSTypeName = 'WD.ToolHealth'
        Id       = $Id
        Name     = $Name
        State    = $State
        Reason   = $Reason
        Fix      = $Fix
        Detail   = $Detail
        Affects  = @($Affects)
        Handlers = @($Handlers)
        Scope    = $Scope
        Safety   = [bool]$Safety
        Rank     = $script:WDToolRank[$State]
        Ms       = 0
    }
}

function Test-WDToolHealth {
    <#
        Runs every check and returns the results, worst first.

        Cached for the life of the process, because three surfaces ask for this
        - the log at session start, the confirmation before an apply, and the
        run page - and none of them should pay for it twice. -Refresh is what
        the run itself uses after a restart-adjacent step.

        -Deep adds the probes that cost real time: opening a DISM servicing
        session, and asking winget for its sources. Off by default.
    #>
    [CmdletBinding()]
    param([switch]$Refresh, [switch]$Deep)

    if ($script:WDToolHealth -and -not $Refresh) { return $script:WDToolHealth }

    $sys      = Join-Path $env:SystemRoot 'System32'
    $results  = New-Object System.Collections.Generic.List[psobject]
    $elevated = $false
    try { $elevated = Test-WDAdmin } catch { }

    # Every check goes through here so that one which throws cannot take the
    # sweep down, and so each one is timed.
    $run = {
        param([string]$Id, [scriptblock]$Body)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = $null
        try { $r = & $Body } catch {
            $r = New-WDToolResult -Id $Id -Name $Id -State Unknown `
                    -Reason 'The check itself failed.' `
                    -Detail "$($_.Exception.GetType().Name): $($_.Exception.Message)"
        }
        $sw.Stop()
        if ($r) { $r.Ms = [int]$sw.ElapsedMilliseconds; $results.Add($r) }
    }

    # A pending restart is read once and used by three checks.
    $rebootCbs = $false; $rebootWu = $false
    try { $rebootCbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' } catch { }
    try { $rebootWu  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' } catch { }
    $rebootPending = ($rebootCbs -or $rebootWu)

    # ---------------------------------------------------------- privilege ---

    & $run 'elevation' {
        if ($elevated) {
            New-WDToolResult -Id 'elevation' -Name 'Administrator rights' -State Ok
        } else {
            New-WDToolResult -Id 'elevation' -Name 'Administrator rights' -State Unavailable `
                -Reason 'This process is not elevated, so almost nothing can be removed.' `
                -Fix 'Close this and start it again through Run-WinSetupToolkit.cmd, which asks for elevation.' `
                -Affects @('appx','appxPolicy','uninstall','registry','registryKey','service','task','feature','capability','file','shortcut','winget','script')
        }
    }

    # ---------------------------------------------------- the servicing stack ---

    & $run 'dism' {
        $mod = $null
        try { $mod = @(Get-Module -ListAvailable -Name Dism -ErrorAction Stop).Count } catch { }
        if (-not $mod) {
            return New-WDToolResult -Id 'dism' -Name 'Windows features and capabilities (DISM)' -State Unavailable `
                -Reason 'The DISM PowerShell module is not present on this machine.' `
                -Fix 'This is unusual and usually means a damaged install. sfc /scannow is the place to start.' `
                -Affects @('feature','capability')
        }
        # THE case, and the reason this whole module exists. DISM refuses every
        # servicing operation while a restart is outstanding, and each affected
        # item then fails on its own with a bare 0x800f0conflict-style code.
        if ($rebootPending) {
            return New-WDToolResult -Id 'dism' -Name 'Windows features and capabilities (DISM)' -State Unavailable `
                -Reason 'A restart is already pending, and DISM refuses every servicing operation until it is done.' `
                -Fix 'Restart the computer, then run this again. Nothing else fixes it.' `
                -Detail "Pending restart flags: cbs=$rebootCbs, windowsUpdate=$rebootWu" `
                -Affects @('feature','capability')
        }
        if (-not $elevated) {
            return New-WDToolResult -Id 'dism' -Name 'Windows features and capabilities (DISM)' -State Unknown `
                -Reason 'DISM cannot be asked anything without administrator rights.' `
                -Fix 'Re-run elevated.' -Affects @('feature','capability')
        }
        # TrustedInstaller is the service that actually performs the work.
        $ti = $null
        try { $ti = Get-Service TrustedInstaller -ErrorAction Stop } catch { }
        if ($ti -and $ti.StartType -eq 'Disabled') {
            return New-WDToolResult -Id 'dism' -Name 'Windows features and capabilities (DISM)' -State Unavailable `
                -Reason 'The Windows Modules Installer service (TrustedInstaller) is disabled, and DISM cannot work without it.' `
                -Fix 'Set TrustedInstaller back to Manual: sc.exe config TrustedInstaller start= demand' `
                -Affects @('feature','capability')
        }
        if ($Deep) {
            # The only probe that proves it. Slow, because it opens a real
            # servicing session, which is exactly why it is not the default.
            try {
                $null = Get-WindowsOptionalFeature -Online -FeatureName 'NetFx3' -ErrorAction Stop
            } catch {
                return New-WDToolResult -Id 'dism' -Name 'Windows features and capabilities (DISM)' -State Unavailable `
                    -Reason 'DISM refused a simple query, so the servicing stack is not answering.' `
                    -Fix 'Try DISM /Online /Cleanup-Image /RestoreHealth, then sfc /scannow, then restart.' `
                    -Detail $_.Exception.Message -Affects @('feature','capability')
            }
        }
        New-WDToolResult -Id 'dism' -Name 'Windows features and capabilities (DISM)' -State Ok
    }

    & $run 'component-store' {
        # Cheap corruption and mid-servicing markers - not a substitute for
        # /ScanHealth, which takes minutes and has no business on this path.
        #
        # COUNT, NEVER TEST FOR EXISTENCE. SessionsPending is present and EMPTY
        # on a settled machine, so keying on the key reports every healthy
        # install as degraded.
        #
        # And count only INCOMPLETE sessions. A finished session is left behind
        # under this key with Complete=1, so a bare subkey count tells somebody
        # to restart and goes on telling them after they have. A check whose
        # advice cannot satisfy it is worse than no check. Absent Complete counts
        # as outstanding.
        $sessions = 0
        $packages = 0
        try {
            foreach ($s in (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending' -ErrorAction Stop)) {
                $done = (Get-ItemProperty -LiteralPath $s.PSPath -Name Complete -ErrorAction SilentlyContinue).Complete
                if ([int]$done -eq 1) { continue }
                $sessions++
            }
        } catch { }
        try {
            $k2 = Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending' -ErrorAction Stop
            $packages = [int]$k2.SubKeyCount
        } catch { }
        if ($sessions -gt 0 -or $packages -gt 0) {
            return New-WDToolResult -Id 'component-store' -Name 'Component store' -State Degraded `
                -Reason "Windows has $($sessions + $packages) servicing operation(s) still outstanding, so changing a feature or capability may fail." `
                -Fix 'Restart, let Windows finish installing updates, and run this again.' `
                -Detail "sessionsPending=$sessions, packagesPending=$packages" `
                -Affects @('feature','capability')
        }
        New-WDToolResult -Id 'component-store' -Name 'Component store' -State Ok
    }

    # ------------------------------------------------ the deployment stack ---

    & $run 'appx' {
        $svc = $null
        try { $svc = Get-Service AppXSvc -ErrorAction Stop } catch { }
        if ($svc -and $svc.StartType -eq 'Disabled') {
            return New-WDToolResult -Id 'appx' -Name 'Store app removal (deployment stack)' -State Unavailable `
                -Reason 'The AppX Deployment Service is disabled, so no Store package can be added or removed.' `
                -Fix 'Set AppXSvc back to Manual: sc.exe config AppXSvc start= demand' `
                -Affects @('appx','appxPolicy')
        }
        try {
            # One package by name - the cheapest call that exercises the stack.
            $null = Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction Stop
        } catch {
            return New-WDToolResult -Id 'appx' -Name 'Store app removal (deployment stack)' -State Unavailable `
                -Reason 'The deployment stack refused a simple package query.' `
                -Fix 'Restart, then try again. If it persists, the package repository may be damaged.' `
                -Detail $_.Exception.Message -Affects @('appx','appxPolicy')
        }
        New-WDToolResult -Id 'appx' -Name 'Store app removal (deployment stack)' -State Ok
    }

    & $run 'appx-provisioned' {
        # The half that makes a removal STICK. Without it a package comes back
        # for the next account that signs in, which is the single most
        # confusing outcome this toolkit can produce - it looks like the
        # removal silently undid itself weeks later.
        if (-not $elevated) {
            return New-WDToolResult -Id 'appx-provisioned' -Name 'Permanent Store app removal (deprovisioning)' -State Unavailable `
                -Reason 'Provisioned packages cannot be listed without administrator rights, so removals will come back for new accounts.' `
                -Fix 'Re-run elevated to make Store app removals permanent.' `
                -Affects @('appx')
        }
        try { $null = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop).Count }
        catch {
            return New-WDToolResult -Id 'appx-provisioned' -Name 'Permanent Store app removal (deprovisioning)' -State Unavailable `
                -Reason 'The provisioned package list could not be read, so removals may not be permanent.' `
                -Fix 'A restart usually clears this. It is also blocked by a pending servicing operation.' `
                -Detail $_.Exception.Message -Affects @('appx')
        }
        New-WDToolResult -Id 'appx-provisioned' -Name 'Permanent Store app removal (deprovisioning)' -State Ok
    }

    # ---------------------------------------------------------- installers ---

    & $run 'winget' {
        $cmd = $null
        try { $cmd = Get-Command winget.exe -ErrorAction Stop } catch { }
        if (-not $cmd) {
            return New-WDToolResult -Id 'winget' -Name 'Software installs and vendor uninstalls (winget)' -State Unavailable `
                -Reason 'winget is not on this machine, so nothing can be installed and some vendor uninstalls cannot run.' `
                -Fix 'Install App Installer from the Microsoft Store, then run this again.' `
                -Affects @('winget')
        }
        $ver = ''
        try { $ver = (& winget.exe --version 2>&1 | Out-String).Trim() } catch { }
        if (-not $ver -or $ver -notmatch 'v?\d+\.\d+') {
            return New-WDToolResult -Id 'winget' -Name 'Software installs and vendor uninstalls (winget)' -State Degraded `
                -Reason 'winget is present but did not report a version, so it may not be usable.' `
                -Fix 'Open a terminal and run winget --version to see what it says.' `
                -Detail $ver -Affects @('winget')
        }
        if ($Deep) {
            $src = ''
            try { $src = (& winget.exe source list 2>&1 | Out-String) } catch { }
            if ($src -and $src -notmatch 'winget') {
                return New-WDToolResult -Id 'winget' -Name 'Software installs and vendor uninstalls (winget)' -State Degraded `
                    -Reason "winget $ver has no usable package source, so installs will fail to find anything." `
                    -Fix 'Run: winget source reset --force' -Detail $src -Affects @('winget')
            }
        }
        New-WDToolResult -Id 'winget' -Name 'Software installs and vendor uninstalls (winget)' -State Ok -Detail $ver
    }

    & $run 'network' {
        $ok = $false
        $client = $null
        try {
            $client = New-Object Net.Sockets.TcpClient
            $async = $client.BeginConnect('cdn.winget.microsoft.com', 443, $null, $null)
            $ok = $async.AsyncWaitHandle.WaitOne(1500)
        } catch { }
        finally { try { if ($client) { $client.Close() } } catch { } }
        if (-not $ok) {
            return New-WDToolResult -Id 'network' -Name 'Internet access' -State Unavailable `
                -Reason 'The package servers could not be reached, so nothing can be downloaded or installed.' `
                -Fix 'Connect to a network. Removals do not need one; installs do.' `
                -Affects @('winget')
        }
        New-WDToolResult -Id 'network' -Name 'Internet access' -State Ok
    }

    # ------------------------------------------------- scheduler and the SCM ---

    & $run 'task-scheduler' {
        $svc = $null
        try { $svc = Get-Service Schedule -ErrorAction Stop } catch { }
        if ($svc -and $svc.Status -ne 'Running') {
            return New-WDToolResult -Id 'task-scheduler' -Name 'Scheduled tasks' -State Unavailable `
                -Reason "The Task Scheduler service is $($svc.Status), so scheduled tasks cannot be read or changed." `
                -Fix 'Start it: sc.exe start Schedule' `
                -Affects @('task') -Handlers @('InstallPersistenceGuard','InstallUpdateGuard')
        }
        try {
            $s = New-Object -ComObject Schedule.Service
            $s.Connect()
            $null = $s.GetFolder('\')
        } catch {
            return New-WDToolResult -Id 'task-scheduler' -Name 'Scheduled tasks' -State Unavailable `
                -Reason 'The Task Scheduler refused a connection, so tasks cannot be read or changed.' `
                -Fix 'A restart usually clears this.' -Detail $_.Exception.Message `
                -Affects @('task') -Handlers @('InstallPersistenceGuard','InstallUpdateGuard')
        }
        New-WDToolResult -Id 'task-scheduler' -Name 'Scheduled tasks' -State Ok
    }

    & $run 'services' {
        try { $null = @(Get-Service -ErrorAction Stop).Count }
        catch {
            return New-WDToolResult -Id 'services' -Name 'Service control' -State Unavailable `
                -Reason 'The service list could not be read, so no service can be changed.' `
                -Fix 'This usually means a damaged install or a policy restriction.' `
                -Detail $_.Exception.Message -Affects @('service')
        }
        New-WDToolResult -Id 'services' -Name 'Service control' -State Ok
    }

    & $run 'wmi' {
        # A broken CIM repository is rare and catastrophic: the machine profile,
        # the service list, the process sweeps and the uninstall detection all
        # go through it, so the failure looks like the toolkit having lost its
        # mind rather than like one subsystem being down.
        try { $null = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).BuildNumber }
        catch {
            return New-WDToolResult -Id 'wmi' -Name 'Windows management (WMI/CIM)' -State Unavailable `
                -Reason 'WMI is not answering. Detection, service changes, and uninstalls all depend on it.' `
                -Fix 'winmgmt /verifyrepository, and if it reports inconsistency, winmgmt /salvagerepository' `
                -Detail $_.Exception.Message `
                -Affects @('service','uninstall') -Handlers @('RemoveUninstallLeftovers','RemoveUninstallResidue')
        }
        New-WDToolResult -Id 'wmi' -Name 'Windows management (WMI/CIM)' -State Ok
    }

    # ----------------------------------------------------------- registry ---

    & $run 'user-hives' {
        # Only matters for scope:allusers writes, which is the one scope with a
        # per-account answer.
        try { $null = @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction Stop).Count }
        catch {
            return New-WDToolResult -Id 'user-hives' -Name 'Per-account settings (other users'' registry)' -State Unavailable `
                -Reason 'The other accounts'' registry hives cannot be read, so per-account settings will only reach this account.' `
                -Fix 'Re-run elevated.' -Detail $_.Exception.Message `
                -Affects @('registry') -Scope 'allusers'
        }
        $defaultHive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $defaultHive)) {
            return New-WDToolResult -Id 'user-hives' -Name 'Per-account settings (other users'' registry)' -State Degraded `
                -Reason 'The default profile hive is missing, so accounts created later will not inherit these settings.' `
                -Fix 'Nothing to do here - existing accounts are still written.' `
                -Affects @('registry') -Scope 'allusers'
        }
        New-WDToolResult -Id 'user-hives' -Name 'Per-account settings (other users'' registry)' -State Ok
    }

    & $run 'managed' {
        # A managed machine is not broken, but a policy this toolkit writes can
        # be silently overwritten at the next policy refresh, and "it came back
        # on its own" then has no explanation anywhere.
        $domain = $false; $mdm = 0
        try { $domain = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch { }
        try {
            $mdm = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop |
                     Where-Object { (Get-ItemProperty $_.PSPath -Name EnrollmentState -ErrorAction SilentlyContinue).EnrollmentState -eq 1 }).Count
        } catch { }
        if ($domain -or $mdm -gt 0) {
            return New-WDToolResult -Id 'managed' -Name 'Policy management' -State Degraded `
                -Reason "This machine is managed$(if ($domain) { ' by a domain' })$(if ($mdm) { ' by an MDM' }), and policy settings written here can be put back by the next policy refresh." `
                -Fix 'Nothing to do. Expect some settings to revert, and expect that not to be this toolkit''s doing.' `
                -Detail "domainJoined=$domain, mdmEnrollments=$mdm" `
                -Affects @('registry','registryKey')
        }
        New-WDToolResult -Id 'managed' -Name 'Policy management' -State Ok
    }

    & $run 'tamper-protection' {
        $tp = $null
        try { $tp = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name TamperProtection -ErrorAction Stop).TamperProtection } catch { }
        if ($tp -eq 1 -or $tp -eq 5) {
            return New-WDToolResult -Id 'tamper-protection' -Name 'Defender tamper protection' -State Degraded `
                -Reason 'Tamper protection is on, so Defender''s own settings cannot be changed by any tool, including this one.' `
                -Fix 'Nothing to do - this toolkit does not switch Defender off, and would be refused if it tried.' `
                -Detail "TamperProtection=$tp"
        }
        New-WDToolResult -Id 'tamper-protection' -Name 'Defender tamper protection' -State Ok -Detail "TamperProtection=$tp"
    }

    & $run 'associations' {
        # UCPD is a kernel filter driver that refuses writes to the http,
        # https, and .pdf UserChoice keys from a denylist that includes
        # powershell.exe, even as SYSTEM. Nothing gets past it.
        $ucpd = $null
        try { $ucpd = Get-Service UCPD -ErrorAction Stop } catch { }
        if ($ucpd -and $ucpd.Status -eq 'Running') {
            return New-WDToolResult -Id 'associations' -Name 'Changing the default browser' -State Degraded `
                -Reason 'The UCPD driver blocks scripted changes to the web link associations, so the default browser cannot be set silently.' `
                -Fix 'The toolkit opens the right Settings page instead - one click finishes it.' `
                -Handlers @('SetDefaultBrowser')
        }
        New-WDToolResult -Id 'associations' -Name 'Changing the default browser' -State Ok `
            -Handlers @('SetDefaultBrowser')
    }

    & $run 'edge-removal' {
        $file = Join-Path $sys 'IntegratedServicesRegionPolicySet.json'
        if (-not (Test-Path -LiteralPath $file)) {
            return New-WDToolResult -Id 'edge-removal' -Name 'Edge removal' -State Ok `
                -Detail 'No region policy file, which is normal on builds older than KB5032288.' `
                -Handlers @('RemoveEdge')
        }
        try { $null = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json }
        catch {
            return New-WDToolResult -Id 'edge-removal' -Name 'Edge removal' -State Degraded `
                -Reason 'The region policy that decides whether Edge may be uninstalled could not be read.' `
                -Fix 'Edge removal will be attempted anyway and will report what happened.' `
                -Detail $_.Exception.Message -Handlers @('RemoveEdge')
        }
        New-WDToolResult -Id 'edge-removal' -Name 'Edge removal' -State Ok -Handlers @('RemoveEdge')
    }

    # ------------------------------------------------------- the way back ---

    & $run 'system-restore' {
        $disabled = $null
        try { $disabled = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name DisableSR -ErrorAction Stop).DisableSR } catch { }
        $vss = $null
        try { $vss = Get-Service VSS -ErrorAction Stop } catch { }
        if ($vss -and $vss.StartType -eq 'Disabled') {
            return New-WDToolResult -Id 'system-restore' -Name 'System restore point' -State Unavailable -Safety `
                -Reason 'The Volume Shadow Copy service is disabled, so no restore point can be created.' `
                -Fix 'Set VSS back to Manual: sc.exe config VSS start= demand' `
                -Detail "DisableSR=$disabled"
        }
        if ($disabled -eq 1) {
            return New-WDToolResult -Id 'system-restore' -Name 'System restore point' -State Unavailable -Safety `
                -Reason 'System Protection is switched off, so no restore point can be created.' `
                -Fix 'The toolkit will try to switch it on. If that is refused, the rollback script is the only way back.' `
                -Detail "DisableSR=$disabled"
        }
        if (-not $elevated) {
            return New-WDToolResult -Id 'system-restore' -Name 'System restore point' -State Unknown -Safety `
                -Reason 'Whether a restore point can be created cannot be checked without administrator rights.' `
                -Fix 'Re-run elevated.'
        }
        $count = $null
        try { $count = @(Get-ComputerRestorePoint -ErrorAction Stop).Count } catch { }
        if ($count -eq 0) {
            return New-WDToolResult -Id 'system-restore' -Name 'System restore point' -State Degraded -Safety `
                -Reason 'There are no restore points on this machine yet, which is normal on a new or OEM install.' `
                -Fix 'The toolkit will create one before it changes anything.' -Detail 'restorePoints=0'
        }
        New-WDToolResult -Id 'system-restore' -Name 'System restore point' -State Ok -Safety -Detail "restorePoints=$count"
    }

    & $run 'recycle-bin' {
        # Anything promising reversibility for a deleted file depends on this,
        # and FOF_ALLOWUNDO is a REQUEST - a volume with no bin deletes
        # permanently and still reports success.
        $ok = $null
        try { if (Get-Command Test-WDRecycleAvailable -ErrorAction SilentlyContinue) { $ok = Test-WDRecycleAvailable -Path $env:SystemDrive } } catch { }
        if ($null -eq $ok) {
            return New-WDToolResult -Id 'recycle-bin' -Name 'Recycle Bin (recoverable file deletion)' -State Unknown -Safety `
                -Reason 'Whether the Recycle Bin is available could not be determined.'
        }
        if (-not $ok) {
            return New-WDToolResult -Id 'recycle-bin' -Name 'Recycle Bin (recoverable file deletion)' -State Unavailable -Safety `
                -Reason 'The system volume has no working Recycle Bin, so file deletions cannot be undone.' `
                -Fix 'Items that promise recoverable deletion will refuse to run rather than delete permanently.' `
                -Affects @('file')
        }
        New-WDToolResult -Id 'recycle-bin' -Name 'Recycle Bin (recoverable file deletion)' -State Ok -Safety
    }

    & $run 'journal' {
        # If the run folder cannot be written there is no journal, no rollback
        # script, and no trace - the run would proceed and be unrecoverable.
        $root = $null
        try { $s = Get-WDSession; if ($s) { $root = $s.RunDir } } catch { }
        if (-not $root) { $root = Join-Path $env:ProgramData 'WinSetupToolkit' }
        try {
            if (-not (Test-Path -LiteralPath $root)) { $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop }
            $probe = Join-Path $root ".wd-write-probe"
            Set-Content -LiteralPath $probe -Value 'probe' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        } catch {
            return New-WDToolResult -Id 'journal' -Name 'Undo journal and logs' -State Unavailable -Safety `
                -Reason 'The run folder cannot be written, so there would be no journal, no rollback script, and no log.' `
                -Fix "Check permissions on $root." -Detail $_.Exception.Message
        }
        New-WDToolResult -Id 'journal' -Name 'Undo journal and logs' -State Ok -Safety
    }

    # ------------------------------------------------------- the machine ---

    & $run 'disk-space' {
        $free = $null
        try {
            $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
            $free = [Math]::Round($d.FreeSpace / 1GB, 1)
        } catch { }
        if ($null -eq $free) {
            return New-WDToolResult -Id 'disk-space' -Name 'Free disk space' -State Unknown `
                -Reason 'Free space on the system drive could not be read.'
        }
        if ($free -lt 2) {
            return New-WDToolResult -Id 'disk-space' -Name 'Free disk space' -State Unavailable `
                -Reason "Only $free GB is free, which is not enough for a restore point, a registry backup, or an installer." `
                -Fix 'Free up space before running this.' -Affects @('winget','feature','capability')
        }
        if ($free -lt 10) {
            return New-WDToolResult -Id 'disk-space' -Name 'Free disk space' -State Degraded `
                -Reason "Only $free GB is free. Restore points and installs may fail." `
                -Fix 'The storage clean-ups in Extras will help.' -Affects @('winget')
        }
        New-WDToolResult -Id 'disk-space' -Name 'Free disk space' -State Ok -Detail "$free GB free"
    }

    & $run 'power' {
        $bat = @()
        try { $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop) } catch { }
        if (-not $bat.Count) {
            return New-WDToolResult -Id 'power' -Name 'Power' -State Ok -Detail 'No battery - desktop or unreadable.'
        }
        $onMains = [bool](@($bat | Where-Object { $_.BatteryStatus -eq 2 }).Count)
        $pct = ($bat | Select-Object -First 1).EstimatedChargeRemaining
        if (-not $onMains) {
            return New-WDToolResult -Id 'power' -Name 'Power' -State Degraded `
                -Reason "Running on battery at $pct%. Losing power partway through a run is the one interruption that cannot be made safe." `
                -Fix 'Plug in before applying.'
        }
        New-WDToolResult -Id 'power' -Name 'Power' -State Ok -Detail "On mains, battery $pct%"
    }

    & $run 'safe-mode' {
        $opt = $null
        try { $opt = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option' -Name OptionValue -ErrorAction Stop).OptionValue } catch { }
        if ($opt) {
            return New-WDToolResult -Id 'safe-mode' -Name 'Normal boot' -State Unavailable `
                -Reason 'This machine is in safe mode. Most services are not running and DISM refuses to work.' `
                -Fix 'Restart normally before running this.' -Detail "SafeBoot OptionValue=$opt" `
                -Affects @('feature','capability','service','appx','winget','task')
        }
        New-WDToolResult -Id 'safe-mode' -Name 'Normal boot' -State Ok
    }

    & $run 'shell' {
        $n = 0
        try { $n = @(Get-Process explorer -ErrorAction Stop).Count } catch { }
        if ($n -eq 0) {
            return New-WDToolResult -Id 'shell' -Name 'Windows shell (Explorer)' -State Degraded `
                -Reason 'Explorer is not running, so shell changes cannot be applied or seen until it starts.' `
                -Fix 'Sign out and back in, or start explorer.exe.' `
                -Handlers @('RestartExplorer','SetTaskbarAutoHide','VerifyShellHealth')
        }
        New-WDToolResult -Id 'shell' -Name 'Windows shell (Explorer)' -State Ok
    }

    & $run 'command-tools' {
        # The external binaries several handlers shell out to. Missing ones are
        # rare, but a stripped or previously-debloated image is exactly the
        # machine somebody points this at.
        $need = [ordered]@{
            'reg.exe'      = @('registry')
            'sc.exe'       = @('service')
            'powercfg.exe' = @()
            'pnputil.exe'  = @()
            'takeown.exe'  = @()
            'icacls.exe'   = @()
            'vssadmin.exe' = @()
            'dism.exe'     = @('feature','capability')
            'schtasks.exe' = @('task')
        }
        $missing = New-Object System.Collections.Generic.List[string]
        $affects = New-Object System.Collections.Generic.List[string]
        foreach ($exe in $need.Keys) {
            if (-not (Test-Path -LiteralPath (Join-Path $sys $exe))) {
                $missing.Add($exe)
                foreach ($a in $need[$exe]) { $affects.Add($a) }
            }
        }
        if ($missing.Count) {
            return New-WDToolResult -Id 'command-tools' -Name 'Windows command-line tools' -State Unavailable `
                -Reason "$($missing.Count) tool(s) this toolkit shells out to are missing: $($missing -join ', ')." `
                -Fix 'This machine has been modified in a way that is not safe to build on. sfc /scannow.' `
                -Affects @($affects)
        }
        New-WDToolResult -Id 'command-tools' -Name 'Windows command-line tools' -State Ok -Detail "$($need.Count) of $($need.Count) present"
    }

    & $run 'ps-modules' {
        $want = @('Appx', 'Dism', 'ScheduledTasks', 'Defender', 'NetSecurity')
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($m in $want) {
            $have = $false
            try { $have = [bool]@(Get-Module -ListAvailable -Name $m -ErrorAction Stop).Count } catch { }
            if (-not $have) { $missing.Add($m) }
        }
        if ($missing.Count) {
            return New-WDToolResult -Id 'ps-modules' -Name 'PowerShell modules' -State Degraded `
                -Reason "Missing module(s): $($missing -join ', '). Anything depending on them will report Blocked." `
                -Fix 'These ship with Windows, so a missing one means a damaged or heavily stripped install.'
        }
        New-WDToolResult -Id 'ps-modules' -Name 'PowerShell modules' -State Ok
    }

    & $run 'single-instance' {
        # The worst outcome in this whole file. Two runs interleaving read each
        # other's changes as the "previous value" for their own journals, and
        # both rollbacks then restore the wrong thing - silently, and only
        # discovered by somebody trying to undo.
        $others = @()
        try {
            $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
                        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'WinSetupToolkit\.ps1' })
        } catch { }
        if ($others.Count) {
            return New-WDToolResult -Id 'single-instance' -Name 'Only one copy running' -State Unavailable -Safety `
                -Reason "$($others.Count) other copy of the toolkit is running. Two runs at once corrupt each other's undo data." `
                -Fix 'Close the other one, or wait for it to finish, before applying.' `
                -Detail (($others | ForEach-Object { "pid $($_.ProcessId)" }) -join ', ')
        }
        New-WDToolResult -Id 'single-instance' -Name 'Only one copy running' -State Ok -Safety
    }

    $script:WDToolHealth = @($results | Sort-Object -Property @{ Expression = 'Rank'; Descending = $true }, 'Name')
    $script:WDToolHealth
}

function Get-WDToolHealthSummary {
    <#  Counts and a single sentence, for a header or a log line.  #>
    param($Health)
    if (-not $Health) { $Health = Test-WDToolHealth }
    $bad  = @($Health | Where-Object { $_.State -eq 'Unavailable' })
    $soft = @($Health | Where-Object { $_.State -eq 'Degraded' })
    $unk  = @($Health | Where-Object { $_.State -eq 'Unknown' })
    $text = 'Everything this toolkit depends on is working.'
    if ($unk.Count -and -not $bad.Count -and -not $soft.Count) {
        $text = "$($unk.Count) check(s) could not be answered."
    }
    if ($soft.Count -and -not $bad.Count) {
        $text = "$($soft.Count) thing(s) will work, but not fully."
    }
    if ($bad.Count) {
        $text = "$($bad.Count) thing(s) this toolkit depends on are not working: $((@($bad | ForEach-Object { $_.Name }) | Select-Object -First 3) -join ', ')."
    }
    [pscustomobject]@{
        Total       = @($Health).Count
        Ok          = @($Health | Where-Object { $_.State -eq 'Ok' }).Count
        Degraded    = $soft.Count
        Unavailable = $bad.Count
        Unknown     = $unk.Count
        Worst       = $(if ($bad.Count) { 'Unavailable' } elseif ($unk.Count) { 'Unknown' } elseif ($soft.Count) { 'Degraded' } else { 'Ok' })
        Text        = $text
    }
}

function Get-WDHealthImpact {
    <#
        Which items in a plan a broken tool will actually break.

        This is the half that makes the whole thing worth having. "DISM is
        unavailable" is a fact about the machine; "DISM is unavailable, and 6
        of the 118 options you have selected need it" is a decision somebody
        can make. Without the count, a warning about a subsystem nothing in
        this run touches is noise, and noise is how warnings get ignored.
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        $Health
    )
    if (-not $Health) { $Health = Test-WDToolHealth }
    $out = New-Object System.Collections.Generic.List[psobject]

    foreach ($h in @($Health)) {
        if ($h.State -eq 'Ok') { continue }
        $hit = New-Object System.Collections.Generic.List[psobject]
        foreach ($item in @($Plan)) {
            $match = $false
            foreach ($a in @($item.Actions)) {
                $type = [string](Get-Prop $a 'type' '')
                if ($h.Affects -and $h.Affects -contains $type) {
                    # A scoped check only speaks for actions in that scope -
                    # the other-accounts hive check has nothing to say about
                    # an HKLM policy write, and 45 of the registry actions in
                    # the manifest are exactly that.
                    if ($h.Scope) {
                        $scope = [string](Get-Prop $a 'scope' 'machine')
                        if ($scope -ine $h.Scope) { continue }
                    }
                    $match = $true; break
                }
                if ($h.Handlers -and $type -eq 'script') {
                    $handler = [string](Get-Prop $a 'handler' '')
                    if ($handler -and $h.Handlers -contains $handler) { $match = $true; break }
                }
            }
            if ($match) { $hit.Add($item) }
        }
        # A safety check is reported whether or not the plan names it: those
        # break the way BACK, and every run has one of those.
        if ($hit.Count -or $h.Safety) {
            $out.Add([pscustomobject]@{
                Health = $h
                Items  = @($hit)
                Count  = $hit.Count
            })
        }
    }
    # NOT ",@(...)". Every caller wraps this in @() - the console, the pre-apply
    # dialog, the run page, and the self test - and `@(f)` where f returns
    # `,@(...)` is one element holding the whole array. That is the trap this
    # codebase has a section about, and it bit here exactly as written up:
    # $imp.Count read the array's own Count, $imp[0].Health member-enumerated
    # into four health objects, and the formatter printed all four states mashed
    # into a single line. The comma is right when the caller assigns; here
    # nobody does.
    @($out | Sort-Object -Property @{ Expression = { $_.Health.Rank }; Descending = $true },
                                   @{ Expression = 'Count'; Descending = $true })
}

function Format-WDToolHealthText {
    <#
        The block a person reads, used by the console, the pre-apply
        confirmation, and the run page. One formatter, so those three cannot
        drift into describing the machine differently.

        -Impact turns it from "what is broken" into "what is broken that
        matters to this run", which is the version worth interrupting somebody
        with.
    #>
    param(
        $Health,
        $Impact,
        [switch]$IncludeOk,
        [int]$Width = 76
    )
    if (-not $Health) { $Health = Test-WDToolHealth }
    $lines = New-Object System.Collections.Generic.List[string]

    $rows = @()
    if ($Impact) {
        $rows = @($Impact | ForEach-Object {
            [pscustomobject]@{ H = $_.Health; Count = $_.Count }
        })
    } else {
        $rows = @($Health | Where-Object { $IncludeOk -or $_.State -ne 'Ok' } |
                  ForEach-Object { [pscustomobject]@{ H = $_; Count = $null } })
    }
    if (-not $rows.Count) {
        $lines.Add('Everything this toolkit depends on is working.')
        return ($lines -join "`r`n")
    }

    foreach ($r in $rows) {
        $h = $r.H
        if (-not $IncludeOk -and $h.State -eq 'Ok') { continue }
        $mark = switch ($h.State) {
            'Unavailable' { 'NOT WORKING' }
            'Degraded'    { 'LIMITED    ' }
            'Unknown'     { 'UNKNOWN    ' }
            default       { 'OK         ' }
        }
        $affected = ''
        if ($null -ne $r.Count) {
            if ($r.Count -gt 0) {
                $affected = "  ($($r.Count) selected option$(if ($r.Count -ne 1) { 's' }) affected)"
            } elseif ($h.Safety) {
                $affected = '  (affects the way back, not the run)'
            }
        }
        $lines.Add("[$mark] $($h.Name)$affected")
        if ($h.Reason) { $lines.Add("             $($h.Reason)") }
        if ($h.Fix)    { $lines.Add("             -> $($h.Fix)") }
    }
    ($lines -join "`r`n")
}

function Write-WDToolHealthLog {
    <#  Puts the sweep into the run log and the trace. Called from
        Write-WDRunEnvironment, so every run records it whether or not anybody
        was looking at a screen.  #>
    param([switch]$Deep)
    $health = $null
    try { $health = Test-WDToolHealth -Refresh -Deep:$Deep } catch { return $null }
    $sum = Get-WDToolHealthSummary -Health $health

    if (Get-Command Add-WDTrace -ErrorAction SilentlyContinue) {
        Add-WDTrace -Kind 'tool-health' -Data @{
            summary = @{ ok = $sum.Ok; degraded = $sum.Degraded; unavailable = $sum.Unavailable
                         unknown = $sum.Unknown; worst = $sum.Worst }
            checks  = @($health | ForEach-Object {
                [ordered]@{ id = $_.Id; state = $_.State; ms = $_.Ms
                            reason = $_.Reason; detail = $_.Detail
                            affects = @($_.Affects); handlers = @($_.Handlers) }
            })
        }
    }

    if (Get-Command Write-WDLog -ErrorAction SilentlyContinue) {
        Write-WDLog ("Tool check: {0} ok, {1} limited, {2} not working, {3} unknown." -f `
                     $sum.Ok, $sum.Degraded, $sum.Unavailable, $sum.Unknown) `
                    -Level $(if ($sum.Unavailable) { 'Warn' } else { 'Info' })
        foreach ($h in @($health | Where-Object { $_.State -ne 'Ok' })) {
            $lvl = switch ($h.State) { 'Unavailable' { 'Warn' } 'Unknown' { 'Info' } default { 'Info' } }
            Write-WDLog "  [$($h.State)] $($h.Name): $($h.Reason)" -Level $lvl
            if ($h.Fix) { Write-WDLog "            Fix: $($h.Fix)" -Level $lvl }
        }
    }
    $health
}

Export-ModuleMember -Function Test-WDToolHealth, Get-WDToolHealthSummary, Get-WDHealthImpact,
                              Format-WDToolHealthText, Write-WDToolHealthLog, New-WDToolResult
