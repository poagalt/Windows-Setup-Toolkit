<#
    WD.Actions - one executor per action type.

    Contract every executor honours:
      * Never throw. Return a WD.Result instead.
      * Preview mode performs every lookup but no mutation, so the preview
        report is accurate rather than a guess.

    Status vocabulary, which is deliberately strict:
      NotPresent  the target was not found. Presumed absent - though in
                  principle the search could have missed it.
      Skipped     found or not, WE chose not to attempt it: a guard excluded
                  it, a precondition was unmet, or it needs an edition this
                  machine is not running.
      Blocked     the target WAS found and something outside us refused the
                  change. Needing elevation, TrustedInstaller ownership and
                  NonRemovable in-box packages all land here, whether or not
                  the operator can do anything about it.
      Failed      attempted, and it errored.
#>

# Deliberately no StrictMode here: manifest objects come from JSON with many
# optional fields, and Get-Prop is the disciplined way to read them.

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    $p.Value
}

function Test-WDElevationError {
    <#
        Distinguishes "Windows refused us" from "this genuinely broke". Running
        unelevated, or against a TrustedInstaller-owned object, is a Blocked
        outcome - reporting it as Failed would drown the real problems.
    #>
    param([string]$Message)
    if (-not $Message) { return $false }
    # 'unauthorized operation' is the one that kept being missed. The registry
    # provider raises UnauthorizedAccessException with the message "Attempted to
    # perform an unauthorized operation." - which does not contain the type name
    # this used to look for, so an ACL refusal on an elevated run was reported as
    # Failed. Failed means the toolkit broke; this means Windows said no.
    $Message -match 'requires elevation|Access is denied|0x800702E4|0x80070005|privilege is not held|UnauthorizedAccess|unauthorized operation|is not allowed'
}

function Invoke-WDProcess {
    <#  Start-Process with a hard timeout, so a hung uninstaller cannot wedge the run.  #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 300
    )
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $FilePath
        $psi.Arguments              = ($ArgumentList -join ' ')
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        # Drain asynchronously; a full pipe buffer deadlocks WaitForExit.
        $out = $proc.StandardOutput.ReadToEndAsync()
        $err = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            return [pscustomobject]@{ ExitCode = -1; Output = ''; Error = "Timed out after ${TimeoutSeconds}s"; TimedOut = $true }
        }
        [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Output   = $out.Result
            Error    = $err.Result
            TimedOut = $false
        }
    } catch {
        [pscustomobject]@{ ExitCode = -1; Output = ''; Error = $_.Exception.Message; TimedOut = $false }
    }
}

# ---------------------------------------------------------------- appx -----

$script:ProvisionedWarned = $false

# Enumerating provisioned packages is a DISM call, and it was being made once
# per wildcard pattern - about 180 times in a full run, each one several hundred
# milliseconds of servicing-stack work, all returning the same list. It is now
# read once and invalidated whenever something is actually deprovisioned, which
# is the only thing that can change it. An explicit invalidation rather than a
# clock: staleness here should be a decision, not a timer that happens to expire
# in the middle of a run.
$script:ProvisionedCache = $null

function Get-WDProvisionedPackages {
    if ($null -eq $script:ProvisionedCache) {
        # Deliberately not caught: the caller distinguishes "not elevated" from
        # "none present" and would lose that if this swallowed the error.
        $script:ProvisionedCache = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
    }
    $script:ProvisionedCache
}

function Clear-WDProvisionedCache { $script:ProvisionedCache = $null }

# The same shape for Windows capabilities: one DISM enumeration per capability
# pattern became one per run.
$script:CapabilityCache = $null

function Get-WDCapabilityList {
    if ($null -eq $script:CapabilityCache) {
        $script:CapabilityCache = @(Get-WindowsCapability -Online -ErrorAction SilentlyContinue)
    }
    $script:CapabilityCache
}

function Clear-WDCapabilityCache { $script:CapabilityCache = $null }

function Invoke-WDAppxAction {
    param($Action, $Context)

    $names   = @(Get-Prop $Action 'names' @())
    $preview = $Context.Preview
    # Same opt-out as the uninstaller: an item can refuse to have anything
    # closed on its behalf with "closeRunning": false.
    $kill    = [bool](Get-Prop $Action 'closeRunning' $true)
    $removed = New-Object System.Collections.Generic.List[string]
    $blocked = New-Object System.Collections.Generic.List[string]
    $inbox   = New-Object System.Collections.Generic.List[string]
    $errors  = New-Object System.Collections.Generic.List[string]
    $found   = $false
    $recovered = ''

    foreach ($pattern in $names) {

        # --- installed packages, every user ------------------------------
        $pkgs = @()
        try {
            $pkgs = @(Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue)
        } catch {
            # -AllUsers needs elevation and fails oddly on some builds; degrade.
            try { $pkgs = @(Get-AppxPackage -Name $pattern -ErrorAction SilentlyContinue) } catch { }
        }

        foreach ($pkg in $pkgs) {
            $found = $true
            # NonRemovable is set by the deployment stack on in-box components
            # that Windows will never uninstall - CBS packages serviced by
            # Windows Update, and shell hosts. Tracked separately only so the
            # message can explain itself; the outcome is still Blocked, because
            # the package was found and an external force refused the removal.
            if ($pkg.NonRemovable -eq $true) {
                $inbox.Add($pkg.Name)
                continue
            }
            if ($preview) { $removed.Add($pkg.Name); continue }

            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                $removed.Add($pkg.Name)
                Add-WDJournal -ItemId $Context.ItemId -Type 'appx' -Target $pkg.PackageFullName `
                              -Status 'Removed' -Undo @{ method = 'reinstall'; name = $pkg.Name }
            } catch {
                $msg = $_.Exception.Message
                # 0x80073CFA / "not applicable" = system-protected package.
                if ($msg -match '0x80073CFA|not applicable|cannot be removed|system app') {
                    $blocked.Add($pkg.Name)
                } else {
                    $done = $false
                    # Retry without -AllUsers; some packages only yield per-user.
                    try {
                        Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                        $removed.Add($pkg.Name)
                        Add-WDJournal -ItemId $Context.ItemId -Type 'appx' -Target $pkg.PackageFullName `
                                      -Status 'Removed' -Undo @{ method = 'reinstall'; name = $pkg.Name }
                        $done = $true
                    } catch { $msg = $_.Exception.Message }

                    # 0x80073D02 is the deployment stack saying the app is
                    # running: "resources it modifies are currently in use". It
                    # is the appx spelling of the failure the uninstaller path
                    # already answers, and the answer is the same - close what
                    # is holding it and ask again.
                    #
                    # Swept by the package's own folder under WindowsApps, which
                    # is per-package and so names exactly this app's processes.
                    # Only retried when something was actually closed; otherwise
                    # the second call fails identically and says so twice.
                    if (-not $done -and $kill) {
                        $under = [string](Test-WDSweepableRoot -Path $pkg.InstallLocation)
                        # ASSIGNED, NEVER WRAPPED. Stop-WDBlockers ends in
                        # ,@(...) so assigning it does not unroll; @() around it
                        # is one element holding the array, so Count read 1 with
                        # nothing closed and this retried every single refusal.
                        $shut  = Stop-WDBlockers -Path $under -Because "$($pkg.Name) could be removed"
                        if ($shut.Count) {
                            try {
                                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                                $removed.Add($pkg.Name)
                                Add-WDJournal -ItemId $Context.ItemId -Type 'appx' -Target $pkg.PackageFullName `
                                              -Status 'Removed' -Undo @{ method = 'reinstall'; name = $pkg.Name }
                                $done = $true
                            } catch { $msg = $_.Exception.Message }
                        }
                    }

                    if (-not $done) { $errors.Add("$($pkg.Name): $msg") }
                }
            }
        }

        # --- provisioned packages (stops it returning for new users) ------
        try {
            $prov = @(Get-WDProvisionedPackages | Where-Object { $_.DisplayName -like $pattern })
            foreach ($p in $prov) {
                $found = $true
                if ($preview) { continue }
                try {
                    $null = Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop
                    Clear-WDProvisionedCache
                    if ($removed -notcontains $p.DisplayName) { $removed.Add($p.DisplayName) }
                    Add-WDJournal -ItemId $Context.ItemId -Type 'appx-provisioned' -Target $p.PackageName `
                                  -Status 'Removed' -Undo @{ method = 'reinstall'; name = $p.DisplayName }
                } catch {
                    $blocked.Add("$($p.DisplayName) (provisioned)")
                }
            }
        } catch {
            $msg = $_.Exception.Message
            if (Test-WDElevationError $msg) {
                # Enumerating provisioned packages needs elevation, and it fails
                # for every appx item alike. Recording it per item made absent
                # apps report "needs administrator rights", which is both noisy
                # and wrong. Warn once for the run instead.
                if (-not $script:ProvisionedWarned) {
                    $script:ProvisionedWarned = $true
                    Write-WDLog 'Not elevated: provisioned packages cannot be enumerated, so removals will not be deprovisioned. Re-run elevated to make them permanent.' -Level Warn
                }
            } else {
                $errors.Add("provisioned query failed: $msg")
            }
        }
    }

    # Patterns overlap heavily, so the same refusal arrives many times over.
    $removed = @($removed | Sort-Object -Unique)
    $blocked = @($blocked | Sort-Object -Unique)
    $inbox   = @($inbox   | Sort-Object -Unique)
    $errors  = @($errors  | Sort-Object -Unique)

    # ASK REALITY BEFORE REPORTING A REFUSAL.
    #
    # A refusal from the deployment stack is a statement about one call, not
    # about the outcome. The same package is reachable by more than one route -
    # the installed copy, the provisioned entry, an overlapping pattern in this
    # same action, and a vendor uninstaller in another item - so an API that
    # said no can be followed by the thing being gone regardless. OneDriveSync
    # did exactly that: 'Protected by Windows - cannot be removed even as
    # administrator' against a machine with no OneDrive left on it anywhere.
    #
    # Reporting that is worse than saying nothing. It sends somebody after a
    # problem that does not exist, and it teaches them that Blocked cannot be
    # believed - which is the status this toolkit needs believed most.
    #
    # NonRemovable packages are excluded from the re-check on purpose: those are
    # still present, still refused, and still worth a row.
    if (-not $preview -and $blocked.Count) {
        $stillThere = $false
        foreach ($pattern in $names) {
            $live = @()
            try   { $live = @(Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue) }
            catch { try { $live = @(Get-AppxPackage -Name $pattern -ErrorAction SilentlyContinue) } catch { } }
            if (@($live | Where-Object { $_.NonRemovable -ne $true }).Count) { $stillThere = $true; break }
            try {
                if (@(Get-WDProvisionedPackages | Where-Object { $_.DisplayName -like $pattern }).Count) { $stillThere = $true; break }
            } catch { }
        }
        if (-not $stillThere) {
            foreach ($b in $blocked) { if ($removed -notcontains $b) { $removed += $b } }
            $recovered = 'the deployment stack refused one of the calls, but the package is gone - another route removed it'
            $blocked = @()
        }
    }

    if ($errors.Count -and -not $removed.Count) {
        return New-WDResult -Status Failed -Message "Could not remove packages" -Detail ($errors -join '; ')
    }
    if ($removed.Count) {
        $detail = $removed -join ', '
        if ($inbox.Count)   { $detail += " (in-box, not removable: $($inbox -join ', '))" }
        if ($blocked.Count) { $detail += " (skipped: $($blocked -join ', '))" }
        return New-WDResult -Status Removed -Message "$($removed.Count) package(s)" -Detail $detail -Recovered $recovered
    }
    if ($inbox.Count -and -not $blocked.Count) {
        # Found, and Windows refuses to remove it. That is Blocked by definition,
        # even though there is nothing the operator can do about it - the detail
        # says so rather than the status pretending it was never attempted.
        return New-WDResult -Status Blocked `
            -Message "$($inbox.Count) in-box component(s) Windows refuses to remove" `
            -Detail (($inbox -join ', ') +
                     ' - flagged NonRemovable by the deployment stack. Serviced by Windows Update rather than the Store, so no privilege, ownership change or policy removes them. Present and blocked, not absent.')
    }
    if ($blocked.Count -and $inbox.Count) {
        return New-WDResult -Status Blocked -Message 'Refused by Windows' `
            -Detail ("in-box, cannot be removed: $($inbox -join ', ') | $($blocked -join ', ')")
    }
    if ($blocked.Count) {
        # Two very different causes, so say which. Elevation is fixable by
        # re-running as admin; NonRemovable is not fixable at all, because
        # Windows owns the package and refuses even a full administrator.
        $needsAdmin = @($blocked | Where-Object { $_ -match 'needs elevation' }).Count
        $msg = if ($needsAdmin -eq $blocked.Count) { 'Needs administrator rights' }
               elseif ($needsAdmin)                { 'Partly protected by Windows, partly needs administrator rights' }
               else                                { 'Protected by Windows - cannot be removed even as administrator' }
        return New-WDResult -Status Blocked -Message $msg -Detail ($blocked -join ', ')
    }
    if (-not $found) {
        return New-WDResult -Status NotPresent -Message 'Not installed'
    }
    New-WDResult -Status NotPresent -Message 'Nothing to remove'
}

# --------------------------------------------------------- appx policy -----

function Invoke-WDAppxPolicyAction {
    <#
        Windows 11 25H2 shipped a supported way to deprovision in-box apps.
        It only exists on Enterprise and Education, so this action is additive:
        it strengthens the appx removal where available and is a no-op elsewhere.
    #>
    param($Action, $Context)

    $profile = $Context.Profile
    if (-not $profile.IsEnterprise) {
        return New-WDResult -Status Skipped -Message 'Policy needs Enterprise/Education; appx removal already covers this'
    }
    if ($profile.Build -lt 26200) {
        return New-WDResult -Status Skipped -Message 'Needs Windows 11 25H2 or newer'
    }

    $packages = @(Get-Prop $Action 'packages' @())
    if (-not $packages.Count) { return New-WDResult -Status Skipped -Message 'No packages listed' }

    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx'
    if ($Context.Preview) {
        return New-WDResult -Status Changed -Message "Would set removal policy for $($packages.Count) package(s)"
    }

    try {
        Backup-WDRegistryKey -Path $key
        if (-not (Test-Path $key)) { $null = New-Item -Path $key -Force }
        Set-ItemProperty -Path $key -Name 'RemoveDefaultMicrosoftStorePackages' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $key -Name 'RemoveDefaultMicrosoftStorePackagesList' -Value ($packages -join ';') -Type String -Force
        Add-WDJournal -ItemId $Context.ItemId -Type 'appx-policy' -Target $key -Status 'Changed' `
                      -Undo @{ method = 'registry'; path = $key; name = 'RemoveDefaultMicrosoftStorePackages'; previous = '__ABSENT__'; kind = 'DWord' }
        New-WDResult -Status Changed -Message "Removal policy set for $($packages.Count) package(s)"
    } catch {
        New-WDResult -Status Failed -Message 'Policy write failed' -Detail $_.Exception.Message
    }
}

# ------------------------------------------------------------ winget -------

function Invoke-WDWingetInstall {
    <#
        The one place this toolkit puts something on rather than takes it off:
        the replacement browser offered when Edge is removed. Kept in the winget
        executor behind "mode": "install" so it goes through the same presence
        probe, the same timeouts, and the same journal as everything else.

        NotPresent here means "nothing to do" in the install sense - it is
        already installed. That is the success bucket, which is where a run that
        found its work already done belongs.
    #>
    param($Action, $Context, [string[]]$Ids)

    $done   = New-Object System.Collections.Generic.List[string]
    $had    = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($id in $Ids) {
        $probe = Invoke-WDProcess -FilePath 'winget.exe' `
                                  -ArgumentList @('list', '--id', $id, '--exact',
                                                  '--accept-source-agreements',
                                                  '--disable-interactivity') -TimeoutSeconds 90
        if ($probe.ExitCode -eq 0 -and $probe.Output -match [regex]::Escape($id)) { $had.Add($id); continue }
        if ($Context.Preview) { $done.Add($id); continue }

        # Some installers do nothing useful with their default arguments - the
        # Visual Studio build tools land as an empty shell unless the workload
        # is named - so an item can supply the installer's own command line.
        # --silent is dropped alongside it: winget refuses the pair, and the
        # override has to carry its own quiet switches anyway.
        $over = [string](Get-Prop $Action 'override' '')
        $args = @('install', '--id', $id, '--exact')
        if ($over) { $args += @('--override', $over) } else { $args += '--silent' }
        $args += @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
        # Big toolchains legitimately outrun the default; the item says so.
        $secs = [int](Get-Prop $Action 'timeoutSeconds' 900)
        if ($secs -le 0) { $secs = 900 }

        $res = Invoke-WDProcess -FilePath 'winget.exe' -ArgumentList $args -TimeoutSeconds $secs
        if ($res.ExitCode -eq 0) {
            $done.Add($id)
            Add-WDJournal -ItemId $Context.ItemId -Type 'winget' -Target $id -Status 'Changed' `
                          -Undo @{ method = 'uninstall'; name = $id }
        } elseif ($res.TimedOut) {
            $errors.Add("$id timed out")
        } else {
            $errors.Add("$id exit $($res.ExitCode)")
        }
    }

    if ($errors.Count) {
        if ($done.Count) {
            return New-WDResult -Status Partial -Message "Installed $($done.Count), failed $($errors.Count)" `
                                -Detail (($done -join ', ') + ' | ' + ($errors -join '; '))
        }
        return New-WDResult -Status Failed -Message 'winget install failed' -Detail ($errors -join '; ')
    }
    if ($done.Count) {
        # A preview reaches this with the same list, so the tense has to follow
        # it - "installed" on the preview page is a straight lie about what has
        # already happened.
        $msg = if ($Context.Preview) { "Would install $($done.Count) app(s) via winget" }
               else                  { "$($done.Count) app(s) installed via winget" }
        return New-WDResult -Status Changed -Message $msg -Detail ($done -join ', ')
    }
    if ($had.Count) {
        return New-WDResult -Status NotPresent -Message 'Already installed' -Detail (($had -join ', ') + ' - nothing to do')
    }
    New-WDResult -Status Skipped -Message 'Nothing to install'
}

function Invoke-WDWingetAction {
    param($Action, $Context)

    if (-not $Context.Profile.HasWinget) {
        return New-WDResult -Status Skipped -Message 'winget not available on this machine'
    }

    $ids = @(Get-Prop $Action 'ids' @())
    if ((Get-Prop $Action 'mode' 'uninstall') -eq 'install') {
        return Invoke-WDWingetInstall -Action $Action -Context $Context -Ids $ids
    }
    $removed = New-Object System.Collections.Generic.List[string]
    $errors  = New-Object System.Collections.Generic.List[string]
    $found   = $false

    foreach ($id in $ids) {
        # `winget list` is the cheap presence test and avoids a pointless
        # uninstall attempt (and its interactive prompts) for absent apps.
        $probe = Invoke-WDProcess -FilePath 'winget.exe' `
                                  -ArgumentList @('list', '--id', $id, '--exact',
                                                  '--accept-source-agreements',
                                                  '--disable-interactivity') -TimeoutSeconds 90
        if ($probe.ExitCode -ne 0 -or $probe.Output -notmatch [regex]::Escape($id)) { continue }

        $found = $true
        if ($Context.Preview) { $removed.Add($id); continue }

        $res = Invoke-WDProcess -FilePath 'winget.exe' `
                                -ArgumentList @('uninstall', '--id', $id, '--exact', '--silent',
                                                '--accept-source-agreements', '--disable-interactivity',
                                                '--force') -TimeoutSeconds 600
        if ($res.ExitCode -eq 0) {
            $removed.Add($id)
            Add-WDJournal -ItemId $Context.ItemId -Type 'winget' -Target $id -Status 'Removed' `
                          -Undo @{ method = 'reinstall'; name = $id }
        } elseif ($res.TimedOut) {
            $errors.Add("$id timed out")
        } else {
            $errors.Add("$id exit $($res.ExitCode)")
        }
    }

    if ($removed.Count) {
        return New-WDResult -Status Removed -Message "$($removed.Count) app(s) via winget" -Detail ($removed -join ', ')
    }
    if ($errors.Count) {
        return New-WDResult -Status Failed -Message 'winget uninstall failed' -Detail ($errors -join '; ')
    }
    if (-not $found) { return New-WDResult -Status NotPresent -Message 'Not installed' }
    New-WDResult -Status NotPresent -Message 'Nothing to remove'
}

# ------------------------------------------------------- classic MSI/EXE ---

function Clear-WDProgramCache {
    <#
        Drops the installed-programs sweep so the next caller reads the hives
        again.

        The cache expires on its own after 45 seconds, which is right for a run
        asking about twenty items in a row and wrong for the Refresh button: that
        one exists precisely because somebody has just installed or removed
        something, and "wait three quarters of a minute and press it again" is not
        an answer.
    #>
    $script:ProgramCache       = $null
    $script:ProgramCacheExpiry = [datetime]::MinValue
}

function Get-WDInstalledPrograms {
    <#  Cached sweep of both uninstall hives plus per-user.  #>
    if ($script:ProgramCache -and (Get-Date) -lt $script:ProgramCacheExpiry) { return $script:ProgramCache }

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $list = New-Object System.Collections.Generic.List[psobject]
    foreach ($root in $roots) {
        foreach ($sub in (Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.PSObject.Properties['DisplayName'] -or -not $p.DisplayName) { continue }
            $list.Add([pscustomobject]@{
                DisplayName     = [string]$p.DisplayName
                Publisher       = [string](Get-Prop $p 'Publisher' '')
                UninstallString = [string](Get-Prop $p 'UninstallString' '')
                QuietString     = [string](Get-Prop $p 'QuietUninstallString' '')
                DisplayIcon     = [string](Get-Prop $p 'DisplayIcon' '')
                InstallLocation = [string](Get-Prop $p 'InstallLocation' '')
                # Windows hides these from Add/Remove Programs: they are the
                # sub-features and bundle records of a product that has its own
                # visible entry. Kept on the record rather than filtered here,
                # because a curated manifest item is still allowed to name one.
                SystemComponent = [int](Get-Prop $p 'SystemComponent' 0)
                ParentName      = [string](Get-Prop $p 'ParentDisplayName' '')
                # What the installer claimed it would occupy, in KB. Roughly two
                # thirds of entries carry it and the rest report 0, so it is a
                # floor on what uninstalling frees rather than a measurement -
                # anything shown from it has to say "about".
                Bytes           = ([int64](Get-Prop $p 'EstimatedSize' 0)) * 1024
                KeyName         = $sub.PSChildName
            })
        }
    }
    $script:ProgramCache       = $list
    $script:ProgramCacheExpiry = (Get-Date).AddSeconds(45)
    $list
}

function Resolve-WDSilentUninstall {
    <#
        Work out how to run an uninstaller without a UI. QuietUninstallString
        is authoritative when the vendor provided it; otherwise infer from the
        installer technology, which is what the switches below identify.
    #>
    param($Program, [string]$SilentArgsOverride)

    if ($Program.QuietString) { return $Program.QuietString }

    $u = $Program.UninstallString
    if (-not $u) { return $null }

    # MSI products are the easy, fully reliable case.
    if ($u -match '\{[0-9A-Fa-f\-]{36}\}') {
        $guid = $Matches[0]
        return "msiexec.exe /x $guid /qn /norestart"
    }
    if ($SilentArgsOverride) { return "$u $SilentArgsOverride" }

    # Heuristics by installer family. Wrong guesses show a UI rather than
    # breaking anything, and the result is reported as Blocked on timeout.
    if ($u -match 'unins\d*\.exe')          { return "$u /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" }  # Inno
    if ($u -match 'Uninstall\.exe')         { return "$u /S" }                                        # NSIS
    if ($u -match 'setup\.exe|InstallShield'){ return "$u /S /v/qn" }                                 # InstallShield
    $null
}

function Invoke-WDUninstallAction {
    param($Action, $Context)

    $patterns  = @(Get-Prop $Action 'match' @())
    $exclude   = @(Get-Prop $Action 'exclude' @())
    $silentArg = Get-Prop $Action 'silentArgs' $null
    $timeout   = [int](Get-Prop $Action 'timeoutSeconds' 600)
    # Close what is holding the program open before asking its uninstaller to
    # remove it. On by default, because the alternative is the failure this was
    # written for: an uninstaller that exits non-zero because the application is
    # running, reported as "exit 1" with nothing saying why. An item can opt out
    # with "closeRunning": false where killing the process is worse than a failed
    # uninstall.
    $kill      = [bool](Get-Prop $Action 'closeRunning' $true)
    $killNamed = @(Get-Prop $Action 'processes' @())

    $programs = Get-WDInstalledPrograms
    $targets  = New-Object System.Collections.Generic.List[psobject]

    foreach ($p in $programs) {
        $hit = $false
        foreach ($pat in $patterns) {
            if ($p.DisplayName -like $pat) { $hit = $true; break }
        }
        if (-not $hit) { continue }
        $skip = $false
        foreach ($ex in $exclude) {
            if ($p.DisplayName -like $ex) { $skip = $true; break }
        }
        if (-not $skip) { $targets.Add($p) }
    }

    if (-not $targets.Count) { return New-WDResult -Status NotPresent -Message 'Not installed' }

    $removed = New-Object System.Collections.Generic.List[string]
    $failed  = New-Object System.Collections.Generic.List[string]
    $blocked = New-Object System.Collections.Generic.List[string]
    $retried = New-Object System.Collections.Generic.List[string]

    foreach ($t in $targets) {
        if ($Context.Preview) { $removed.Add($t.DisplayName); continue }

        # Two sources, because one of them is not enough on its own.
        #
        # Anything running out of the program's OWN folder is found by path. That
        # needs no authoring and covers the ordinary case - a game or an
        # application whose own executable is what holds its files.
        #
        # A launcher that lives somewhere else entirely has to be named, and that
        # is the case this exists for: Riot Client sits in C:\Riot Games\Riot
        # Client, not in Valorant's directory, and it is what stops Valorant
        # being removed. No amount of sweeping the target's folder finds it, so
        # an item carries a "processes" list for exactly this.
        #
        # An installer may have written a bare shared root into InstallLocation.
        # Sweeping that would kill every running program on the machine rather
        # than this one, so the path is checked before it is used, and a refusal
        # leaves the named half still working.
        $root = ''
        if ($kill) {
            $root = [string](Test-WDSweepableRoot -Path $t.InstallLocation)
            $null = Stop-WDBlockers -Path $root -AlsoNamed $killNamed `
                        -Because "$($t.DisplayName) could be uninstalled"
        }

        $cmd = Resolve-WDSilentUninstall -Program $t -SilentArgsOverride $silentArg
        if (-not $cmd) {
            # Not a failure. The program ships an interactive uninstaller and
            # there is no switch that makes it run quietly, so there is nothing
            # the toolkit can do here and nothing that went wrong. Blocked says
            # "refused, and here is what to do about it"; Failed says the
            # toolkit broke, which sends people looking for a bug.
            $blocked.Add("$($t.DisplayName): no silent uninstaller, so it has to be removed by hand from Installed apps")
            continue
        }

        # Split the resolved command into executable + arguments.
        $exe = $cmd; $args = ''
        if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $args = $Matches[2] }
        elseif ($cmd -match '^\s*(\S+\.exe)\s*(.*)$') { $exe = $Matches[1]; $args = $Matches[2] }

        $res = Invoke-WDProcess -FilePath $exe -ArgumentList @($args) -TimeoutSeconds $timeout

        # The refusal is the second place closing things earns its keep, and it
        # catches what the sweep before the attempt cannot: a launcher that
        # restarted itself, a helper the uninstaller started, or a process that
        # simply was not running yet when the first sweep went past.
        #
        # Only retried when this sweep actually closed something NEW. A second
        # identical run of an uninstaller that failed for some other reason is
        # ten more minutes of the same answer, and on an uninstaller that shows
        # UI it is a second dialog nobody asked for. A timeout is not retried at
        # all - the first one may still be working, and starting a second
        # uninstaller over the top of it is how a half-removed program happens.
        if ($kill -and -not $res.TimedOut -and $res.ExitCode -notin @(0, 3010, 1605)) {
            # ASSIGNED, NEVER WRAPPED IN @(). This is the site where it cost the
            # most: Stop-WDBlockers ends in ,@(...), so @() around its pipeline
            # output gave Count 1 whether it had closed anything or not, and
            # every uninstaller that exited non-zero was therefore run a SECOND
            # time - the doubled runtime, the second dialog on an uninstaller
            # that shows UI, and a log line reading "System.Object[] was closed
            # and it is being retried". All three are what the comment above
            # says this guard exists to prevent.
            $again = Stop-WDBlockers -Path $root -AlsoNamed $killNamed `
                         -Because "$($t.DisplayName) could be uninstalled on a second attempt"
            if ($again.Count) {
                # Say so while it happens. A second run of an uninstaller can
                # take minutes, and from the outside a step that has already
                # been going for one and is silently starting again looks like
                # a step that has hung.
                Write-WDLog ("$($t.DisplayName) refused the first attempt, so " +
                             "$($again -join ', ') " +
                             $(if ($again.Count -eq 1) { 'was' } else { 'were' }) +
                             ' closed and it is being retried.') -Level Info -Item $Context.ItemId
                $res = Invoke-WDProcess -FilePath $exe -ArgumentList @($args) -TimeoutSeconds $timeout
                if ($res.ExitCode -in @(0, 3010, 1605)) {
                    $retried.Add("$($t.DisplayName) (after closing $($again -join ', '))")
                }
            }
        }

        # 3010 = success, reboot required. 1605 = already gone.
        if ($res.ExitCode -in @(0, 3010, 1605)) {
            $removed.Add($t.DisplayName)
            if ($res.ExitCode -eq 3010) { Set-WDRebootNeeded }
            Add-WDJournal -ItemId $Context.ItemId -Type 'uninstall' -Target $t.DisplayName `
                          -Status 'Removed' -Undo @{ method = 'reinstall'; name = $t.DisplayName }
            # The uninstall key goes with the program, and InstallLocation with
            # it, so the leftover sweep cannot look this up afterwards. Recorded
            # here, while the program still exists, or not at all.
            Register-WDUninstalled -Name $t.DisplayName -InstallLocation $t.InstallLocation
        } elseif ($res.TimedOut) {
            $failed.Add("$($t.DisplayName): uninstaller did not exit (may need manual removal)")
        } else {
            $failed.Add("$($t.DisplayName): exit $($res.ExitCode)")
        }
    }

    if ($removed.Count -and -not $failed.Count -and -not $blocked.Count) {
        $rec = ''
        if ($retried.Count) { $rec = 'the first attempt was refused; it worked once ' + ($retried -join '; ') }
        return New-WDResult -Status Removed -Message "$($removed.Count) program(s)" -Detail ($removed -join ', ') -Recovered $rec
    }
    if ($removed.Count) {
        $rest = @($failed) + @($blocked)
        return New-WDResult -Status Partial -Message "$($removed.Count) removed, $($rest.Count) needs attention" -Detail (($removed -join ', ') + ' | ' + ($rest -join '; '))
    }
    # Nothing removed. An interactive-only uninstaller is a refusal with a clear
    # next step, not a fault, so it must not be filed beside a broken run.
    if ($blocked.Count -and -not $failed.Count) {
        return New-WDResult -Status Blocked -Message 'Needs to be uninstalled by hand' -Detail ($blocked -join '; ')
    }
    New-WDResult -Status Failed -Message 'Uninstall failed' -Detail ((@($failed) + @($blocked)) -join '; ')
}

# ---------------------------------------------------------- registry -------

$script:RegProbeCache = $null

function Clear-WDRegistryProbeCache {
    <#  Dropped whenever something might have written to the registry.  #>
    $script:RegProbeCache = $null
}

function Get-WDRegistryKeyValues {
    <#
        Every value under one key, read once and kept.

        The "already set" probe runs for every value of every opt-in item while
        the window is being built - several hundred reads, and it was paying a
        Test-Path plus a per-value Get-ItemProperty for each one. Items share
        keys heavily (a dozen Explorer tweaks all live under Advanced), so one
        read per key answers most of them.

        $null means the key does not exist, and that is cached too - a missing
        key was costing a Test-Path every time somebody asked about it.
    #>
    param([string]$Full)

    if ($null -eq $script:RegProbeCache) {
        $script:RegProbeCache = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    }
    $hit = $null
    if ($script:RegProbeCache.TryGetValue($Full, [ref]$hit)) { return $hit }

    $v = $null
    if (Test-Path -LiteralPath $Full) { $v = Get-ItemProperty -LiteralPath $Full -ErrorAction SilentlyContinue }
    $script:RegProbeCache[$Full] = $v
    $v
}

function Test-WDRegistryValueSet {
    <#
        One value, one hive: is it already what the action would write?

        The TYPE has to agree as well as the number, and that is not fussiness.
        Get-ItemProperty hands back whatever .NET type the value is stored as,
        so a policy written as REG_SZ "1" where this action wants a REG_DWORD 1
        compares equal after a cast and is a different value as far as Windows
        is concerned - the thing reading it looks for a DWORD and finds none.
        Answering "already set" there would gray out the row that fixes it, and
        (since the executor now asks this same question) skip the write that
        fixes it.

        The type check is a cast test rather than a call to GetValueKind,
        because the value is already in hand: one property read answers both
        halves and GetValueKind would be a second trip to the registry for
        every value of every opt-in item while the window is being built.

        REG_EXPAND_SZ is the one case that always answers false: Get-ItemProperty
        returns it expanded, so "%SystemRoot%\x" never equals "C:\Windows\x" and
        the action is reported as outstanding. That is the safe direction - it
        writes a value that was already correct - and it is not worth a second
        read of every string value on the machine to sharpen.
    #>
    param([string]$Full, [string]$Name, $Data, [string]$Kind, [bool]$Delete)

    $existing = Get-WDRegistryKeyValues -Full $Full
    if ($null -eq $existing) { return [bool]$Delete }
    $present  = [bool]$existing.PSObject.Properties[$Name]
    if ($Delete)      { return -not $present }
    if (-not $present) { return $false }

    $cur = $existing.$Name
    switch ($Kind) {
        'Binary'      {
            if ($cur -isnot [byte[]]) { return $false }
            return -not (Compare-Object @([byte[]]$cur) @([byte[]]$Data) -SyncWindow 0)
        }
        'MultiString' {
            if ($cur -isnot [string[]]) { return $false }
            return -not (Compare-Object @([string[]]$cur) @([string[]]$Data) -SyncWindow 0)
        }
        'DWord'       {
            if ($cur -isnot [int]) { return $false }
            return ([int64]$cur -eq [int64]$Data)
        }
        'QWord'       {
            if ($cur -isnot [long]) { return $false }
            return ([int64]$cur -eq [int64]$Data)
        }
        'ExpandString' { return $false }
        default       {
            if ($cur -isnot [string]) { return $false }
            return ([string]$cur -eq [string]$Data)
        }
    }
}

function Test-WDServiceActionSatisfied {
    <#
        Is every service this action names already where it would put it?

        Deliberately reads the same two fields Invoke-WDServiceAction compares -
        StartType, and Status when the action also stops the service - because a
        probe that asks a different question from the executor answers about a
        different machine.

        A pattern that matches nothing answers FALSE, and that is the careful
        direction rather than the obvious one. The executor would report
        NotPresent, which is a success, so "nothing to do" is arguable - but the
        tag this feeds says "already applied", and claiming a machine is already
        set up a certain way because the service was never on it is a different
        statement and not a true one. An item whose targets are genuinely absent
        is answered by Get-WDItemPresence, in those words.
    #>
    param($Action)

    $names = @(Get-Prop $Action 'names' @())
    if (-not $names.Count) { return $false }
    $target = [string](Get-Prop $Action 'startupType' 'Disabled')
    $stop   = [bool](Get-Prop $Action 'stop' $true)
    $found  = $false
    foreach ($pattern in $names) {
        $svcs = @(Get-Service -Name $pattern -ErrorAction SilentlyContinue)
        foreach ($svc in $svcs) {
            $found = $true
            $cur = $null
            try { $cur = [string]$svc.StartType } catch { }
            if ($cur -ne $target) { return $false }
            if ($stop -and $svc.Status -eq 'Running') { return $false }
        }
    }
    $found
}

function Test-WDRegistryActionSatisfied {
    <#
        Is every value this action would write already written?

        Mirrors Invoke-WDRegistryAction's path resolution deliberately - a test
        that resolves paths differently from the executor answers a different
        question and is worse than no test at all.

        For 'allusers' this asks about the accounts that exist on the machine
        now. The executor also writes the default profile hive so accounts made
        later inherit the setting, and that cannot be checked from here; an item
        reported as already set may still have that one write left to do.
    #>
    param($Action)

    $values = @(Get-Prop $Action 'values' @())
    if (-not $values.Count) { return $false }
    $scope = [string](Get-Prop $Action 'scope' 'machine')

    # Cached: this runs for every value of every opt-in item while the window is
    # being built, and enumerating HKU each time cost two seconds of startup.
    # Hives do not appear and disappear mid-session.
    if ($scope -ieq 'allusers' -and -not $script:HiveCache) { $script:HiveCache = @(Get-WDUserHives) }
    $roots = switch ($scope.ToLower()) {
        'user'     { @([pscustomobject]@{ Path = 'HKCU:' }) }
        'allusers' { $script:HiveCache }
        default    { @([pscustomobject]@{ Path = 'HKLM:' }) }
    }
    if (-not @($roots).Count) { return $false }

    foreach ($root in $roots) {
        foreach ($v in $values) {
            $rel = [string](Get-Prop $v 'path' '')
            if (-not $rel) { continue }
            $full = $(if ($scope -ieq 'allusers') { Join-Path $root.Path $rel } else { $rel })
            $ok = Test-WDRegistryValueSet -Full $full `
                                          -Name ([string](Get-Prop $v 'name' '')) `
                                          -Data (Get-Prop $v 'value' 0) `
                                          -Kind ([string](Get-Prop $v 'kind' 'DWord')) `
                                          -Delete ([bool](Get-Prop $v 'delete' $false))
            if (-not $ok) { return $false }
        }
    }
    $true
}

function Invoke-WDRegistryAction {
    param($Action, $Context)

    $scope   = [string](Get-Prop $Action 'scope' 'machine')
    $values  = @(Get-Prop $Action 'values' @())
    $written = 0; $errors = New-Object System.Collections.Generic.List[string]
    # Values that are already exactly what this would write. Counted, never
    # written, and reported as a distinct outcome.
    #
    # The preview path used to be `if ($Context.Preview) { $written++; continue }`
    # - every value counted as a change without the value ever being read. So a
    # preview of a selection that had just been applied to this machine reported
    # a hundred and twenty-one items to change, all of which were already true,
    # which is exactly the noise that teaches somebody to stop reading previews.
    #
    # Asked in apply too, not only in preview. Two reasons, and the second is
    # the load-bearing one: writing a value that already holds it is work and a
    # journal entry for nothing, and - if preview and apply asked different
    # questions - a page of grey rows would turn green the moment somebody
    # pressed the button, which is worse than either answer on its own.
    $already = 0

    # Build the list of hive roots this action applies to.
    $roots = @()
    switch ($scope.ToLower()) {
        'machine'  { $roots = @([pscustomobject]@{ Name = 'HKLM'; Path = 'HKLM:' }) }
        'user'     { $roots = @([pscustomobject]@{ Name = 'HKCU'; Path = 'HKCU:' }) }
        # The one scope with a choice in it: which accounts' hives get written.
        # HKLM has no per-account version and never will, so nothing else here
        # takes an Accounts list. A null list means every account, which is what
        # the command line and the re-apply guards pass.
        'allusers' {
            $roots = @(Select-WDAccountHives -Hives (Get-WDUserHives) -Default $Context.DefaultHive `
                                             -Accounts (Get-WDContextAccounts $Context))
        }
        default    { $roots = @([pscustomobject]@{ Name = 'HKLM'; Path = 'HKLM:' }) }
    }

    foreach ($root in $roots) {
        foreach ($v in $values) {
            $rel  = [string](Get-Prop $v 'path' '')
            $name = [string](Get-Prop $v 'name' '')
            $kind = [string](Get-Prop $v 'kind' 'DWord')
            $data = Get-Prop $v 'value' 0
            $del  = [bool](Get-Prop $v 'delete' $false)
            if (-not $rel) { continue }

            # 'machine'/'user' entries carry a full path; per-hive entries are relative.
            $full = $rel
            if ($scope -ieq 'allusers') { $full = Join-Path $root.Path $rel }

            try {
                # Read before deciding, in both modes. Test-WDRegistryValueSet
                # is the same function that grays an "already set" row on the
                # Advanced page, deliberately: a preview that answered this
                # question differently from the page above it would be a third
                # opinion nobody asked for.
                if (Test-WDRegistryValueSet -Full $full -Name $name -Data $data -Kind $kind -Delete $del) {
                    $already++
                    continue
                }
                if ($Context.Preview) { $written++; continue }

                Backup-WDRegistryKey -Path $full

                # This key is about to change, so anything the probe cache says
                # about it stops being true here rather than at the end of the
                # run. Cheap: it is one dictionary clear, and the cache exists
                # to make the window build fast, not to make a run fast.
                Clear-WDRegistryProbeCache

                # The value, not a rendering of it. This used to wrap a string
                # in single quotes here, so the journal held a PowerShell
                # literal that Export-WDUndoScript then interpolated unquoted -
                # which put the escaping in the one place nothing could check it.
                # A previous value containing an apostrophe produced a rollback
                # script that stopped parsing at that line; a MultiString one
                # came out as the text "System.String[]"; and Get-WDUndoStatus,
                # comparing "'Allow'" against the machine's Allow, reported
                # every string value as still outstanding after a rollback that
                # had already put it back. Rendering belongs to the emitter, and
                # `raw` is what tells it this entry holds a value.
                $prev = '__ABSENT__'
                if (Test-Path -LiteralPath $full) {
                    $existing = Get-ItemProperty -LiteralPath $full -Name $name -ErrorAction SilentlyContinue
                    if ($existing -and $existing.PSObject.Properties[$name]) { $prev = $existing.$name }
                }

                if ($del) {
                    if ($prev -ne '__ABSENT__') {
                        Remove-ItemProperty -LiteralPath $full -Name $name -Force -ErrorAction Stop
                        $written++
                    }
                } else {
                    if (-not (Test-Path -LiteralPath $full)) { $null = New-Item -Path $full -Force -ErrorAction Stop }
                    Set-ItemProperty -LiteralPath $full -Name $name -Value $data -Type $kind -Force -ErrorAction Stop
                    $written++
                }

                Add-WDJournal -ItemId $Context.ItemId -Type 'registry' -Target "$full\$name" -Status 'Changed' `
                              -Undo @{ method = 'registry'; path = $full; name = $name; previous = $prev; kind = $kind; raw = $true }
            } catch {
                # Policy keys under TrustedInstaller ownership refuse writes even
                # to an administrator. Seizing the key and retrying is reliable.
                $retried = $false
                if ((Get-Prop $Context 'AllowOwnership' $false) -and (Test-WDElevationError $_.Exception.Message)) {
                    $own = Grant-WDRegistryOwnership -Path $full
                    if ($own.Success) {
                        Add-WDJournal -ItemId $Context.ItemId -Type 'ownership' -Target $full -Status 'Changed' `
                                      -Undo @{ method = 'owner'; path = $full; previous = $own.PreviousOwner }
                        try {
                            if ($del) { Remove-ItemProperty -LiteralPath $full -Name $name -Force -ErrorAction Stop }
                            else      { Set-ItemProperty -LiteralPath $full -Name $name -Value $data -Type $kind -Force -ErrorAction Stop }
                            $written++; $retried = $true
                            Add-WDJournal -ItemId $Context.ItemId -Type 'registry' -Target "$full\$name" -Status 'Changed' `
                                          -Undo @{ method = 'registry'; path = $full; name = $name; previous = $prev; kind = $kind; raw = $true }
                        } catch { }
                    }
                }
                if (-not $retried) { $errors.Add("$full\$name : $($_.Exception.Message)") }
            }
        }
    }

    if ($written -and -not $errors.Count) {
        # What was skipped is said, because "3 value(s) set" on an action that
        # holds twelve reads as though nine went missing.
        $rest = $(if ($already) { ", $already already set" } else { '' })
        return New-WDResult -Status Changed -Message "$written value(s) set$rest"
    }

    # Some landed and some were refused. That is Partial, not Changed - it said
    # "2 set, 2 refused" in its own message while reporting success, so the item
    # never reached the run report's not-clean count and nobody saw it.
    if ($written) {
        return New-WDResult -Status Partial -Message "$written set, $($errors.Count) refused" -Detail ($errors -join '; ')
    }

    # Nothing landed. Refused by Windows is Blocked; anything else is Failed.
    if ($errors.Count) {
        $allRefusals = $true
        foreach ($e in $errors) { if (-not (Test-WDElevationError -Message $e)) { $allRefusals = $false; break } }
        if ($allRefusals) {
            return New-WDResult -Status Blocked -Message 'Registry write refused' -Detail ($errors -join '; ')
        }
        return New-WDResult -Status Failed -Message 'Registry write failed' -Detail ($errors -join '; ')
    }
    # Nothing to write because it is all already written. Distinct from
    # NotPresent, which is about a target that is not here at all.
    if ($already) {
        return New-WDResult -Status AlreadySet -Message "$already value(s) already set"
    }
    New-WDResult -Status NotPresent -Message 'Nothing to change'
}

function Invoke-WDRegistryKeyAction {
    <#  Delete whole keys - used for Explorer namespace CLSIDs and similar.  #>
    param($Action, $Context)

    $paths   = @(Get-Prop $Action 'paths' @())
    $deleted = 0; $errors = New-Object System.Collections.Generic.List[string]

    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if ($Context.Preview) { $deleted++; continue }
        try {
            $backup = Backup-WDRegistryKey -Path $p
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            $deleted++
            Add-WDJournal -ItemId $Context.ItemId -Type 'registry-key' -Target $p -Status 'Removed' `
                          -Undo @{ method = 'regfile'; file = $backup }
        } catch {
            $errors.Add("$p : $($_.Exception.Message)")
        }
    }

    if ($deleted) { return New-WDResult -Status Removed -Message "$deleted key(s) removed" }
    if ($errors.Count) { return New-WDResult -Status Blocked -Message 'Key removal refused' -Detail ($errors -join '; ') }
    New-WDResult -Status NotPresent -Message 'Keys not present'
}

# ----------------------------------------------------------- services ------

function Invoke-WDServiceAction {
    param($Action, $Context)

    $names   = @(Get-Prop $Action 'names' @())
    $target  = [string](Get-Prop $Action 'startupType' 'Disabled')
    $stop    = [bool](Get-Prop $Action 'stop' $true)
    # Same opt-out as everywhere else that closes something.
    $kill    = [bool](Get-Prop $Action 'closeRunning' $true)
    $changed = New-Object System.Collections.Generic.List[string]
    $blocked = New-Object System.Collections.Generic.List[string]
    # Services already at the startup type this would set, and not running.
    # Apply has always skipped these - the `$prev -eq $target` line below - and
    # said nothing about it; preview counted every one of them as a change.
    $already = New-Object System.Collections.Generic.List[string]
    # Services on WD.Core's critical list, which nothing in a manifest may
    # override. Its own bucket rather than $blocked, because Blocked means
    # Windows was asked and said no, and here the toolkit did not ask.
    $refused = New-Object System.Collections.Generic.List[string]
    $found   = $false

    foreach ($pattern in $names) {
        $svcs = @(Get-Service -Name $pattern -ErrorAction SilentlyContinue)
        foreach ($svc in $svcs) {
            $found = $true
            # THE ONE THING NO OPTION GETS TO DO. Asked here, on the resolved
            # service name, so a wildcard in a manifest cannot reach one of
            # these by accident - 'Xbox*' is matched against the machine before
            # anything arrives at this line.
            #
            # Refused in preview as well as in apply, and that half is
            # load-bearing: a preview promising to disable a service the apply
            # will refuse is a preview that stops being worth reading, which is
            # the same argument AlreadySet exists under.
            if (Test-WDCriticalService -Name $svc.Name) {
                $refused.Add($svc.Name)
                Write-WDLog ("Refused to change $($svc.Name): it is on the toolkit's critical-service " +
                             'list. Disabling it leaves the machine unable to reach a desktop, be ' +
                             'patched, or defend itself, so no option may override it.') `
                            -Level Warn -Item $Context.ItemId
                continue
            }
            if ($Context.Preview) {
                # ServiceController carries StartType on .NET 4.6.1 and above,
                # which is every machine this runs on, and it is already in hand.
                # The CIM query the apply path uses costs tens of milliseconds
                # per service and there are enough service actions in the
                # manifest to make that seconds of a preview - and the apply
                # path needs the CIM record anyway, for the process id.
                #
                # A StartType this cannot read is $null, compares unequal, and
                # is reported as a change. That is the safe direction.
                $cur = $null
                try { $cur = [string]$svc.StartType } catch { }
                if ($cur -eq $target -and $svc.Status -ne 'Running') { $already.Add($svc.Name) }
                else { $changed.Add($svc.Name) }
                continue
            }

            $prev = 'Automatic'
            # Cleared each time round, or a service whose query fails inherits
            # the previous service's process id and gets it killed.
            $wmi  = $null
            try {
                $wmi = Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
                if ($wmi) {
                    $prev = switch ($wmi.StartMode) {
                        'Auto'     { 'Automatic' }
                        'Manual'   { 'Manual' }
                        'Disabled' { 'Disabled' }
                        default    { 'Manual' }
                    }
                }
            } catch { }

            if ($prev -eq $target -and $svc.Status -ne 'Running') { $already.Add($svc.Name); continue }

            try {
                if ($stop -and $svc.Status -eq 'Running') {
                    Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue

                    # A service that refuses to stop is the stubborn case here,
                    # and the startup type alone does not answer it: Disabled
                    # takes effect at the next boot, so until then the thing the
                    # operator ticked a row to stop is still running and still
                    # doing it. Closing its process is the same answer the
                    # uninstaller and the file sweep give, under the same switch.
                    #
                    # Never a shared host. Most of the services on the machine
                    # run inside one svchost.exe, so killing it to stop one of
                    # them takes the others with it - which is not a trade this
                    # gets to make on somebody's behalf.
                    if ($kill) {
                        try { $svc.Refresh() } catch { }
                        if ($svc.Status -eq 'Running' -and $wmi -and
                            [int]$wmi.ProcessId -gt 4 -and
                            [string]$wmi.PathName -notmatch 'svchost\.exe') {
                            try {
                                Stop-Process -Id ([int]$wmi.ProcessId) -Force -ErrorAction Stop
                                Write-WDLog "Closed $($svc.Name) (pid $($wmi.ProcessId)); it refused to stop." -Level Info
                            } catch { }
                        }
                    }
                }
                Set-Service -Name $svc.Name -StartupType $target -ErrorAction Stop
                $changed.Add($svc.Name)
                Add-WDJournal -ItemId $Context.ItemId -Type 'service' -Target $svc.Name -Status 'Changed' `
                              -Undo @{ method = 'service'; name = $svc.Name; previous = $prev }
            } catch {
                # Several telemetry services are ACL-locked to TrustedInstaller.
                # sc.exe config sometimes succeeds where Set-Service does not.
                $sc = Invoke-WDProcess -FilePath 'sc.exe' -ArgumentList @('config', $svc.Name, "start=$(if($target -eq 'Disabled'){'disabled'}elseif($target -eq 'Manual'){'demand'}else{'auto'})") -TimeoutSeconds 30
                if ($sc.ExitCode -eq 0) {
                    $changed.Add($svc.Name)
                    Add-WDJournal -ItemId $Context.ItemId -Type 'service' -Target $svc.Name -Status 'Changed' `
                                  -Undo @{ method = 'service'; name = $svc.Name; previous = $prev }
                } elseif (Get-Prop $Context 'AllowOwnership' $false) {
                    # Last resort: the service's configuration lives in a registry
                    # key owned by TrustedInstaller. Seizing it and retrying is
                    # the standard fix, and it genuinely works here - unlike on
                    # non-removable Appx packages, which are refused by the
                    # deployment stack rather than by an ACL.
                    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)"
                    $own = Grant-WDRegistryOwnership -Path $key
                    if ($own.Success) {
                        Add-WDJournal -ItemId $Context.ItemId -Type 'ownership' -Target $key -Status 'Changed' `
                                      -Undo @{ method = 'owner'; path = $key; previous = $own.PreviousOwner }
                        try {
                            Set-Service -Name $svc.Name -StartupType $target -ErrorAction Stop
                            $changed.Add("$($svc.Name) (after taking ownership)")
                            Add-WDJournal -ItemId $Context.ItemId -Type 'service' -Target $svc.Name -Status 'Changed' `
                                          -Undo @{ method = 'service'; name = $svc.Name; previous = $prev }
                        } catch {
                            $blocked.Add("$($svc.Name) (still refused after taking ownership)")
                        }
                    } else {
                        $blocked.Add("$($svc.Name) (ownership takeover failed: $($own.Error))")
                    }
                } else {
                    $blocked.Add("$($svc.Name) (locked; enable take ownership to retry)")
                }
            }
        }
    }

    if ($changed.Count) {
        $d = ($changed -join ', ')
        if ($blocked.Count) { $d += " (locked: $($blocked -join ', '))" }
        if ($already.Count) { $d += " (already $($target.ToLower()): $($already -join ', '))" }
        if ($refused.Count) { $d += " (kept, critical to Windows: $($refused -join ', '))" }
        return New-WDResult -Status Changed -Message "$($changed.Count) service(s) -> $target" -Detail $d
    }
    if ($blocked.Count) { return New-WDResult -Status Blocked -Message 'Protected by Windows' -Detail ($blocked -join ', ') }
    # Skipped rather than Blocked, for the reason a NonRemovable package is:
    # Blocked should mean "refused, and you might be able to do something about
    # it", and there is nothing to do about this one by design.
    if ($refused.Count) {
        return New-WDResult -Status Skipped `
                            -Message "$($refused.Count) service(s) kept - critical to Windows" `
                            -Detail (($refused -join ', ') +
                                     '. These are on the toolkit''s critical-service list: disabling them ' +
                                     'leaves the machine unable to reach a desktop, be patched, or defend itself.')
    }
    if (-not $found)    { return New-WDResult -Status NotPresent -Message 'Service not present' }
    # The service is here and is already set the way this asks for. That was
    # NotPresent with a message contradicting its own status, which nothing
    # reads and no count could tell apart from a service that is not installed.
    New-WDResult -Status AlreadySet -Message "$($already.Count) service(s) already $target" -Detail ($already -join ', ')
}

# ------------------------------------------------------ scheduled tasks ----

function Invoke-WDTaskAction {
    param($Action, $Context)

    $tasks   = @(Get-Prop $Action 'tasks' @())
    $delete  = [bool](Get-Prop $Action 'delete' $false)
    $changed = New-Object System.Collections.Generic.List[string]
    $blocked = New-Object System.Collections.Generic.List[string]
    # Tasks that are already disabled. This branch existed and simply skipped;
    # counting it is what lets the row say nothing to do rather than not present.
    $already = New-Object System.Collections.Generic.List[string]
    $found   = $false

    foreach ($spec in $tasks) {
        # Accept "\Path\Name" or "\Path\*".
        $path = Split-Path $spec -Parent
        $name = Split-Path $spec -Leaf
        if (-not $path.EndsWith('\')) { $path = "$path\" }

        $matched = @()
        try {
            $matched = @(Get-ScheduledTask -TaskPath $path -ErrorAction SilentlyContinue |
                         Where-Object { $_.TaskName -like $name })
        } catch { }

        foreach ($t in $matched) {
            $found = $true
            if ($t.State -eq 'Disabled' -and -not $delete) { $already.Add($t.TaskName); continue }
            if ($Context.Preview) { $changed.Add($t.TaskName); continue }

            try {
                if ($delete) {
                    Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
                } else {
                    $null = Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop
                }
                $changed.Add($t.TaskName)
                Add-WDJournal -ItemId $Context.ItemId -Type 'task' -Target "$($t.TaskPath)$($t.TaskName)" -Status 'Changed' `
                              -Undo @{ method = 'task'; path = $t.TaskPath; name = $t.TaskName }
            } catch {
                # A locked task's entry in TaskCache is TrustedInstaller-owned.
                $done = $false
                if (Get-Prop $Context 'AllowOwnership' $false) {
                    $tree = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree' +
                            ($t.TaskPath.TrimEnd('\')) + '\' + $t.TaskName
                    $own = Grant-WDRegistryOwnership -Path $tree
                    if ($own.Success) {
                        Add-WDJournal -ItemId $Context.ItemId -Type 'ownership' -Target $tree -Status 'Changed' `
                                      -Undo @{ method = 'owner'; path = $tree; previous = $own.PreviousOwner }
                        try {
                            if ($delete) { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop }
                            else         { $null = Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop }
                            $changed.Add("$($t.TaskName) (after taking ownership)")
                            $done = $true
                            Add-WDJournal -ItemId $Context.ItemId -Type 'task' -Target "$($t.TaskPath)$($t.TaskName)" -Status 'Changed' `
                                          -Undo @{ method = 'task'; path = $t.TaskPath; name = $t.TaskName }
                        } catch { }
                    }
                }
                if (-not $done) { $blocked.Add($t.TaskName) }
            }
        }
    }

    if ($changed.Count) {
        $d = ($changed -join ', ')
        if ($blocked.Count) { $d += " (locked: $($blocked -join ', '))" }
        if ($already.Count) { $d += " (already disabled: $($already -join ', '))" }
        return New-WDResult -Status Changed -Message "$($changed.Count) task(s) disabled" -Detail $d
    }
    if ($blocked.Count) { return New-WDResult -Status Blocked -Message 'Task protected' -Detail ($blocked -join ', ') }
    if (-not $found)    { return New-WDResult -Status NotPresent -Message 'Task not present' }
    New-WDResult -Status AlreadySet -Message "$($already.Count) task(s) already disabled" -Detail ($already -join ', ')
}

# --------------------------------------------- optional features / caps ----

function Invoke-WDFeatureAction {
    <#
        Both directions. "mode": "enable" turns a feature on instead of off,
        which is how the optional-feature install rows work - .NET 3.5, Sandbox,
        Hyper-V, WSL. The direction is recorded in the journal rather than left
        for the rollback to infer from the feature's state, because by then the
        state is whatever this run made it.

        -All on the way up, because Sandbox and WSL both sit under a parent
        feature and enabling the leaf on its own fails with a bare 0x800f080c.
    #>
    param($Action, $Context)

    $names   = @(Get-Prop $Action 'names' @())
    $enable  = ([string](Get-Prop $Action 'mode' 'remove') -ieq 'enable')
    $changed = New-Object System.Collections.Generic.List[string]
    $errors  = New-Object System.Collections.Generic.List[string]
    $found   = $false

    foreach ($n in $names) {
        $f = $null
        try { $f = Get-WindowsOptionalFeature -Online -FeatureName $n -ErrorAction SilentlyContinue } catch { }
        if (-not $f) { continue }
        $found = $true
        if ($enable) { if ($f.State -eq 'Enabled') { continue } }
        else         { if ($f.State -ne 'Enabled') { continue } }
        if ($Context.Preview) { $changed.Add($n); continue }

        try {
            if ($enable) {
                $r = Enable-WindowsOptionalFeature -Online -FeatureName $n -All -NoRestart -ErrorAction Stop
                $changed.Add($n)
                if ($r -and $r.RestartNeeded) { Set-WDRebootNeeded }
                Add-WDJournal -ItemId $Context.ItemId -Type 'feature' -Target $n -Status 'Changed' `
                              -Undo @{ method = 'feature-off'; name = $n }
            } else {
                $r = Disable-WindowsOptionalFeature -Online -FeatureName $n -NoRestart -ErrorAction Stop
                $changed.Add($n)
                if ($r -and $r.RestartNeeded) { Set-WDRebootNeeded }
                Add-WDJournal -ItemId $Context.ItemId -Type 'feature' -Target $n -Status 'Removed' `
                              -Undo @{ method = 'feature'; name = $n }
            }
        } catch {
            $errors.Add("$n : $($_.Exception.Message)")
        }
    }

    if ($enable) {
        if ($changed.Count) { return New-WDResult -Status Changed -Message "$($changed.Count) feature(s) enabled" -Detail ($changed -join ', ') -Reboot }
        if ($errors.Count)  { return New-WDResult -Status Failed -Message 'Feature could not be enabled' -Detail ($errors -join '; ') }
        if (-not $found)    { return New-WDResult -Status NotPresent -Message 'Feature not offered on this build' }
        return New-WDResult -Status AlreadySet -Message 'Already enabled'
    }

    if ($changed.Count) { return New-WDResult -Status Removed -Message "$($changed.Count) feature(s)" -Detail ($changed -join ', ') -Reboot }
    if ($errors.Count)  { return New-WDResult -Status Failed -Message 'Feature removal failed' -Detail ($errors -join '; ') }
    if (-not $found)    { return New-WDResult -Status NotPresent -Message 'Feature not present on this build' }
    New-WDResult -Status AlreadySet -Message 'Already disabled'
}

function Invoke-WDCapabilityAction {
    <#  "mode": "install" is the enabling direction, as on features above.  #>
    param($Action, $Context)

    $names   = @(Get-Prop $Action 'names' @())
    $install = ([string](Get-Prop $Action 'mode' 'remove') -ieq 'install')
    $changed = New-Object System.Collections.Generic.List[string]
    $errors  = New-Object System.Collections.Generic.List[string]
    $found   = $false

    foreach ($pattern in $names) {
        $caps = @()
        try { $caps = @(Get-WDCapabilityList | Where-Object { $_.Name -like $pattern }) } catch { }
        foreach ($c in $caps) {
            if ($install) { if ($c.State -eq 'Installed') { continue } }
            else          { if ($c.State -ne 'Installed') { continue } }
            $found = $true
            if ($Context.Preview) { $changed.Add($c.Name); continue }
            try {
                if ($install) {
                    $r = Add-WindowsCapability -Online -Name $c.Name -ErrorAction Stop
                    Clear-WDCapabilityCache
                    $changed.Add($c.Name)
                    if ($r -and $r.RestartNeeded) { Set-WDRebootNeeded }
                    Add-WDJournal -ItemId $Context.ItemId -Type 'capability' -Target $c.Name -Status 'Changed' `
                                  -Undo @{ method = 'capability-off'; name = $c.Name }
                } else {
                    $r = Remove-WindowsCapability -Online -Name $c.Name -ErrorAction Stop
                    Clear-WDCapabilityCache
                    $changed.Add($c.Name)
                    if ($r -and $r.RestartNeeded) { Set-WDRebootNeeded }
                    Add-WDJournal -ItemId $Context.ItemId -Type 'capability' -Target $c.Name -Status 'Removed' `
                                  -Undo @{ method = 'reinstall'; name = $c.Name }
                }
            } catch {
                $errors.Add("$($c.Name) : $($_.Exception.Message)")
            }
        }
    }

    if ($install) {
        if ($changed.Count) { return New-WDResult -Status Changed -Message "$($changed.Count) capability(ies) installed" -Detail ($changed -join ', ') }
        if ($errors.Count)  { return New-WDResult -Status Failed -Message 'Capability install failed' -Detail ($errors -join '; ') }
        return New-WDResult -Status AlreadySet -Message 'Already installed'
    }

    if ($changed.Count) { return New-WDResult -Status Removed -Message "$($changed.Count) capability(ies)" -Detail ($changed -join ', ') }
    if ($errors.Count)  { return New-WDResult -Status Blocked -Message 'Capability removal refused' -Detail ($errors -join '; ') }
    if (-not $found)    { return New-WDResult -Status NotPresent -Message 'Not installed' }
    New-WDResult -Status NotPresent -Message 'Nothing to remove'
}

# -------------------------------------------------------- files/shortcuts --

function Invoke-WDFileAction {
    param($Action, $Context)

    $paths   = @(Get-Prop $Action 'paths' @())
    # Opt-in per action. A hard delete cannot be journalled back, so anything
    # that removes a folder the operator might want again asks for the bin.
    $recycle = [bool](Get-Prop $Action 'recycle' $false)
    # Same opt-out as everywhere else that closes something.
    $kill    = [bool](Get-Prop $Action 'closeRunning' $true)
    $deleted = 0; $errors = New-Object System.Collections.Generic.List[string]

    # One attempt, so the retry after closing what held the folder open is the
    # same code as the first try rather than a second copy of it - three delete
    # routes and two chances at each is exactly where a copy drifts. Answers
    # with the error text or $null; the counting stays outside, because a
    # scriptblock invoked with & writes its own scope.
    $tryDelete = {
        param($Item)
        try {
            if ($recycle -and (Test-WDIrreversible)) {
                # The operator asked for no way back, so stop buying one.
                Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop
                Add-WDJournal -ItemId $Context.ItemId -Type 'file' -Target $Item.FullName -Status 'Removed' -Undo $null
            } elseif ($recycle) {
                # Refuse rather than quietly hard-delete: the whole point of
                # asking for the bin is that this is reversible, and
                # SHFileOperation reports success either way.
                if (-not (Test-WDRecycleAvailable -Path $Item.FullName)) {
                    return "$($Item.FullName) : no Recycle Bin on that volume, left in place"
                }
                if (-not (Remove-WDToRecycleBin -Path $Item.FullName)) {
                    return "$($Item.FullName) : could not be moved to the Recycle Bin"
                }
                Add-WDJournal -ItemId $Context.ItemId -Type 'file' -Target $Item.FullName -Status 'Removed' `
                              -Undo @{ method = 'recycle'; path = $Item.FullName }
            } else {
                Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop
                Add-WDJournal -ItemId $Context.ItemId -Type 'file' -Target $Item.FullName -Status 'Removed' -Undo $null
            }
        } catch {
            return "$($Item.FullName) : $($_.Exception.Message)"
        }
        $null
    }

    foreach ($raw in $paths) {
        $expanded = [Environment]::ExpandEnvironmentVariables($raw)
        $hits = @()
        try { $hits = @(Get-Item -Path $expanded -Force -ErrorAction SilentlyContinue) } catch { }
        foreach ($h in $hits) {
            if ($Context.Preview) { $deleted++; continue }

            $err = & $tryDelete $h

            # "In use or protected" is the one refusal here that something can
            # be done about, so it is asked a second time with whatever was
            # running out of the folder closed. Directories only, and only ones
            # specific enough to belong to one program: a locked single file is
            # usually a DLL loaded by a process living elsewhere, and the only
            # way to find that from a path is to guess at names, which is not a
            # thing to do with Stop-Process.
            if ($err -and $kill -and $h.PSIsContainer) {
                $under = [string](Test-WDSweepableRoot -Path $h.FullName)
                if ($under) {
                    # Assigned, never wrapped - see the appx and uninstall paths.
                    $shut = Stop-WDBlockers -Path $under -Because "$($h.FullName) could be deleted"
                    if ($shut.Count) { $err = & $tryDelete $h }
                }
            }

            if ($err) { $errors.Add($err) } else { $deleted++ }
        }
    }

    if ($deleted)      { return New-WDResult -Status Removed -Message "$deleted item(s) deleted" }
    if ($errors.Count) { return New-WDResult -Status Blocked -Message 'In use or protected' -Detail ($errors -join '; ') }
    New-WDResult -Status NotPresent -Message 'Nothing to delete'
}

function Invoke-WDShortcutAction {
    <#  Sweeps shortcut locations for planted links.

        `names` are BaseName wildcards; `exclude` patterns win over them.
        `locations` narrows the sweep to 'desktop' and/or 'startmenu' and
        defaults to both, which is what every earlier manifest entry expects.
        `recurse` defaults on for the same reason -- but a sweep that takes
        everything ("names": ["*"]) should switch it off, because a folder of
        shortcuts on somebody's desktop is something they organized, not
        something an installer planted. `recycle` mirrors the file action:
        journalled to the bin so a rollback can put the links back, refused
        when the volume has no bin, and a plain delete under irreversible
        mode.  #>
    param($Action, $Context)

    $names   = @(Get-Prop $Action 'names' @())
    $exclude = @(Get-Prop $Action 'exclude' @())
    $where   = @(Get-Prop $Action 'locations' @('desktop', 'startmenu'))
    $recurse = [bool](Get-Prop $Action 'recurse' $true)
    $recycle = [bool](Get-Prop $Action 'recycle' $false)

    $dirs = @()
    if ($where -contains 'desktop') {
        $dirs += @(
            [Environment]::GetFolderPath('CommonDesktopDirectory'),
            [Environment]::GetFolderPath('Desktop'),
            (Join-Path $env:PUBLIC 'Desktop')
        )
    }
    if ($where -contains 'startmenu') {
        $dirs += @(
            [Environment]::GetFolderPath('CommonStartMenu'),
            [Environment]::GetFolderPath('StartMenu')
        )
    }
    $dirs = @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
              Sort-Object -Unique)

    $deleted = New-Object System.Collections.Generic.List[string]
    $errors  = New-Object System.Collections.Generic.List[string]
    foreach ($d in $dirs) {
        $hits = @()
        try {
            # -File plus a Where rather than -Include: -Include silently
            # matches nothing without -Recurse, so a non-recursive sweep
            # written that way looks like an empty desktop.
            $hits = @(Get-ChildItem -LiteralPath $d -Recurse:$recurse -File -Force -ErrorAction SilentlyContinue |
                      Where-Object { $_.Extension -eq '.lnk' -or $_.Extension -eq '.url' })
        } catch { }
        foreach ($h in $hits) {
            $wanted = $false
            foreach ($pattern in $names) {
                if ($h.BaseName -like $pattern) { $wanted = $true; break }
            }
            foreach ($pattern in $exclude) {
                if ($h.BaseName -like $pattern) { $wanted = $false; break }
            }
            if (-not $wanted) { continue }
            if ($Context.Preview) { $deleted.Add($h.BaseName); continue }
            try {
                if ($recycle -and -not (Test-WDIrreversible)) {
                    # Refuse rather than quietly hard-delete, exactly as the
                    # file action does: SHFileOperation reports success
                    # whether or not the volume had a bin to catch it.
                    if (-not (Test-WDRecycleAvailable -Path $h.FullName)) {
                        $errors.Add("$($h.FullName) : no Recycle Bin on that volume, left in place")
                        continue
                    }
                    if (-not (Remove-WDToRecycleBin -Path $h.FullName)) {
                        $errors.Add("$($h.FullName) : could not be moved to the Recycle Bin")
                        continue
                    }
                    Add-WDJournal -ItemId $Context.ItemId -Type 'file' -Target $h.FullName -Status 'Removed' `
                                  -Undo @{ method = 'recycle'; path = $h.FullName }
                } else {
                    Remove-Item -LiteralPath $h.FullName -Force -ErrorAction Stop
                }
                $deleted.Add($h.BaseName)
            } catch {
                $errors.Add("$($h.FullName) : $($_.Exception.Message)")
            }
        }
    }

    if ($deleted.Count) { return New-WDResult -Status Removed -Message "$($deleted.Count) shortcut(s)" -Detail (($deleted | Sort-Object -Unique) -join ', ') }
    if ($errors.Count)  { return New-WDResult -Status Blocked -Message 'In use or protected' -Detail ($errors -join '; ') }
    New-WDResult -Status NotPresent -Message 'No matching shortcuts'
}

# ===================================================== symptom synonyms ====
#
# The lookup document is only worth as much as the phrase somebody happens to
# type, and nobody types the phrase that was authored. "app cannot see my name"
# is written down; what gets typed is "app can't see my name", "app doesnt see
# my name", "cant access account info". One missing spelling and the document
# answers nothing at all for that person, having been right the whole time.
#
# So the manifest carries SEEDS and this generates the rest. Generated rather
# than authored for the same reason Get-WDItemMechanics is: an authored list of
# a thousand contractions is a thousand things to keep in step with the phrases
# they came from, and the first item added after this is written would have
# none of them. Every item gets the same treatment, including one added
# tomorrow, and there is nothing to forget.
#
# Three families, applied in that order, most useful first:
#
#   TAILS   the phrase ends in a state word, so the rest of it is the subject
#           and the subject can be recast. "account info blocked" gives up
#           "account info", and out come "cannot access account info",
#           "account info access denied", "cannot view account info".
#   VERBS   a verb pair somewhere in the middle. "cannot see" also gets typed
#           as "does not see", "cannot find", "does not have".
#   SPELLING every contraction both ways, plus the apostrophe-free form. This
#           is the cheapest family and probably the most valuable: "cant",
#           "doesnt" and "wont" are what people actually type into a search box.
#
# All lower case, because Notepad's Find is case-sensitive only if you ask and
# the authored phrases are lower case already. Nothing over seventy characters:
# past that it is a sentence, and nobody searches with a sentence.

# The state word a phrase ends in, and what its subject can be recast as.
# {0} is the phrase with the tail removed.
$script:WDSymptomTails = [ordered]@{
    'not working' = @('{0} broken', '{0} stopped working', '{0} does not work',
                      '{0} not working anymore', '{0} no longer works', '{0} has stopped working')
    'not work'    = @('{0} does not work', '{0} broken', '{0} stopped working')
    'broken'      = @('{0} not working', '{0} stopped working', '{0} does not work', '{0} no longer works')
    'missing'     = @('no {0}', '{0} gone', '{0} disappeared', '{0} not there',
                      'where is {0}', 'where did {0} go', '{0} not showing')
    'gone'        = @('{0} missing', '{0} disappeared', 'no {0}', 'where is {0}', '{0} not there')
    'blocked'     = @('cannot access {0}', '{0} access denied', 'cannot view {0}',
                      'no access to {0}', '{0} not allowed', '{0} is blocked')
    'empty'       = @('{0} shows nothing', 'nothing in {0}', '{0} has nothing in it', '{0} is empty')
    'not found'   = @('cannot find {0}', '{0} missing', 'no {0} found', '{0} not detected')
    'not detected'= @('{0} not found', '{0} missing', 'cannot find {0}')
    'disabled'    = @('{0} turned off', '{0} is off', 'cannot enable {0}', '{0} switched off')
    'off'         = @('{0} turned off', '{0} switched off', '{0} disabled', 'cannot turn on {0}')
    'error'       = @('{0} not working', 'error with {0}', '{0} problem', '{0} keeps erroring')
    'slow'        = @('{0} very slow', '{0} is slow', '{0} taking ages', '{0} slower than before')
    'not showing' = @('{0} missing', '{0} does not show', '{0} not visible', 'no {0}')
    'not opening' = @('{0} will not open', '{0} does not open', 'cannot open {0}')
    'not loading' = @('{0} will not load', '{0} does not load', '{0} stuck loading')
    'stuck'       = @('{0} hangs', '{0} frozen', '{0} not responding')
    'crashing'    = @('{0} keeps crashing', '{0} closes on its own', '{0} crashes')
    'not syncing' = @('{0} does not sync', '{0} will not sync', '{0} stopped syncing', '{0} sync broken')
    'not saving'  = @('{0} does not save', '{0} will not save', '{0} stopped saving')
    'not updating'= @('{0} does not update', '{0} will not update', '{0} stopped updating')
    'not learning'= @('{0} does not learn', '{0} will not learn', '{0} stopped learning')
    'not responding' = @('{0} hangs', '{0} frozen', '{0} stuck')
    'came back'   = @('{0} keeps coming back', '{0} reappeared', '{0} is back', '{0} returned')
    'keeps coming back' = @('{0} came back', '{0} reappeared', '{0} is back again')
    'worse'       = @('{0} got worse', '{0} is worse', '{0} has got worse')
    'wrong'       = @('{0} is wrong', '{0} are wrong', '{0} incorrect')
    'bad'         = @('{0} is bad', '{0} poor', '{0} is terrible')
}

# The state word a phrase STARTS with. "no printers" and "no tips" are as
# common a shape as "printer missing", and without this eighty-two items in the
# manifest produced no variants at all - every one of them phrased as the
# absence somebody notices rather than as a thing that broke.
$script:WDSymptomLeads = [ordered]@{
    'no'      = @('{0} missing', '{0} gone', 'where is {0}', 'cannot find {0}', '{0} not there', '{0} disappeared')
    'missing' = @('no {0}', '{0} is missing', 'where is {0}')
    'lost'    = @('no {0}', '{0} missing', '{0} gone')
}

# A lead word that is really the start of a longer phrase, not a subject.
# "no longer works" would otherwise be recast as "longer works missing".
$script:WDSymptomNotSubjects = @('longer', 'more', 'idea', 'way')

# A subject cannot end in one of these. Two ways it goes wrong, and the first
# is the one that turned up in the manifest: "downloads not blocked" leaves the
# subject "downloads not", and every recast of it is a double negative -
# "downloads not not allowed", "cannot access downloads not". The phrase means
# the opposite of the tail it appears to end with, so there is nothing to
# recast. The second is a dangling preposition or article, which reads as a
# sentence somebody did not finish.
$script:WDSymptomDanglers = @(
    'not', 'no', 'never', 'is', 'are', 'was', 'were', 'be', 'been',
    'isnt', 'arent', 'wasnt', 'dont', 'doesnt', 'cant', 'cannot', 'wont',
    'in', 'on', 'of', 'to', 'for', 'with', 'and', 'or', 'the', 'a', 'an',
    'my', 'your', 'its', 'it', 'that', 'this', 'at', 'by', 'from')

# A verb pair anywhere in the phrase, and the other ways it gets typed.
# Longest key first: 'cannot sign in' has to be tried before 'cannot'.
$script:WDSymptomVerbs = [ordered]@{
    'cannot sign in' = @('cannot log in', 'cannot login', 'will not sign in', 'unable to sign in')
    'cannot connect' = @('will not connect', 'does not connect', 'cannot pair', 'unable to connect')
    'cannot access'  = @('cannot reach', 'cannot open', 'cannot use', 'has no access to', 'unable to access')
    'cannot see'     = @('does not see', 'cannot find', 'does not show', 'does not have', 'cannot view')
    'cannot read'    = @('does not read', 'cannot see', 'cannot access')
    'cannot find'    = @('cannot see', 'cannot locate', 'does not find', 'unable to find')
    'cannot open'    = @('will not open', 'cannot launch', 'does not open', 'unable to open')
    'cannot start'   = @('will not start', 'does not start', 'cannot launch')
    'cannot install' = @('will not install', 'install fails', 'unable to install')
    'cannot change'  = @('will not change', 'unable to change', 'cannot set')
    'not showing'    = @('does not show', 'no longer shows', 'not displaying')
    'never asks'     = @('does not ask', 'stopped asking', 'no longer asks')
    'missing from'   = @('not in', 'gone from', 'no longer in')
    # Spelled out per verb rather than as a bare 'no longer' -> 'does not'.
    # That shorter rule turned "no longer works" into "does not works", because
    # the verb has to lose its s and a substitution cannot know that.
    'no longer works' = @('does not work', 'stopped working', 'not working')
    'no longer opens' = @('does not open', 'will not open')
    'no longer shows' = @('does not show', 'stopped showing')
    'no longer syncs' = @('does not sync', 'stopped syncing')
    'will not'       = @('does not', 'wont', "won't", 'refuses to')
}

# Spelling, both ways, and the apostrophe-free form of each. Whole words only,
# so 'cant' inside 'cantilever' is left alone.
$script:WDSymptomSpellings = [ordered]@{
    'cannot'    = @("can't", 'cant', 'can not', 'unable to')
    "can't"     = @('cannot', 'cant')
    'cant'      = @('cannot', "can't")
    'does not'  = @("doesn't", 'doesnt')
    "doesn't"   = @('does not', 'doesnt')
    'doesnt'    = @('does not', "doesn't")
    'do not'    = @("don't", 'dont')
    "don't"     = @('do not', 'dont')
    'will not'  = @("won't", 'wont')
    "won't"     = @('will not', 'wont')
    'is not'    = @("isn't", 'isnt')
    "isn't"     = @('is not', 'isnt')
    'are not'   = @("aren't", 'arent')
    'did not'   = @("didn't", 'didnt')
    'pc'        = @('computer', 'laptop')
    'app'       = @('application', 'program')
}

function New-WDPhraseVariants {
    <#
        Other ways one authored phrase gets typed. Internal to the expansion
        below; nothing else should reach for it.

        Order matters and is by usefulness, because the caller caps the result:
        a recast subject finds somebody the authored phrase would have missed
        entirely, where a contraction only finds them if they were already
        close. Both are worth having and only one is worth having first.
    #>
    param([string]$Phrase)

    $out = New-Object System.Collections.Generic.List[string]
    $p = ([string]$Phrase).Trim().ToLower()
    if (-not $p) { return $out }

    # --- tails: the phrase ends in a state word, so the rest is the subject --
    foreach ($tail in $script:WDSymptomTails.Keys) {
        if (-not $p.EndsWith(" $tail")) { continue }
        $subject = $p.Substring(0, $p.Length - $tail.Length - 1).Trim()
        # A subject of one or two characters is not a subject - "is missing"
        # recast as "no is" is noise, and noise in a lookup file is the thing
        # that makes somebody stop trusting it.
        if ($subject.Length -lt 3) { break }
        $last = ($subject -split ' ')[-1]
        if ($script:WDSymptomDanglers -contains $last) { break }
        foreach ($form in $script:WDSymptomTails[$tail]) { $out.Add(($form -f $subject)) }
        # One tail only. "not working" and "not work" both match the same
        # phrase and the second recast would be built from a subject that
        # still has "ing" hanging off it.
        break
    }

    # --- leads: the phrase starts with the state word -----------------------
    foreach ($lead in $script:WDSymptomLeads.Keys) {
        if (-not $p.StartsWith("$lead ")) { continue }
        $subject = $p.Substring($lead.Length + 1).Trim()
        if ($subject.Length -lt 3) { break }
        # "no longer works" is not a missing thing called "longer works".
        $head = ($subject -split ' ')[0]
        if ($script:WDSymptomNotSubjects -contains $head) { break }
        foreach ($form in $script:WDSymptomLeads[$lead]) { $out.Add(($form -f $subject)) }
        break
    }

    # --- verbs: a pair somewhere in the middle ------------------------------
    foreach ($verb in $script:WDSymptomVerbs.Keys) {
        if ($p -notmatch "\b$([regex]::Escape($verb))\b") { continue }
        foreach ($alt in $script:WDSymptomVerbs[$verb]) {
            $out.Add(($p -replace "\b$([regex]::Escape($verb))\b", $alt))
        }
        break
    }

    # --- spelling, over the phrase and over everything produced so far ------
    #
    # Over the variants too, deliberately. "account info blocked" becomes
    # "cannot access account info" up there, and the person looking for it is
    # every bit as likely to type "cant access account info".
    $spellingSeed = New-Object System.Collections.Generic.List[string]
    $spellingSeed.Add($p)
    foreach ($v in $out) { $spellingSeed.Add($v) }

    $rows = New-Object 'System.Collections.Generic.List[string[]]'
    foreach ($base in $spellingSeed) {
        foreach ($word in $script:WDSymptomSpellings.Keys) {
            if ($base -notmatch "\b$([regex]::Escape($word))\b") { continue }
            $row = New-Object System.Collections.Generic.List[string]
            foreach ($alt in $script:WDSymptomSpellings[$word]) {
                $row.Add(($base -replace "\b$([regex]::Escape($word))\b", $alt))
            }
            $rows.Add($row.ToArray())
            # One spelling family per phrase. Crossing two of them produces
            # combinations nobody types and buries the ones they do.
            break
        }
    }

    # Interleaved, not base by base, because the caller caps the list. Taken in
    # order, every spelling of the authored phrase lands before the first
    # spelling of any recast one - so "app doesn't have my name" fell off the
    # end behind four ways of writing "app cannot see my name", which is the
    # wrong four to keep. One alternative from each row, then the next.
    $widest = 0
    foreach ($row in $rows) { if ($row.Count -gt $widest) { $widest = $row.Count } }
    for ($i = 0; $i -lt $widest; $i++) {
        foreach ($row in $rows) {
            if ($i -lt $row.Count) { $out.Add($row[$i]) }
        }
    }

    $out
}

function Expand-WDSymptoms {
    <#
        An item's authored lookup phrases, plus every other way they get typed.

        Authored phrases come first and are never dropped - they are what
        somebody wrote down on purpose, and a generator that reorders them is
        a generator that has an opinion it has not earned.

        Emitted unrolled with no leading comma. Every caller wraps in @(), so
        the comma form would hand them one element holding the whole array -
        the trap this repo has hit from both directions.
    #>
    param([string[]]$Phrases, [int]$PerPhrase = 12)

    $out  = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $add = {
        param([string]$Text)
        $t = ([string]$Text).Trim()
        # The same floor and ceiling the self test holds the authored phrases
        # to. Under four characters is not a search; over seventy is a sentence.
        if ($t.Length -lt 4 -or $t.Length -gt 70) { return }
        if (-not $seen.Add($t)) { return }
        $out.Add($t)
    }

    foreach ($p in @($Phrases)) { & $add $p }
    foreach ($p in @($Phrases)) {
        $n = 0
        foreach ($v in (New-WDPhraseVariants -Phrase $p)) {
            if ($n -ge $PerPhrase) { break }
            $before = $out.Count
            & $add $v
            if ($out.Count -gt $before) { $n++ }
        }
    }
    $out.ToArray()
}

# What each script handler does, in one plain sentence that names the place it
# acts on. Authored, and it has to be: the handler name is a function name, and
# "A step in code rather than one setting: ClearDeliveryOptimization" told
# somebody reading the detail dialog nothing at all - not what it is, not where
# it lives, not how they would do it themselves.
#
# Kept here beside the renderer rather than beside the handlers, so adding a
# line is one edit in the file that reads it. The self test fails if a
# registered handler has no note, which is the guard that makes that safe.
$script:WDHandlerNotes = @{
    'CleanComponentStore'     = 'Runs DISM /StartComponentCleanup, which discards the superseded copies of Windows components kept under C:\Windows\WinSxS. The same thing Disk Cleanup calls Windows Update Cleanup.'
    'ClearActivityTraces'     = 'Clears the recent-items lists Windows keeps: jump lists, Quick Access, the Run box history, and the Registry Editor last key and favourites.'
    'ClearDeliveryOptimization' = 'Empties the update pieces Windows caches to share with other PCs on the network, under C:\Windows\SoftwareDistribution\DeliveryOptimization. Windows refills it as needed; nothing is uninstalled.'
    'ClearRunLogs'            = 'Deletes this toolkit''s own past run folders. Nothing about Windows.'
    'ClearTempFiles'          = 'Empties C:\Windows\Temp and your own %TEMP% folder, skipping anything a program currently has open.'
    'ClearThumbnailCache'     = 'Deletes the thumbnail and icon cache databases under %LOCALAPPDATA%\Microsoft\Windows\Explorer. Explorer rebuilds them on demand.'
    'ClearUpdateCache'        = 'Empties C:\Windows\SoftwareDistribution\Download, where Windows keeps update files it has already installed.'
    'CloseResurrectionPaths'  = 'Shuts the five routes a removed app comes back through: deprovisioning what was uninstalled, the content-delivery values that reinstall bundled apps at sign-in, the consumer-features policy, the push-to-install tasks, and the Edge updater when Edge is gone.'
    'CopilotKeyToRightCtrl'   = 'Remaps the Copilot key. Uses the native setting in Settings > Personalization > Text input where the build has it, and PowerToys Keyboard Manager where it does not.'
    'DisableHibernation'      = 'Runs powercfg /hibernate off, which also deletes C:\hiberfil.sys and takes fast startup with it.'
    'DisableReservedStorage'  = 'Runs DISM /Set-ReservedStorageState, releasing the several gigabytes Windows holds back for updates.'
    'DisableStartupEntries'   = 'Switches off the startup entries you picked, the same ones listed in Task Manager > Startup apps.'
    'EmptyRecycleBin'         = 'Empties the Recycle Bin on every drive, including anything you put there yourself.'
    'EnableIrreversibleMode'  = 'Changes how the rest of this run behaves: files are deleted outright instead of to the Recycle Bin. It removes nothing itself.'
    'InstallChosenBrowser'    = 'Installs the browser you picked, with winget, from that vendor''s own package.'
    'InstallPersistenceGuard' = 'Registers a scheduled task under Task Scheduler that re-runs your saved selection at every sign-in.'
    'InstallUpdateGuard'      = 'Registers a scheduled task that checks the Windows build at every boot and re-runs your saved selection only after a feature update.'
    'McAfeeScrub'             = 'Downloads and runs McAfee''s own removal tool, MCPR, from mcafee.com.'
    'NortonScrub'             = 'Downloads and runs Norton''s own removal tool from norton.com.'
    'RemoveEdge'              = 'Blocks every reinstall path first - the EdgeUpdate policies, its three services, and its scheduled tasks - then runs Edge''s own uninstaller. The WebView2 runtime other programs embed is deliberately kept.'
    'RemoveInstallShortcuts'  = 'Deletes the desktop shortcuts an installer this run just created.'
    'RemoveOneDrive'          = 'Runs OneDrive''s own uninstaller, then removes its program and cache folders. Your synced OneDrive folder is not one of them and is not touched.'
    'RemoveUninstallLeftovers'= 'Removes a folder a program declared as its install location and left behind after uninstalling.'
    'RemoveUninstallResidue'  = 'Searches AppData, ProgramData, Program Files, and the registry for folders and keys named after programs this run removed, and recycles what it finds.'
    'RemoveWindowsOld'        = 'Takes ownership of C:\Windows.old and deletes it, which is the copy of your previous Windows kept for the ten-day go-back option.'
    'ReportPreservedVendorTools' = 'Lists which of your manufacturer''s tools were deliberately kept. Changes nothing.'
    'ReportVendorProfile'     = 'Reads the SMBIOS manufacturer string and says which vendor profile the run will use. Changes nothing.'
    'RestartExplorer'         = 'Stops and restarts explorer.exe once, so the taskbar, Start menu, and context menus re-read the settings this run wrote.'
    'ScanStartup'             = 'Lists what currently starts with Windows. Changes nothing.'
    'SetDefaultBrowser'       = 'Reads every protocol and file type the current browser holds - http and https, and .htm, .html, .pdf, .svg and the rest of what a browser opens - then opens Settings > Apps > Default apps at the browser you have and says which button to press, because Windows will not let any tool move them silently. Names anything the new browser has not registered for, since Set default cannot move those either.'
    'SetNoSoundScheme'        = 'Sets the sound scheme to No Sounds, the same as Control Panel > Sound > Sounds > Sound Scheme.'
    'SetPowerPlan'            = 'Runs powercfg /setactive, the same as picking a plan in Control Panel > Power Options.'
    'SetPowerToysModule'      = 'Writes PowerToys'' own settings.json under %LOCALAPPDATA%\Microsoft\PowerToys, which is what its own settings window edits.'
    'SetShortcutArrow'        = 'Writes a blank icon into the toolkit''s own folder and points HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons value 29 at it, which is where Explorer reads the shortcut overlay from. Also clears the icon cache so the change shows.'
    'SetTaskbarAutoHide'      = 'Flips one bit in the taskbar layout blob at HKCU\...\StuckRects3, the same as ticking auto-hide in Settings > Personalization > Taskbar.'
    'SetPowerScheme'          = 'Sets one value in the power plan currently in use, for both mains and battery, through powercfg - the same numbers Control Panel > Power Options > Change advanced power settings shows, including the ones Windows hides from that page. Your previous values are recorded first, so undoing the run puts your own settings back rather than Microsoft''s defaults.'
    'SetUpdateDeferral'       = 'Writes the deferral policy under HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate for the number of days you chose. The same thing Settings > Windows Update > Advanced options exposes on Pro and above.'
    'WriteCommonIssues'       = 'Writes a text file listing, for every option this run took, the phrases somebody would search for if it turned out to cause a problem, and how to undo that one option. It changes no setting.'
    'WriteRollbackScript'     = 'Turns this run''s journal into Undo-WinSetupToolkit.ps1, a script that restores every registry value and service start-type the run changed, using the values recorded at the time. It runs last, so the journal it reads is complete, and it changes no setting itself.'
    'VerifyDefender'          = 'Checks that Microsoft Defender took back over after a third-party antivirus was removed, and reports what it found. Changes nothing.'
    'VerifyShellHealth'       = 'Checks that Explorer, the Start menu, and the search host are running after the run. Changes nothing.'
}

# Handlers that ride along behind another action in the same item rather than
# being the item. They change nothing, so an item whose every other action has
# gone inert has nothing left to do, and Test-WDItemApplies drops it.
#
# Not every handler that changes nothing belongs here, and the distinction is
# the whole point. `VerifyDefender` also changes nothing and is deliberately
# NOT in this list, because it IS its item - "Confirm Defender took back over"
# is a row somebody can want on its own, and there is no removal for it to be a
# rider on. `VerifyShellHealth` exists only because CoreAI removal can take
# Explorer with it. Kept as a list rather than inferred from the "Changes
# nothing." sentence above: that sentence is prose for the operator, and
# rewording it must not silently change what gets listed.
$script:WDPassiveHandlers = @('VerifyShellHealth')

function Get-WDHandlerNote {
    <#  One plain sentence about a script handler, or empty for one nobody has
        written yet - which the self test refuses.  #>
    param([string]$Name)
    if ($script:WDHandlerNotes.ContainsKey($Name)) { return [string]$script:WDHandlerNotes[$Name] }
    ''
}

function Test-WDPassiveHandler {
    <#  Whether a script handler only looks and reports.  #>
    param([string]$Name)
    [bool]($Name -and $script:WDPassiveHandlers -contains $Name)
}

function Get-WDHandlerNoteNames {
    <#  Lets the self test compare this table against the registered handlers. #>
    ,@($script:WDHandlerNotes.Keys)
}

$script:WDActionConsoles = @{
    'registry'    = @{ Label = 'the Registry Editor (regedit)';        Keys = @('regedit', 'registry editor') }
    'registryKey' = @{ Label = 'the Registry Editor (regedit)';        Keys = @('regedit', 'registry editor') }
    'service'     = @{ Label = 'the Services console (services.msc)';  Keys = @('services.msc', 'services console') }
    'task'        = @{ Label = 'Task Scheduler (taskschd.msc)';        Keys = @('taskschd', 'task scheduler') }
    'feature'     = @{ Label = 'Turn Windows features on or off';      Keys = @('optionalfeatures', 'windows features') }
    'capability'  = @{ Label = 'Settings, System, Optional features';  Keys = @('optional features') }
}

function Get-WDItemConsoles {
    <#
        The consoles an item's changes can be reached through by hand, each
        with the words that would give it away in prose somebody has already
        written. Deduplicated by label.
    #>
    param([Parameter(Mandatory)]$Item)

    $seen = New-WDStringSet @()
    $out  = New-Object System.Collections.Generic.List[psobject]
    foreach ($a in @(Get-Prop $Item 'actions' @())) {
        $t = [string](Get-Prop $a 'type' '')
        if (-not $script:WDActionConsoles.ContainsKey($t)) { continue }
        $c = $script:WDActionConsoles[$t]
        if (-not $seen.Add([string]$c.Label)) { continue }
        $out.Add([pscustomobject]@{ Label = [string]$c.Label; Keys = @($c.Keys) })
    }
    $out.ToArray()
}

function Get-WDItemMechanics {
    <#
        What an item actually does to the machine, in plain lines, derived from
        its own actions.

        Generated rather than authored, and that is the point: these are the
        same fields the executors read, so the description cannot drift from
        what happens. An authored "this writes X" is a second copy of a fact,
        and the copy goes wrong the first time somebody edits the action and
        not the prose.

        Three things come off the item itself, because no amount of reading the
        actions can produce them:

        - settingsPath  where the same thing can be changed by hand, and only
                        where a page for it genuinely exists. A hand-written
                        path to a setting Windows has no page for is a fiction,
                        and Microsoft moves the pages that do exist most
                        releases - so this is authored for the few dozen items
                        where it is both true and stable, and absent elsewhere.
        - symptoms      what somebody would say if this turned out to be the
                        cause of a problem weeks later, in their own words.
                        Written for the failure moment; riskNote is written for
                        the decision moment and reads nothing like it.
        - mechanics     an override line for the handful of script handlers
                        whose name says nothing useful on its own.
    #>
    param(
        [Parameter(Mandatory)]$Item,
        # Read each registry value and say whether it is already what this would
        # write. Off by default, and that is not laziness: the written record is
        # produced AFTER the run, where every value is set because the run set
        # it, so "already set" there would be true and useless. The dialog is
        # read BEFORE, where it is the question being asked.
        [switch]$ShowState
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $kindOf = @{
        'DWord' = 'number'; 'QWord' = 'number'; 'String' = 'text'
        'ExpandString' = 'text'; 'Binary' = 'bytes'; 'MultiString' = 'list'
    }

    # Where one value stands, across every hive the executor would write it to.
    # Resolved the same way Invoke-WDRegistryAction resolves it, or this answers
    # a different question than the run will.
    $stateOf = {
        param($Action, $Value)
        if (-not $ShowState) { return '' }
        $scope = [string](Get-Prop $Action 'scope' 'machine')
        $roots = @()
        try {
            $roots = switch ($scope.ToLower()) {
                'user'     { @([pscustomobject]@{ Path = 'HKCU:' }) }
                'allusers' { @(Get-WDUserHives) }
                default    { @([pscustomobject]@{ Path = 'HKLM:' }) }
            }
        } catch { }
        if (-not @($roots).Count) { return '' }
        $rel = [string](Get-Prop $Value 'path' '')
        if (-not $rel) { return '' }
        $set = 0
        foreach ($root in $roots) {
            $full = $(if ($scope -ieq 'allusers') { Join-Path $root.Path $rel } else { $rel })
            if (Test-WDRegistryValueSet -Full $full -Name ([string](Get-Prop $Value 'name' '')) `
                                        -Data (Get-Prop $Value 'value' 0) `
                                        -Kind ([string](Get-Prop $Value 'kind' 'DWord')) `
                                        -Delete ([bool](Get-Prop $Value 'delete' $false))) { $set++ }
        }
        $n = @($roots).Count
        if ($set -eq $n) { return '   [already set]' }
        if ($set -eq 0)  { return '   [will be set]' }
        # Only one scope can produce this, and saying which accounts is the
        # whole of what makes it actionable.
        "   [already set for $set of $n account(s), will be set for the rest]"
    }

    foreach ($a in @(Get-Prop $Item 'actions' @())) {
        $type = [string](Get-Prop $a 'type' '')
        switch ($type) {
            'registry' {
                # allusers is the only scope in the manifest that is not
                # machine-wide, and it is the one thing somebody checking a
                # value by hand has to be told: what they are looking at is
                # their copy of it, not the only one.
                $scope = [string](Get-Prop $a 'scope' 'machine')
                $tail  = ''
                if ($scope -eq 'allusers') { $tail = '   [written to every account, and to the profile new accounts are copied from]' }
                foreach ($v in @(Get-Prop $a 'values' @())) {
                    $path = [string](Get-Prop $v 'path' '')
                    $name = [string](Get-Prop $v 'name' '')
                    if (-not $path) { continue }
                    $state = & $stateOf $a $v
                    if ([bool](Get-Prop $v 'delete' $false)) {
                        $lines.Add("Registry: deletes $name from $path$tail$state")
                    } else {
                        $kind = [string](Get-Prop $v 'kind' 'DWord')
                        $word = $kind
                        if ($kindOf.ContainsKey($kind)) { $word = $kindOf[$kind] }
                        $lines.Add("Registry: $path -> $name = $(Get-Prop $v 'value' 0) ($word)$tail$state")
                    }
                }
            }
            'registryKey' {
                foreach ($p in @(Get-Prop $a 'paths' @())) { $lines.Add("Registry: deletes the whole key $p") }
            }
            'appx' {
                # One line for the whole action, not one per name. The tail is
                # fourteen words and identical every time, so an item naming
                # six Copilot packages printed it six times - ninety words of
                # repetition around six package names, in a list somebody is
                # reading to find out what happened to their machine.
                $names = @(Get-Prop $a 'names' @())
                if ($names.Count -eq 1) {
                    $lines.Add("Store package: removes $($names[0]) for every account, and deprovisions it so a Windows update cannot stage it again")
                } elseif ($names.Count) {
                    $lines.Add("Store packages: removes $($names -join ', ') for every account, and deprovisions them so a Windows update cannot stage them again")
                }
            }
            'appxPolicy' {
                $names = @(Get-Prop $a 'names' @())
                if ($names.Count) {
                    $lines.Add("Policy: deprovisions $($names -join ', ') through the supported Enterprise and Education route")
                }
            }
            'service' {
                $st = [string](Get-Prop $a 'startupType' 'Disabled')
                foreach ($n in @(Get-Prop $a 'names' @())) {
                    $stop = ''
                    if ([bool](Get-Prop $a 'stop' $false)) { $stop = ', and stops it now' }
                    # ServiceController carries StartType and is already cheap.
                    # Tasks and Windows features are deliberately not probed:
                    # Get-ScheduledTask with a path costs about a second and DISM
                    # costs several, and this runs while somebody is waiting on
                    # a dialog they clicked.
                    $state = ''
                    if ($ShowState) {
                        $svcs = @(Get-Service -Name $n -ErrorAction SilentlyContinue)
                        if (-not $svcs.Count) {
                            $state = '   [not on this machine]'
                        } else {
                            $done = @($svcs | Where-Object {
                                $cur = $null
                                try { $cur = [string]$_.StartType } catch { }
                                $cur -eq $st -and $_.Status -ne 'Running' }).Count
                            if ($done -eq $svcs.Count)  { $state = '   [already set]' }
                            elseif ($done -eq 0)        { $state = '   [will be set]' }
                            else                        { $state = "   [already set for $done of $($svcs.Count)]" }
                        }
                    }
                    $lines.Add("Service: sets $n to $st$stop   [services.msc]$state")
                }
            }
            'task' {
                $verb = 'disables'
                if ([bool](Get-Prop $a 'delete' $false)) { $verb = 'deletes' }
                foreach ($n in @(Get-Prop $a 'tasks' @())) {
                    $lines.Add("Scheduled task: $verb $n   [Task Scheduler]")
                }
            }
            'feature' {
                $on = ([string](Get-Prop $a 'mode' 'remove') -ieq 'enable')
                foreach ($n in @(Get-Prop $a 'names' @())) {
                    $word = 'off'
                    if ($on) { $word = 'on' }
                    $lines.Add("Windows feature: turns $n $word   [Turn Windows features on or off]")
                }
            }
            'capability' {
                $on = ([string](Get-Prop $a 'mode' 'remove') -ieq 'install')
                foreach ($n in @(Get-Prop $a 'names' @())) {
                    $word = 'removes'
                    if ($on) { $word = 'installs' }
                    $lines.Add("Windows capability: $word $n   [Settings > Apps > Optional features]")
                }
            }
            'file' {
                $how = ' outright'
                if ([bool](Get-Prop $a 'recycle' $false)) { $how = ' to the Recycle Bin' }
                foreach ($p in @(Get-Prop $a 'paths' @())) { $lines.Add("File: deletes $p$how") }
            }
            'shortcut' {
                foreach ($n in @(Get-Prop $a 'names' @())) { $lines.Add("Shortcut: deletes $n from the desktop and the Start menu") }
            }
            'uninstall' {
                # 'match' rather than 'names' on every OEM and antivirus entry:
                # the point of those items is that nobody knows in advance which
                # of a dozen brands is on the machine, so they are patterns
                # against the uninstall hive with an exclusion list beside them.
                # Rendering only 'names' left thirty-odd items describing
                # nothing at all, which the self test now refuses.
                foreach ($n in @(Get-Prop $a 'names' @())) { $lines.Add("Runs the program's own uninstaller for $n, silently") }
                $pat = @(Get-Prop $a 'match' @())
                if ($pat.Count) {
                    $lines.Add("Runs the uninstaller of anything in Installed apps matching: $($pat -join ', ')")
                    $ex = @(Get-Prop $a 'exclude' @())
                    if ($ex.Count) { $lines.Add("   but never anything matching: $($ex -join ', ')") }
                }
            }
            'winget' {
                $word = 'removes'
                if ([string](Get-Prop $a 'mode' 'remove') -ieq 'install') { $word = 'installs' }
                foreach ($n in @(@(Get-Prop $a 'ids' @()) + @(Get-Prop $a 'packages' @()) + @(Get-Prop $a 'names' @()))) {
                    if ($n) { $lines.Add("winget: $word $n") }
                }
            }
            'script' {
                # The handler NAME says nothing to anybody reading this - it is
                # a function name. What goes in is the authored sentence about
                # what it touches and where that lives.
                $h = [string](Get-Prop $a 'handler' '')
                if ($h) {
                    $note = Get-WDHandlerNote -Name $h
                    if ($note) { $lines.Add($note) } else { $lines.Add("Runs the $h step.") }
                }
            }
            default { if ($type) { $lines.Add("A $type action") } }
        }
    }

    $mech = [string](Get-Prop $Item 'mechanics' '')
    if ($mech) { $lines.Insert(0, $mech) }

    [pscustomobject]@{
        Id       = [string](Get-Prop $Item 'id' '')
        Name     = [string](Get-Prop $Item 'name' (Get-Prop $Item 'id' ''))
        # Stamped by Resolve-WDPlan and absent on a bare manifest item, which is
        # why it falls back rather than being assumed. The written record groups
        # by it, so a hundred and fifty options read as a dozen headings.
        Category = [string](Get-Prop $Item 'category' 'Other')
        Lines    = $lines.ToArray()
        Settings = [string](Get-Prop $Item 'settingsPath' '')
        Symptoms = @(Get-Prop $Item 'symptoms' @())
        RiskNote = [string](Get-Prop $Item 'riskNote' '')
        Revert   = (Get-WDItemRevertibility -Item $Item)
        # Which consoles this item's changes can be reached through by hand,
        # for the one-line pointer the readable record carries. The full steps
        # are Get-WDItemRevertRoutes' job and live in the lookup document; two
        # copies of a numbered procedure is one copy plus a way to disagree.
        #
        # Keys, not just a label, so a caller can tell whether the item's own
        # authored settingsPath already named this console. Several do - "Task
        # Scheduler, or undo the run" - and appending "By hand in Task
        # Scheduler (taskschd.msc)" to that is the sentence saying itself twice.
        Consoles = (Get-WDItemConsoles -Item $Item)
    }
}

function Get-WDItemRevertibility {
    <#
        Whether undoing the run puts this item back, and it is three-valued
        because the honest answer is.

        Fully:     every action is journalled with its previous value and the
                   rollback script restores it exactly - registry, services,
                   scheduled tasks, Windows features and capabilities.
        Partially: something can be put back, but not to the state it was in.
                   An uninstalled app is a reinstall hint, not an undo; a
                   recycled file comes out of the bin.
        No:        nothing can restore it. A file deleted outright, and anything
                   the manifest says so about.

        A `revert` field on the item overrides the answer, for the handful of
        script handlers where reading the action types cannot produce it. A
        script handler with no override is "partially" rather than "fully",
        because an unknown is not a promise.
    #>
    param([Parameter(Mandatory)]$Item)

    $said = [string](Get-Prop $Item 'revert' '')
    if ($said -in @('full','partial','none')) {
        return $(switch ($said) { 'full' { 'fully' } 'partial' { 'partially' } default { 'no' } })
    }

    $full = @('registry','registryKey','service','task','feature','capability','appxPolicy')
    $best = 'fully'
    $rank = @{ 'fully' = 0; 'partially' = 1; 'no' = 2 }
    foreach ($a in @(Get-Prop $Item 'actions' @())) {
        $type = [string](Get-Prop $a 'type' '')
        $mine = 'partially'
        if ($type -in $full) {
            $mine = 'fully'
        } elseif ($type -eq 'file' -or $type -eq 'shortcut') {
            $mine = $(if ([bool](Get-Prop $a 'recycle' $false)) { 'partially' } else { 'no' })
        }
        if ($rank[$mine] -gt $rank[$best]) { $best = $mine }
    }
    $best
}

function Format-WDHivePath {
    <#  A registry path as regedit shows it, from the PowerShell form.  #>
    param([string]$Path)
    $p = [string]$Path
    $p = $p -replace '^HKLM:\\?',  'HKEY_LOCAL_MACHINE\'
    $p = $p -replace '^HKCU:\\?',  'HKEY_CURRENT_USER\'
    $p = $p -replace '^HKCR:\\?',  'HKEY_CLASSES_ROOT\'
    $p = $p -replace '^HKU:\\?',   'HKEY_USERS\'
    $p
}

function Get-WDItemRevertRoutes {
    <#
        Every way one option can be put back, each one as steps somebody can
        follow, narrowest first.

        The manifest's settingsPath is one route and was the only one printed.
        For an item that writes three policy values and has no Settings page,
        that left "undo the run" as the whole of the advice - which is a
        sledgehammer for one nail, and untrue besides: anybody can open regedit
        and put a value back, and this run recorded exactly what it was.

        THE PREVIOUS VALUES COME FROM THE JOURNAL, not the manifest. The
        manifest knows what was written and cannot know what was there before,
        so a document built from it alone can say "set it to 0" and never "set
        it back to 1". The journal has both, and by the time the lookup
        document is written it holds every entry this run made.

        With no journal - a preview, or the self test - the registry route is
        still emitted, because knowing WHERE the value lives is most of it, and
        it says plainly that the previous value is in the rollback script
        rather than inventing one.

        The two blunt instruments go last and are always offered. Somebody who
        wanted the whole run gone would not be reading one option's entry.
    #>
    param($Item, $JournalEntries = @())

    $routes = New-Object System.Collections.Generic.List[psobject]
    $addRoute = {
        param([string]$Title, $Steps)
        $s = @($Steps | Where-Object { $_ })
        if (-not $s.Count) { return }
        $routes.Add([pscustomobject]@{ Title = $Title; Steps = $s })
    }

    $entries = @($JournalEntries)
    $byMethod = {
        param([string]$Method)
        @($entries | Where-Object { $_ -and $_.undo -and [string]$_.undo.method -eq $Method })
    }

    # ---- 1. the authored one-liner, whatever it is -------------------------
    #
    # Not titled "In Settings": settingsPath is a grab-bag by design. Some of
    # them are a Settings path, some name a console, and some say there is
    # nothing to undo because the item only wrote a file. A title claiming all
    # of those are Settings is wrong on most of them.
    $settings = [string](Get-Prop $Item 'settingsPath' '')
    if ($settings) { & $addRoute 'The short answer' @($settings) }

    # ---- 2. the Registry Editor --------------------------------------------
    $regActions = @(@(Get-Prop $Item 'actions' @()) |
                    Where-Object { [string](Get-Prop $_ 'type' '') -eq 'registry' })
    if ($regActions.Count) {
        $steps = New-Object System.Collections.Generic.List[string]
        $steps.Add('Press Win+R, type regedit, and press Enter. Say Yes to the prompt that appears.')
        $steps.Add('Paste each path below into the address bar at the top of the Registry Editor and press Enter, then act on the value named under it.')

        $regUndo = & $byMethod 'registry'
        if (@($regUndo).Count) {
            # Grouped by what the value is and what it was, not by hive. An
            # allusers write on a machine with four accounts is the same
            # instruction four times over with a different SID in front of it,
            # and a list like that is one somebody gives up on.
            $groups = @{}
            foreach ($e in $regUndo) {
                $path = Format-WDHivePath ([string]$e.undo.path)
                $name = [string]$e.undo.name
                $prev = [string]$e.undo.previous
                $key  = "$name|$prev|$($path -replace '^HKEY_USERS\\[^\\]+\\', 'PERUSER\')"
                if (-not $groups.ContainsKey($key)) {
                    $groups[$key] = [pscustomobject]@{ Paths = (New-Object System.Collections.Generic.List[string])
                                                       Name = $name; Prev = $prev }
                }
                $groups[$key].Paths.Add($path)
            }
            foreach ($k in ($groups.Keys | Sort-Object)) {
                $g = $groups[$k]
                $shown = @($g.Paths | Sort-Object -Unique)
                $where = [string]$shown[0]
                $extra = ''
                if ($shown.Count -gt 1) {
                    $extra = "  (the same value was also written under $($shown.Count - 1) other account hive$(if ($shown.Count -gt 2) { 's' }) below HKEY_USERS - repeat this there if you want it back for those accounts too)"
                }
                # '__ABSENT__' is what the executor records when the value did
                # not exist. Deleting it is the undo, and saying "set it back
                # to __ABSENT__" would be a line nobody can act on.
                $what = $(if ($g.Prev -eq '__ABSENT__') {
                              "right-click $($g.Name) and choose Delete - it did not exist before this run"
                          } else {
                              "double-click $($g.Name) and set it back to $($g.Prev)"
                          })
                $steps.Add("$where  ->  $what$extra")
            }
        } else {
            # No journal to read: name the values the actions would write, and
            # be honest that what they held before is not knowable from here.
            foreach ($a in $regActions) {
                foreach ($v in @(Get-Prop $a 'values' @())) {
                    $path = [string](Get-Prop $v 'path' '')
                    if (-not $path) { continue }
                    $steps.Add("$(Format-WDHivePath $path)  ->  $(Get-Prop $v 'name' '')")
                }
            }
            $steps.Add('What each of these held before the run is recorded in the rollback script, Undo-WinSetupToolkit.ps1, in the run folder. Open it in Notepad and search for the value name.')
        }
        $steps.Add('Sign out and back in, or restart, for the change to take effect. Some of these are read only when Windows or Explorer starts.')
        & $addRoute 'In the Registry Editor' $steps
    }

    # ---- 3. the Services console -------------------------------------------
    $svcActions = @(@(Get-Prop $Item 'actions' @()) |
                    Where-Object { [string](Get-Prop $_ 'type' '') -eq 'service' })
    if ($svcActions.Count) {
        $steps = New-Object System.Collections.Generic.List[string]
        $steps.Add('Press Win+R, type services.msc, and press Enter.')
        $svcUndo = & $byMethod 'service'
        if (@($svcUndo).Count) {
            foreach ($e in $svcUndo) {
                $steps.Add("Find $([string]$e.undo.name), double-click it, set Startup type back to $([string]$e.undo.previous), press Apply, then press Start.")
            }
        } else {
            foreach ($a in $svcActions) {
                foreach ($n in @(Get-Prop $a 'names' @())) {
                    $steps.Add("Find $n, double-click it, set Startup type back to Automatic or Manual, press Apply, then press Start.")
                }
            }
            $steps.Add('The exact start type each one had before the run is in the rollback script, Undo-WinSetupToolkit.ps1, in the run folder.')
        }
        & $addRoute 'In the Services console' $steps
    }

    # ---- 4. Task Scheduler --------------------------------------------------
    $taskActions = @(@(Get-Prop $Item 'actions' @()) |
                     Where-Object { [string](Get-Prop $_ 'type' '') -eq 'task' })
    if ($taskActions.Count) {
        $deleted = @($taskActions | Where-Object { [bool](Get-Prop $_ 'delete' $false) }).Count
        $steps = New-Object System.Collections.Generic.List[string]
        $steps.Add('Press Win+R, type taskschd.msc, and press Enter.')
        $steps.Add('Expand Task Scheduler Library on the left and work down to the folder named in the path below.')
        $taskUndo = & $byMethod 'task'
        if (@($taskUndo).Count) {
            foreach ($e in $taskUndo) {
                $steps.Add("$([string]$e.undo.path)  ->  right-click $([string]$e.undo.name) and choose Enable.")
            }
        } else {
            foreach ($a in $taskActions) {
                foreach ($n in @(Get-Prop $a 'tasks' @())) { $steps.Add("$n  ->  right-click it and choose Enable.") }
            }
        }
        if ($deleted) {
            $steps.Add('Any task this run DELETED rather than disabled cannot be re-created by hand. Those come back only by reinstalling whatever registered them, or from a system restore point.')
        }
        & $addRoute 'In Task Scheduler' $steps
    }

    # ---- 5. Windows features and optional features --------------------------
    $featActions = @(@(Get-Prop $Item 'actions' @()) |
                     Where-Object { [string](Get-Prop $_ 'type' '') -eq 'feature' })
    if ($featActions.Count) {
        $steps = New-Object System.Collections.Generic.List[string]
        $steps.Add('Press Win+R, type optionalfeatures, and press Enter.')
        foreach ($a in $featActions) {
            $on = ([string](Get-Prop $a 'mode' 'remove') -ieq 'enable')
            foreach ($n in @(Get-Prop $a 'names' @())) {
                $steps.Add($(if ($on) { "Clear the tick beside $n and press OK." } else { "Tick $n and press OK." }))
            }
        }
        $steps.Add('Windows downloads what it needs and asks for a restart. This can take several minutes.')
        & $addRoute 'In Turn Windows features on or off' $steps
    }

    $capActions = @(@(Get-Prop $Item 'actions' @()) |
                    Where-Object { [string](Get-Prop $_ 'type' '') -eq 'capability' })
    if ($capActions.Count) {
        $steps = New-Object System.Collections.Generic.List[string]
        $steps.Add('Open Settings, System, Optional features.')
        $steps.Add('Press Add an optional feature, then View features.')
        foreach ($a in $capActions) {
            foreach ($n in @(Get-Prop $a 'names' @())) {
                $steps.Add("Search for $($n -replace '~.*$', '') and tick it, then press Next and Install.")
            }
        }
        & $addRoute 'In Settings, Optional features' $steps
    }

    # ---- 6. putting software back -------------------------------------------
    $appx = @(@(Get-Prop $Item 'actions' @()) |
              Where-Object { [string](Get-Prop $_ 'type' '') -in @('appx', 'appxPolicy') })
    if ($appx.Count) {
        & $addRoute 'By reinstalling it from the Microsoft Store' @(
            'Open the Microsoft Store and search for the app by the name you know it by.',
            'If it does not appear, this run also told Windows not to stage it again for new accounts. Undo the whole run, or reinstall it and accept that a feature update may take it away again.')
    }
    $unins = @(@(Get-Prop $Item 'actions' @()) |
               Where-Object { [string](Get-Prop $_ 'type' '') -in @('uninstall', 'winget') })
    if ($unins.Count) {
        & $addRoute 'By installing the program again' @(
            'Download it from the vendor and install it as you did the first time. An uninstall is not something any journal can reverse.',
            'Its settings are usually gone with it. Anything it kept lives under your user folder and may still be there.')
    }

    # ---- 7. the two blunt instruments, always -------------------------------
    & $addRoute 'By undoing this one option from the toolkit' @(
        'Open Windows Setup Toolkit and press Revert past changes.',
        'Untick everything except this option, then press Revert. That restores only what this option changed.')
    & $addRoute 'By undoing the whole run' @(
        'Open the run folder left on your desktop and right-click Undo-WinSetupToolkit.ps1, then choose Run with PowerShell. Say Yes to the prompt.',
        'That puts back every registry value and service start-type the run changed, using the values recorded at the time. It cannot bring back an uninstalled program.')

    $routes.ToArray()
}

Export-ModuleMember -Function Invoke-WD*, Get-WDInstalledPrograms, Get-Prop, Resolve-WDSilentUninstall,
                              Get-WDItemRevertRoutes, Format-WDHivePath, Get-WDItemConsoles,
                              Test-WDRegistryActionSatisfied, Test-WDRegistryValueSet,
                              Test-WDServiceActionSatisfied,
                              Get-WDProvisionedPackages, Clear-WDProvisionedCache,
                              Get-WDCapabilityList, Clear-WDCapabilityCache,
                              Get-WDItemMechanics, Get-WDItemRevertibility, Expand-WDSymptoms,
                              Get-WDHandlerNote, Get-WDHandlerNoteNames, Test-WDPassiveHandler,
                              Get-WDRegistryKeyValues, Clear-WDRegistryProbeCache, Clear-WDProgramCache
