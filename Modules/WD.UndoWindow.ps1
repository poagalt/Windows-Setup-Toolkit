$ErrorActionPreference = 'Continue'

# A window needs an STA and "Run with PowerShell" does not always give one.
# Relaunch once, marked so a failure cannot loop.
if (-not $Console -and -not $env:WD_UNDO_STA -and
    [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $env:WD_UNDO_STA = '1'
    $me = $PSCommandPath
    if ($me) {
        & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $me @PSBoundParameters
        exit $LASTEXITCODE
    }
}

# Nothing below changes anything: every step is asked which side of its change
# the machine is on.

$global:WDRegCache   = @{}
$global:WDSched      = $null
$global:WDFeatures   = $null
$global:WDFeatureJob = $null

function global:Get-WDRegNow {
    param([string]$Path, [string]$Name)

    $out = @{ Key = $false; Has = $false; Value = $null }
    if (-not $global:WDRegCache.ContainsKey($Path)) {
        $v = $null
        try {
            if (Test-Path -LiteralPath $Path) { $v = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue }
        } catch { }
        $global:WDRegCache[$Path] = $v
    }
    $p = $global:WDRegCache[$Path]
    if ($null -eq $p) { return $out }
    $out.Key = $true
    if ($p.PSObject.Properties[$Name]) { $out.Has = $true; $out.Value = $p.$Name }
    $out
}

function global:Test-WDPathReachable {
    param([string]$Path)

    if ($Path -notlike 'HKU:\*') { return $true }
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) { return $false }
    $hive = (($Path.Substring(5)) -split '\\')[0]
    if (-not $hive) { return $false }
    try { return [bool](Test-Path -LiteralPath ('HKU:\' + $hive)) } catch { return $false }
}

function global:Test-WDSameValue {
    param($A, $B, [string]$Kind)

    switch ($Kind) {
        'Binary' {
            if ($null -eq $A -or $null -eq $B) { return $false }
            $x = @($A); $y = @($B)
            if ($x.Count -ne $y.Count) { return $false }
            for ($i = 0; $i -lt $x.Count; $i++) { if ([int]$x[$i] -ne [int]$y[$i]) { return $false } }
            return $true
        }
        'MultiString' {
            $x = @($A); $y = @($B)
            if ($x.Count -ne $y.Count) { return $false }
            for ($i = 0; $i -lt $x.Count; $i++) { if ([string]$x[$i] -ne [string]$y[$i]) { return $false } }
            return $true
        }
        'DWord' { try { return ([int64]$A -eq [int64]$B) } catch { return $false } }
        'QWord' { try { return ([int64]$A -eq [int64]$B) } catch { return $false } }
        default { return ([string]$A -eq [string]$B) }
    }
}

function global:Get-WDTaskEnabled {
    # Enabled, disabled, or $null for "could not ask".
    param([string]$Path, [string]$Name)

    try {
        if (-not $global:WDSched) {
            $global:WDSched = New-Object -ComObject 'Schedule.Service'
            $global:WDSched.Connect()
        }
        $p = [string]$Path
        if ($p) { $p = $p.TrimEnd('\') }
        if (-not $p) { $p = '\' }
        $f = $global:WDSched.GetFolder($p)
        if (-not $f) { return $null }
        $t = $f.GetTask($Name)
        if (-not $t) { return $null }
        return [bool]$t.Enabled
    } catch { return $null }
}

function global:Read-WDFeatureTable {
    $t = @{}
    try {
        foreach ($f in @(Get-CimInstance -ClassName Win32_OptionalFeature -ErrorAction Stop)) {
            if ([int]$f.InstallState -eq 1) { $t[[string]$f.Name] = 'Enabled' }
            else                            { $t[[string]$f.Name] = 'Disabled' }
        }
    } catch { }
    $t
}

function global:Start-WDFeatureRead {
    # Warmed on a runspace of its own: the table is a hashtable of strings, so
    # unlike a decoded frame there is nothing thread-affine to cross back.
    if ($global:WDFeatureJob -or $null -ne $global:WDFeatures) { return }
    $wanted = $false
    foreach ($s in @($global:WDSteps)) {
        if ($s.M -eq 'feature' -or $s.M -eq 'feature-off') { $wanted = $true; break }
    }
    if (-not $wanted) { return }
    try {
        $rs = [RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [PowerShell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript((Get-Command Read-WDFeatureTable).Definition)
        $global:WDFeatureJob = @{ PS = $ps; RS = $rs; H = $ps.BeginInvoke() }
    } catch {
        $global:WDFeatureJob = $null
    }
}

function global:Get-WDFeatureState {
    param([string]$Name)

    if ($null -eq $global:WDFeatures) {
        $j = $global:WDFeatureJob
        $global:WDFeatureJob = $null
        if ($j) {
            try {
                $r = @($j.PS.EndInvoke($j.H))
                if ($r.Count) { $global:WDFeatures = $r[0] }
            } catch { }
            try { $j.PS.Dispose() } catch { }
            try { $j.RS.Dispose() } catch { }
        }
        if ($null -eq $global:WDFeatures) { $global:WDFeatures = Read-WDFeatureTable }
    }
    if ($global:WDFeatures.ContainsKey($Name)) { return $global:WDFeatures[$Name] }

    # A name the CIM class does not carry - Recall and the Remote Desktop client
    # on this build. DISM answers one name in 377 ms against twelve seconds for
    # the lot, so the fallback is per name and the answer is cached either way.
    $st = ''
    try { $st = [string](Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop).State } catch { }
    $global:WDFeatures[$Name] = $st
    if ($st) { return $st }
    $null
}

function global:Get-WDStepState {
    # 'todo' the change is still in place, 'done' the machine is back where it
    # was, 'unknown' could not be asked cheaply.
    param($S)

    switch ($S.M) {
        'registry' {
            if (-not (Test-WDPathReachable $S.P)) { return 'unknown' }
            $now = Get-WDRegNow -Path $S.P -Name $S.N
            if ($S.Gone) { if ($now.Has) { return 'todo' } else { return 'done' } }
            if (-not $now.Has) { return 'todo' }
            if (Test-WDSameValue $now.Value $S.V $S.K) { return 'done' }
            return 'todo'
        }
        'service' {
            $svc = $null
            try { $svc = Get-Service -Name $S.N -ErrorAction SilentlyContinue } catch { }
            if (-not $svc) { return 'unknown' }
            $cur = ''
            try { $cur = [string]$svc.StartType } catch { }
            if (-not $cur) { return 'unknown' }
            if ($cur -eq [string]$S.V) { return 'done' }
            return 'todo'
        }
        'task' {
            $on = Get-WDTaskEnabled -Path $S.P -Name $S.N
            if ($null -eq $on) { return 'unknown' }
            if ($on) { return 'done' }
            return 'todo'
        }
        'unregister-task' {
            $on = Get-WDTaskEnabled -Path '\' -Name $S.N
            if ($null -eq $on) { return 'done' }
            return 'todo'
        }
        'feature' {
            $st = Get-WDFeatureState $S.N
            if (-not $st) { return 'unknown' }
            if ($st -eq 'Enabled') { return 'done' }
            return 'todo'
        }
        'feature-off' {
            $st = Get-WDFeatureState $S.N
            if (-not $st) { return 'unknown' }
            if ($st -eq 'Disabled') { return 'done' }
            return 'todo'
        }
        'rename' {
            if (Test-Path -LiteralPath $S.To)   { return 'done' }
            if (Test-Path -LiteralPath $S.From) { return 'todo' }
            return 'unknown'
        }
        'file-restore' {
            if ($S.F) {
                if (Test-Path -LiteralPath $S.T) { return 'todo' }
                return 'unknown'
            }
            if (Test-Path -LiteralPath $S.T) { return 'todo' }
            return 'done'
        }
        'recycle' {
            if (Test-Path -LiteralPath $S.P) { return 'done' }
            return 'todo'
        }
        'uninstall' {
            # Installed by the run, so undoing it is an uninstall, and winget is
            # the only thing that can say whether it is still here.
            return 'unknown'
        }
        default { return 'unknown' }
    }
}

function global:Get-WDStepText {
    param($S)

    switch ($S.M) {
        'registry' {
            if ($S.Gone) { return "Delete $($S.N) under $($S.P) - it did not exist before the run" }
            return "Set $($S.N) under $($S.P) back to $(Format-WDShort $S.V)"
        }
        'service'         { return "Set the $($S.N) service back to $($S.V) startup" }
        'task'            { return "Re-enable the scheduled task $($S.P)$($S.N)" }
        'unregister-task' { return "Remove the scheduled task $($S.N), which this run registered" }
        'feature'         { return "Turn the Windows feature $($S.N) back on" }
        'feature-off'     { return "Turn the Windows feature $($S.N) back off" }
        'capability-off'  { return "Remove the Windows capability $($S.N), which this run added" }
        'powercfg'        { return "Put the power setting $($S.Sub)\$($S.Set) back to $($S.Ac) on mains, and $($S.Dc) on battery" }
        'regfile'         { return "Import $($S.F), which is the whole of $($S.T) as it was before the run" }
        'file-restore'    { if ($S.F) { return "Restore $($S.T) from the copy taken before the run" }
                            return "Delete $($S.T), which this run created" }
        'rename'          { return "Move $($S.From) back to $($S.To)" }
        'recycle'         { return "Take $($S.P) back out of the Recycle Bin" }
        'uninstall'       { return "Uninstall $($S.N), which this run installed" }
        default           { return "$($S.M) $($S.N)" }
    }
}

function global:Format-WDShort {
    param($V)
    if ($null -eq $V) { return '(nothing)' }
    if ($V -is [Array]) {
        $n = @($V).Count
        if ($n -gt 8) { return "$n bytes" }
        return (@($V) -join ', ')
    }
    $s = [string]$V
    if ($s.Length -gt 60) { return $s.Substring(0, 57) + '...' }
    if ($s -eq '') { return '(an empty value)' }
    $s
}

function global:Open-WDRegKeyForWrite {
    # Straight from .NET, because a key's default value has two names and
    # neither spelling works on both sides of the provider.
    param([string]$Path)

    $root = $null; $rest = ''
    if     ($Path -match '^HKLM:\\(.*)$') { $root = [Microsoft.Win32.Registry]::LocalMachine; $rest = $Matches[1] }
    elseif ($Path -match '^HKCU:\\(.*)$') { $root = [Microsoft.Win32.Registry]::CurrentUser;  $rest = $Matches[1] }
    elseif ($Path -match '^HKCR:\\(.*)$') { $root = [Microsoft.Win32.Registry]::ClassesRoot;  $rest = $Matches[1] }
    elseif ($Path -match '^HKU:\\(.*)$')  { $root = [Microsoft.Win32.Registry]::Users;        $rest = $Matches[1] }
    if (-not $root) { return $null }
    try { return $root.OpenSubKey($rest, $true) } catch { return $null }
}

function global:Invoke-WDStep {
    # Never throws: a rollback that stops at the first refusal leaves the
    # machine in a state nobody chose.
    param($S)

    try {
        switch ($S.M) {
            'registry' {
                if (-not (Test-WDPathReachable $S.P)) {
                    return @{ Ok = $false; Note = 'that part of the registry is not mounted' }
                }
                if ($S.Gone) {
                    # A key's default value cannot be deleted through the
                    # provider - Remove-ItemProperty -Name '(default)' answers
                    # "does not exist" however plainly it is there, because the
                    # delete path takes the raw name and the raw name is the
                    # empty string.
                    if ($S.N -eq '(default)') {
                        $k = Open-WDRegKeyForWrite $S.P
                        if (-not $k) { return @{ Ok = $false; Note = 'that key could not be opened for writing' } }
                        try { $k.DeleteValue('', $false) } finally { $k.Close() }
                    } else {
                        Remove-ItemProperty -LiteralPath $S.P -Name $S.N -Force -ErrorAction Stop
                    }
                } else {
                    if (-not (Test-Path -LiteralPath $S.P)) {
                        $null = New-Item -Path ([Management.Automation.WildcardPattern]::Escape($S.P)) -Force -ErrorAction Stop
                    }
                    Set-ItemProperty -LiteralPath $S.P -Name $S.N -Value $S.V -Type $S.K -Force -ErrorAction Stop
                }
                $global:WDRegCache.Remove($S.P) | Out-Null
                return @{ Ok = $true; Note = '' }
            }
            'service' {
                Set-Service -Name $S.N -StartupType $S.V -ErrorAction Stop
                return @{ Ok = $true; Note = '' }
            }
            'task' {
                $null = Enable-ScheduledTask -TaskPath $S.P -TaskName $S.N -ErrorAction Stop
                return @{ Ok = $true; Note = '' }
            }
            'unregister-task' {
                Unregister-ScheduledTask -TaskName $S.N -Confirm:$false -ErrorAction Stop
                return @{ Ok = $true; Note = '' }
            }
            'feature' {
                if ($global:WDDismBlocked) { return @{ Ok = $false; Note = 'a restart is pending, so Windows will not service features yet' } }
                $null = Enable-WindowsOptionalFeature -Online -FeatureName $S.N -NoRestart -ErrorAction Stop
                return @{ Ok = $true; Note = 'a restart finishes this' }
            }
            'feature-off' {
                if ($global:WDDismBlocked) { return @{ Ok = $false; Note = 'a restart is pending, so Windows will not service features yet' } }
                $null = Disable-WindowsOptionalFeature -Online -FeatureName $S.N -NoRestart -ErrorAction Stop
                return @{ Ok = $true; Note = 'a restart finishes this' }
            }
            'capability-off' {
                if ($global:WDDismBlocked) { return @{ Ok = $false; Note = 'a restart is pending, so Windows will not service capabilities yet' } }
                $null = Remove-WindowsCapability -Online -Name $S.N -ErrorAction Stop
                return @{ Ok = $true; Note = '' }
            }
            'powercfg' {
                $null = & powercfg.exe /setacvalueindex SCHEME_CURRENT $S.Sub $S.Set $S.Ac
                $null = & powercfg.exe /setdcvalueindex SCHEME_CURRENT $S.Sub $S.Set $S.Dc
                $null = & powercfg.exe /setactive SCHEME_CURRENT
                return @{ Ok = $true; Note = '' }
            }
            'regfile' {
                if (-not (Test-Path -LiteralPath $S.F)) {
                    return @{ Ok = $false; Note = 'the backup file this needs is no longer there' }
                }
                $null = & reg.exe import "$($S.F)"
                if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Note = "reg import exit $LASTEXITCODE" } }
                return @{ Ok = $true; Note = '' }
            }
            'file-restore' {
                if ($S.F) {
                    if (-not (Test-Path -LiteralPath $S.F)) {
                        return @{ Ok = $false; Note = 'the copy taken before the run is no longer there' }
                    }
                    Copy-Item -LiteralPath $S.F -Destination $S.T -Force -ErrorAction Stop
                } else {
                    Remove-Item -LiteralPath $S.T -Force -ErrorAction Stop
                }
                return @{ Ok = $true; Note = '' }
            }
            'rename' {
                if (-not (Test-Path -LiteralPath $S.From)) { return @{ Ok = $false; Note = 'the parked folder is no longer there' } }
                if (Test-Path -LiteralPath $S.To)          { return @{ Ok = $false; Note = 'something is already at that name' } }
                Rename-Item -LiteralPath $S.From -NewName (Split-Path $S.To -Leaf) -Force -ErrorAction Stop
                return @{ Ok = $true; Note = '' }
            }
            'recycle'   { return (Restore-WDFromBin -Path $S.P) }
            'uninstall' {
                if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
                    return @{ Ok = $false; Note = 'winget is not available on this machine' }
                }
                $null = & winget.exe uninstall --id $S.N --exact --silent --disable-interactivity --accept-source-agreements
                if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Note = "winget exit $LASTEXITCODE" } }
                return @{ Ok = $true; Note = '' }
            }
        }
        return @{ Ok = $false; Note = "nothing here knows how to undo '$($S.M)'" }
    } catch {
        return @{ Ok = $false; Note = $_.Exception.Message }
    }
}

$global:WDBin = $null
function global:Restore-WDFromBin {
    # Out of the bin by moving the item rather than invoking the Restore verb,
    # which is localised.
    param([string]$Path)

    try {
        if ($null -eq $global:WDBin) {
            $global:WDBin = @{}
            $ns = (New-Object -ComObject Shell.Application).NameSpace(0xA)
            foreach ($it in @($ns.Items())) {
                try {
                    $from = $it.ExtendedProperty('System.Recycle.DeletedFrom')
                    if ($from) { $global:WDBin[[string](Join-Path $from $it.Name)] = $it }
                } catch { }
            }
        }
        if (-not $global:WDBin.ContainsKey($Path)) { return @{ Ok = $false; Note = 'not in the Recycle Bin any more' } }
        $parent = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop }
        # 0x14 is no confirmation dialog and no progress window; the shell can
        # otherwise raise UI with nobody at the screen.
        (New-Object -ComObject Shell.Application).NameSpace($parent).MoveHere($global:WDBin[$Path], 0x14)
        return @{ Ok = $true; Note = '' }
    } catch {
        return @{ Ok = $false; Note = $_.Exception.Message }
    }
}

$global:WDDismBlocked  = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                         (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
$global:WDDefaultOurs  = $false
$global:WDDefaultOk    = $true

function global:Enter-WDUndoSingleInstance {
    $createdNew = $false
    try {
        $sec  = New-Object System.Security.AccessControl.MutexSecurity
        $rule = New-Object System.Security.AccessControl.MutexAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'),
                    [System.Security.AccessControl.MutexRights]::FullControl,
                    [System.Security.AccessControl.AccessControlType]::Allow)
        $sec.AddAccessRule($rule)
        $global:WDInstanceMutex = New-Object System.Threading.Mutex(
                                      $false, 'Global\WinSetupToolkit.Toolkit.1', [ref]$createdNew, $sec)
    } catch {
        try {
            $global:WDInstanceMutex = New-Object System.Threading.Mutex(
                                          $false, 'Global\WinSetupToolkit.Toolkit.1', [ref]$createdNew)
        } catch { return $true }
    }
    if ($createdNew) { return $true }
    try { $global:WDInstanceMutex.Dispose() } catch { }
    $global:WDInstanceMutex = $null

    # For the message only - the mutex has already decided. Matched on the
    # script rather than the word, or any shell mentioning the folder counts.
    $who = @()
    try {
        $who = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
                 Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'WinSetupToolkit\.ps1' } |
                 ForEach-Object {
                     $kind = 'the toolkit'
                     if ($_.CommandLine -match 'Undo-WinSetupToolkit\.ps1') { $kind = 'another rollback script' }
                     "Already running: $kind, process $($_.ProcessId)"
                 })
    } catch { }

    # Word for word what the toolkit says, because it is the same refusal from
    # the other side.
    Write-Host ''
    Write-Host 'For your own safety, having two instances of the Windows Setup Toolkit or its reversion script open is not allowed. There is no reason why you should need two instances, and it can only do harm. Close the other instance to open a new one, or just use the existing one.' -ForegroundColor Yellow
    if ($who.Count) {
        Write-Host ''
        foreach ($line in $who) { Write-Host $line -ForegroundColor Yellow }
    }
    Write-Host ''
    $false
}

function global:Open-WDHives {
    # HKU: is not one of PowerShell's default drives, and HKU:\WD_DEFAULT is not
    # a hive at all - it is C:\Users\Default\NTUSER.DAT, mounted for the length
    # of a run.
    if (-not $global:WDWantsHku) { return }
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        $null = New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -Scope Global -ErrorAction SilentlyContinue
    }
    if (-not $global:WDWantsDefault) { return }
    if (Test-Path 'HKU:\WD_DEFAULT') { return }
    $dat = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $dat)) { $global:WDDefaultOk = $false; return }
    $null = & reg.exe load "HKU\WD_DEFAULT" "$dat" 2>&1
    $global:WDDefaultOurs = [bool](Test-Path 'HKU:\WD_DEFAULT')
    $global:WDDefaultOk   = $global:WDDefaultOurs
}

function global:Close-WDHives {
    # Unload what this script loaded and only that. Remove the PSDrive first:
    # that is what releases the provider's key handles, and collecting alone
    # leaves them.
    if (-not $global:WDDefaultOurs) { return }
    $global:WDRegCache.Clear()

    for ($try = 1; $try -le 3; $try++) {
        Remove-PSDrive -Name HKU -Force -ErrorAction SilentlyContinue
        [gc]::Collect(); [gc]::WaitForPendingFinalizers(); [gc]::Collect()
        $out = & reg.exe unload "HKU\WD_DEFAULT" 2>&1
        $null = New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -Scope Global -ErrorAction SilentlyContinue
        if (-not (Test-Path 'HKU:\WD_DEFAULT')) {
            $global:WDDefaultOurs = $false
            return
        }
        if ($try -eq 3) {
            Write-Host ''
            Write-Host 'The default user profile could not be unmounted again, so it is still loaded.' -ForegroundColor Yellow
            Write-Host 'Nothing is broken by that, but it should not be left behind. From an administrator' -ForegroundColor Yellow
            Write-Host 'prompt, run:  reg unload HKU\WD_DEFAULT' -ForegroundColor Yellow
            Write-Host "  ($($out -join ' '))" -ForegroundColor DarkGray
        }
        Start-Sleep -Milliseconds 250
    }
    $global:WDDefaultOurs = $false
}

function global:Invoke-WDUndo {
    param($Steps, [scriptblock]$Say)

    $out = [pscustomobject]@{ Restored = 0; Already = 0; Failed = 0; Notes = (New-Object System.Collections.Generic.List[string]) }
    $n = 0
    foreach ($s in @($Steps)) {
        $n++
        $state = Get-WDStepState $s
        if ($state -eq 'done') {
            $out.Already++
            & $Say @{ Level = 'skip'; Index = $n; Text = "Already back: $(Get-WDStepText $s)" }
            continue
        }
        $r = Invoke-WDStep $s
        if ($r.Ok) {
            $out.Restored++
            $t = Get-WDStepText $s
            if ($r.Note) { $t = "$t - $($r.Note)" }
            & $Say @{ Level = 'ok'; Index = $n; Text = $t }
        } else {
            $out.Failed++
            $msg = "Could not: $(Get-WDStepText $s) - $($r.Note)"
            $out.Notes.Add($msg)
            & $Say @{ Level = 'bad'; Index = $n; Text = $msg }
        }
    }
    $out
}

function global:Get-WDSelectedSteps {
    param($Ids)
    if (-not @($Ids).Count) { return @($global:WDSteps) }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($i in @($Ids)) { $null = $set.Add([string]$i) }
    @($global:WDSteps | Where-Object { $set.Contains([string]$_.Id) })
}

function global:Invoke-WDUndoConsole {
    # Taken as parameters rather than read off script scope: every function here
    # is global so a WPF callback can find it, and a global function reading an
    # unqualified script variable finds nothing.
    param([string[]]$Only = @(), [switch]$ListOnly)

    Write-Host ''
    Write-Host "Undoing Windows Setup Toolkit run $global:WDRun" -ForegroundColor Cyan
    if ($global:WDWhen) { Write-Host "  applied $global:WDWhen" -ForegroundColor DarkGray }
    Write-Host ''

    Start-WDFeatureRead
    Open-WDHives
    if ($global:WDWantsDefault -and -not $global:WDDefaultOk) {
        Write-Host "The default user profile could not be loaded, so $global:WDWantsDefault value(s) that only affect accounts created later cannot be restored." -ForegroundColor Yellow
        Write-Host 'Everything that affects accounts on this machine now is restored regardless.' -ForegroundColor Yellow
        Write-Host ''
    }
    if ($global:WDDismBlocked) {
        Write-Host 'A restart is pending, so Windows features and capabilities cannot be changed yet.' -ForegroundColor Yellow
        Write-Host 'Everything else is restored now. Restart, then run this again to finish those.' -ForegroundColor Yellow
        Write-Host ''
    }

    $steps = Get-WDSelectedSteps $Only

    if ($ListOnly) {
        Write-Host ''
        $todo = 0; $done = 0; $huh = 0
        foreach ($s in $steps) {
            switch (Get-WDStepState $s) {
                'todo'    { $todo++; Write-Host "  still in place : $(Get-WDStepText $s)" }
                'done'    { $done++ }
                'unknown' { $huh++;  Write-Host "  cannot tell    : $(Get-WDStepText $s)" -ForegroundColor DarkGray }
            }
        }
        Write-Host ''
        Write-Host "$todo of $(@($steps).Count) change(s) are still in place, $done already back, $huh not checkable from here."
        Close-WDHives
        return 0
    }

    $say = {
        param($L)
        switch ($L.Level) {
            'ok'   { Write-Host "  $($L.Text)" -ForegroundColor Green }
            'bad'  { Write-Host "  $($L.Text)" -ForegroundColor Red }
            default { }
        }
    }
    $r = Invoke-WDUndo -Steps $steps -Say $say
    Close-WDHives

    Write-Host ''
    Write-Host "$($r.Restored) change(s) put back, $($r.Already) were already back, $($r.Failed) could not be done." -ForegroundColor Cyan
    if ($global:WDReinstall.Count) {
        Write-Host ''
        Write-Host "$($global:WDReinstall.Count) program(s) were uninstalled by that run. Nothing can put those back automatically:" -ForegroundColor Yellow
        foreach ($x in $global:WDReinstall) { Write-Host "    $x" -ForegroundColor Yellow }
    }
    if ($global:WDOwners.Count) {
        Write-Host ''
        Write-Host 'Registry keys whose owner was changed to Administrators (restore with takeown or icacls if you want to):' -ForegroundColor DarkGray
        foreach ($x in $global:WDOwners) { Write-Host "    $x" -ForegroundColor DarkGray }
    }
    Write-Host ''
    if ($r.Failed) {
        Write-Host 'Finished, but not completely - see the lines above. A restart is recommended.' -ForegroundColor Yellow
        return 1
    }
    Write-Host 'Finished. A restart is recommended.' -ForegroundColor Green
    0
}

function global:Get-WDUndoThemeKey {
    param([string]$Theme = '')
    if ($Theme -eq 'dark' -or $Theme -eq 'light') { return $Theme }
    try {
        $v = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        if ($v.AppsUseLightTheme -eq 0) { return 'dark' }
    } catch { }
    'light'
}

function global:Get-WDUndoPalette {
    # Flat is the one addition: a transparent key, so a hover that comes and
    # goes is a resource reference like everything else rather than a literal
    # brush.
    param([string]$Theme)

    if ((Get-WDUndoThemeKey $Theme) -eq 'dark') {
        @{ Dark='1'; Bg='#FF1F1F1F'; Panel='#FF2B2B2B'; Card='#FF303030'; CardSel='#FF37475A'
           Text='#FFBABABA'; Sub='#FF9A9A9A'; Line='#FF454545'; Accent='#FF4CA6FF'
           Ok='#FF5FD07F'; Warn='#FFE8B44A'; Bad='#FFF06C6C'; Muted='#FF9E9E9E'
           RowHover='#FF3A3A3A'; ScrollThumb='#FF5A5A5A'; ScrollThumbHover='#FF8C8C8C'
           BtnBg='#FF3C3C3C'; BtnBorder='#FF5E5E5E'; BtnTint='#26FFFFFF'; FieldBg='#FF262626'
           Flat='#00000000' }
    } else {
        @{ Dark='0'; Bg='#FFF5F5F5'; Panel='#FFFFFFFF'; Card='#FFFAFAFA'; CardSel='#FFE4EEF8'
           Text='#FF141414'; Sub='#FF555555'; Line='#FFD8D8D8'; Accent='#FF0F6CBD'
           Ok='#FF1A7F37'; Warn='#FF8A5A00'; Bad='#FFC03030'; Muted='#FF6B6B6B'
           RowHover='#FFEDEDED'; ScrollThumb='#FFBFBFBF'; ScrollThumbHover='#FF8A8A8A'
           BtnBg='#FFF0F0F0'; BtnBorder='#FFACACAC'; BtnTint='#1A000000'; FieldBg='#FFFFFFFF'
           Flat='#00000000' }
    }
}

function global:Get-WDUndoPaletteKeys {
    ,@('Bg','Panel','Card','CardSel','Text','Sub','Line','Accent','Ok','Warn','Bad','Muted',
       'RowHover','ScrollThumb','ScrollThumbHover','BtnBg','BtnBorder','BtnTint','FieldBg','Flat')
}

function global:Set-WDUndoBrushes {
    # One frozen brush per palette entry, under the key everything points at
    # with a DynamicResource. A theme switch is this function again with the
    # other palette.
    param($Window, $Pal)
    foreach ($k in (Get-WDUndoPaletteKeys)) {
        $b = (New-Object Windows.Media.BrushConverter).ConvertFromString($Pal[$k])
        $b.Freeze()
        $Window.Resources['Wd' + $k] = $b
    }
}

function global:Use-WDUndoNative {
    # One csc invocation for every P/Invoke this script needs: the first in a
    # process costs 400-500 ms and each after it 150-200.
    if ('WDUndo.Native' -as [type]) { return $true }
    try {
        Add-Type -Namespace 'WDUndo' -Name 'Native' -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
"@ -ErrorAction Stop
        return $true
    } catch { return $false }
}

function global:Set-WDUndoConsole {
    param([switch]$Show)
    try {
        if (-not (Use-WDUndoNative)) { return }
        $h = [WDUndo.Native]::GetConsoleWindow()
        if ($h -eq [IntPtr]::Zero) { return }
        # SW_HIDE is 0, SW_SHOWNA is 8 - shown without taking the foreground.
        $null = [WDUndo.Native]::ShowWindow($h, $(if ($Show) { 8 } else { 0 }))
    } catch { }
}

function global:Set-WDUndoDarkTitleBar {
    # A white caption over a dark page is the one part of a window that never
    # follows the theme, and the part always on screen.
    param($Window, [bool]$Dark)
    try {
        if (-not (Use-WDUndoNative)) { return }
        $h = (New-Object Windows.Interop.WindowInteropHelper $Window).EnsureHandle()
        $on = [int]$Dark
        $null = [WDUndo.Native]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)
    } catch { }
}

function global:Set-WDUndoTaskbarIdentity {
    # A taskbar button is grouped by AppUserModelID, and a process that sets
    # none is given one derived from its executable - so the shell draws
    # PowerShell's icon and never consults Window.Icon.
    try {
        if (-not (Use-WDUndoNative)) { return }
        $null = [WDUndo.Native]::SetCurrentProcessExplicitAppUserModelID('WinSetupToolkit.Rollback')
    } catch { }
}

function global:Get-WDUndoIcon {
    # Bytes cross threads and decoded frames do not: a BitmapFrame keeps a
    # reference to its decoder, which belongs to the thread that built it, and
    # Freeze does not freeze the decoder.
    param([string]$Theme = '')
    $b64 = $global:WDIconLight
    if ((Get-WDUndoThemeKey $Theme) -eq 'dark') { $b64 = $global:WDIconDark }
    if (-not $b64) { return $null }
    try {
        $ms = New-Object System.IO.MemoryStream (,[byte[]][Convert]::FromBase64String($b64))
        $dec = New-Object Windows.Media.Imaging.IconBitmapDecoder `
                   $ms, ([Windows.Media.Imaging.BitmapCreateOptions]::None),
                   ([Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $pick = $dec.Frames[0]
        foreach ($f in $dec.Frames) { if ($f.PixelWidth -eq 32) { $pick = $f } }
        if ($pick.CanFreeze) { $pick.Freeze() }
        return $pick
    } catch { return $null }
}

function global:New-WDUndoSplash {
    # On a UI thread of its own, because WPF runs the animation clock on the
    # dispatcher that owns the element and this thread is about to block on
    # reading the machine.
    param([string]$Theme = '', [string]$Caption = '')

    $sync = [hashtable]::Synchronized(@{
        Status = 'Starting up'; Note = ''; Close = $false; Ready = $false; Error = $null
    })

    $xaml = @(
    '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"'
    '        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
    '        WindowStyle="None" AllowsTransparency="True" Background="Transparent"'
    '        WindowStartupLocation="CenterScreen" ShowInTaskbar="True"'
    '        SizeToContent="Manual" Width="470" Height="230" Topmost="True"'
    '        Title="Windows Setup Toolkit">'
    '  <Window.Triggers>'
    '    <EventTrigger RoutedEvent="FrameworkElement.Loaded">'
    '      <BeginStoryboard>'
    '        <Storyboard RepeatBehavior="Forever" AutoReverse="True">'
    '          <DoubleAnimation Storyboard.TargetName="Shift" Storyboard.TargetProperty="X"'
    '                           From="0" To="290" Duration="0:0:1.1">'
    '            <DoubleAnimation.EasingFunction><SineEase EasingMode="EaseInOut"/></DoubleAnimation.EasingFunction>'
    '          </DoubleAnimation>'
    '          <DoubleAnimation Storyboard.TargetName="Shuttle" Storyboard.TargetProperty="Opacity"'
    '                           From="0.55" To="1.0" Duration="0:0:1.1"/>'
    '        </Storyboard>'
    '      </BeginStoryboard>'
    '    </EventTrigger>'
    '  </Window.Triggers>'
    '  <Border Name="Card" CornerRadius="10" BorderThickness="1" Padding="30,26,30,24">'
    '    <StackPanel>'
    '      <TextBlock Name="Title" Text="Windows Setup Toolkit" FontSize="21" FontWeight="SemiBold"/>'
    '      <TextBlock Name="Machine" FontSize="12.5" Margin="0,5,0,0" TextTrimming="CharacterEllipsis"/>'
    '      <Border Name="Track" Height="4" CornerRadius="2" Margin="0,26,0,0" ClipToBounds="True"'
    '              HorizontalAlignment="Stretch">'
    '        <Border Name="Shuttle" Height="4" Width="120" CornerRadius="2" HorizontalAlignment="Left">'
    '          <Border.RenderTransform><TranslateTransform x:Name="Shift" X="0"/></Border.RenderTransform>'
    '        </Border>'
    '      </Border>'
    '      <TextBlock Name="Status" FontSize="13.5" Margin="0,16,0,0" TextWrapping="NoWrap"'
    '                 TextTrimming="CharacterEllipsis"/>'
    '      <TextBlock Name="Detail" FontSize="11.5" Margin="0,4,0,0" TextWrapping="NoWrap"'
    '                 TextTrimming="CharacterEllipsis"/>'
    '    </StackPanel>'
    '  </Border>'
    '</Window>'
    ) -join [Environment]::NewLine

    $key = Get-WDUndoThemeKey $Theme
    $ico = $global:WDIconLight
    if ($key -eq 'dark') { $ico = $global:WDIconDark }

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'          # WPF refuses to start on an MTA thread
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        # Plain data only. The runspace runs none of the functions in this file.
        $rs.SessionStateProxy.SetVariable('Sync',    $sync)
        $rs.SessionStateProxy.SetVariable('Xaml',    $xaml)
        $rs.SessionStateProxy.SetVariable('Pal',     (Get-WDUndoPalette -Theme $key))
        $rs.SessionStateProxy.SetVariable('IconB64', [string]$ico)
        $rs.SessionStateProxy.SetVariable('Caption', [string]$Caption)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript({
            try {
                Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
                $box = $Sync
                $Brush = { param($hex) (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }
                $win = [Windows.Markup.XamlReader]::Parse($Xaml)
                # In a try of its own, which is the lesson rather than the
                # decoration: the splash must not be able to fail over an icon.
                if ($IconB64) {
                    try {
                        $ims = New-Object System.IO.MemoryStream (,[byte[]][Convert]::FromBase64String($IconB64))
                        $idc = New-Object Windows.Media.Imaging.IconBitmapDecoder `
                                   $ims, ([Windows.Media.Imaging.BitmapCreateOptions]::None),
                                   ([Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                        $pick = $idc.Frames[0]
                        foreach ($fr in $idc.Frames) { if ($fr.PixelWidth -eq 32) { $pick = $fr } }
                        if ($pick.CanFreeze) { $pick.Freeze() }
                        $win.Icon = $pick
                    } catch { }
                }
                $get = { param([string]$n) $win.FindName($n) }
                $card = & $get 'Card'
                $card.Background  = & $Brush $Pal.Panel
                $card.BorderBrush = & $Brush $Pal.Line
                (& $get 'Title').Foreground   = & $Brush $Pal.Text
                (& $get 'Track').Background   = & $Brush $Pal.Line
                (& $get 'Shuttle').Background = & $Brush $Pal.Accent
                $status = & $get 'Status'; $status.Foreground = & $Brush $Pal.Text
                $detail = & $get 'Detail'; $detail.Foreground = & $Brush $Pal.Muted
                $machine = & $get 'Machine'
                $machine.Foreground = & $Brush $Pal.Sub
                $machine.Text = [string]$Caption
                $status.Text  = [string]$box.Status
                $win.Add_MouseLeftButtonDown({ try { $this.DragMove() } catch { } })
                $win.Show()

                # Polling at 60ms rather than marshalling each update across,
                # because the caller must never block on the splash.
                $tick = New-Object Windows.Threading.DispatcherTimer
                $tick.Interval = [TimeSpan]::FromMilliseconds(60)
                $tick.Add_Tick({
                    try {
                        $s = [string]$box.Status
                        if ($s -and $status.Text -ne $s) { $status.Text = $s }
                        $n = [string]$box.Note
                        if ($detail.Text -ne $n) { $detail.Text = $n }
                        if ($box.Close) {
                            $tick.Stop(); $win.Close()
                            [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
                        }
                    } catch { }
                }.GetNewClosure())
                $tick.Start()
                $box.Ready = $true
                [Windows.Threading.Dispatcher]::Run()
            } catch {
                $Sync.Error = $_.Exception.Message
                $Sync.Ready = $true      # or the caller waits out the whole timeout
            }
        })
        $handle = $ps.BeginInvoke()
    } catch {
        return $null
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $sync.Ready -and $sw.ElapsedMilliseconds -lt 6000) { Start-Sleep -Milliseconds 15 }

    @{
        State  = $sync
        Status = { param([string]$Text, [string]$Note)
                   if ($Text) { $sync.Status = $Text }
                   $sync.Note = [string]$Note }.GetNewClosure()
        Close  = { $sync.Close = $true
                   $w = [Diagnostics.Stopwatch]::StartNew()
                   while (-not $handle.IsCompleted -and $w.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 10 }
                   try { $ps.Dispose(); $rs.Dispose() } catch { } }.GetNewClosure()
    }
}

function global:Get-WDUndoKind {
    param($S)
    switch ([string]$S.M) {
        'registry'        { 'Registry values' }
        'regfile'         { 'Registry values' }
        'service'         { 'Services' }
        'task'            { 'Scheduled tasks' }
        'unregister-task' { 'Scheduled tasks' }
        'feature'         { 'Windows features' }
        'feature-off'     { 'Windows features' }
        'capability-off'  { 'Windows features' }
        'file-restore'    { 'Files and folders' }
        'rename'          { 'Files and folders' }
        'recycle'         { 'Files and folders' }
        'powercfg'        { 'Power settings' }
        'uninstall'       { 'Installed programs' }
        default           { 'Other' }
    }
}

function global:Show-WDUndoWindow {
    param([string]$Theme = '', [switch]$BuildOnly)

    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    } catch {
        Write-Host 'A window could not be opened on this machine, so this is the console version.' -ForegroundColor Yellow
        return (Invoke-WDUndoConsole)
    }

    $themeKey = Get-WDUndoThemeKey $Theme
    $pal      = Get-WDUndoPalette -Theme $themeKey
    $title    = "Revert changes from Windows Setup Toolkit run $global:WDRun"
    if ($global:WDWhen) { $title += " applied on $global:WDWhen" }

    # The splash gets shorter wording: its subtitle is a single 410px line that
    # does not wrap, and the full title arrived ellipsised with the run id cut
    # off.
    $caption = "Reverting run $global:WDRun"
    if ($global:WDWhen) { $caption += ", applied $global:WDWhen" }

    # Both before the first window exists: the taskbar id because the button
    # takes its icon when it is created, and the console because from here there
    # is a window to look at.
    if (-not $BuildOnly) {
        Set-WDUndoTaskbarIdentity
        Set-WDUndoConsole
    }

    # -BuildOnly shows nothing at all, splash included, so a headless check can
    # ask what the page says without drawing over whatever somebody is doing.
    $splash = $null
    if (-not $BuildOnly) { $splash = New-WDUndoSplash -Theme $themeKey -Caption $caption }
    $tell = {
        param([string]$Text, [string]$Note)
        if ($splash) { & $splash.Status $Text $Note }
    }.GetNewClosure()

    # Where the wait goes, recorded rather than guessed at. Each number has a
    # different answer if it grows: the read is the machine, the rows are WPF
    # construction, the layout is this file's own arranging.
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $ms = @{ Read = 0; Rows = 0; Shell = 0; Layout = 0 }

    & $tell 'Reading what is still in place' ''
    Start-WDFeatureRead
    Open-WDHives

    # One entry per option, each carrying its own steps and one state derived
    # from them. An option is outstanding if any change is still in place - a
    # half-undone option is not undone.
    $order = New-Object System.Collections.Generic.List[string]
    $byId  = @{}
    foreach ($s in @($global:WDSteps)) {
        $id = [string]$s.Id
        if (-not $byId.ContainsKey($id)) {
            $order.Add($id)
            $byId[$id] = [pscustomobject]@{
                Id = $id; Name = [string]$s.Nm; Cat = [string]$s.Cat
                # Empty for a script written with no plan in hand, and for the
                # steps Resolve-WDPlan appends, which are not manifest items.
                Desc = [string]$(if ($global:WDDesc -and $global:WDDesc.ContainsKey($id)) { $global:WDDesc[$id] } else { '' })
                Steps = (New-Object System.Collections.Generic.List[psobject])
                Kinds = (New-Object System.Collections.Generic.List[string])
                Todo = 0; Done = 0; Unknown = 0; State = 'done'
            }
        }
        $byId[$id].Steps.Add($s)
        $k = Get-WDUndoKind $s
        if (-not $byId[$id].Kinds.Contains($k)) { $byId[$id].Kinds.Add($k) }
    }
    $seen = 0
    foreach ($id in $order) {
        $o = $byId[$id]
        $seen++
        & $tell '' "$seen of $($order.Count) - $($o.Name)"
        foreach ($s in $o.Steps) {
            switch (Get-WDStepState $s) {
                'todo'    { $o.Todo++ }
                'done'    { $o.Done++ }
                default   { $o.Unknown++ }
            }
        }
        if ($o.Todo)         { $o.State = 'todo' }
        elseif ($o.Unknown)  { $o.State = 'unknown' }
        else                 { $o.State = 'done' }
        # Counted once here. The footer used to ask the machine again for every
        # change of every ticked option, inside the click handler.
        $o | Add-Member -NotePropertyName Pending -NotePropertyValue ($o.Todo + $o.Unknown) -Force
        # Built beside the counts rather than inside the row builder, so this
        # and the Revert page's builder can be read against each other line by
        # line.
        $o | Add-Member -NotePropertyName Count -NotePropertyValue (@($o.Steps).Count) -Force
        $o | Add-Member -NotePropertyName CountText `
                        -NotePropertyValue (@($o.Steps).Count.ToString() + $(if (@($o.Steps).Count -eq 1) { ' change' } else { ' changes' })) -Force
        $dl = New-Object System.Collections.Generic.List[string]
        foreach ($s in $o.Steps) { $dl.Add('- ' + (Get-WDStepText $s)) }
        $o | Add-Member -NotePropertyName DetailText -NotePropertyValue ($dl -join [Environment]::NewLine) -Force
    }
    $opts = @($order | ForEach-Object { $byId[$_] })

    $totalSteps = @($global:WDSteps).Count
    $totalTodo  = 0; $totalDone = 0; $totalHuh = 0
    foreach ($o in $opts) { $totalTodo += $o.Todo; $totalDone += $o.Done; $totalHuh += $o.Unknown }

    $ms.Read = [int]$clock.ElapsedMilliseconds; $clock.Restart()
    & $tell 'Building the list' ''

    # Every colour is a DynamicResource pointing at a key this script fills in,
    # which is what makes the theme button a repaint rather than a rebuild.
    $x = @(
    '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"'
    '        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
    '        Title="@Title@" Width="1120" Height="760"'
    '        MinWidth="900" MinHeight="600" WindowStartupLocation="CenterScreen"'
    '        Background="{DynamicResource WdBg}" UseLayoutRounding="True"'
    '        TextOptions.TextFormattingMode="Display">'
    '  <Window.Resources>'
    # Always set the Min of whichever dimension is narrowed: the default theme
    # style sets both, and Min beats the plain property in layout - a bare Width
    # reads back 5 while the bar arranges at 17.
    '    <ControlTemplate x:Key="WdVBarTemplate" TargetType="ScrollBar">'
    '      <Grid Background="Transparent">'
    '        <Track Name="PART_Track" IsDirectionReversed="True">'
    '          <Track.Thumb>'
    '            <Thumb Name="WdThumb" Background="{DynamicResource WdScrollThumb}">'
    '              <Thumb.Template>'
    '                <ControlTemplate TargetType="Thumb">'
    # The transparent Grid is the draggable part. A Thumb with no Background is
    # not hit-testable, so only the inset mark was, and the pixels beside it
    # fell through to the track and paged.
    '                  <Grid Background="Transparent">'
    '                    <Border CornerRadius="3" Width="5.5" Margin="0,0,3,0" HorizontalAlignment="Right"'
    '                            Background="{Binding Background, RelativeSource={RelativeSource TemplatedParent}}"/>'
    '                  </Grid>'
    '                </ControlTemplate>'
    '              </Thumb.Template>'
    '            </Thumb>'
    '          </Track.Thumb>'
    '          <Track.IncreaseRepeatButton>'
    '            <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>'
    '          </Track.IncreaseRepeatButton>'
    '          <Track.DecreaseRepeatButton>'
    '            <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>'
    '          </Track.DecreaseRepeatButton>'
    '        </Track>'
    '      </Grid>'
    '      <ControlTemplate.Triggers>'
    '        <Trigger Property="IsMouseOver" Value="True">'
    '          <Setter TargetName="WdThumb" Property="Background" Value="{DynamicResource WdScrollThumbHover}"/>'
    '        </Trigger>'
    '      </ControlTemplate.Triggers>'
    '    </ControlTemplate>'
    '    <ControlTemplate x:Key="WdHBarTemplate" TargetType="ScrollBar">'
    '      <Grid Background="Transparent">'
    '        <Track Name="PART_Track" Orientation="Horizontal">'
    '          <Track.Thumb>'
    '            <Thumb Name="WdThumb" Background="{DynamicResource WdScrollThumb}">'
    '              <Thumb.Template>'
    '                <ControlTemplate TargetType="Thumb">'
    '                  <Grid Background="Transparent">'
    '                    <Border CornerRadius="2" Margin="0,1.5"'
    '                            Background="{Binding Background, RelativeSource={RelativeSource TemplatedParent}}"/>'
    '                  </Grid>'
    '                </ControlTemplate>'
    '              </Thumb.Template>'
    '            </Thumb>'
    '          </Track.Thumb>'
    '          <Track.IncreaseRepeatButton>'
    '            <RepeatButton Command="ScrollBar.PageRightCommand" Opacity="0" Focusable="False"/>'
    '          </Track.IncreaseRepeatButton>'
    '          <Track.DecreaseRepeatButton>'
    '            <RepeatButton Command="ScrollBar.PageLeftCommand" Opacity="0" Focusable="False"/>'
    '          </Track.DecreaseRepeatButton>'
    '        </Track>'
    '      </Grid>'
    '      <ControlTemplate.Triggers>'
    '        <Trigger Property="IsMouseOver" Value="True">'
    '          <Setter TargetName="WdThumb" Property="Background" Value="{DynamicResource WdScrollThumbHover}"/>'
    '        </Trigger>'
    '      </ControlTemplate.Triggers>'
    '    </ControlTemplate>'
    '    <Style x:Key="WdSlimBar" TargetType="ScrollBar">'
    '      <Setter Property="Background" Value="Transparent"/>'
    '      <Style.Triggers>'
    '        <Trigger Property="Orientation" Value="Vertical">'
    '          <Setter Property="Template" Value="{StaticResource WdVBarTemplate}"/>'
    # 16 of hit area carrying a 5.5 mark, as the toolkit's is. Both Width and
    # MinWidth.
    '          <Setter Property="Width" Value="16"/><Setter Property="MinWidth" Value="16"/>'
    '          <Setter Property="Height" Value="Auto"/>'
    '        </Trigger>'
    '        <Trigger Property="Orientation" Value="Horizontal">'
    '          <Setter Property="Template" Value="{StaticResource WdHBarTemplate}"/>'
    '          <Setter Property="Height" Value="7"/><Setter Property="MinHeight" Value="7"/>'
    '          <Setter Property="Width" Value="Auto"/>'
    '        </Trigger>'
    '      </Style.Triggers>'
    '    </Style>'
    '    <Style TargetType="ScrollBar" BasedOn="{StaticResource WdSlimBar}"/>'
    # The rail wants 5px beside a 196px column. An implicit style has to live in
    # the ScrollViewer's own resources to reach the bar inside its template.
    '    <ControlTemplate x:Key="WdRailBarTemplate" TargetType="ScrollBar">'
    '      <Grid Background="Transparent">'
    '        <Track Name="PART_Track" IsDirectionReversed="True">'
    '          <Track.Thumb>'
    '            <Thumb Name="WdRailThumb" Background="{DynamicResource WdScrollThumb}">'
    '              <Thumb.Template>'
    '                <ControlTemplate TargetType="Thumb">'
    '                  <Grid Background="Transparent">'
    '                    <Border CornerRadius="2.5"'
    '                            Background="{Binding Background, RelativeSource={RelativeSource TemplatedParent}}"/>'
    '                  </Grid>'
    '                </ControlTemplate>'
    '              </Thumb.Template>'
    '            </Thumb>'
    '          </Track.Thumb>'
    '          <Track.IncreaseRepeatButton>'
    '            <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>'
    '          </Track.IncreaseRepeatButton>'
    '          <Track.DecreaseRepeatButton>'
    '            <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>'
    '          </Track.DecreaseRepeatButton>'
    '        </Track>'
    '      </Grid>'
    '      <ControlTemplate.Triggers>'
    '        <Trigger Property="IsMouseOver" Value="True">'
    '          <Setter TargetName="WdRailThumb" Property="Background" Value="{DynamicResource WdScrollThumbHover}"/>'
    '        </Trigger>'
    '      </ControlTemplate.Triggers>'
    '    </ControlTemplate>'
    '    <Style x:Key="WdRailBar" TargetType="ScrollBar">'
    '      <Setter Property="Width" Value="5"/><Setter Property="MinWidth" Value="5"/>'
    '      <Setter Property="Background" Value="Transparent"/>'
    '      <Setter Property="Template" Value="{StaticResource WdRailBarTemplate}"/>'
    '    </Style>'
    # Button, ToggleButton, TextBox, and ComboBox keep the system chrome unless
    # retemplated, and that chrome is light in both palettes. Hover is a
    # translucent overlay rather than a Background setter, so a button with a
    # colour of its own is not flattened.
    '    <Style x:Key="WdButton" TargetType="Button">'
    '      <Setter Property="Background" Value="{DynamicResource WdBtnBg}"/>'
    '      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>'
    '      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>'
    '      <Setter Property="BorderThickness" Value="1"/>'
    '      <Setter Property="Padding" Value="10,4"/>'
    '      <Setter Property="SnapsToDevicePixels" Value="True"/>'
    '      <Setter Property="Template">'
    '        <Setter.Value>'
    '          <ControlTemplate TargetType="Button">'
    '            <Grid>'
    '              <Border Name="WdBtnFace" CornerRadius="4" Background="{TemplateBinding Background}"'
    '                      BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"'
    '                      SnapsToDevicePixels="True"/>'
    '              <Border Name="WdBtnTint" CornerRadius="4" Opacity="0" Background="{DynamicResource WdBtnTint}"/>'
    '              <ContentPresenter Margin="{TemplateBinding Padding}"'
    '                                HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"'
    '                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"'
    '                                RecognizesAccessKey="True"'
    '                                TextElement.Foreground="{TemplateBinding Foreground}"/>'
    '            </Grid>'
    '            <ControlTemplate.Triggers>'
    '              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="WdBtnTint" Property="Opacity" Value="0.55"/></Trigger>'
    '              <Trigger Property="IsPressed" Value="True"><Setter TargetName="WdBtnTint" Property="Opacity" Value="1"/></Trigger>'
    '              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="WdBtnFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/></Trigger>'
    '              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>'
    '            </ControlTemplate.Triggers>'
    '          </ControlTemplate>'
    '        </Setter.Value>'
    '      </Setter>'
    '    </Style>'
    '    <Style TargetType="Button" BasedOn="{StaticResource WdButton}"/>'
    # Not BasedOn WdButton: a style's BasedOn target has to be its own type or a
    # base of it, and Button and ToggleButton are siblings under ButtonBase. It
    # parses and then throws on the first element that uses it.
    '    <Style x:Key="WdToggle" TargetType="ToggleButton">'
    '      <Setter Property="Background" Value="{DynamicResource WdBtnBg}"/>'
    '      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>'
    '      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>'
    '      <Setter Property="BorderThickness" Value="1"/>'
    '      <Setter Property="SnapsToDevicePixels" Value="True"/>'
    '      <Setter Property="Template">'
    '        <Setter.Value>'
    '          <ControlTemplate TargetType="ToggleButton">'
    '            <Grid>'
    '              <Border Name="WdTgFace" CornerRadius="4" Background="{TemplateBinding Background}"'
    '                      BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"'
    '                      SnapsToDevicePixels="True"/>'
    '              <Border Name="WdTgTint" CornerRadius="4" Opacity="0" Background="{DynamicResource WdBtnTint}"/>'
    '              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center"'
    '                                VerticalAlignment="Center" RecognizesAccessKey="True"'
    '                                TextElement.Foreground="{TemplateBinding Foreground}"/>'
    '            </Grid>'
    '            <ControlTemplate.Triggers>'
    '              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="WdTgTint" Property="Opacity" Value="0.55"/></Trigger>'
    '              <Trigger Property="IsChecked" Value="True">'
    '                <Setter TargetName="WdTgTint" Property="Opacity" Value="1"/>'
    '                <Setter TargetName="WdTgFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>'
    '              </Trigger>'
    '              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>'
    '            </ControlTemplate.Triggers>'
    '          </ControlTemplate>'
    '        </Setter.Value>'
    '      </Setter>'
    '    </Style>'
    '    <Style x:Key="WdTextBox" TargetType="TextBox">'
    '      <Setter Property="Background" Value="{DynamicResource WdFieldBg}"/>'
    '      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>'
    '      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>'
    '      <Setter Property="CaretBrush" Value="{DynamicResource WdText}"/>'
    '      <Setter Property="SelectionBrush" Value="{DynamicResource WdAccent}"/>'
    '      <Setter Property="BorderThickness" Value="1"/>'
    '      <Setter Property="Template">'
    '        <Setter.Value>'
    '          <ControlTemplate TargetType="TextBox">'
    '            <Border Name="WdTbFace" CornerRadius="4" Background="{TemplateBinding Background}"'
    '                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"'
    '                    SnapsToDevicePixels="True">'
    '              <ScrollViewer Name="PART_ContentHost" Focusable="False" Margin="{TemplateBinding Padding}"'
    '                            HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>'
    '            </Border>'
    '            <ControlTemplate.Triggers>'
    '              <Trigger Property="IsKeyboardFocusWithin" Value="True">'
    '                <Setter TargetName="WdTbFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>'
    '              </Trigger>'
    '            </ControlTemplate.Triggers>'
    '          </ControlTemplate>'
    '        </Setter.Value>'
    '      </Setter>'
    '    </Style>'
    '    <Style TargetType="TextBox" BasedOn="{StaticResource WdTextBox}"/>'
    # A ComboBox draws its closed bar from SelectionBoxItem in its own
    # foreground and its popup on the system window brush, which is white in
    # both themes. Painting the items makes it worse.
    '    <ControlTemplate x:Key="WdComboToggle" TargetType="ToggleButton">'
    '      <Border Name="WdCbFace" CornerRadius="4" Background="{DynamicResource WdFieldBg}"'
    '              BorderBrush="{DynamicResource WdBtnBorder}" BorderThickness="1" SnapsToDevicePixels="True">'
    '        <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,1,9,0"'
    '              Data="M 0 0 L 8 0 L 4 4 Z" Fill="{DynamicResource WdSub}"/>'
    '      </Border>'
    '      <ControlTemplate.Triggers>'
    '        <Trigger Property="IsMouseOver" Value="True">'
    '          <Setter TargetName="WdCbFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>'
    '        </Trigger>'
    '      </ControlTemplate.Triggers>'
    '    </ControlTemplate>'
    '    <Style x:Key="WdCombo" TargetType="ComboBox">'
    '      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>'
    '      <Setter Property="Background" Value="{DynamicResource WdFieldBg}"/>'
    '      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>'
    '      <Setter Property="Padding" Value="8,4,24,4"/>'
    '      <Setter Property="Template">'
    '        <Setter.Value>'
    '          <ControlTemplate TargetType="ComboBox">'
    '            <Grid>'
    '              <ToggleButton Name="WdCbToggle" Focusable="False" ClickMode="Press"'
    '                            Template="{StaticResource WdComboToggle}"'
    '                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>'
    '              <ContentPresenter Name="WdCbText" IsHitTestVisible="False"'
    '                                Content="{TemplateBinding SelectionBoxItem}"'
    '                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"'
    '                                Margin="{TemplateBinding Padding}" HorizontalAlignment="Left"'
    '                                VerticalAlignment="Center" TextElement.Foreground="{TemplateBinding Foreground}"/>'
    '              <Popup Name="PART_Popup" Placement="Bottom" Focusable="False" AllowsTransparency="True"'
    '                     IsOpen="{TemplateBinding IsDropDownOpen}">'
    '                <Border Name="WdCbList" CornerRadius="4" BorderThickness="1"'
    '                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"'
    '                        MaxHeight="{TemplateBinding MaxDropDownHeight}"'
    '                        Background="{DynamicResource WdPanel}" BorderBrush="{DynamicResource WdLine}">'
    '                  <ScrollViewer><StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>'
    '                </Border>'
    '              </Popup>'
    '            </Grid>'
    '          </ControlTemplate>'
    '        </Setter.Value>'
    '      </Setter>'
    '    </Style>'
    '    <Style TargetType="ComboBox" BasedOn="{StaticResource WdCombo}"/>'
    '    <Style x:Key="WdComboItem" TargetType="ComboBoxItem">'
    '      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>'
    '      <Setter Property="Background" Value="Transparent"/>'
    '      <Setter Property="Padding" Value="9,5"/>'
    '      <Setter Property="Template">'
    '        <Setter.Value>'
    '          <ControlTemplate TargetType="ComboBoxItem">'
    '            <Border Name="WdItemFace" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">'
    '              <ContentPresenter TextElement.Foreground="{TemplateBinding Foreground}"/>'
    '            </Border>'
    '            <ControlTemplate.Triggers>'
    '              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="WdItemFace" Property="Background" Value="{DynamicResource WdRowHover}"/></Trigger>'
    '              <Trigger Property="IsSelected" Value="True"><Setter TargetName="WdItemFace" Property="Background" Value="{DynamicResource WdCardSel}"/></Trigger>'
    '            </ControlTemplate.Triggers>'
    '          </ControlTemplate>'
    '        </Setter.Value>'
    '      </Setter>'
    '    </Style>'
    '    <Style TargetType="ComboBoxItem" BasedOn="{StaticResource WdComboItem}"/>'
    '    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="{DynamicResource WdText}"/></Style>'
    '  </Window.Resources>'
    '  <Grid Margin="18,14,0,14">'
    '    <Grid.RowDefinitions>'
    '      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>'
    '      <RowDefinition Height="*"/><RowDefinition Height="Auto"/>'
    '    </Grid.RowDefinitions>'
    '    <DockPanel Grid.Row="0" Margin="0,0,18,12">'
    '      <Button x:Name="BtnTheme" DockPanel.Dock="Right" VerticalAlignment="Top" Margin="12,0,0,0"'
    '              Padding="12,4" FontSize="12.5" MinWidth="106"/>'
    # Non-verbose is the default, as in the application: the standing
    # description is the same on every visit, and Details still carries the
    # whole of it.
    '      <ToggleButton x:Name="BtnVerbose" DockPanel.Dock="Right" VerticalAlignment="Top" Margin="12,0,0,0"'
    '                    Content="Verbose" Padding="12,4" FontSize="12.5" MinWidth="92"'
    '                    Style="{StaticResource WdToggle}"'
    '                    ToolTip="Show the one-line description under every option. Off by default - Details still shows it for one option at a time."/>'
    '      <StackPanel>'
    '        <TextBlock x:Name="Head" FontSize="20" FontWeight="SemiBold" TextWrapping="Wrap"'
    '                   Foreground="{DynamicResource WdText}"/>'
    '        <TextBlock x:Name="Sub1" FontSize="12.5" Margin="0,4,0,0" TextWrapping="Wrap"'
    '                   Foreground="{DynamicResource WdSub}"/>'
    '        <TextBlock x:Name="Sub2" FontSize="12.5" Margin="0,4,0,0" TextWrapping="Wrap"'
    '                   Foreground="{DynamicResource WdSub}"/>'
    '      </StackPanel>'
    '    </DockPanel>'
    '    <Border x:Name="Bar" Grid.Row="1" Background="{DynamicResource WdPanel}"'
    '            BorderBrush="{DynamicResource WdLine}" BorderThickness="1"'
    '            CornerRadius="4" Padding="12,9,12,10" Margin="0,0,18,10">'
    '      <StackPanel>'
    '        <DockPanel LastChildFill="True">'
    '          <ToggleButton x:Name="BtnFilter" Content="Filter" Padding="12,3" FontSize="12.5"'
    '                        Style="{StaticResource WdToggle}" Margin="0,0,12,0" MinWidth="118"/>'
    '          <TextBlock Text="Group by" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="12.5"'
    '                     Foreground="{DynamicResource WdText}"/>'
    '          <ComboBox x:Name="CmbOrder" Width="160" FontSize="12.5" Margin="0,0,12,0"/>'
    '          <TextBlock Text="Sort by" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="12.5"'
    '                     Foreground="{DynamicResource WdText}"/>'
    '          <ComboBox x:Name="CmbSort" Width="152" FontSize="12.5" Margin="0,0,16,0"/>'
    '          <Button x:Name="BtnSelectAll" Content="Select all" Padding="10,3" FontSize="12.5"'
    '                  Margin="0,0,16,0" MinWidth="90"'
    '                  ToolTip="Selects every option on screen that can be reverted. Press again to clear them."/>'
    '          <TextBlock Text="Collapse all" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="12.5"'
    '                     Foreground="{DynamicResource WdText}"/>'
    '          <Button x:Name="BtnCollapseAll" Content="-" Width="26" Padding="0,1" FontSize="13"'
    '                  FontWeight="Bold" Margin="0,0,4,0" ToolTip="Collapse every group on the page"/>'
    '          <Button x:Name="BtnExpandAll" Content="+" Width="26" Padding="0,1" FontSize="13"'
    '                  FontWeight="Bold" Margin="0,0,16,0" ToolTip="Expand every group on the page"/>'
    # This page is a reading of the machine taken when it was built, and
    # somebody may have put something back by hand since.
    '          <Button x:Name="BtnRefresh" Content="Refresh" Padding="10,3" FontSize="12.5" Margin="0,0,16,0"'
    '                  ToolTip="Reads this machine again and rebuilds the page, so anything put back by hand since it was opened is accounted for."/>'
    '          <TextBlock x:Name="TxtCount" VerticalAlignment="Center" Margin="0,0,16,0" FontSize="12.5"'
    '                     Foreground="{DynamicResource WdSub}"/>'
    '          <TextBlock Text="Search" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="12.5"'
    '                     Foreground="{DynamicResource WdText}"/>'
    '          <TextBox x:Name="Find" Padding="7,3" FontSize="12.5" MinWidth="140"/>'
    '        </DockPanel>'
    '        <WrapPanel x:Name="FilterChips" Margin="0,9,0,0" Visibility="Collapsed"/>'
    '      </StackPanel>'
    '    </Border>'
    '    <Popup x:Name="FilterPopup" PlacementTarget="{Binding ElementName=BtnFilter}" Placement="Bottom"'
    '           StaysOpen="False" AllowsTransparency="True" VerticalOffset="4"'
    '           IsOpen="{Binding IsChecked, ElementName=BtnFilter, Mode=TwoWay}">'
    '      <Border Background="{DynamicResource WdPanel}" BorderBrush="{DynamicResource WdLine}"'
    '              BorderThickness="1" CornerRadius="6" Padding="16,12" MinWidth="300">'
    '        <StackPanel>'
    '          <ScrollViewer MaxHeight="430" VerticalScrollBarVisibility="Auto">'
    '            <StackPanel x:Name="FilterPanel"/>'
    '          </ScrollViewer>'
    '          <DockPanel LastChildFill="False" Margin="0,12,0,0">'
    '            <Button x:Name="BtnFilterClear" Content="Clear all" Padding="12,4" FontSize="12.5"/>'
    '            <Button x:Name="BtnFilterDone" DockPanel.Dock="Right" Content="Done" Padding="16,4" FontSize="12.5" Margin="0"/>'
    '          </DockPanel>'
    '        </StackPanel>'
    '      </Border>'
    '    </Popup>'
    # Three columns with a splitter, because where the rail should stop depends
    # on which names are in it. No right margin on the grid: the list's own
    # scroller carries the inset as padding, so the bar stays against the window
    # edge.
    '    <Grid x:Name="ListPage" Grid.Row="2">'
    '      <Grid.ColumnDefinitions>'
    '        <ColumnDefinition x:Name="IndexCol" Width="196" MinWidth="120" MaxWidth="420"/>'
    '        <ColumnDefinition Width="Auto"/>'
    '        <ColumnDefinition Width="*"/>'
    '      </Grid.ColumnDefinitions>'
    '      <ScrollViewer x:Name="RailScroll" Grid.Column="0" VerticalScrollBarVisibility="Auto"'
    '                    HorizontalScrollBarVisibility="Disabled">'
    '        <ScrollViewer.Resources>'
    '          <Style TargetType="ScrollBar" BasedOn="{StaticResource WdRailBar}"/>'
    '        </ScrollViewer.Resources>'
    '        <StackPanel x:Name="Rail" Margin="0,0,6,0"/>'
    '      </ScrollViewer>'
    '      <Border Grid.Column="1" Width="1" Margin="9,0,0,0" HorizontalAlignment="Left"'
    '              IsHitTestVisible="False" Background="{DynamicResource WdLine}"/>'
    '      <GridSplitter Grid.Column="1" Width="10" HorizontalAlignment="Center"'
    '                    VerticalAlignment="Stretch" Background="Transparent" ShowsPreview="False"/>'
    '      <ScrollViewer x:Name="Scroll" Grid.Column="2" Padding="14,0,14,0"'
    '                    VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">'
    '        <StackPanel x:Name="List"/>'
    '      </ScrollViewer>'
    '    </Grid>'
    '    <Grid x:Name="RunPage" Grid.Row="2" Margin="0,0,18,0" Visibility="Collapsed">'
    '      <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>'
    '      <Border Grid.Row="0" Background="{DynamicResource WdPanel}" BorderBrush="{DynamicResource WdLine}"'
    '              BorderThickness="1" CornerRadius="4">'
    '        <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto" Padding="10">'
    '          <StackPanel x:Name="Log"/>'
    '        </ScrollViewer>'
    '      </Border>'
    '      <TextBlock x:Name="RunNote" Grid.Row="1" Margin="2,10,0,0" FontSize="12.5" TextWrapping="Wrap"'
    '                 Foreground="{DynamicResource WdSub}"/>'
    '    </Grid>'
    '    <DockPanel Grid.Row="3" Margin="0,12,18,0">'
    '      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">'
    '        <Button x:Name="BtnGo" Content="Revert selected" Padding="14,5" Margin="0,0,8,0"/>'
    '        <Button x:Name="BtnClose" Content="Close" Padding="14,5" Margin="0"/>'
    '      </StackPanel>'
    '      <TextBlock x:Name="Tally" VerticalAlignment="Center" FontSize="12.5" TextWrapping="Wrap"'
    '                 Foreground="{DynamicResource WdSub}"/>'
    '    </DockPanel>'
    '  </Grid>'
    '</Window>'
    ) -join [Environment]::NewLine

    $esc = ([string]$title).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    $x = $x.Replace('@Title@', $esc)

    $win = $null
    try {
        $win = [Windows.Markup.XamlReader]::Parse($x)
    } catch {
        if ($splash) { & $splash.Close }
        # The console was hidden on the way in, so anything falling through to
        # printing has to put it back.
        Set-WDUndoConsole -Show
        Write-Host "The window could not be built ($($_.Exception.Message)), so this is the console version." -ForegroundColor Yellow
        Close-WDHives
        return (Invoke-WDUndoConsole)
    }
    Set-WDUndoBrushes -Window $win -Pal $pal

    $ui = @{}
    foreach ($n in @('Head','Sub1','Sub2','Bar','Find','BtnTheme','BtnVerbose','BtnFilter','FilterPopup','FilterPanel',
                     'FilterChips','BtnFilterClear','BtnFilterDone','CmbOrder','CmbSort','BtnSelectAll','BtnCollapseAll',
                     'BtnExpandAll','BtnRefresh','TxtCount','IndexCol','RailScroll','Rail','Scroll','List','ListPage',
                     'RunPage','Log','LogScroll','RunNote','BtnGo','BtnClose','Tally')) {
        $ui[$n] = $win.FindName($n)
    }

    # The property identifier has to come from the type that declares it - a
    # TextBlock's Foreground is TextElement's, a Control's is Control's, and the
    # wrong one throws.
    $dpCache = @{}
    $Ref = {
        param($El, [string]$Prop, [string]$Key)
        $ck = $El.GetType().Name + '|' + $Prop
        if (-not $dpCache.ContainsKey($ck)) {
            $dp = $null
            switch ($Prop) {
                'Foreground' {
                    if ($El -is [Windows.Controls.TextBlock]) { $dp = [Windows.Controls.TextBlock]::ForegroundProperty }
                    else { $dp = [Windows.Controls.Control]::ForegroundProperty }
                }
                'Background' {
                    if     ($El -is [Windows.Controls.Border])    { $dp = [Windows.Controls.Border]::BackgroundProperty }
                    elseif ($El -is [Windows.Controls.Panel])     { $dp = [Windows.Controls.Panel]::BackgroundProperty }
                    elseif ($El -is [Windows.Controls.TextBlock]) { $dp = [Windows.Controls.TextBlock]::BackgroundProperty }
                    else { $dp = [Windows.Controls.Control]::BackgroundProperty }
                }
                'BorderBrush' {
                    if ($El -is [Windows.Controls.Border]) { $dp = [Windows.Controls.Border]::BorderBrushProperty }
                    else { $dp = [Windows.Controls.Control]::BorderBrushProperty }
                }
            }
            $dpCache[$ck] = $dp
        }
        $dp = $dpCache[$ck]
        if ($dp) { $El.SetResourceReference($dp, 'Wd' + $Key) }
    }.GetNewClosure()

    $palBox = @{ Key = $themeKey; Cur = $pal }
    $applyTheme = {
        param([string]$Key)
        $p = Get-WDUndoPalette -Theme $Key
        $palBox.Key = $Key
        $palBox.Cur = $p
        Set-WDUndoBrushes -Window $win -Pal $p
        Set-WDUndoDarkTitleBar -Window $win -Dark ($p.Dark -eq '1')
        $ui.BtnTheme.Content = $(if ($p.Dark -eq '1') { 'Light theme' } else { 'Dark theme' })
        $ic = Get-WDUndoIcon -Theme $Key
        if ($ic) { $win.Icon = $ic }
    }.GetNewClosure()

    $ui.BtnTheme.Content = $(if ($pal.Dark -eq '1') { 'Light theme' } else { 'Dark theme' })
    $ui.BtnTheme.ToolTip = 'Switch between the dark and light palettes.'
    $ico = Get-WDUndoIcon -Theme $themeKey
    if ($ico) { $win.Icon = $ico }
    if (-not $BuildOnly) { Set-WDUndoDarkTitleBar -Window $win -Dark ($pal.Dark -eq '1') }

    $win.Title    = $title
    $ui.Head.Text = $title

    # One place that counts the heading, because Refresh reads the machine again
    # and these are the numbers it changes.
    $saySummary = {
        param([string]$Extra)
        $tTodo = 0; $tDone = 0; $tHuh = 0; $tSteps = 0
        foreach ($o in $opts) {
            $tSteps += [int]@($o.Steps).Count
            $tTodo  += [int]$o.Todo; $tDone += [int]$o.Done; $tHuh += [int]$o.Unknown
        }
        $ui.Sub1.Text = 'Nothing here happens until you press Revert selected.'
        $bits = New-Object System.Collections.Generic.List[string]
        $bits.Add("$tTodo of $tSteps changes are still in place")
        if ($tDone) { $bits.Add("$tDone already back") }
        if ($tHuh)  { $bits.Add("$tHuh could not be checked from here") }
        $txt = ($bits -join ', ') + '.'
        if ($global:WDWantsDefault -and -not $global:WDDefaultOk) {
            $txt += " The default user profile could not be loaded, so $global:WDWantsDefault value(s) affecting accounts created later cannot be read or restored."
        }
        if ($global:WDDismBlocked) {
            $txt += ' A restart is pending, so Windows features cannot be changed until this machine has restarted.'
        }
        if ($Extra) { $txt += ' ' + $Extra }
        $ui.Sub2.Text = $txt
    }.GetNewClosure()
    & $saySummary ''

    # Built once, and re-parented by every change of grouping.
    $ms.Shell = [int]$clock.ElapsedMilliseconds; $clock.Restart()

    $rows = New-Object System.Collections.Generic.List[psobject]
    $tag  = @{ done = 'already back'; unknown = 'cannot tell from here' }
    $col  = @{ done = 'Ok';           unknown = 'Muted' }

    # Declared before the row loop, and that placement is load-bearing: $makeRow
    # resolves $state when it runs. Declared after, every row read $null.Terse
    # as falsy.
    $state = @{ Group = 'category'; Sort = 'name'; Booting = $true; Terse = $true }

    # Reports progress like the machine read does: a line that does not move for
    # three seconds says the same thing a frozen one does.
    $makeRow = {
        param($O, $RefFn, $TagText, $TagInk)
        $Ref = $RefFn
        $card = New-Object Windows.Controls.Border
        $card.CornerRadius = 3; $card.Padding = '8,5,8,6'; $card.Margin = '0,0,0,3'
        & $Ref $card 'Background' 'Flat'

        # The same shape as the toolkit's own row, which is the point of this
        # whole file. The tick box is docked left of a stack that fills, so
        # everything under the name starts at the name's own left edge.
        $panel = New-Object Windows.Controls.DockPanel
        $panel.LastChildFill = $true

        $cb = New-Object Windows.Controls.CheckBox
        $cb.VerticalAlignment = 'Top'; $cb.Margin = '0,4,8,0'
        $cb.IsChecked = ($O.State -ne 'done')
        $cb.IsEnabled = ($O.State -ne 'done')
        [Windows.Controls.DockPanel]::SetDock($cb, 'Left')
        $null = $panel.Children.Add($cb)

        $stack = New-Object Windows.Controls.StackPanel

        # A name then some chips is a WrapPanel and never a horizontal
        # StackPanel: that measures children with infinite width, so nothing
        # wraps and the last chip is drawn off the card.
        $line = New-Object Windows.Controls.WrapPanel

        $nm = New-Object Windows.Controls.TextBlock
        # 15 and SemiBold, as an Advanced row's name is.
        $nm.Text = $O.Name; $nm.FontSize = 15; $nm.FontWeight = 'SemiBold'
        # Wrap, as the toolkit's row does: a WrapPanel arranges a child at its
        # desired width, and an unwrapped TextBlock desires all of its text
        # however narrow the column.
        $nm.TextWrapping = 'Wrap'
        # The key in a variable rather than an if-expression in the argument:
        # the closure check reads the literals handed to $Ref to confirm each is
        # a real theme key.
        $nmInk = 'Text'
        if ($O.State -eq 'done') {
            $nmInk = 'Muted'
            # Struck through and dimmed, exactly as an Advanced row is when its
            # target is not on this machine. A line through a name is the one
            # mark that cannot be mistaken for a style choice.
            $nm.TextDecorations = [Windows.TextDecorations]::Strikethrough
        }
        & $Ref $nm 'Foreground' $nmInk
        $null = $line.Children.Add($nm)

        $tagEl = $null
        if ($TagText.ContainsKey($O.State)) {
            $tagEl = New-Object Windows.Controls.TextBlock
            # 11 at '6,4,0,0', as every tag on an Advanced row is.
            $tagEl.Text = '  ' + $TagText[$O.State]; $tagEl.FontSize = 11; $tagEl.Margin = '6,4,0,0'
            & $Ref $tagEl 'Foreground' $TagInk[$O.State]
            $null = $line.Children.Add($tagEl)
        }

        $cnt = New-Object Windows.Controls.TextBlock
        $cnt.Text = '  ' + $O.CountText
        $cnt.FontSize = 11; $cnt.Margin = '6,4,0,0'
        & $Ref $cnt 'Foreground' 'Muted'
        $null = $line.Children.Add($cnt)

        # A real face and the button border, so it reads as a control at rest
        # rather than a bordered label whose only tell is a hover tint.
        $chip = New-Object Windows.Controls.Border
        $chip.CornerRadius = 4; $chip.Padding = '9,2,9,3'; $chip.Margin = '8,2,0,0'
        $chip.BorderThickness = New-Object Windows.Thickness 1
        $chip.VerticalAlignment = 'Center'
        & $Ref $chip 'BorderBrush' 'BtnBorder'
        & $Ref $chip 'Background' 'BtnBg'
        $chip.Cursor = 'Hand'
        $ct = New-Object Windows.Controls.TextBlock
        $ct.Text = 'Details'; $ct.FontSize = 11
        & $Ref $ct 'Foreground' 'Text'
        $chip.Child = $ct
        $null = $line.Children.Add($chip)
        $null = $stack.Children.Add($line)

        # The always-on description, in the tense this page is written in - see
        # Get-WDRevertDescription.
        $dsc = [string]$O.Desc
        $dscEl = $null
        if ($dsc) {
            $dt = New-Object Windows.Controls.TextBlock
            $dt.Text = $dsc; $dt.FontSize = 13; $dt.TextWrapping = 'Wrap'
            $dt.Margin = '0,2,0,0'
            & $Ref $dt 'Foreground' 'Sub'
            # Built collapsed under Non-verbose rather than skipped, so turning
            # the option back off does not need the page rebuilt.
            if ($state.Terse) { $dt.Visibility = 'Collapsed' }
            $null = $stack.Children.Add($dt)
            $dscEl = $dt
        }

        # Every option arrives ticked, so clearing one is an edit and is marked
        # like one. The words are the half a colour cannot carry: here a tick is
        # what will be undone.
        $skip = New-Object Windows.Controls.TextBlock
        $skip.Text = 'Option will not be reverted'
        $skip.FontSize = 12.5; $skip.TextWrapping = 'Wrap'; $skip.Margin = '0,4,0,0'
        $skip.Visibility = 'Collapsed'
        & $Ref $skip 'Foreground' 'Bad'
        $null = $stack.Children.Add($skip)

        $null = $panel.Children.Add($stack)
        $card.Child = $panel

        # Under the row rather than in a dialog: an answer that covers the
        # question while you read it is the wrong shape for this page.
        $detText = [string]$O.DetailText

        # GetNewClosure snapshots this block's locals, so each row's handlers
        # hold their own elements.
        $refL = $RefFn
        # A local of this invocation, never a reach up the chain: this block is
        # invoked with &, so a closure built in it copies these locals and
        # nothing of the function's.
        $stateHere = $state
        $hold = @{ Det = $null }
        $chip.Add_MouseLeftButtonUp({
            if ($hold.Det -and $hold.Det.Visibility -eq 'Visible') {
                $hold.Det.Visibility = 'Collapsed'
                return
            }
            if (-not $hold.Det) {
                # 12 at LineHeight 18, as the Advanced panel is. No left indent
                # - the stack begins at the name, because the tick box is docked
                # outside it.
                $d = New-Object Windows.Controls.TextBlock
                $d.FontSize = 12; $d.Margin = '0,4,8,7'
                $d.TextWrapping = 'Wrap'; $d.LineHeight = 18
                $d.LineStackingStrategy = 'BlockLineHeight'
                & $refL $d 'Foreground' 'Sub'
                $null = $stack.Children.Add($d)
                $hold.Det = $d
            }
            # Set on every open, not once: under Non-verbose the row is not
            # showing its description, so the panel carries it.
            $body = $detText
            if ($stateHere.Terse -and $dsc) { $body = $dsc + [Environment]::NewLine + [Environment]::NewLine + $detText }
            $hold.Det.Text = $body
            $hold.Det.Visibility = 'Visible'
        }.GetNewClosure())
        $chip.Add_MouseEnter({ & $refL $ct 'Foreground' 'Accent' }.GetNewClosure())
        $chip.Add_MouseLeave({ & $refL $ct 'Foreground' 'Text' }.GetNewClosure())

        # A row with nothing left to decide is inert: no hand cursor and no
        # hover tint, because the tint is this application's signal for "you can
        # act on this".
        if ($O.State -eq 'done') {
            $card.Cursor  = 'Arrow'
            $card.Opacity = 0.6
        } else {
            $card.Cursor = 'Hand'
            $card.Add_MouseEnter({ & $refL $card 'Background' 'RowHover' }.GetNewClosure())
            $card.Add_MouseLeave({ & $refL $card 'Background' 'Flat'     }.GetNewClosure())
        }

        # Clicking the row ticks it, because the box is a 13px target on a row a
        # column wide. A Button marks its click handled first, so the Details
        # chip does not also toggle the row.
        $card.Add_MouseLeftButtonUp({
            if (-not $args[1].Handled -and $this.Tag.Box.IsEnabled) {
                $this.Tag.Box.IsChecked = -not [bool]$this.Tag.Box.IsChecked
                if ($this.Tag.After) { & $this.Tag.After }
            }
        }.GetNewClosure())
        $card.Tag = @{ Box = $cb; After = $null }

        [pscustomobject]@{
            Opt = $O; Card = $card; Check = $cb; Tag = $tagEl
            # Handed out rather than walked to: reaching the name as
            # Card.Child.Children[0] describes the layout rather than the row,
            # and moving the tick box outside the stack silently broke it.
            Line = $line
            NameEl = $nm; Skip = $skip
            Detail = $hold; DetailText = $detText; Desc = $dsc; DescEl = $dscEl
            Cat = [string]$O.Cat; Name = [string]$O.Name
            Kinds = @($O.Kinds); Count = [int]$O.Count
            # Declared here rather than added later: a pscustomobject takes a
            # new property only through Add-Member.
            GKey = ''
        }
    }.GetNewClosure()

    $made = 0
    foreach ($o in $opts) {
        $made++
        & $tell 'Building the list' "$made of $($opts.Count) - $($o.Name)"
        $rows.Add((& $makeRow $o $Ref $tag $col))
    }

    $ms.Rows = [int]$clock.ElapsedMilliseconds; $clock.Restart()

    # Two controls, not one, and every pairing means something - so there is
    # nothing to gray out.
    $GROUPS = @(
        @{ Key = 'category'; Label = 'Category' }
        @{ Key = 'status';   Label = 'What is left' }
        @{ Key = 'kind';     Label = 'Kind of change' }
        @{ Key = 'alpha';    Label = 'Name (A-Z)' }
    )
    $SORTS = @(
        @{ Key = 'name';     Label = 'Name (A-Z)' }
        @{ Key = 'selected'; Label = 'Selected first' }
        @{ Key = 'most';     Label = 'Most changes first' }
    )
    $STATE_LABEL = @{ todo = 'Still in place'; unknown = 'Cannot tell from here'; done = 'Already back' }
    $STATE_RANK  = @{ todo = 0;                unknown = 1;                       done = 2 }
    # The Revert page's table, entry for entry, including one kind nothing here
    # produces. A rank for a kind that never appears costs nothing; a missing
    # one sorts to the top.
    $KIND_RANK   = @{ 'Registry values' = 0; 'Services' = 1; 'Scheduled tasks' = 2
                      'Windows features' = 3; 'Files and folders' = 4; 'Power settings' = 5
                      'Installed programs' = 6; 'Recurring effects' = 7; 'Other' = 8 }

    $catOrder = @{}
    $catSeen = 0
    foreach ($r in $rows) { if (-not $catOrder.ContainsKey($r.Cat)) { $catOrder[$r.Cat] = $catSeen; $catSeen++ } }

    $alphaOf = {
        param([string]$Name)
        if (-not $Name.Length) { return @{ Key = 'zz'; Label = 'Other' } }
        $c = ([string]$Name.Substring(0, 1)).ToUpper()
        if ($c -notmatch '^[A-Z]$') { return @{ Key = 'zz'; Label = 'Other' } }
        foreach ($b in @(@('A','E'), @('F','J'), @('K','O'), @('P','T'), @('U','Z'))) {
            if ($c -ge $b[0] -and $c -le $b[1]) { return @{ Key = $b[0]; Label = "$($b[0]) - $($b[1])" } }
        }
        @{ Key = 'zz'; Label = 'Other' }
    }

    $groupsFor = {
        param([string]$Mode)
        $out   = New-Object System.Collections.Generic.List[psobject]
        $index = @{}
        $add = {
            param([string]$Key, [string]$Label, [int]$Rank, $Row)
            if (-not $index.ContainsKey($Key)) {
                $g = [pscustomobject]@{
                    Key = $Key; Label = $Label; Rank = $Rank
                    Members = (New-Object System.Collections.Generic.List[psobject])
                }
                $index[$Key] = $g
                $out.Add($g)
            }
            $index[$Key].Members.Add($Row)
        }
        foreach ($r in $rows) {
            switch ($Mode) {
                'status' { & $add $r.Opt.State $STATE_LABEL[$r.Opt.State] $STATE_RANK[$r.Opt.State] $r }
                'kind'   {
                    # An option can touch more than one kind, so it is filed
                    # under its first. Filing it under all would list the same
                    # tick twice.
                    $k = [string]@($r.Kinds)[0]
                    & $add $k $k ([int]$KIND_RANK[$k]) $r
                }
                'alpha'  { $a = & $alphaOf $r.Name; & $add $a.Key $a.Label 0 $r }
                default  { & $add $r.Cat $r.Cat ([int]$catOrder[$r.Cat]) $r }
            }
        }
        if ($Mode -eq 'alpha') { return ,@($out | Sort-Object @{ E = { $_.Key } }) }
        ,@($out | Sort-Object @{ E = { $_.Rank } }, @{ E = { $_.Label } })
    }.GetNewClosure()

    $sortMembers = {
        param($Members, [string]$Mode)
        switch ($Mode) {
            'selected' { ,@($Members | Sort-Object @{ E = { if ($_.Check.IsChecked) { 0 } else { 1 } } }, @{ E = { $_.Name } }) }
            'most'     { ,@($Members | Sort-Object @{ E = { -1 * $_.Count } }, @{ E = { $_.Name } }) }
            default    { ,@($Members | Sort-Object @{ E = { $_.Name } }) }
        }
    }

    # OR within a group and AND across groups.
    $FILTER_GROUPS = @('State', 'View', 'Kind', 'Cat')
    $filterSel = @{}
    foreach ($fg in $FILTER_GROUPS) { $filterSel[$fg] = New-Object System.Collections.Generic.List[string] }
    $filterBoxes = New-Object System.Collections.Generic.List[psobject]
    # Selected only / Unselected only are a snapshot: a live query deletes the
    # row you just clicked out from under the pointer.
    $viewSnap = @{ Ids = $null }
    # The holder that breaks the cycle: a chip has to un-tick a box, drop the
    # facet, and re-filter, and it is built by the filter pass it has to call.
    $fx = @{ Filter = $null; Pairs = $null }

    $blocks    = New-Object System.Collections.Generic.List[psobject]
    $railCards = New-Object System.Collections.Generic.List[psobject]
    $spy       = @{ Offsets = $null; On = '' }

    # On $state rather than in a local, because Refresh rebuilds the rows and
    # $paintCounts is a closure - a captured int would keep its number for the
    # life of the window.
    $state.Tickable = @($rows | Where-Object { $_.Check.IsEnabled }).Count

    # Whatever the person just did shows immediately; the expensive consequence
    # catches up. Render priority rather than a DispatcherFrame: it flushes
    # layout and stops, so a second click cannot re-enter the handler.
    $showNow = { [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, 'Render') }

    # One pass over the rows, and that is the whole of why a tick used to take a
    # second to appear.
    $paintCounts = {
        $on = @{}; $can = @{}; $free = @{}; $all = @{}
        $pickedCount = 0
        $chg = 0
        $pageLive = 0; $pageFree = 0
        foreach ($r in $rows) {
            $ticked = [bool]$r.Check.IsChecked
            if ($ticked) { $pickedCount++; $chg += [int]$r.Opt.Pending }

            # Marked in the pass already walking every row - two property sets,
            # and only where the answer moved.
            if (-not $ticked -and $r.Check.IsEnabled) {
                & $Ref $r.NameEl 'Foreground' 'Bad'; $r.NameEl.FontWeight = 'Bold'
                $r.Skip.Visibility = 'Visible'
            } elseif ($r.Skip.Visibility -eq 'Visible') {
                & $Ref $r.NameEl 'Foreground' 'Text'; $r.NameEl.FontWeight = 'SemiBold'
                $r.Skip.Visibility = 'Collapsed'
            }

            if ($r.Check.IsEnabled -and $r.Card.Visibility -eq 'Visible') {
                $pageLive++
                if (-not $ticked) { $pageFree++ }
            }
            $k = [string]$r.GKey
            if (-not $k) { continue }
            if (-not $on.ContainsKey($k)) { $on[$k] = 0; $can[$k] = 0; $free[$k] = 0; $all[$k] = 0 }
            # Counted before the enabled test, because a group can be made
            # entirely of rows that refuse a tick and still have that many rows
            # in it.
            $all[$k]++
            if (-not $r.Check.IsEnabled) { continue }
            $can[$k]++
            if ($ticked) { $on[$k]++ }
            elseif ($r.Card.Visibility -eq 'Visible') { $free[$k]++ }
        }
        foreach ($rc in $railCards) {
            $k = [string]$rc.Key
            $rcOn  = 0; if ($on.ContainsKey($k))  { $rcOn  = $on[$k] }
            $rcCan = 0; if ($can.ContainsKey($k)) { $rcCan = $can[$k] }
            $rcAll = 0; if ($all.ContainsKey($k)) { $rcAll = $all[$k] }
            # A fraction is about what is left to decide, and some groups have
            # nothing left and plenty in them. A bare count in Ok for a settled
            # group, the fraction where there are decisions, 0/0 only when there
            # is nothing there.
            if ($rcAll -gt 0 -and $rcCan -eq 0) {
                $rc.Num.Text = "$rcAll"
                & $Ref $rc.Num 'Foreground' 'Ok'
            } else {
                $rc.Num.Text = "$rcOn/$rcCan"
                if     ($rcCan -eq 0)     { & $Ref $rc.Num 'Foreground' 'Muted' }
                elseif ($rcOn -eq $rcCan) { & $Ref $rc.Num 'Foreground' 'Ok' }
                else                      { & $Ref $rc.Num 'Foreground' 'Accent' }
            }
            $rc.Card.Opacity = $(if ($rc.Live) { 1.0 } else { 0.45 })
        }
        foreach ($b in $blocks) {
            $k = [string]$b.Key
            $anyFree = $false; if ($free.ContainsKey($k)) { $anyFree = ($free[$k] -gt 0) }
            # A group with nothing to take reads "Select all" rather than
            # offering to clear a selection that is not there.
            $b.SelAll.Content   = $(if ($anyFree -or -not $b.VisEnabled) { 'Select all' } else { 'Select none' })
            $b.SelAll.IsEnabled = [bool]$b.VisEnabled
        }
        # The page-wide twin, on the same rule and wording. Counted over visible
        # rows, so a search narrows what it takes.
        $ui.BtnSelectAll.Content   = $(if ($pageFree -or -not $pageLive) { 'Select all' } else { 'Select none' })
        $ui.BtnSelectAll.IsEnabled = [bool]$pageLive
        $ui.Tally.Text = "$pickedCount of $($state.Tickable) options selected, $chg change(s) to put back."
        $ui.BtnGo.IsEnabled = [bool]$pickedCount
    }.GetNewClosure()

    # Offsets measured once into a table and thrown away by anything that moves
    # a heading - a filter pass, a re-order, a fold, a resize.
    $spyRun = {
        if (-not $blocks.Count) { return }
        if ($ui.ListPage.Visibility -ne 'Visible') { return }
        if ($ui.Scroll.ActualHeight -le 0) { return }
        if (-not $spy.Offsets) {
            $ui.Scroll.UpdateLayout()
            $t = @{}
            foreach ($b in $blocks) {
                try {
                    $p = $b.Block.TransformToAncestor($ui.Scroll.Content).Transform((New-Object Windows.Point 0, 0))
                    $t[$b.Key] = [double]$p.Y
                } catch { $t[$b.Key] = 0.0 }
            }
            $spy.Offsets = $t
        }
        $y = [double]$ui.Scroll.VerticalOffset + 12
        $best = ''
        foreach ($b in $blocks) {
            if ($b.Block.Visibility -ne 'Visible') { continue }
            if ($spy.Offsets[$b.Key] -le $y) { $best = $b.Key }
        }
        if (-not $best) {
            foreach ($b in $blocks) { if ($b.Block.Visibility -eq 'Visible') { $best = $b.Key; break } }
        }
        if ($best -eq $spy.On) { return }
        $spy.On = $best
        foreach ($rc in $railCards) {
            $lit = ($rc.Key -eq $best)
            $rc.Lit = $lit
            & $Ref $rc.Card 'Background' $(if ($lit) { 'CardSel' } else { 'Flat' })
            & $Ref $rc.Label 'Foreground' $(if ($lit) { 'Text' } else { 'Sub' })
        }
    }.GetNewClosure()

    # What is actually narrowing the list, which the button could never say:
    # "Filter (3)" tells you how many, never which. Everything the handler needs
    # travels on the Tag.
    $chipFor = {
        param([string]$Group, [string]$Value, [string]$Text, $Ctx)
        $b = New-Object Windows.Controls.Border
        $b.CornerRadius = 9; $b.Padding = '9,1,8,2'; $b.Margin = '0,0,6,0'
        $b.BorderThickness = New-Object Windows.Thickness 1
        & $Ref $b 'BorderBrush' 'Line'
        & $Ref $b 'Background' 'Card'
        $b.Cursor = 'Hand'
        $b.ToolTip = 'Drop this filter'
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = "$Text  x"; $t.FontSize = 11.5
        & $Ref $t 'Foreground' 'Sub'
        $b.Child = $t
        $b.Tag = @{ G = $Group; V = $Value; Ctx = $Ctx }
        $b.Add_MouseLeftButtonUp({
            $t2 = $this.Tag
            $c  = $t2.Ctx
            foreach ($fb in $c.Boxes) {
                if ($fb.Group -eq $t2.G -and $fb.Value -eq $t2.V) { $fb.Box.IsChecked = $false }
            }
            $null = $c.Sel[$t2.G].Remove($t2.V)
            if ($t2.G -eq 'View' -and -not $c.Sel['View'].Count) { $c.Snap.Ids = $null }
            if ($c.Fx.Pairs)  { & $c.Fx.Pairs }
            if ($c.Fx.Filter) { & $c.Fx.Filter }
        }.GetNewClosure())
        $b
    }.GetNewClosure()

    $chipCtx = @{ Boxes = $filterBoxes; Sel = $filterSel; Snap = $viewSnap; Fx = $fx }

    # Two columns inside a full-width block, re-filled with what is visible
    # rather than with everything - filling with everything and hiding half is
    # how a search ends up with six rows and an empty column beside them.
    $fillBlock = {
        param($B, $Members)
        $B.ColL.Children.Clear()
        $B.ColR.Children.Clear()
        $list = @($Members)
        $one = ($list.Count -lt 4)
        $gap  = $(if ($one) { 0 } else { 30 })
        $B.Grid.ColumnDefinitions[1].Width = New-Object System.Windows.GridLength -ArgumentList $gap, ([System.Windows.GridUnitType]::Pixel)
        if ($one) {
            $B.Grid.ColumnDefinitions[2].Width = New-Object System.Windows.GridLength -ArgumentList 0, ([System.Windows.GridUnitType]::Pixel)
        } else {
            $B.Grid.ColumnDefinitions[2].Width = New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)
        }
        $half = [Math]::Ceiling($list.Count / 2)
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ($one -or $i -lt $half) { $null = $B.ColL.Children.Add($list[$i].Card) }
            else                       { $null = $B.ColR.Children.Add($list[$i].Card) }
        }
        $B.VisEnabled = @($list | Where-Object { $_.Check.IsEnabled }).Count
    }

    $applyFilter = {
        $needle = ([string]$ui.Find.Text).Trim()
        foreach ($r in $rows) {
            $ok = $true
            if ($ok -and $filterSel['State'].Count) { $ok = $filterSel['State'].Contains([string]$r.Opt.State) }
            if ($ok -and $filterSel['Cat'].Count)   { $ok = $filterSel['Cat'].Contains([string]$r.Cat) }
            if ($ok -and $filterSel['Kind'].Count) {
                $hit = $false
                foreach ($k in $r.Kinds) { if ($filterSel['Kind'].Contains([string]$k)) { $hit = $true } }
                $ok = $hit
            }
            if ($ok -and $filterSel['View'].Count) {
                $was = $false
                if ($viewSnap.Ids) { $was = $viewSnap.Ids.Contains([string]$r.Opt.Id) }
                $hit = $false
                if ($filterSel['View'].Contains('ticked')   -and $was)        { $hit = $true }
                if ($filterSel['View'].Contains('unticked') -and (-not $was)) { $hit = $true }
                $ok = $hit
            }
            if ($ok -and $needle) {
                $ok = ($r.Name -like "*$needle*") -or ($r.Cat -like "*$needle*") -or
                      ($r.Desc -like "*$needle*") -or ($r.DetailText -like "*$needle*")
            }
            $r.Card.Visibility = $(if ($ok) { 'Visible' } else { 'Collapsed' })
        }
        # One pass for the per-group tallies rather than one per block and again
        # per rail card.
        $visBy = @{}
        $shown = 0
        foreach ($r in $rows) {
            if ($r.Card.Visibility -ne 'Visible') { continue }
            $shown++
            $k = [string]$r.GKey
            if (-not $k) { continue }
            if (-not $visBy.ContainsKey($k)) { $visBy[$k] = 0 }
            $visBy[$k]++
        }
        foreach ($b in $blocks) {
            $n = 0; if ($visBy.ContainsKey([string]$b.Key)) { $n = $visBy[[string]$b.Key] }
            $b.Block.Visibility = $(if ($n) { 'Visible' } else { 'Collapsed' })
            & $fillBlock $b @($b.Ordered | Where-Object { $_.Card.Visibility -eq 'Visible' })
        }
        # A rail entry the filter has emptied is dimmed, never removed: entries
        # coming and going as you type reads as broken.
        foreach ($rc in $railCards) {
            $rc.Live = [bool]($visBy.ContainsKey([string]$rc.Key) -and $visBy[[string]$rc.Key])
        }
        $ui.TxtCount.Text = $(if ($shown -eq $rows.Count) { "$($rows.Count) options" } else { "$shown of $($rows.Count) options" })

        $ui.FilterChips.Children.Clear()
        $facets = 0
        foreach ($fg in $FILTER_GROUPS) {
            foreach ($v in @($filterSel[$fg])) {
                $facets++
                $lbl = $v
                if ($fg -eq 'State') { $lbl = $STATE_LABEL[$v] }
                if ($fg -eq 'View')  { $lbl = $(if ($v -eq 'ticked') { 'Selected only' } else { 'Unselected only' }) }
                $null = $ui.FilterChips.Children.Add((& $chipFor $fg $v $lbl $chipCtx))
            }
        }
        $ui.FilterChips.Visibility = $(if ($facets) { 'Visible' } else { 'Collapsed' })
        $ui.BtnFilter.Content = $(if ($facets) { "Filter ($facets)" } else { 'Filter' })

        & $paintCounts
        $spy.Offsets = $null
        $spy.On = ''
        & $spyRun
    }.GetNewClosure()
    $fx.Filter = $applyFilter

    # Shared, because Collapse all does exactly this to every group and a second
    # copy of "what collapsed looks like" is how the sign and the visibility
    # disagree.
    $setGroupOpen = {
        param($Body, $Btn, [bool]$Open, $GroupRows)
        $Body.Visibility = $(if ($Open) { 'Visible' } else { 'Collapsed' })
        $Btn.Content = $(if ($Open) { '-' } else { '+' })
        $Btn.ToolTip = $(if ($Open) { 'Collapse this group' } else { 'Expand this group' })
        if (-not $Open -and $GroupRows) {
            foreach ($r in @($GroupRows)) {
                if ($r.Detail -and $r.Detail.Det) { $r.Detail.Det.Visibility = 'Collapsed' }
            }
        }
    }

    $applyOrder = {
        # A child of a panel cannot be added to another - WPF refuses with
        # "already the logical child of another element" - and Children.Clear()
        # does not touch what the blocks hold.
        foreach ($r in $rows) {
            if ($r.Card.Parent -is [Windows.Controls.Panel]) { $r.Card.Parent.Children.Remove($r.Card) }
        }
        $ui.List.Children.Clear()
        $ui.Rail.Children.Clear()
        $blocks.Clear()
        $railCards.Clear()

        foreach ($g in (& $groupsFor $state.Group)) {
            $block = New-Object Windows.Controls.StackPanel
            $block.Margin = '0,0,0,10'

            # A name then some buttons is a WrapPanel, for the same reason a row
            # is.
            $hp = New-Object Windows.Controls.WrapPanel
            # 16 SemiBold over '0,18,0,6', which is what a category heading on
            # the Advanced page is.
            $hp.Margin = '0,18,0,6'
            $ht = New-Object Windows.Controls.TextBlock
            $ht.Text = [string]$g.Label; $ht.FontSize = 16; $ht.FontWeight = 'SemiBold'
            $ht.VerticalAlignment = 'Center'; $ht.TextWrapping = 'Wrap'
            & $Ref $ht 'Foreground' 'Text'
            $null = $hp.Children.Add($ht)

            # Two columns and a gutter, filled by $fillBlock. The block stays
            # full width and the blocks stack down, which keeps the page's order
            # and the rail's order the same list.
            $body = New-Object Windows.Controls.Grid
            foreach ($w in @((New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)),
                             (New-Object System.Windows.GridLength -ArgumentList 30, ([System.Windows.GridUnitType]::Pixel)),
                             (New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)))) {
                $cd = New-Object Windows.Controls.ColumnDefinition
                $cd.Width = $w
                $body.ColumnDefinitions.Add($cd)
            }
            $colL = New-Object Windows.Controls.StackPanel
            $colR = New-Object Windows.Controls.StackPanel
            [Windows.Controls.Grid]::SetColumn($colL, 0)
            [Windows.Controls.Grid]::SetColumn($colR, 2)
            $null = $body.Children.Add($colL)
            $null = $body.Children.Add($colR)

            # The heading itself is inert: with a collapse control on the same
            # line, clicking the name is as likely to mean "fold this away" as
            # "take all of it".
            $tg = New-Object Windows.Controls.Button
            $tg.Content = '-'; $tg.Width = 24; $tg.Padding = '0,1'; $tg.FontSize = 13
            $tg.FontWeight = 'Bold'; $tg.Margin = '10,0,0,0'; $tg.VerticalAlignment = 'Center'
            $tg.ToolTip = 'Collapse this group'
            $tg.Tag = @{ Body = $body; Set = $setGroupOpen; Spy = $spy; Run = $spyRun }
            $tg.Add_Click({
                $t = $this.Tag
                & $t.Set $t.Body $this (-not ($t.Body.Visibility -eq 'Visible')) $t.Rows
                # Folding moves every heading below it, so the measured offsets
                # are stale.
                $t.Spy.Offsets = $null
                $t.Spy.On = ''
                & $t.Run
            }.GetNewClosure())
            $null = $hp.Children.Add($tg)

            # Acts on what is visible, so it respects the filter rather than
            # quietly selecting rows that are not on screen.
            $sa = New-Object Windows.Controls.Button
            $sa.Content = 'Select all'; $sa.FontSize = 11.5; $sa.Padding = '8,2'
            $sa.Margin = '8,0,0,0'; $sa.VerticalAlignment = 'Center'; $sa.MinWidth = 84
            $sa.ToolTip = 'Selects every option in this group that is on screen and can be reverted. Press again to clear them.'
            $sa.Tag = @{ Members = $g.Members; Paint = $paintCounts; Show = $showNow }
            $sa.Add_Click({
                $t = $this.Tag
                $vis = @($t.Members | Where-Object { $_.Card.Visibility -eq 'Visible' -and $_.Check.IsEnabled })
                if (-not $vis.Count) { return }
                $want = @($vis | Where-Object { -not $_.Check.IsChecked }).Count -gt 0
                foreach ($r in $vis) { $r.Check.IsChecked = $want }
                # The ticks are what the person asked for; the counts are the
                # consequence. Draw the first before doing the second.
                & $t.Show
                & $t.Paint
            }.GetNewClosure())
            $null = $hp.Children.Add($sa)
            $null = $block.Children.Add($hp)

            $rule = New-Object Windows.Controls.Border
            $rule.Height = 1; $rule.Margin = '0,0,0,4'; $rule.Opacity = 0.55
            & $Ref $rule 'Background' 'Line'
            $null = $block.Children.Add($rule)

            $null = $block.Children.Add($body)
            $null = $ui.List.Children.Add($block)
            # Plain assignment, never @(). $sortMembers ends in ,@(...) so a
            # caller who assigns gets the array, and wrapping that gives one
            # element holding the whole list.
            $sorted = & $sortMembers $g.Members $state.Sort
            $rec = [pscustomobject]@{
                Key = $g.Key; Group = $g; Block = $block; Body = $body
                Grid = $body; ColL = $colL; ColR = $colR
                Ordered = $sorted
                VisEnabled = 0; Toggle = $tg; SelAll = $sa
            }
            # Stamped on the row, so every count is one pass over the rows
            # rather than one per block and another per rail card.
            foreach ($m in $rec.Ordered) { $m.GKey = [string]$g.Key }
            # No fill here: $applyFilter runs at the foot of this function and
            # fills every block with what is visible.
            $tg.Tag.Rows = $sorted
            $blocks.Add($rec)

            # An index into the list, never a router. Clicking scrolls.
            $c = New-Object Windows.Controls.Border
            $c.CornerRadius = 3; $c.Padding = '8,4,8,5'; $c.Margin = '0,0,0,2'; $c.Cursor = 'Hand'
            & $Ref $c 'Background' 'Flat'
            $dp = New-Object Windows.Controls.DockPanel
            $num = New-Object Windows.Controls.TextBlock
            $num.FontSize = 11.5; $num.Margin = '6,0,0,0'
            & $Ref $num 'Foreground' 'Accent'
            [Windows.Controls.DockPanel]::SetDock($num, 'Right')
            $null = $dp.Children.Add($num)
            $lbl = New-Object Windows.Controls.TextBlock
            $lbl.Text = [string]$g.Label; $lbl.FontSize = 12.5; $lbl.TextTrimming = 'CharacterEllipsis'
            & $Ref $lbl 'Foreground' 'Sub'
            $null = $dp.Children.Add($lbl)
            $c.Child = $dp
            $null = $ui.Rail.Children.Add($c)
            $entry = [pscustomobject]@{ Key = $g.Key; Group = $g; Card = $c; Num = $num; Label = $lbl
                                        Block = $block; Live = $true; Lit = $false }
            $railCards.Add($entry)

            $refL = $Ref
            $scr  = $ui.Scroll
            $blk  = $block
            $ent  = $entry
            $c.Add_MouseLeftButtonUp({
                try {
                    $p = $blk.TransformToAncestor($scr.Content).Transform((New-Object Windows.Point 0, 0))
                    $scr.ScrollToVerticalOffset($p.Y)
                } catch { }
            }.GetNewClosure())
            # The highlighted card keeps its highlight rather than dimming to a
            # hover tint as the pointer crosses it.
            $c.Add_MouseEnter({ if (-not $ent.Lit) { & $refL $ent.Card 'Background' 'RowHover' } }.GetNewClosure())
            $c.Add_MouseLeave({ if (-not $ent.Lit) { & $refL $ent.Card 'Background' 'Flat' } }.GetNewClosure())
        }

        # Back to the top: the old offset is a position in an arrangement that
        # no longer exists.
        $ui.Scroll.ScrollToVerticalOffset(0)
        $spy.Offsets = $null
        $spy.On = ''
        & $applyFilter
    }.GetNewClosure()

    $addFilterSection = {
        param([string]$Group, [string]$Heading, $Entries)
        if (-not @($Entries).Count) { return }
        $h = New-Object Windows.Controls.TextBlock
        $h.Text = $Heading.ToUpper(); $h.FontSize = 11; $h.FontWeight = 'SemiBold'
        $h.Margin = '0,10,0,4'
        & $Ref $h 'Foreground' 'Muted'
        $null = $ui.FilterPanel.Children.Add($h)
        foreach ($e in @($Entries)) {
            $box = New-Object Windows.Controls.CheckBox
            $box.Content = $e.Label; $box.FontSize = 12.5; $box.Margin = '0,2,0,2'
            # WPF's default CheckBox foreground is the system control-text
            # brush, which is black whatever the Windows theme says - so a box
            # with no Foreground of its own is an invisible label on the dark
            # palette.
            & $Ref $box 'Foreground' 'Text'
            $box.Tag = @{ G = $Group; V = [string]$e.Key; Sel = $filterSel; Fx = $fx
                          Snap = $viewSnap; Rows = $rows }
            $box.Add_Click({
                $t = $this.Tag
                if ($this.IsChecked) {
                    if (-not $t.Sel[$t.G].Contains($t.V)) { $t.Sel[$t.G].Add($t.V) }
                    if ($t.G -eq 'View') {
                        $ids = New-Object System.Collections.Generic.List[string]
                        foreach ($r in $t.Rows) { if ($r.Check.IsChecked) { $ids.Add([string]$r.Opt.Id) } }
                        $t.Snap.Ids = $ids
                    }
                } else {
                    $null = $t.Sel[$t.G].Remove($t.V)
                    if ($t.G -eq 'View' -and -not $t.Sel['View'].Count) { $t.Snap.Ids = $null }
                }
                if ($t.Fx.Pairs)  { & $t.Fx.Pairs }
                if ($t.Fx.Filter) { & $t.Fx.Filter }
            }.GetNewClosure())
            $null = $ui.FilterPanel.Children.Add($box)
            $filterBoxes.Add([pscustomobject]@{ Group = $Group; Value = [string]$e.Key; Box = $box })
        }
    }.GetNewClosure()

    # A block rather than four calls in line, because Refresh has to build this
    # again: a band can empty entirely on a machine somebody has been putting
    # things back on by hand.
    $buildFilterPanel = {
        $ui.FilterPanel.Children.Clear()
        $filterBoxes.Clear()
        $stateEntries = New-Object System.Collections.Generic.List[psobject]
        foreach ($k in @('todo', 'unknown', 'done')) {
            if (@($rows | Where-Object { $_.Opt.State -eq $k }).Count) {
                $stateEntries.Add([pscustomobject]@{ Key = $k; Label = $STATE_LABEL[$k] })
            }
        }
        & $addFilterSection 'State' 'What is left' $stateEntries
        & $addFilterSection 'View' 'View' @(
            [pscustomobject]@{ Key = 'ticked';   Label = 'Selected only' }
            [pscustomobject]@{ Key = 'unticked'; Label = 'Unselected only' }
        )
        $kindEntries = New-Object System.Collections.Generic.List[psobject]
        foreach ($k in (@($rows | ForEach-Object { $_.Kinds } | Select-Object -Unique) | Sort-Object @{ E = { [int]$KIND_RANK[$_] } })) {
            $kindEntries.Add([pscustomobject]@{ Key = [string]$k; Label = [string]$k })
        }
        & $addFilterSection 'Kind' 'Kind of change' $kindEntries
        $catEntries = New-Object System.Collections.Generic.List[psobject]
        foreach ($k in (@($rows | ForEach-Object { $_.Cat } | Select-Object -Unique) | Sort-Object @{ E = { [int]$catOrder[$_] } })) {
            $catEntries.Add([pscustomobject]@{ Key = [string]$k; Label = [string]$k })
        }
        & $addFilterSection 'Cat' 'Category' $catEntries
    }.GetNewClosure()
    & $buildFilterPanel

    # Selected only and Unselected only together are every row, which is what no
    # filter already says, so whichever is ticked disables the other.
    $syncPairs = {
        $a = $null; $b = $null
        foreach ($fb in $filterBoxes) {
            if ($fb.Group -eq 'View' -and $fb.Value -eq 'ticked')   { $a = $fb.Box }
            if ($fb.Group -eq 'View' -and $fb.Value -eq 'unticked') { $b = $fb.Box }
        }
        if ($a -and $b) {
            $a.IsEnabled = -not [bool]$b.IsChecked
            $b.IsEnabled = -not [bool]$a.IsChecked
        }
    }.GetNewClosure()
    $fx.Pairs = $syncPairs

    foreach ($g in $GROUPS) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = $g.Label; $it.Tag = $g.Key
        $null = $ui.CmbOrder.Items.Add($it)
        if ($g.Key -eq $state.Group) { $ui.CmbOrder.SelectedItem = $it }
    }
    foreach ($s in $SORTS) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = $s.Label; $it.Tag = $s.Key
        $null = $ui.CmbSort.Items.Add($it)
        if ($s.Key -eq $state.Sort) { $ui.CmbSort.SelectedItem = $it }
    }

    $ui.CmbOrder.Add_SelectionChanged({
        if ($state.Booting) { return }
        if (-not $ui.CmbOrder.SelectedItem) { return }
        $state.Group = [string]$ui.CmbOrder.SelectedItem.Tag
        & $applyOrder
    }.GetNewClosure())
    $ui.CmbSort.Add_SelectionChanged({
        if ($state.Booting) { return }
        if (-not $ui.CmbSort.SelectedItem) { return }
        $state.Sort = [string]$ui.CmbSort.SelectedItem.Tag
        & $applyOrder
    }.GetNewClosure())

    # The tick is what the person asked for and the counts are the consequence,
    # so the tick is drawn first.
    $afterTick = { & $showNow; & $paintCounts }.GetNewClosure()
    foreach ($r in $rows) {
        $r.Check.Add_Click($afterTick)
        if ($r.Card.Tag) { $r.Card.Tag.After = $afterTick }
    }

    # The whole page at once, on the same rule as the per-group button: visible
    # rows only, and one press either way rather than a pair of which exactly
    # one is ever useful.
    $ui.BtnSelectAll.Add_Click({
        $vis = @($rows | Where-Object { $_.Card.Visibility -eq 'Visible' -and $_.Check.IsEnabled })
        if (-not $vis.Count) { return }
        $want = @($vis | Where-Object { -not $_.Check.IsChecked }).Count -gt 0
        foreach ($r in $vis) { $r.Check.IsChecked = $want }
        & $showNow
        & $paintCounts
    }.GetNewClosure())

    $ui.BtnCollapseAll.Add_Click({
        foreach ($b in $blocks) { & $setGroupOpen $b.Body $b.Toggle $false $b.Ordered }
        $spy.Offsets = $null; $spy.On = ''
        & $spyRun
    }.GetNewClosure())

    # Off as shipped: the standing description is the same on every visit, and
    # Details carries the whole of it for the one option being asked about.
    $applyTerse = {
        $vis = $(if ($state.Terse) { 'Collapsed' } else { 'Visible' })
        foreach ($r in $rows) {
            if ($r.DescEl) { $r.DescEl.Visibility = $vis }
        }
    }.GetNewClosure()
    $ui.BtnVerbose.IsChecked = (-not $state.Terse)
    $ui.BtnVerbose.Add_Click({
        $state.Terse = -not [bool]$this.IsChecked
        & $applyTerse
        # A description appearing or going takes every card below it with it, so
        # the measured offsets describe a page that no longer exists.
        $spy.Offsets = $null
        & $spyRun
    }.GetNewClosure())
    $ui.BtnExpandAll.Add_Click({
        foreach ($b in $blocks) { & $setGroupOpen $b.Body $b.Toggle $true }
        $spy.Offsets = $null; $spy.On = ''
        & $spyRun
    }.GetNewClosure())

    $ui.BtnFilterClear.Add_Click({
        foreach ($fb in $filterBoxes) { $fb.Box.IsChecked = $false; $fb.Box.IsEnabled = $true }
        foreach ($fg in $FILTER_GROUPS) { $filterSel[$fg].Clear() }
        $viewSnap.Ids = $null
        & $applyFilter
    }.GetNewClosure())
    $ui.BtnFilterDone.Add_Click({ $ui.BtnFilter.IsChecked = $false }.GetNewClosure())

    # A TextChanged handler runs synchronously inside the input event, so a pass
    # over every row is time the character just typed is not on screen. Restart,
    # not start, so the pass runs once at the end.
    $findTimer = New-Object Windows.Threading.DispatcherTimer
    $findTimer.Interval = [TimeSpan]::FromMilliseconds(180)
    $findTimer.Add_Tick({ $findTimer.Stop(); & $applyFilter }.GetNewClosure())
    $ui.Find.Add_TextChanged({ $findTimer.Stop(); $findTimer.Start() }.GetNewClosure())

    $ui.Scroll.Add_ScrollChanged({ & $spyRun }.GetNewClosure())
    # A narrower list re-wraps every card, so the offsets go with it. This
    # handler changes no layout of its own, which keeps it from feeding itself.
    $ui.ListPage.Add_SizeChanged({ $spy.Offsets = $null; & $spyRun }.GetNewClosure())

    $ui.BtnTheme.Add_Click({
        & $applyTheme $(if ($palBox.Key -eq 'dark') { 'light' } else { 'dark' })
    }.GetNewClosure())
    $ui.BtnClose.Add_Click({ $win.Close() }.GetNewClosure())

    # A rebuild rather than a repaint: an option's state decides whether its box
    # takes a tick, whether the name is struck through, and which band it is
    # filed under.
    $ui.BtnRefresh.Add_Click({
        # Paint first. The read is seconds of a blocked UI thread, and a control
        # that does not move reads as a click that missed.
        $ui.BtnRefresh.IsEnabled = $false
        $ui.Sub1.Text = 'Reading this machine again...'
        & $showNow
        try {
            $wasRows = $rows.Count
            $wasTodo = @($rows | Where-Object { $_.Opt.State -eq 'todo' }).Count
            $wasPend = 0
            foreach ($r in $rows) { $wasPend += [int]$r.Opt.Pending }

            # The machine, rather than what it looked like when this opened:
            # both caches keep what they have read for the life of the process.
            $global:WDRegCache.Clear()
            $global:WDFeatures   = $null
            $global:WDFeatureJob = $null

            foreach ($o in $opts) {
                $o.Todo = 0; $o.Done = 0; $o.Unknown = 0
                foreach ($s in $o.Steps) {
                    switch (Get-WDStepState $s) {
                        'todo'  { $o.Todo++ }
                        'done'  { $o.Done++ }
                        default { $o.Unknown++ }
                    }
                }
                if ($o.Todo)        { $o.State = 'todo' }
                elseif ($o.Unknown) { $o.State = 'unknown' }
                else                { $o.State = 'done' }
                $o.Pending = $o.Todo + $o.Unknown
            }

            # Mutate, never assign. Every closure on this page captured these
            # collections, and a fresh assignment would leave all of them
            # reading the old one for ever.
            $rows.Clear()
            foreach ($o in $opts) { $rows.Add((& $makeRow $o $Ref $tag $col)) }
            foreach ($r in $rows) {
                $r.Check.Add_Click($afterTick)
                if ($r.Card.Tag) { $r.Card.Tag.After = $afterTick }
            }
            $state.Tickable = @($rows | Where-Object { $_.Check.IsEnabled }).Count

            # The panel too, since the bands are derived from the rows. Every
            # facet is cleared with it: a selection whose box has just been
            # thrown away filters against nothing.
            foreach ($fg in $FILTER_GROUPS) { $filterSel[$fg].Clear() }
            $viewSnap.Ids = $null
            & $buildFilterPanel
            $ui.Find.Text = ''

            $spy.Offsets = $null; $spy.On = ''
            & $applyOrder

            $nowTodo = @($rows | Where-Object { $_.Opt.State -eq 'todo' }).Count
            $nowPend = 0
            foreach ($r in $rows) { $nowPend += [int]$r.Opt.Pending }
            # Said, rather than left for somebody to spot - a Refresh that
            # changed nothing looks exactly like one that did not run.
            $moved = ''
            if ($wasRows -eq $rows.Count -and $wasTodo -eq $nowTodo -and $wasPend -eq $nowPend) {
                $moved = 'Read again just now - nothing has changed since this window opened.'
            } else {
                $moved = "Read again just now: still in place $wasTodo to $nowTodo option(s), $wasPend to $nowPend change(s)."
            }
            & $saySummary $moved
        } finally {
            $ui.BtnRefresh.IsEnabled = $true
        }
    }.GetNewClosure())

    $done = @{ Ran = $false; Failed = 0 }
    $ui.BtnGo.Add_Click({
        $picked = @($rows | Where-Object { $_.Check.IsChecked })
        if (-not $picked.Count) { return }
        $steps = New-Object System.Collections.Generic.List[psobject]
        foreach ($p in $picked) { foreach ($s in $p.Opt.Steps) { $steps.Add($s) } }

        $ui.ListPage.Visibility = 'Collapsed'
        $ui.Bar.Visibility = 'Collapsed'
        $ui.RunPage.Visibility = 'Visible'
        $ui.BtnGo.IsEnabled = $false
        $ui.Head.Text = 'Putting it back'
        $ui.Sub1.Text = "$($steps.Count) change(s) from $($picked.Count) option(s)."
        $ui.Sub2.Text = 'Windows features can take a minute each, and the window does not answer while one is running.'
        $ui.RunNote.Text = ''

        $pump = { [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, 'Render') }
        $say = {
            param($L)
            $t = New-Object Windows.Controls.TextBlock
            $t.Text = $L.Text; $t.FontSize = 12.5; $t.TextWrapping = 'Wrap'; $t.Margin = '0,0,0,2'
            & $Ref $t 'Foreground' $(switch ($L.Level) { 'ok' { 'Ok' } 'bad' { 'Bad' } default { 'Muted' } })
            $null = $ui.Log.Children.Add($t)
            $ui.LogScroll.ScrollToEnd()
            $ui.Tally.Text = "$($L.Index) of $($steps.Count)..."
            & $pump
        }.GetNewClosure()

        $r = Invoke-WDUndo -Steps $steps -Say $say
        $done.Ran = $true
        $done.Failed = $r.Failed

        $ui.Head.Text = 'Finished'
        $ui.Sub1.Text = "$($r.Restored) change(s) put back, $($r.Already) were already back, $($r.Failed) could not be done."
        $ui.Sub2.Text = 'A restart is recommended.'
        $ui.Tally.Text = ''
        $note = New-Object System.Collections.Generic.List[string]
        if ($global:WDReinstall.Count) {
            $note.Add("$($global:WDReinstall.Count) program(s) were uninstalled by that run and nothing can put those back automatically: " + (($global:WDReinstall | Select-Object -First 12) -join ', ') + $(if ($global:WDReinstall.Count -gt 12) { ', and more.' } else { '.' }))
        }
        if ($global:WDOwners.Count) {
            $note.Add("$($global:WDOwners.Count) registry key(s) had their owner changed to Administrators. Restoring an owner needs takeown or icacls and is not done here.")
        }
        $ui.RunNote.Text = ($note -join ' ')
        $ui.BtnClose.Content = 'Close'
    }.GetNewClosure())

    $state.Booting = $false
    & $tell 'Arranging the page' "$($rows.Count) options"
    & $applyOrder
    $ms.Layout = [int]$clock.ElapsedMilliseconds

    # The seam. ShowDialog blocks the dispatcher with nobody to dismiss it, so
    # the only thing a headless check can ask is whether the page assembles and
    # what it says.
    if ($BuildOnly) {
        Close-WDHives
        return [pscustomobject]@{
            Options   = @($rows).Count
            Groups    = @($blocks).Count
            Rail      = @($railCards).Count
            Ticked    = @($rows | Where-Object { $_.Check.IsChecked }).Count
            Locked    = @($rows | Where-Object { -not $_.Check.IsEnabled }).Count
            Todo      = $totalTodo
            Done      = $totalDone
            Unknown   = $totalHuh
            Steps     = $totalSteps
            Theme     = $palBox.Key
            Icon      = [bool]$ico
            Ms        = $ms
            Tagged    = @($rows | Where-Object { $_.Tag }).Count
            # Must be zero. "Still in place" is what every row is unless it says
            # otherwise, so a marker for it is the page's premise repeated once
            # per row.
            Mistagged = @($rows | Where-Object { $_.Opt.State -eq 'todo' -and $_.Tag }).Count
            Tally     = [string]$ui.Tally.Text
            Summary   = [string]$ui.Sub2.Text
            Title     = [string]$win.Title
            Window    = $win
            Rows      = $rows
            Blocks    = $blocks
            RailCards = $railCards
            Order     = $applyOrder
            Filter    = $applyFilter
            Theming   = $applyTheme
            Boxes     = $filterBoxes
            State     = $state
            Ui        = $ui
            # Zero on a journal read back with no plan in hand, which is a real
            # state rather than a fault.
            Described = @($rows | Where-Object { [string]$_.Desc }).Count
            # The two passes a headless check has to drive: repainting after a
            # tick, and turning the descriptions on. Both are reached by a
            # click, which -BuildOnly cannot make.
            Paint     = $paintCounts
            Terse     = $applyTerse
        }
    }

    # Closed here rather than at the end of the read: building the list is the
    # other half of the wait, and a splash that goes away over an empty screen
    # is worse than one that stays.
    if ($splash) { & $splash.Close }

    $win.Add_ContentRendered({ $this.Activate() | Out-Null })
    $null = $win.ShowDialog()
    Close-WDHives

    if ($done.Ran -and $done.Failed) {
        # The launcher prints what the exit code means in the console this hid,
        # so put it back for the case that has something to say.
        Set-WDUndoConsole -Show
        return 1
    }
    0
}