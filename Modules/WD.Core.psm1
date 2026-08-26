<#
    WD.Core - session state, logging, safety net.

    Everything that must survive a crash lives here: the transcript, the
    per-action journal used to build the rollback script, and the registry
    exports taken before any key is touched.
#>

# StrictMode is deliberately off across the toolkit: journal and manifest data
# arrives as JSON with many optional properties, and a missing property must
# degrade rather than abort a run that is halfway through modifying a machine.
#
# Collections use List[psobject], never List[object]. On Windows PowerShell 5.1
# the array subexpression @($list) throws "Argument types do not match" when the
# generic argument is exactly System.Object - List[psobject], List[string] and
# ArrayList are all unaffected. Do not "simplify" these back to List[object].

$script:Session = $null

# Status vocabulary shared by every action executor. Anything not in this list
# is a bug. 'NotPresent' is deliberately a success state - on a fresh install
# most of the removal list will legitimately not exist.
#
# 'AlreadySet' is the other success nobody expects to need until they see the
# alternative. A registry value that is already the value this option would
# write is not absent, so NotPresent is a lie about it, and it is not Changed
# either - nothing happened. Reporting it as either one is what made a preview
# of a selection that had just been applied claim a hundred and twenty-one
# changes over a machine where every one of them was already true.
#
# 'Obstruction' is not an outcome for a removal at all. It is something in the
# way: a subsystem this run depends on that is degraded, or a step Windows will
# not let any program complete silently and hands to the operator instead.
# Those used to report Blocked, which put "changing the default browser" and
# "component store" in the same column as a package Windows refused to remove -
# and Blocked has a specific meaning worth keeping, namely that this run tried
# to do something and was told no.
$script:StatusOrder = @{
    Removed     = 0   # target existed and is gone
    Changed     = 1   # setting written
    AlreadySet  = 2   # target present and already what this would make it
    NotPresent  = 3   # nothing to do, target absent
    Skipped     = 4   # deliberately not attempted (guard failed)
    Obstruction = 5   # something stands in the way; not a removal that failed
    Partial     = 6   # some actions succeeded, some did not
    Blocked     = 7   # attempted, refused by OS/policy/lock
    Failed      = 8   # attempted, errored
}

# ------------------------------------------------------- native, and when ----
#
# EVERY Add-Type IN THIS TOOLKIT IS A CSC INVOCATION, AND ONE COSTS ABOUT 400 ms.
# There were four, three of them at module-import time, and together they were
# most of the two and a half seconds between the launcher exiting and anything
# appearing on screen. Nothing about them is fast: the first compile in a
# process pays for loading the compiler, and each one after it still pays
# 150-200 ms of its own. Reflection.Emit was measured as an alternative and is
# no better - 240-375 ms, for the same reason, one subsystem loading once.
#
# So: one shared type for the two the startup path actually needs, compiled on
# a runspace of its own while the main thread goes on importing modules, and
# everything else deferred to the moment something reaches for it.
#
# The two here are the ones that cannot wait. GetSystemMetrics answers the touch
# question in the machine profile, and the AppUserModelID has to be set before
# the first window is created or the taskbar draws PowerShell's icon whatever
# Window.Icon says. The two heavyweights - WDPriv for ownership escalation and
# WDDisk for the drive walk - are compiled by their own first caller, which on
# a normal launch is a background runspace or a run that has already started.
$script:WDNativeSource = @'
using System;
using System.Runtime.InteropServices;
namespace WD {
    public static class Native {
        [DllImport("user32.dll")]
        public static extern int GetSystemMetrics(int nIndex);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        public static extern void SetCurrentProcessExplicitAppUserModelID(string AppID);
    }
}
'@

$script:WDNativeJob = $null

function Start-WDNative {
    <#
        Kicks the compile off and returns. Measured: BeginInvoke costs the
        caller 33-49 ms, the compile it starts takes about 400 ms, and the
        module imports that follow take longer than that - so by the time
        anything asks, the answer is already there. On the launch path this
        turned 1,154 ms into 845 ms and the wait at the end into 8 ms.

        Best effort throughout. A machine that will not give us a runspace
        still gets the type, from Use-WDNative, the slow way.
    #>
    if ($script:WDNativeJob -or ('WD.Native' -as [type])) { return }
    try {
        $ps = [powershell]::Create()
        $null = $ps.AddScript({
            param($Source)
            Add-Type -TypeDefinition $Source -ErrorAction SilentlyContinue
        }).AddArgument($script:WDNativeSource)
        $script:WDNativeJob = @{ PS = $ps; Handle = $ps.BeginInvoke() }
    } catch {
        $script:WDNativeJob = $null
    }
}

function Use-WDNative {
    <#
        Waits for the warm-up if one is in flight, compiles here if it never
        started or did not finish, and answers whether [WD.Native] can be
        called. Every caller checks - a machine where the compile fails should
        lose the taskbar icon and the touch guard, not the launch.
    #>
    if ('WD.Native' -as [type]) { return $true }
    if ($script:WDNativeJob) {
        $job = $script:WDNativeJob
        $script:WDNativeJob = $null
        try {
            $null = $job.Handle.AsyncWaitHandle.WaitOne(20000)
            $null = $job.PS.EndInvoke($job.Handle)
        } catch { }
        try { $job.PS.Dispose() } catch { }
    }
    if ('WD.Native' -as [type]) { return $true }
    try { Add-Type -TypeDefinition $script:WDNativeSource -ErrorAction SilentlyContinue } catch { }
    [bool]('WD.Native' -as [type])
}

function New-WDStringSet {
    <#  Seeded HashSet[string] that survives an empty or null seed.

        New-Object cannot pick between HashSet's IEnumerable and
        IEqualityComparer overloads when the seed array has no elements, and
        throws "Multiple ambiguous overloads found for HashSet`1". Filling an
        empty set sidesteps the binder entirely. The comma keeps the set itself
        on the pipeline instead of unrolling its contents.  #>
    param([string[]]$From)
    $set = New-Object System.Collections.Generic.HashSet[string]
    foreach ($s in $From) { $null = $set.Add($s) }
    ,$set
}

function New-WDResult {
    <#  Uniform return shape for every action executor.  #>
    param(
        [Parameter(Mandatory)][ValidateSet('Removed','Changed','AlreadySet','NotPresent','Skipped','Obstruction','Partial','Blocked','Failed')]
        [string]$Status,
        [string]$Message = '',
        [string]$Detail  = '',
        # What had to be done differently for this to work. Set only when a
        # first attempt was refused and a second route succeeded.
        #
        # The status is then a SUCCESS status and stays one. An outcome that was
        # reached is not Blocked, however it was reached, and reporting the
        # refusal that happened along the way puts a red row on the page for
        # something that worked - which teaches people that red rows can be
        # ignored. What is worth saying is that it took another route, because
        # that is a fact about the machine somebody may need later; so it is
        # said, in its own field, on a row that reads as done.
        [string]$Recovered = '',
        [switch]$Reboot
    )
    [pscustomobject]@{
        PSTypeName = 'WD.Result'
        Status     = $Status
        Message    = $Message
        Detail     = $Detail
        Recovered  = $Recovered
        Reboot     = [bool]$Reboot
        Severity   = $script:StatusOrder[$Status]
    }
}

function Test-WDAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-WDSession {
    <#
        Creates the run directory and wires up logging. Called once, early,
        before anything is allowed to touch the machine.
    #>
    param(
        [string]$Root,
        [switch]$Preview,
        # Skip the environment record. For the interface's own bookkeeping
        # session ONLY, and it is worth four seconds of every launch.
        #
        # That record exists to reconstruct a run that went wrong - a pending
        # restart that made DISM refuse everything, no disk space, a second
        # copy of the toolkit running. The window's session runs nothing: a
        # preview or an apply creates its OWN session on the run runspace, and
        # writes the whole record there, where it describes the machine at the
        # moment something actually happened to it.
        #
        # Measured on this machine: Get-WDRunEnvironment 1.75s and the tool
        # sweep 2.25s, both on the critical path between the splash and the
        # window, for a file nothing reads.
        [switch]$QuickEnvironment
    )

    if (-not $Root) {
        $Root = Join-Path $env:ProgramData 'WinSetupToolkit'
    }
    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $runDir  = Join-Path $Root "run-$stamp"
    $null    = New-Item -ItemType Directory -Path $runDir -Force
    $null    = New-Item -ItemType Directory -Path (Join-Path $runDir 'registry') -Force

    $script:Session = [pscustomobject]@{
        Id          = $stamp
        Root        = $Root
        RunDir      = $runDir
        RegDir      = Join-Path $runDir 'registry'
        LogFile     = Join-Path $runDir 'debloat.log'
        JournalFile = Join-Path $runDir 'journal.jsonl'
        ReportFile  = Join-Path $runDir 'report.json'
        UndoFile    = Join-Path $runDir 'Undo-WinSetupToolkit.ps1'
        # Written beside the rollback script, and for the case the rollback
        # script cannot serve: somebody who wants one thing back rather than
        # the run back, or who is looking for what caused a problem weeks
        # later and does not yet know this run is the answer.
        # Markdown, not text. This is the one of the three written records that
        # is meant to be read straight through rather than searched or parsed,
        # so it gets headings, a summary table, and grouping - and .md is what
        # makes a viewer render those rather than showing the hashes.
        NotesFile   = Join-Path $runDir 'What-this-run-did.md'
        # The searchable half, written by the issues-doc item when it is
        # selected. Named here rather than by the handler so that the handler,
        # the desktop copy, and anything else that wants it agree on one path -
        # the handler used to choose its own folder and nothing else could find
        # what it had written.
        IssuesFile  = Join-Path $runDir 'Common-issues.txt'
        # The flight recorder, and the machine as it stood before anything was
        # touched. Separate from the journal because the journal is the undo -
        # see Add-WDTrace.
        TraceFile   = Join-Path $runDir 'trace.jsonl'
        EnvFile     = Join-Path $runDir 'environment.json'
        Preview     = [bool]$Preview
        Started     = Get-Date
        RebootNeeded= $false
        # Set by the engine so log lines can surface in the GUI live.
        Sink        = $null
    }

    Write-WDLog "Session $stamp started. Preview=$($script:Session.Preview)" -Level Info
    Write-WDLog "Run directory: $runDir" -Level Info
    # Before anything is allowed to touch the machine, which is what this
    # function's own contract promises - so this is the only correct place for
    # it. A pending reboot or safe mode makes a whole class of items fail for
    # one reason, and reading that afterwards off a scatter of item results is
    # guesswork.
    if ($QuickEnvironment) {
        Write-WDLog 'Interface session - the environment record is written by the run itself.' -Level Debug
    } else {
        $null = Write-WDRunEnvironment
    }
    $script:Session
}

function Get-WDSession { $script:Session }

function Set-WDLogSink {
    <#  Engine hands us a scriptblock so GUI log panes update in real time.  #>
    param([scriptblock]$Sink)
    if ($script:Session) { $script:Session.Sink = $Sink }
}

function Write-WDLog {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('Debug','Info','Warn','Error','Success')][string]$Level = 'Info',
        [string]$Item = ''
    )

    $line = '{0} [{1,-7}] {2}{3}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper(),
            $(if ($Item) { "($Item) " } else { '' }), $Message

    if ($script:Session) {
        # Logging must never be the thing that kills a run.
        try { Add-Content -LiteralPath $script:Session.LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
        if ($script:Session.Sink) {
            try { & $script:Session.Sink $Level $Message $Item } catch { }
        }
    }

    switch ($Level) {
        'Error'   { Write-Host $line -ForegroundColor Red }
        'Warn'    { Write-Host $line -ForegroundColor Yellow }
        'Success' { Write-Host $line -ForegroundColor Green }
        'Debug'   { Write-Verbose $line }
        default   { Write-Host $line -ForegroundColor Gray }
    }
}

function ConvertTo-WDAbsoluteHivePath {
    <#
        HKCU: IS NOT AN ADDRESS - it means "whichever user is asking".

        That is fine for writing a value and wrong for recording how to put one
        back, because the rollback is performed later and not necessarily by the
        same person. A rollback script needs administrator rights, so on a
        machine with two admin accounts it is entirely ordinary for the other
        one to run it - and every HKCU entry in the journal would then restore
        the first user's values into the second user's hive. Neither of them
        would have any way to work out what had happened.

        Rewritten to HKU:\<sid> so the entry names the hive it was actually
        written to. Anything else is handed back untouched, which is every HKLM
        path, every already-absolute HKU: path from an allusers write, and the
        file and task methods that have no registry path at all.

        No drive is created here: this produces a string, and the two things
        that later read one - the Revert page and the generated rollback script
        - each make HKU: for themselves.
    #>
    param([string]$Path)
    if (-not $Path) { return $Path }
    if ($Path -notmatch '^(HKCU:|HKEY_CURRENT_USER)') { return $Path }
    $sid = ''
    try { $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value } catch { }
    # No SID means no better answer than the one we were given. A journal line
    # that is ambiguous about the hive beats no journal line at all.
    if (-not $sid) { return $Path }
    $Path -replace '^(HKCU:|HKEY_CURRENT_USER)', "HKU:\$sid"
}

function Add-WDJournal {
    <#
        Append-only record of everything changed, with enough information to
        reverse it. Written as JSON Lines so a half-finished run is still valid.
    #>
    param(
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Status,
        [hashtable]$Undo
    )
    if (-not $script:Session) { return }

    # Every handler and every executor that records an undo comes through here,
    # so this is the one place the hive has to be pinned down - see
    # ConvertTo-WDAbsoluteHivePath. Four handlers journal an HKCU path today
    # (the Copilot key remap, the shell folders, the Run entries, and the
    # residue sweep's key export) and fixing it at each of them would be four
    # copies of one rule, with the fifth arriving unfixed.
    if ($Undo -and $Undo.ContainsKey('path')) {
        $Undo['path'] = ConvertTo-WDAbsoluteHivePath -Path ([string]$Undo['path'])
    }

    $entry = [ordered]@{
        ts     = (Get-Date).ToString('o')
        item   = $ItemId
        type   = $Type
        target = $Target
        status = $Status
        undo   = $Undo
    }
    try {
        Add-Content -LiteralPath $script:Session.JournalFile `
                    -Value ($entry | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8
    } catch {
        # Error, not Warn. Every line in this file is a promise, so a line that
        # could not be written is a change that has already been made and can
        # no longer be undone - by the rollback script, by the Revert page, or
        # by anything else. That is the most serious thing this function can
        # report and it read as a routine warning.
        Write-WDLog ("Journal write FAILED for $ItemId ($Type -> $Target): " +
                     "$($_.Exception.Message). That change is now applied with no way back - " +
                     'the rollback script will not offer to reverse it.') -Level Error -Item $ItemId
    }
}

function Add-WDTrace {
    <#
        The diagnostic record, separate from the journal on purpose.

        The journal is the UNDO: it holds what changed and how to put it back,
        it is read by the rollback script, and every line in it is a promise.
        This is the FLIGHT RECORDER: it holds everything that happened
        including the things that did not change anything - actions that found
        nothing, refusals, guards that failed, timings - and nothing reads it
        but a human working out why.

        Keeping them apart matters both ways round. Noise in the journal turns
        into rollback steps that do nothing, and a journal filtered down to
        what is reversible cannot answer "why did that item do nothing".

        JSON Lines, appended, flushed per line, so a machine switched off
        mid-run still leaves a readable file up to the last completed action.
        Never throws: a diagnostic that can take a run down is a liability.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [hashtable]$Data
    )
    if (-not $script:Session) { return }
    if (-not $script:Session.TraceFile) { return }
    try {
        $entry = [ordered]@{ ts = (Get-Date).ToString('o'); kind = $Kind }
        if ($Data) {
            foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
        }
        Add-Content -LiteralPath $script:Session.TraceFile `
                    -Value ($entry | ConvertTo-Json -Compress -Depth 8) -Encoding UTF8
    } catch { }
}

function Format-WDException {
    <#
        Everything about a thrown error that is worth having afterwards.

        `$_.Exception.Message` alone is what the codebase logged, and it is the
        half that is least often enough: "Access is denied" names no path, no
        call, and no line. The type separates a permissions refusal from a null
        reference; the position names the line; the inner exception is where a
        wrapped COM or CIM failure keeps the actual reason.
    #>
    param($ErrorRecord)
    if (-not $ErrorRecord) { return $null }
    $ex = $ErrorRecord.Exception
    $inner = @()
    $walk = if ($ex) { $ex.InnerException } else { $null }
    $depth = 0
    while ($walk -and $depth -lt 4) {
        $inner += [ordered]@{ type = $walk.GetType().FullName; message = $walk.Message }
        $walk = $walk.InnerException
        $depth++
    }
    [ordered]@{
        type       = if ($ex) { $ex.GetType().FullName } else { $null }
        message    = if ($ex) { $ex.Message } else { [string]$ErrorRecord }
        category   = [string]$ErrorRecord.CategoryInfo.Category
        targetName = [string]$ErrorRecord.CategoryInfo.TargetName
        fqid       = [string]$ErrorRecord.FullyQualifiedErrorId
        at         = [string]$ErrorRecord.InvocationInfo.PositionMessage
        line       = [int]$ErrorRecord.InvocationInfo.ScriptLineNumber
        script     = [string]$ErrorRecord.InvocationInfo.ScriptName
        # The HRESULT is what makes a COM or DISM failure searchable. 0x800f080c
        # and "the operation failed" are the same event and only one is useful.
        hresult    = if ($ex -and $ex.PSObject.Properties['HResult']) { '0x{0:X8}' -f $ex.HResult } else { $null }
        stack      = [string]$ErrorRecord.ScriptStackTrace
        inner      = $inner
    }
}

function Get-WDMachineIdentity {
    <#
        Which machine this is, in a form that survives a rename and can be
        compared against a run recorded weeks ago.

        This exists because a run folder is portable ON PURPOSE - the whole
        point of Export-WDRunFolder is that a copy can be carried away on the
        stick that brought the toolkit - so "the journals I can see" and "the
        journals that describe THIS machine" are not the same set, and reverting
        against the wrong one writes another computer's registry values over
        this one's.

        Two ids rather than one, because they answer different questions.
        MachineGuid is per Windows INSTALLATION: written at setup, stable across
        renames, new hardware and domain joins. It is the one that decides,
        because a journal describes registry state and a reimage makes every
        previous value in it meaningless. The SMBIOS UUID is per HARDWARE and
        survives a reimage, which is the only thing that can tell "this box,
        reinstalled" apart from "a different box" - worth recording, never worth
        deciding on.

        Read once per process. Two CIM queries and a registry read, on a path
        the window build waits for.
    #>
    if ($script:MachineIdentity) { return $script:MachineIdentity }
    $g = { param([scriptblock]$B) try { & $B } catch { $null } }

    # Firmware that was never programmed reports one of these rather than
    # nothing at all, and two machines off the same line then look like one
    # machine. Neither is an id, so neither is kept.
    $dead = @('', '00000000-0000-0000-0000-000000000000', 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF',
              'Default string', 'To be filled by O.E.M.', 'System Serial Number', 'None')
    $clean = {
        param($V)
        $s = ([string]$V).Trim()
        foreach ($d in $dead) { if ($s -ieq $d) { return $null } }
        if (-not $s) { return $null }
        $s
    }

    $csp  = & $g { Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop }
    $bios = & $g { Get-CimInstance Win32_BIOS -ErrorAction Stop }
    $cs   = & $g { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }

    $script:MachineIdentity = [ordered]@{
        machineGuid  = & $clean (& $g { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid })
        systemUuid   = & $clean $(if ($csp)  { $csp.UUID }         else { $null })
        serial       = & $clean $(if ($bios) { $bios.SerialNumber } else { $null })
        computer     = [string]$env:COMPUTERNAME
        manufacturer = $(if ($cs) { [string]$cs.Manufacturer } else { $null })
        model        = $(if ($cs) { [string]$cs.Model }        else { $null })
    }
    $script:MachineIdentity
}

# ---------------------------------------------------------- one at a time ---
#
# THE NAME IS SHARED WITH THE ROLLBACK SCRIPT ON PURPOSE. Both change the same
# machine, and the failure this prevents is the one Write-WDRunEnvironment has
# always recorded and never stopped: two copies running at once each read the
# other's changes as the "previous value" for their own journal, so both
# rollbacks then restore the wrong thing. That is not a crash, it is a pair of
# undo files that are quietly, permanently wrong - the worst outcome this
# project has.
#
# So the toolkit and any rollback script are mutually exclusive, not merely one
# of each. A rollback script is exactly the thing that must not run while the
# Revert page is open.
$script:WDInstanceName  = 'Global\WinSetupToolkit.Toolkit.1'
$script:WDInstanceMutex = $null

function Enter-WDSingleInstance {
    <#
        Answers whether this process may proceed, and holds the claim if so.

        THE HANDLE IS THE CLAIM, not ownership of the mutex. WaitOne/ReleaseMutex
        is thread-affine - the GUI runs its dispatcher on this thread and the
        engine runs on another - and it has the abandoned-mutex case to get right
        when a process is killed. A named mutex object exists for exactly as long
        as somebody holds a handle to it, and Windows closes handles on process
        exit however the process died, so "did I create it" answers the question
        with no ownership, no release, and nothing to leak.

        Global\ so it spans sessions, and an explicit Everyone rule so it spans
        users: this writes HKLM and deprovisions packages, which are machine-wide
        whoever is signed in.

        Never throws. If the mutex cannot be created at all - a locked-down image,
        a policy - the answer is YES. Refusing to start because a safety
        interlock could not be built is a worse failure than the one it guards.
    #>
    param([string]$Mode = '')
    if ($script:WDInstanceMutex) { return @{ Ok = $true; Holder = @() } }
    $createdNew = $false
    try {
        $sec  = New-Object System.Security.AccessControl.MutexSecurity
        $rule = New-Object System.Security.AccessControl.MutexAccessRule(
                    (New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'),
                    [System.Security.AccessControl.MutexRights]::FullControl,
                    [System.Security.AccessControl.AccessControlType]::Allow)
        $sec.AddAccessRule($rule)
        $script:WDInstanceMutex = New-Object System.Threading.Mutex(
                                      $false, $script:WDInstanceName, [ref]$createdNew, $sec)
    } catch {
        try {
            $script:WDInstanceMutex = New-Object System.Threading.Mutex($false, $script:WDInstanceName, [ref]$createdNew)
        } catch {
            $script:WDInstanceMutex = $null
            return @{ Ok = $true; Holder = @(); Note = "the interlock could not be created: $($_.Exception.Message)" }
        }
    }
    if ($createdNew) { return @{ Ok = $true; Holder = @() } }
    # Somebody else has a handle open. Let go of ours so we are not the reason
    # the next process to ask gets the same answer.
    try { $script:WDInstanceMutex.Dispose() } catch { }
    $script:WDInstanceMutex = $null
    @{ Ok = $false; Holder = @(Get-WDRunningToolkits) }
}

function Exit-WDSingleInstance {
    <#  Optional - process exit does this too. Here so a long-lived host that
        runs the toolkit twice is not blocked by its own first run.  #>
    if (-not $script:WDInstanceMutex) { return }
    try { $script:WDInstanceMutex.Dispose() } catch { }
    $script:WDInstanceMutex = $null
}

function Get-WDRunningToolkits {
    <#
        Best effort description of who else is running, for the message only -
        the mutex has already decided.

        Matched on the SCRIPT rather than the word, the same rule
        Write-WDRunEnvironment follows: 'WinSetupToolkit' alone matches any shell
        whose command line merely mentions the folder. Undo-WinSetupToolkit.ps1
        matches the same pattern, which is wanted here - it is the other thing
        this interlock exists to exclude.

        Unelevated this may see nothing at all, because reading another user's
        command line needs rights this may not have. An empty list is therefore
        "could not tell", never "nobody", and the caller words it that way.
    #>
    $out = New-Object System.Collections.Generic.List[psobject]
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)) {
            if ($p.ProcessId -eq $PID) { continue }
            $cmd = [string]$p.CommandLine
            if ($cmd -notmatch 'WinSetupToolkit\.ps1') { continue }
            $kind = 'the toolkit'
            if ($cmd -match 'Undo-WinSetupToolkit\.ps1') { $kind = 'a rollback script' }
            $started = $null
            try { $started = $p.CreationDate } catch { }
            $out.Add([pscustomobject]@{ Pid = [int]$p.ProcessId; Kind = $kind; Started = $started; Command = $cmd })
        }
    } catch { }
    @($out)
}

function Get-WDSingleInstanceMessage {
    <#
        One wording for every surface, so the console, the GUI, and the rollback
        script cannot describe the same refusal three different ways.
    #>
    param($Holder, [string]$Me = 'This')
    # Where-Object, not @($Holder).Count. An empty array handed to a parameter
    # arrives as $null, and @($null) is a ONE-element array holding nothing - so
    # the count test passed and this printed "Already running: , process " with
    # both fields blank. Same trap that once drew a single blank radio button in
    # the browser picker.
    $seen  = @($Holder | Where-Object { $_ })
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('For your own safety, having two instances of the Windows Setup Toolkit or its reversion script open is not allowed. There is no reason why you should need two instances, and it can only do harm. Close the other instance to open a new one, or just use the existing one.')
    # Which one, when it can be read, under the sentence rather than inside it -
    # the paragraph is the answer, and this is the detail somebody needs only if
    # they cannot find the other window. Silence when nothing could be read: see
    # Get-WDRunningToolkits, where an empty list means "could not tell" and never
    # "nobody", and a line claiming either would be a guess.
    if ($seen.Count) {
        $lines.Add('')
        foreach ($h in $seen) {
            $when = ''
            if ($h.Started) { try { $when = ", started $([datetime]$h.Started)" } catch { } }
            $lines.Add("Already running: $($h.Kind), process $($h.Pid)$when")
        }
    }
    ($lines -join [Environment]::NewLine)
}

function Test-WDSameMachine {
    <#
        Does this record describe the machine we are running on?

        THREE-VALUED, and the third value is the whole point. $true is a match
        on an id, $false is a mismatch on an id, and $null is "cannot say" -
        which is what every run written before this existed answers, because it
        carries no id at all. Folding $null into either of the others is the one
        thing that must not happen: called $false it hides every historical run
        from the page that exists to undo them, and called $true it hands back
        the guarantee this function was written to provide.

        MachineGuid decides. The others are recorded for a human reading the
        file and are deliberately not compared: a computer can be renamed, and
        two machines of the same model share a model.
    #>
    param($Recorded)

    if ($null -eq $Recorded) { return $null }
    # Not Get-Prop: that lives in WD.Actions, which loads after this module, and
    # two paths import Core on its own - the generated rollback script and the
    # first-sign-in result window. The record also arrives as a hashtable from
    # Get-WDMachineIdentity and as a PSCustomObject from ConvertFrom-Json, so
    # both shapes are read here rather than assumed.
    $his = ''
    if ($Recorded -is [System.Collections.IDictionary]) {
        if ($Recorded.Contains('machineGuid')) { $his = [string]$Recorded['machineGuid'] }
    } elseif ($Recorded.PSObject.Properties['machineGuid']) {
        $his = [string]$Recorded.machineGuid
    }
    $mine = Get-WDMachineIdentity
    if (-not $his -or -not $mine.machineGuid) { return $null }
    ($his -ieq [string]$mine.machineGuid)
}

function Get-WDRunIndexPath {
    <#  Where the standing record of applies lives. Root of the data folder.  #>
    param([string]$Root = '')
    if (-not $Root) {
        if ($script:Session) { $Root = [string]$script:Session.Root }
        else                 { $Root = Join-Path $env:ProgramData 'WinSetupToolkit' }
    }
    Join-Path $Root 'runs.jsonl'
}

function Register-WDRunRecord {
    <#
        One line per apply, written at the ROOT of the data folder rather than
        inside the run folder it describes.

        That placement is the entire feature. "Delete old run logs" removes the
        run-* folders and every journal with them, so after it the machine has
        been changed by runs it holds no record of whatsoever - not even their
        dates. This file outlives that, which lets the page that offers to undo
        things still name what happened, when, and by which run, and say plainly
        that the journal it would have needed is gone. A change nobody can undo
        is bad; a change nobody can even account for is worse.

        It also carries the machine identity, which is what makes "runs that
        happened on THIS machine" answerable at all - a run folder is portable
        by design, so its presence on a disk is not evidence about which
        computer it was applied to.

        Append-only, and best-effort throughout: this runs after an apply has
        already succeeded and must never be the thing that fails it.
    #>
    param($Report = $null)

    if (-not $script:Session -or $script:Session.Preview) { return $null }
    try {
        $rec = [ordered]@{
            v       = 1
            run     = [string]$script:Session.Id
            started = ([datetime]$script:Session.Started).ToString('o')
            ended   = (Get-Date).ToString('o')
            machine = Get-WDMachineIdentity
            dir     = [string]$script:Session.RunDir
            journal = (Test-Path -LiteralPath $script:Session.JournalFile)
            undo    = (Test-Path -LiteralPath (Join-Path $script:Session.RunDir 'Undo-WinSetupToolkit.ps1'))
            counts  = $null
        }
        if ($Report -and $Report.PSObject.Properties['counts']) { $rec.counts = $Report.counts }
        # One line, no indentation: this file is appended to for the life of the
        # machine and is read a line at a time.
        $line = $rec | ConvertTo-Json -Depth 6 -Compress
        Add-Content -LiteralPath (Get-WDRunIndexPath) -Value $line -Encoding UTF8
        Write-WDLog "Run recorded in the standing index." -Level Debug
        return $rec
    } catch {
        Write-WDLog "Could not record this run in the standing index: $($_.Exception.Message)" -Level Warn
        return $null
    }
}

function Get-WDRunIndex {
    <#
        Every apply this machine has a standing record of, oldest first.

        A line that will not parse is skipped rather than taken as the end of
        the file: this is appended to by every run for the life of the machine,
        and one truncated write must not hide everything after it.
    #>
    param([string]$Root = '')

    $path = Get-WDRunIndexPath -Root $Root
    $out  = New-Object System.Collections.Generic.List[psobject]
    if (-not (Test-Path -LiteralPath $path)) { return $out.ToArray() }
    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        if (-not "$line".Trim()) { continue }
        try { $out.Add(($line | ConvertFrom-Json)) } catch { }
    }
    $out.ToArray()
}

function Get-WDRunEnvironment {
    <#
        Everything about the machine that decides whether a run can work,
        gathered once, before anything is touched.

        This exists because the failures that are hardest to reconstruct
        afterwards are the ones where the machine was never in a state to
        succeed - a pending reboot that makes DISM refuse every feature, safe
        mode, no space, a second copy of the toolkit already running. Each of
        those produces a scatter of unrelated-looking item failures, and none
        of them is visible in the item results.

        Best effort throughout. A field that cannot be read comes back null
        rather than taking the block down, because this runs on the path to
        every apply.
    #>
    $g = { param([scriptblock]$B) try { & $B } catch { $null } }

    $cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os = & $g { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
    $cs = & $g { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }

    $renames = & $g {
        $p = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
                              -Name PendingFileRenameOperations -ErrorAction Stop
        @($p.PendingFileRenameOperations | Where-Object { $_ }).Count
    }

    $sysDrive = if ($os) { $os.SystemDrive } else { $env:SystemDrive }
    $free = & $g {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'" -ErrorAction Stop
        [pscustomobject]@{ FreeGb = [Math]::Round($d.FreeSpace / 1GB, 2)
                           TotalGb = [Math]::Round($d.Size / 1GB, 2) }
    }

    # 2 means running on mains. Anything else on a machine that HAS a battery
    # means a run could lose power partway, which is the one interruption this
    # toolkit cannot make safe.
    #
    # hasBattery is recorded separately rather than letting onMains default to
    # true, because "plugged in" and "there is no battery to be unplugged from"
    # are different facts and only one of them is reassuring. A desktop and a
    # laptop whose battery cannot be enumerated would otherwise read alike.
    $bat = & $g { @(Get-CimInstance Win32_Battery -ErrorAction Stop) }
    $hasBattery = [bool]($bat -and @($bat).Count)
    $onMains = $true
    $batteryPct = $null
    if ($hasBattery) {
        $onMains = [bool](@($bat | Where-Object { $_.BatteryStatus -eq 2 }).Count)
        $batteryPct = ($bat | Select-Object -First 1).EstimatedChargeRemaining
    }

    # Three-valued, like everything else here that can be refused rather than
    # answered. Unelevated this throws, and a null that the caller compares
    # against 0 silently means "no warning" - which is the opposite of what an
    # unreadable safety net should produce.
    $rpCount = $null
    $rpError = $null
    try { $rpCount = @(Get-ComputerRestorePoint -ErrorAction Stop).Count }
    catch { $rpError = $_.Exception.Message }

    # Another copy of the toolkit, or a guard task firing mid-run. Two runs
    # interleaving read each other's "previous value" into their journals and
    # both rollbacks then restore the wrong thing.
    # Matched on the SCRIPT, not on the word. 'WinSetupToolkit' alone matches any
    # shell whose command line merely mentions the folder - a test harness, an
    # editor's terminal, a path in an unrelated argument - and a false alarm
    # about corrupted undo data is exactly the kind nobody can check and so
    # everybody learns to ignore.
    $others = & $g {
        @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
          Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'WinSetupToolkit\.ps1' } |
          ForEach-Object { [ordered]@{ pid = $_.ProcessId; cmd = [string]$_.CommandLine } })
    }

    # Which code is actually running. "It worked on my machine" is unanswerable
    # without this, and the modules are edited constantly.
    $modules = & $g {
        @(Get-ChildItem (Join-Path $PSScriptRoot '*.psm1') -ErrorAction Stop | ForEach-Object {
            [ordered]@{
                name  = $_.Name
                bytes = $_.Length
                wrote = $_.LastWriteTime.ToString('o')
                sha256 = (Get-FileHash $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
            }
        })
    }

    [ordered]@{
        # --- who and what ---
        user          = "$env:USERDOMAIN\$env:USERNAME"
        sid           = & $g { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
        elevated      = (Test-WDAdmin)
        psVersion     = $PSVersionTable.PSVersion.ToString()
        psEdition     = [string]$PSVersionTable.PSEdition
        clrVersion    = [string]$PSVersionTable.CLRVersion
        executionPolicy = & $g { [string](Get-ExecutionPolicy) }
        processId     = $PID
        commandLine   = & $g { (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).CommandLine }
        culture       = [string](Get-Culture).Name
        uiCulture     = [string](Get-UICulture).Name

        # --- the machine ---
        # The identity block, so a journal read back later can be checked
        # against the machine it is about to be replayed on. The three fields
        # below it are kept as they were: they are what the log line prints,
        # and dropping them would change every environment.json ever written.
        machine       = Get-WDMachineIdentity
        computer      = $env:COMPUTERNAME
        manufacturer  = if ($cs) { $cs.Manufacturer } else { $null }
        model         = if ($cs) { $cs.Model } else { $null }
        domainJoined  = if ($cs) { [bool]$cs.PartOfDomain } else { $null }
        osCaption     = if ($os) { $os.Caption } else { $null }
        build         = & $g { [string](Get-ItemProperty $cv -Name CurrentBuild -ErrorAction Stop).CurrentBuild }
        ubr           = & $g { [string](Get-ItemProperty $cv -Name UBR -ErrorAction Stop).UBR }
        displayVersion= & $g { [string](Get-ItemProperty $cv -Name DisplayVersion -ErrorAction Stop).DisplayVersion }
        edition       = & $g { [string](Get-ItemProperty $cv -Name EditionID -ErrorAction Stop).EditionID }
        lastBoot      = if ($os) { $os.LastBootUpTime.ToString('o') } else { $null }
        uptimeHours   = if ($os) { [Math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1) } else { $null }

        # --- the four states that break a run before it starts ---
        # Safe mode: most services are not running and DISM refuses outright.
        bootupState   = if ($os) { [string]$os.BootupState } else { $null }
        safeBoot      = & $g { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option' -Name OptionValue -ErrorAction Stop).OptionValue }
        # Pending reboot: every feature and capability action will refuse.
        rebootPending = [ordered]@{
            cbs       = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
            wu        = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
            renames   = $renames
        }
        freeGb        = if ($free) { $free.FreeGb } else { $null }
        totalGb       = if ($free) { $free.TotalGb } else { $null }
        hasBattery    = $hasBattery
        onMains       = $onMains
        batteryPct    = $batteryPct

        # --- the safety net, and whether it exists ---
        restorePoints = $rpCount
        restorePointsError = $rpError
        srDisabled    = & $g { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name DisableSR -ErrorAction Stop).DisableSR }
        srFrequency   = & $g { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name SystemRestorePointCreationFrequency -ErrorAction Stop).SystemRestorePointCreationFrequency }
        tamperProtect = & $g { (Get-MpComputerStatus -ErrorAction Stop).IsTamperProtected }

        # --- who else is here ---
        otherInstances = $others
        modules        = $modules
    }
}

function Write-WDRunEnvironment {
    <#
        Writes the environment block to the run folder and puts the handful of
        facts that change what a run can do into the log itself, at a level
        somebody will actually see.

        The distinction matters: the file is for reconstructing a failure
        weeks later, and the log lines are for noticing NOW that this run is
        about to do less than it says.
    #>
    if (-not $script:Session) { return $null }
    # Not $env. That is the environment-variable provider's prefix, and a
    # variable of that name works right up until somebody writes "$env.field"
    # inside a double-quoted string, where it interpolates as the provider and
    # then the literal text. Cheap to avoid, expensive to find.
    $info = $null
    try { $info = Get-WDRunEnvironment } catch {
        Write-WDLog "Could not read the run environment: $($_.Exception.Message)" -Level Warn
        return $null
    }
    try {
        $info | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $script:Session.EnvFile -Encoding UTF8
    } catch { }
    Add-WDTrace -Kind 'environment' -Data @{ env = $info }

    Write-WDLog ("Machine: {0} {1}, {2} {3} build {4}.{5}, {6}" -f `
                 $info.manufacturer, $info.model, $info.osCaption, $info.displayVersion,
                 $info.build, $info.ubr, $info.edition) -Level Info
    Write-WDLog ("Running as {0}, elevated={1}, PowerShell {2}, policy {3}" -f `
                 $info.user, $info.elevated, $info.psVersion, $info.executionPolicy) -Level Info
    Write-WDLog ("Free space on the system drive: {0} GB of {1} GB" -f $info.freeGb, $info.totalGb) -Level Info

    # Everything below is a reason this run may quietly do less than it says.
    if (-not $info.elevated) {
        Write-WDLog 'NOT ELEVATED. Most removals will report Blocked.' -Level Warn
    }
    if ($info.safeBoot) {
        Write-WDLog "SAFE MODE (OptionValue=$($info.safeBoot)). Services and DISM will not behave normally." -Level Warn
    }
    if ($info.rebootPending.cbs -or $info.rebootPending.wu) {
        Write-WDLog ('A RESTART IS ALREADY PENDING (cbs={0}, wu={1}). Windows features and capabilities will refuse to change until the machine is restarted.' -f `
                     $info.rebootPending.cbs, $info.rebootPending.wu) -Level Warn
    }
    if ($info.rebootPending.renames -gt 0) {
        Write-WDLog "$($info.rebootPending.renames) file operation(s) were already queued for the next restart before this run." -Level Info
    }
    if ($null -ne $info.freeGb -and $info.freeGb -lt 5) {
        Write-WDLog "Only $($info.freeGb) GB free. Restore points, backups, and installers may fail." -Level Warn
    }
    if ($info.hasBattery -and -not $info.onMains) {
        Write-WDLog "Running on battery ($($info.batteryPct)%). Losing power partway through cannot be made safe." -Level Warn
    }
    # Three cases, and the middle one used to be silent: null is "could not
    # read", which is not the same as zero and must not be reported as though
    # the safety net had been checked and found empty.
    if ($null -ne $info.restorePointsError) {
        Write-WDLog "Could not read the restore point list ($($info.restorePointsError)). Whether there is a way back is unknown." -Level Warn
    } elseif ($info.restorePoints -eq 0) {
        Write-WDLog 'There are no system restore points on this machine. The rollback script is the only way back.' -Level Warn
    } else {
        Write-WDLog "System restore points on this machine: $($info.restorePoints)." -Level Info
    }
    # The tool sweep, if WD.Preflight is loaded. Guarded rather than assumed:
    # Core loads first and must not depend on a module that comes after it, and
    # two paths import Core on its own - the generated rollback script, and the
    # first-sign-in result window.
    if (Get-Command Write-WDToolHealthLog -ErrorAction SilentlyContinue) {
        try { $null = Write-WDToolHealthLog } catch {
            Write-WDLog "The tool check could not run: $($_.Exception.Message)" -Level Warn
        }
    }

    if ($info.otherInstances -and @($info.otherInstances).Count) {
        Write-WDLog ("ANOTHER COPY OF THE TOOLKIT MAY BE RUNNING ({0} process(es)). Two runs at once corrupt each other's undo data - each reads the other's changes as the 'previous value' and both rollbacks then restore the wrong thing." -f `
                     @($info.otherInstances).Count) -Level Error
        # The command line, not only the pid, because this matches on the word
        # WinSetupToolkit appearing anywhere in it - a shell sitting in the folder
        # counts, and a false alarm nobody can check is worse than no alarm.
        foreach ($o in @($info.otherInstances)) {
            $cmd = [string]$o.cmd
            if ($cmd.Length -gt 160) { $cmd = $cmd.Substring(0, 157) + '...' }
            Write-WDLog "  pid $($o.pid): $cmd" -Level Error
        }
    }
    $info
}

function New-WDRestorePoint {
    <#
        OEM images very often ship with System Protection disabled, and Windows
        silently swallows restore points created within 24h of the last one.
        Handle both before giving up.
    #>
    param([string]$Description = 'Windows Setup Toolkit - before debloat')

    if ($script:Session -and $script:Session.Preview) {
        Write-WDLog 'Preview mode: skipping restore point.' -Level Info
        return New-WDResult -Status Skipped -Message 'Preview mode'
    }

    try {
        $drive = "$env:SystemDrive\"
        Write-WDLog "Enabling System Protection on $drive" -Level Info
        Enable-ComputerRestore -Drive $drive -ErrorAction Stop
    } catch {
        Write-WDLog "Could not enable System Protection: $($_.Exception.Message)" -Level Warn
    }

    # Lift the once-per-24h throttle for this run, then put it back.
    #
    # RESTORING A SAVED SETTING HAS THREE CASES, NOT TWO: it was this, it was
    # that, or IT WAS NOT THERE. SystemRestorePointCreationFrequency does not
    # exist on a default Windows install, so the old "put it back if it is not
    # null" ending never fired and the value was left at 0 permanently - which
    # makes Windows take a restore point at every trigger rather than at most
    # one a day, churning through the shadow storage cap and deleting older
    # restore points, including in time the one this function just made. The
    # safety net degraded because the safety net was created.
    $srKey    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $freqName = 'SystemRestorePointCreationFrequency'
    $hadFreq  = $false
    $restore  = $null
    try {
        if (Test-Path $srKey) {
            $prop = Get-ItemProperty -Path $srKey -Name $freqName -ErrorAction SilentlyContinue
            if ($null -ne $prop -and $null -ne $prop.$freqName) {
                $hadFreq = $true
                $restore = $prop.$freqName
            }
        } else {
            $null = New-Item -Path $srKey -Force
        }
        Set-ItemProperty -Path $srKey -Name $freqName -Value 0 -Type DWord -Force
        # JOURNALLED AS WELL AS RESTORED IN THE FINALLY, and the two cover
        # different failures. A finally covers an exception; it does not cover
        # the process being killed - and Checkpoint-Computer below holds this
        # window open for tens of seconds. Left at 0, Windows takes a restore
        # point at every trigger rather than at most one a day, churns through
        # the shadow storage cap and evicts older restore points including the
        # one this function just made, and nothing anywhere records that this
        # run is why. Exactly the argument RemoveEdge's home-region flip is
        # journalled under.
        Add-WDJournal -ItemId 'restore-point' -Type 'registry' -Target "$srKey\$freqName" `
                      -Status 'Changed' -Undo @{
                          method   = 'registry'
                          path     = $srKey
                          name     = $freqName
                          kind     = 'DWord'
                          previous = $(if ($hadFreq) { $restore } else { '__ABSENT__' })
                          raw      = $true
                      }
    } catch {
        Write-WDLog "Could not adjust restore point frequency: $($_.Exception.Message)" -Level Warn
    }

    try {
        Write-WDLog 'Creating system restore point...' -Level Info
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-WDLog 'Restore point created.' -Level Success
        $result = New-WDResult -Status Changed -Message 'Restore point created'
    } catch {
        Write-WDLog "Restore point FAILED: $($_.Exception.Message)" -Level Error
        $result = New-WDResult -Status Failed -Message 'Restore point failed' -Detail $_.Exception.Message
    } finally {
        try {
            if ($hadFreq) {
                Set-ItemProperty -Path $srKey -Name $freqName -Value $restore -Type DWord -Force
            } else {
                # It was not there. Putting it back means taking it away again,
                # not leaving this run's zero standing.
                Remove-ItemProperty -Path $srKey -Name $freqName -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    $result
}

function Backup-WDRegistryKey {
    <#
        Export a key before we write to it. Exports are deduped per run so a
        manifest touching the same hive fifty times only pays for it once.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not $script:Session -or $script:Session.Preview) { return }

    # Accept both PS-drive and native forms.
    $native = $Path -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\' `
                    -replace '^HKCR:\\', 'HKCR\' -replace '^HKU:\\',  'HKU\'

    $safe = ($native -replace '[\\/:*?"<>|]', '_')
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0, 120) }
    $out  = Join-Path $script:Session.RegDir "$safe.reg"
    if (Test-Path -LiteralPath $out) { return $out }

    $psPath = $native -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\' `
                      -replace '^HKCR\\', 'HKCR:\' -replace '^HKU\\',  'HKU:\'
    if (-not (Test-Path -LiteralPath $psPath)) { return }   # nothing to back up

    # reg.exe prints failures to the console; capture both streams so a refused
    # export never looks like the tool itself crashed.
    $so = [IO.Path]::GetTempFileName(); $se = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath reg.exe -ArgumentList @('export', "`"$native`"", "`"$out`"", '/y') `
                           -NoNewWindow -Wait -PassThru -RedirectStandardOutput $so -RedirectStandardError $se `
                           -ErrorAction SilentlyContinue
        if ($p -and $p.ExitCode -eq 0) {
            Write-WDLog "Backed up $native" -Level Debug
            return $out
        }
        Write-WDLog "Registry backup failed for $native" -Level Warn
    } catch {
        Write-WDLog "Registry backup errored for $native : $($_.Exception.Message)" -Level Warn
    } finally {
        Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------- ownership escalation ----
#
# Some objects are owned by TrustedInstaller, and an administrator gets access
# denied on them. Taking ownership and granting Administrators full control is
# the standard fix, and it works reliably for REGISTRY objects - which covers
# service configuration, scheduled task entries and policy keys.
#
# It is deliberately NOT used for Appx packages Windows marks non-removable.
# Those are refused by the deployment stack, not by an ACL; seizing
# C:\Program Files\WindowsApps and deleting the folder does not make
# Remove-AppxPackage succeed, it just desynchronizes the package state
# repository and breaks servicing and Store updates. See CLAUDE.md.

#
# Compiled by Enable-WDOwnershipPrivileges rather than at import, because it is
# only ever wanted part-way into a run that is escalating - and a csc invocation
# at import time is 400 ms of the launch spent on something most runs never
# touch. See the native note at the top of this file.
$script:WDPrivSource = @'
using System;
using System.Runtime.InteropServices;
public class WDPriv {
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool LookupPrivilegeValue(string sys, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TOKEN_PRIVILEGES nw, uint len, IntPtr prev, IntPtr rl);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    public static bool Enable(string privilege) {
        IntPtr tok = IntPtr.Zero;
        if (!OpenProcessToken(GetCurrentProcess(), 0x20 | 0x8, out tok)) { return false; }
        try {
            LUID luid;
            if (!LookupPrivilegeValue(null, privilege, out luid)) { return false; }
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Privileges.Luid = luid;
            tp.Privileges.Attributes = 0x2;   // SE_PRIVILEGE_ENABLED
            if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) { return false; }
            return Marshal.GetLastWin32Error() == 0;
        } finally { if (tok != IntPtr.Zero) { CloseHandle(tok); } }
    }
}
'@

$script:PrivilegesEnabled = $null

function Enable-WDOwnershipPrivileges {
    <#
        SeTakeOwnership and SeRestore are present in an admin token but disabled
        by default, and .NET will not enable them for you - SetAccessControl
        just fails with access denied until they are switched on.
    #>
    if ($null -ne $script:PrivilegesEnabled) { return $script:PrivilegesEnabled }
    if (-not ('WDPriv' -as [type])) {
        try { Add-Type -ErrorAction SilentlyContinue -TypeDefinition $script:WDPrivSource } catch { }
    }
    if (-not ('WDPriv' -as [type])) {
        $script:PrivilegesEnabled = $false
        Write-WDLog 'Could not build the take-ownership helper, so ownership escalation is unavailable.' -Level Warn
        return $false
    }
    $ok = $false
    try {
        $a = [WDPriv]::Enable('SeTakeOwnershipPrivilege')
        $b = [WDPriv]::Enable('SeRestorePrivilege')
        $ok = ($a -and $b)
    } catch { $ok = $false }
    $script:PrivilegesEnabled = $ok
    if (-not $ok) { Write-WDLog 'Could not enable take-ownership privileges.' -Level Warn }
    $ok
}

function ConvertTo-WDRegParts {
    <#  PS-style registry path -> hive object plus subkey.  #>
    param([string]$Path)
    $p = $Path -replace '^Registry::', ''
    $map = @{
        'HKLM:'                = [Microsoft.Win32.Registry]::LocalMachine
        'HKEY_LOCAL_MACHINE'   = [Microsoft.Win32.Registry]::LocalMachine
        'HKCU:'                = [Microsoft.Win32.Registry]::CurrentUser
        'HKEY_CURRENT_USER'    = [Microsoft.Win32.Registry]::CurrentUser
        'HKCR:'                = [Microsoft.Win32.Registry]::ClassesRoot
        'HKEY_CLASSES_ROOT'    = [Microsoft.Win32.Registry]::ClassesRoot
        'HKU:'                 = [Microsoft.Win32.Registry]::Users
        'HKEY_USERS'           = [Microsoft.Win32.Registry]::Users
    }
    foreach ($prefix in $map.Keys) {
        if ($p -like "$prefix\*") {
            return [pscustomobject]@{ Hive = $map[$prefix]; SubKey = $p.Substring($prefix.Length + 1) }
        }
    }
    $null
}

function Grant-WDRegistryOwnership {
    <#
        Take ownership of a registry key and give Administrators full control.
        Returns the previous owner SID so the change is recorded and reversible.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Enable-WDOwnershipPrivileges)) {
        return [pscustomobject]@{ Success = $false; PreviousOwner = $null; Error = 'take-ownership privilege unavailable' }
    }
    $parts = ConvertTo-WDRegParts -Path $Path
    if (-not $parts) {
        return [pscustomobject]@{ Success = $false; PreviousOwner = $null; Error = "unrecognized registry path '$Path'" }
    }

    $admins = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $prev   = $null
    try {
        # Owner first - nothing else is permitted until we own the key.
        $k = $parts.Hive.OpenSubKey($parts.SubKey,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if (-not $k) { return [pscustomobject]@{ Success = $false; PreviousOwner = $null; Error = 'key not found' } }
        try {
            $acl = $k.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
            try { $prev = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value } catch { }
            $acl.SetOwner($admins)
            $k.SetAccessControl($acl)
        } finally { $k.Close() }

        # Then the access rule, which now succeeds because we are the owner.
        $k2 = $parts.Hive.OpenSubKey($parts.SubKey,
                 [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                 [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        try {
            $acl2 = $k2.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                        $admins, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl2.SetAccessRule($rule)
            $k2.SetAccessControl($acl2)
        } finally { $k2.Close() }

        Write-WDLog "Took ownership of $Path (was $prev)" -Level Warn
        [pscustomobject]@{ Success = $true; PreviousOwner = $prev; Error = $null }
    } catch {
        [pscustomobject]@{ Success = $false; PreviousOwner = $prev; Error = $_.Exception.Message }
    }
}

function Set-WDRebootNeeded {
    if ($script:Session) { $script:Session.RebootNeeded = $true }
}

# What this run uninstalled, and where each program said it lived. Recorded at
# uninstall time because the registry key that holds InstallLocation is removed
# along with the program - by the time the leftover sweep runs there is nothing
# left to ask.
$script:UninstalledThisRun = New-Object System.Collections.Generic.List[psobject]

# Run-wide, set by the 'irreversible' item at the very start of the plan. Every
# path that would otherwise preserve a way back checks it: file deletions stop
# going to the Recycle Bin, and the bin is emptied when the run finishes.
$script:Irreversible = $false

function Set-WDIrreversible { $script:Irreversible = $true }
function Test-WDIrreversible { $script:Irreversible }

function Clear-WDRecycleBin {
    <#
        Empties the Recycle Bin for every drive, including whatever was already
        in it before this run. That is the point of the mode and it is what the
        item's risk note says, but it is worth being explicit here too: this
        destroys the operator's own deleted files, not just the toolkit's.
    #>
    if (-not (Initialize-WDRecycleType)) { return $false }
    try {
        # SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND
        $rc = [WD.Shell]::SHEmptyRecycleBin([IntPtr]::Zero, $null, 0x07)
        # 0 is done; -2147418113 (E_UNEXPECTED) is what an already-empty bin
        # returns on some builds, and that is not a failure.
        if ($rc -eq 0 -or $rc -eq -2147418113) { return $true }
        Write-WDLog "Emptying the Recycle Bin returned $rc" -Level Warn
        $false
    } catch {
        Write-WDLog "Emptying the Recycle Bin failed: $($_.Exception.Message)" -Level Warn
        $false
    }
}

function Write-WDFinding {
    <#
        One line in the preview for something the operator has to look at
        individually, rather than a count buried in an item's detail. The
        residue sweep is the reason this exists: "14 suspicious folders" is not
        a thing anyone can approve, and the whole point of that item is that a
        human reads the list.

        Findings are informational. They never touch the run counts and they are
        not excludable rows - excluding is per item, and the item is the sweep.
    #>
    param([Parameter(Mandatory)][string]$Name, [string]$Detail, [string]$ItemId)

    Write-WDLog "Found: $Name$(if ($Detail) { " - $Detail" })" -Level Debug -Item $ItemId
    if ($script:Session -and $script:Session.Sink) {
        try { & $script:Session.Sink 'Finding' @{ Name = $Name; Detail = $Detail } $ItemId } catch { }
    }
}

function Register-WDUninstalled {
    param([string]$Name, [string]$InstallLocation)
    $script:UninstalledThisRun.Add([pscustomobject]@{
        Name = $Name; InstallLocation = $InstallLocation
    })
}

function Get-WDUninstalledThisRun {
    ,@($script:UninstalledThisRun)
}

$script:RecycleTypeReady = $false

function Initialize-WDRecycleType {
    if ($script:RecycleTypeReady) { return $true }
    try {
        if (-not ('WD.Shell' -as [type])) {
            Add-Type -Namespace 'WD' -Name 'Shell' -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct SHFILEOPSTRUCT {
    public IntPtr hwnd;
    public uint   wFunc;
    [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
    [MarshalAs(UnmanagedType.LPWStr)] public string pTo;
    public ushort fFlags;
    [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
    public IntPtr hNameMappings;
    [MarshalAs(UnmanagedType.LPWStr)] public string lpszProgressTitle;
}
[DllImport("shell32.dll", CharSet=CharSet.Unicode)]
public static extern int SHFileOperation(ref SHFILEOPSTRUCT lpFileOp);
[DllImport("shell32.dll", CharSet=CharSet.Unicode)]
public static extern int SHEmptyRecycleBin(IntPtr hwnd, string pszRootPath, uint dwFlags);
'@ -ErrorAction Stop
        }
        $script:RecycleTypeReady = $true
    } catch {
        Write-WDLog "Recycle Bin support unavailable: $($_.Exception.Message)" -Level Warn
    }
    $script:RecycleTypeReady
}

function Remove-WDToRecycleBin {
    <#
        Delete to the Recycle Bin rather than outright, so the one part of this
        toolkit that touches the file system is still reversible. Everything
        else in the journal can be put back exactly; a hard Remove-Item cannot,
        which is why the leftover sweep and the extension removals both come
        through here.

        SHFileOperation rather than Microsoft.VisualBasic.FileSystem: the latter
        can raise a shell dialog, and the engine runs on a background runspace
        where a modal dialog has nobody to dismiss it.

        Returns $true only when the item is actually gone. FOF_ALLOWUNDO is a
        request, not a guarantee - a volume with no Recycle Bin, or an item
        larger than the bin's quota, deletes permanently instead. Callers that
        promise reversibility must check Test-WDRecycleAvailable first.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if (-not (Initialize-WDRecycleType)) { return $false }

    $op = New-Object WD.Shell+SHFILEOPSTRUCT
    $op.wFunc  = 3                        # FO_DELETE
    $op.pFrom  = $Path + "`0`0"           # the list is double-null terminated
    # SILENT | NOCONFIRMATION | ALLOWUNDO | NOCONFIRMMKDIR | NOERRORUI
    $op.fFlags = [uint16](0x0004 -bor 0x0010 -bor 0x0040 -bor 0x0200 -bor 0x0400)

    try {
        $rc = [WD.Shell]::SHFileOperation([ref]$op)
        if ($rc -ne 0) {
            Write-WDLog "Recycle failed for $Path (SHFileOperation $rc)" -Level Warn
            return $false
        }
        if ($op.fAnyOperationsAborted) { return $false }
        -not (Test-Path -LiteralPath $Path)
    } catch {
        Write-WDLog "Recycle threw for $Path : $($_.Exception.Message)" -Level Warn
        $false
    }
}

function Test-WDRecycleAvailable {
    <#
        Whether the volume holding a path actually has a Recycle Bin. Network
        shares, removable media configured not to use one, and anything the
        policy "do not move files to the Recycle Bin" applies to do not, and on
        those SHFileOperation deletes permanently while reporting success.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $qualifier = [IO.Path]::GetPathRoot($Path)
        if (-not $qualifier) { return $false }
        $drive = Get-Item -LiteralPath $qualifier -ErrorAction Stop
        if ((Get-Item -LiteralPath $Path -ErrorAction Stop).PSDrive.Provider.Name -ne 'FileSystem') { return $false }
        $di = New-Object System.IO.DriveInfo $qualifier
        if ($di.DriveType -ne 'Fixed') { return $false }
        # Group policy can switch the bin off machine-wide or per-user.
        foreach ($k in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer',
                         'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer')) {
            $v = Get-ItemProperty -LiteralPath $k -Name 'NoRecycleFiles' -ErrorAction SilentlyContinue
            if ($v -and [int]$v.NoRecycleFiles -eq 1) { return $false }
        }
        $null = $drive
        $true
    } catch { $false }
}

$script:PendingDeleteReady = $false

function Initialize-WDPendingDeleteType {
    if ($script:PendingDeleteReady) { return $true }
    try {
        if (-not ('WD.Pending' -as [type])) {
            Add-Type -Namespace 'WD' -Name 'Pending' -MemberDefinition @'
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, uint dwFlags);
'@ -ErrorAction Stop
        }
        $script:PendingDeleteReady = $true
    } catch {
        Write-WDLog "Delete-on-restart support unavailable: $($_.Exception.Message)" -Level Warn
    }
    $script:PendingDeleteReady
}

function Test-WDSweepableRoot {
    <#
        Whether a directory is specific enough to be treated as one program's
        own, and the normalized path when it is.

        Installers do write bare shared roots into InstallLocation - "C:\Program
        Files" is the one that actually turns up - and anything that then acts on
        that folder is acting on every program on the machine rather than on one.
        The leftover sweep has needed this check since it existed. The process
        kill before an uninstall needs exactly the same answer, and it is here
        rather than copied because two copies of a safety list is one list and a
        bug waiting for whoever extends the other one.

        Answers with the normalized path or $null, rather than true or false, so
        a caller cannot check this and then go on to use the raw value it was
        handed - which may still have quotes, a trailing slash, or unexpanded
        environment variables in it.
    #>
    param([string]$Path)
    if (-not $Path) { return $null }
    $p = ''
    try   { $p = [Environment]::ExpandEnvironmentVariables($Path).Trim().Trim('"').TrimEnd('\') }
    catch { return $null }
    # Four characters is what rules out a bare drive root: "C:\" normalizes to
    # "C:" and nothing shorter than four can name a folder inside one.
    if (-not $p -or $p.Length -lt 4) { return $null }
    $forbidden = @(
        $env:SystemRoot, $env:SystemDrive, "$env:SystemDrive\",
        $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
        $env:LOCALAPPDATA, $env:APPDATA, $env:USERPROFILE, $env:PUBLIC,
        (Join-Path $env:ProgramFiles 'Common Files'),
        (Join-Path ${env:ProgramFiles(x86)} 'Common Files'),
        (Join-Path $env:ProgramFiles 'WindowsApps'),
        (Join-Path $env:SystemRoot 'System32'),
        # The PARENT of the profile, which the list reached round on both sides
        # and never named: USERPROFILE and PUBLIC were both here while the
        # folder holding them was not, so an installer declaring C:\Users as its
        # install location described every profile on the machine. Derived
        # rather than literal, so a machine whose profiles were relocated is
        # covered by the same line.
        (Split-Path -Parent $env:USERPROFILE)
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }
    if ($forbidden -contains $p.ToLowerInvariant()) { return $null }
    $p
}

# ====================================================== critical services ===
#
# Services no run may switch off or stop, whatever asked for it.
#
# THIS IS NOT WD.Discover's $ProtectedServices AND MUST NOT BE MERGED WITH IT.
# That list answers "may the scan OFFER this", and it is deliberately broad -
# Themes, FontCache, W32Time, TermService, SysMain and a dozen more are on it
# because an unrecognized service is the worst possible thing to offer to switch
# off, not because disabling them breaks anything. Enforcing that list here
# would forbid a legitimate future item for any of them, and would have made
# the shipped svc-sysmain item silently do nothing - the exact shape this
# project complains about everywhere else.
#
# This list is the narrow one: disabling any of these leaves the machine unable
# to reach a usable desktop, unable to be patched, or unable to defend itself.
# It is enforced in the executor, so it is a fact about what the toolkit does
# rather than about what one of its screens offers. It had no enforcement at all
# before - the guarantee held only because no shipped item happens to name one,
# and a typo naming RpcSs or DcomLaunch would have gone straight through.
$script:CriticalServices = @(
    # Boot, logon, and the shell. Nothing reaches a desktop without these.
    'RpcSs', 'RpcEptMapper', 'DcomLaunch', 'PlugPlay', 'Power', 'ProfSvc', 'UserManager',
    'LSM', 'Winmgmt', 'SamSs', 'KeyIso', 'CoreMessagingRegistrar', 'SystemEventsBroker',
    'gpsvc', 'BrokerInfrastructure', 'Schedule',
    # Servicing, licensing, and the package stack. Losing these strands the
    # machine unpatched, unactivated, or unable to install anything again.
    'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'BITS', 'CryptSvc', 'TrustedInstaller', 'msiserver',
    'sppsvc', 'ClipSVC', 'LicenseManager', 'AppXSvc', 'StateRepository',
    # Security.
    'WinDefend', 'SecurityHealthService', 'wscsvc', 'mpssvc', 'BFE', 'EventLog',
    # The network basics. Not Wi-Fi or file sharing - those are choices.
    'Dhcp', 'Dnscache', 'NlaSvc', 'nsi', 'netprofm',
    # Storage.
    'StorSvc'
)

function Get-WDCriticalServices { ,@($script:CriticalServices) }

function Test-WDCriticalService {
    <#
        Whether a service is one no run may touch.

        Exact name, case-insensitively, and deliberately NOT a wildcard match:
        these are real service names rather than patterns, and a pattern in a
        safety list is a list that quietly grows to cover things nobody put in
        it. A manifest pattern like 'Xbox*' is matched against the machine
        first, so what arrives here is always a resolved name.
    #>
    param([string]$Name)
    if (-not $Name) { return $false }
    foreach ($s in $script:CriticalServices) {
        if ($Name -ieq $s) { return $true }
    }
    $false
}

function Stop-WDProcessesUnder {
    <#
        Kill every process whose image lives under a directory.

        By path rather than by name, because a name list is always out of date -
        Edge alone runs msedge, identity_helper, msedge_proxy, cookie_exporter,
        elevation_service and a pack of renderers, and the set changes between
        versions. The path is the thing that is actually true.

        Win32_Process rather than Get-Process: reading .Path on a process this
        session cannot open throws, and one protected process in the list would
        otherwise take out the whole sweep.

        Returns the names it killed, so the caller can say what it did rather
        than claiming a clean deletion that was in fact a fight.
    #>
    # -Path is optional so this can be asked by name alone. A program whose
    # uninstaller is blocked by a launcher living somewhere else entirely - Riot
    # Client holding Valorant is the case that needs it - has a name to give and
    # no folder of its own to sweep. With neither a path nor a name nothing
    # matches, which is the safe answer rather than a special case.
    param(
        [string]$Path = '',
        [string[]]$AlsoNamed = @()
    )
    $killed = New-Object System.Collections.Generic.List[string]
    $prefix = ''
    if ($Path) { $prefix = $Path.TrimEnd('\') + '\' }

    $procs = @()
    try { $procs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) } catch { }
    foreach ($p in $procs) {
        $exe = [string]$p.ExecutablePath
        if (-not $exe) { continue }
        $mine = $false
        if ($prefix) { $mine = $exe.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }
        if (-not $mine -and @($AlsoNamed).Count) {
            $leaf = [IO.Path]::GetFileNameWithoutExtension($exe)
            $mine = @($AlsoNamed) -contains $leaf
        }
        if (-not $mine) { continue }
        # Never take out the shell or this process, whatever the path says.
        if ([int]$p.ProcessId -le 4 -or [int]$p.ProcessId -eq $PID) { continue }
        try {
            Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop
            $killed.Add([string]$p.Name)
        } catch { }
    }
    ,@($killed | Sort-Object -Unique)
}

function Stop-WDBlockers {
    <#
        Close whatever is holding a thing open, say what was closed, and wait
        for the handles to drop.

        Stop-WDProcessesUnder is the mechanism; this is the policy around it,
        and the policy is the half that has to be identical everywhere. The
        settle especially: file handles do not drop the instant a process dies,
        so a retry that starts immediately fails for the exact reason this
        exists to remove - and it then looks like a case where closing the
        program did not help, which is the wrong lesson to leave in a log.

        Nothing here is journalled. Nothing can put a running process back, and
        an undo entry claiming otherwise is a lie the rollback script would then
        repeat - the same rule the Edge folder sweep follows. It is logged
        instead, because "the toolkit closed my game" has to be answerable.

        -Because completes the sentence "Closed X, Y so ...", so it reads as a
        reason rather than as a bare list of casualties.

        Returns the names it closed, so a caller can report a fight rather than
        claim a clean removal - and can tell "nothing was in the way" from
        "something was, and now is not", which is what decides whether a retry
        is worth the attempt.
    #>
    param(
        [string]$Path = '',
        [string[]]$AlsoNamed = @(),
        [string]$Because = 'it could be removed'
    )
    if (-not $Path -and -not @($AlsoNamed).Count) { return ,@() }
    # ASSIGNED, NEVER WRAPPED IN @(). Stop-WDProcessesUnder ends in ,@(...) so
    # that assigning it does not unroll, which means @() around its pipeline
    # output gives ONE element holding the array - Count 1 whether it closed
    # nothing or ten things, and "$shut -join ', '" renders as
    # 'System.Object[]'. Wrapped, this logged "Closed System.Object[] so X" on
    # every call and spent the 700ms settle with nothing to settle.
    $shut = Stop-WDProcessesUnder -Path $Path -AlsoNamed $AlsoNamed
    if ($shut.Count) {
        Write-WDLog "Closed $($shut -join ', ') so $Because." -Level Info
        Start-Sleep -Milliseconds 700
    }
    ,@($shut)
}

function Remove-WDStubbornDirectory {
    <#
        Delete a directory that fights back.

        Written for the Edge folders, which are held open by processes that
        restart themselves, carry read-only and system attributes, and are owned
        by TrustedInstaller rather than Administrators. A single Remove-Item
        against them fails, and worse, fails having deleted nothing.

        The method is the one that works by hand: kill what is holding it, take
        the ACL, then delete file by file rather than as one recursive
        operation - so that every pass makes progress even when it cannot
        finish, and a folder that needs four rounds gets four rounds instead of
        four identical failures. Attempts back off, because the thing being
        waited for is usually a service restarting.

        What is left when the loop gives up is handed to MoveFileEx with
        MOVEFILE_DELAY_UNTIL_REBOOT, which is how Windows deletes its own files
        that are in use. That is a real deletion, just a deferred one, so the
        caller is told to ask for a restart.

        This is NOT reversible and does not journal an undo. Nothing here can
        put a program's files back; saying otherwise in the journal would be a
        lie the rollback script then tells the user. Callers must only point it
        at things whose removal is the point.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ProcessNames = @(),
        [int]$Attempts = 5,
        [switch]$NoPendingDelete
    )

    $out = [pscustomobject]@{
        Gone       = $true
        Pending    = $false
        Rounds     = 0
        Killed     = @()
        Left       = @()
        FreedBytes = [int64]0
        Note       = ''
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $out }

    $out.Gone = $false
    try {
        $out.FreedBytes = [int64](Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                                  Measure-Object -Property Length -Sum).Sum
    } catch { }

    $killed = New-Object System.Collections.Generic.List[string]
    $tookOwnership = $false

    for ($i = 1; $i -le $Attempts; $i++) {
        $out.Rounds = $i
        foreach ($k in (Stop-WDProcessesUnder -Path $Path -AlsoNamed $ProcessNames)) { $killed.Add($k) }

        # Give a killed process time to actually exit and drop its handles.
        # Ramps, because the usual reason a second attempt fails is a service
        # control manager restart that has not finished yet.
        if ($i -gt 1) { Start-Sleep -Milliseconds ([Math]::Min(4000, 250 * [Math]::Pow(2, $i - 1))) }

        # From the second round on, stop being polite about it.
        if ($i -ge 2 -and -not $tookOwnership) {
            $tookOwnership = $true
            try {
                Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
            } catch { }
            $null = & takeown.exe /F $Path /R /A /D Y 2>&1
            $null = & icacls.exe $Path /grant '*S-1-5-32-544:F' /T /C /Q 2>&1
        }

        # Files first, deepest last, one at a time. The piecemeal pass is the
        # whole point: a recursive delete stops at the first locked file and
        # leaves everything after it, where this leaves only what is genuinely
        # held.
        try {
            Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { } }
            Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch { } }
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        } catch { }

        if (-not (Test-Path -LiteralPath $Path)) { $out.Gone = $true; break }
    }

    $out.Killed = @($killed | Sort-Object -Unique)

    if ($out.Gone) {
        $out.Note = "deleted in $($out.Rounds) pass$(if ($out.Rounds -ne 1) { 'es' })"
        return $out
    }

    $left = @()
    try {
        $left = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.FullName })
    } catch { }
    $out.Left = @($left | Select-Object -First 20)

    if ($NoPendingDelete -or -not (Initialize-WDPendingDeleteType)) {
        $out.Note = 'still in use and could not be deleted'
        return $out
    }

    # MOVEFILE_DELAY_UNTIL_REBOOT. Files before the directories that hold them,
    # deepest first, or the queued directory delete finds itself non-empty and
    # is skipped at boot.
    # Sorted on actual path depth. This was `Sort-Object { $_.Length }`, which
    # is a STRING length - correct only because $left holds FullName strings and
    # a longer path is usually a deeper one. It reads as sorting by file size,
    # and the day anyone keeps the FileInfo objects instead it silently becomes
    # exactly that, which is not an ordering at all.
    $queued = 0
    foreach ($f in ($left | Sort-Object { ([string]$_ -split '\\').Count } -Descending)) {
        try { if ([WD.Pending]::MoveFileEx($f, $null, 0x4)) { $queued++ } } catch { }
    }
    try { if ([WD.Pending]::MoveFileEx($Path, $null, 0x4)) { $queued++ } } catch { }

    if ($queued) {
        $out.Pending = $true
        $out.Note    = "$queued item$(if ($queued -ne 1) { 's' }) queued for deletion at the next restart"
        Set-WDRebootNeeded
    } else {
        $out.Note = 'still in use and could not be deleted or queued'
    }
    $out
}

# Export-WDUndoScript used to live here and is now in WD.Revert.psm1, beside
# Get-WDUndoStatus and the rest of the undo machinery. This file is the
# session, the log and the journal - the thing the rollback reads, not the
# thing that reads it.

function Export-WDRunNotes {
    <#
        The document the rollback script cannot be.

        Undo-WinSetupToolkit.ps1 reverses the whole run, exactly, and is the right
        answer to "put it back". It is the wrong answer to the two questions
        people actually arrive with:

        - "I want this one thing back, not the other ninety." The script is all
          or nothing, so the way back for one setting is knowing where it is.
        - "Something has been broken for a fortnight and I do not know why."
          At that point nobody is looking for a debloat tool at all - they are
          typing what is wrong into a search box. So the symptoms go FIRST, in
          the words somebody would use at the moment things break, and the
          document is written to be searched rather than read.

        Written for every apply, not as an option and not only at the top two
        modes. It costs a few milliseconds, and a document that turns out to be
        missing on the machine that needed it is worth nothing at all.

        Preview runs write nothing: there is no run to describe.
    #>
    param(
        [Parameter(Mandatory)]$Items,
        [string]$PresetName = '',
        [string]$Path = '',
        # All three default to the live session and exist because -Path already
        # promised this works without one. It did not: the run id and the
        # rollback path were read off $script:Session regardless, so a caller
        # that passed -Path got a document headed "run unnumbered" over "(no
        # rollback script was written)" while the script sat beside it. That is
        # a header stating two things that are false about a real run, in the
        # one file written to be believed.
        [string]$RunId = '',
        [string]$UndoFile = '',
        [datetime]$Started = [datetime]::MinValue
    )
    if (-not $Path) {
        if (-not $script:Session) { return }
        $Path = $script:Session.NotesFile
    }
    if (-not $RunId    -and $script:Session) { $RunId    = [string]$script:Session.Id }
    if (-not $UndoFile -and $script:Session) { $UndoFile = [string]$script:Session.UndoFile }
    if ($Started -eq [datetime]::MinValue -and $script:Session -and $script:Session.Started) {
        $Started = [datetime]$script:Session.Started
    }
    if ($Started -eq [datetime]::MinValue) { $Started = Get-Date }

    $runId = $(if ($RunId) { $RunId } else { 'unnumbered' })
    # Asked of the file, not of the selection. "Generate rollback script" is a
    # row that can be unticked and a step that can fail, so a path is not a
    # promise that anything is at the end of it - the same distinction
    # $Sync.HasUndo draws for the closing card.
    $undoRef = '(no rollback script was written)'
    if ($UndoFile -and (Test-Path -LiteralPath $UndoFile)) { $undoRef = $UndoFile }

    $mech = @()
    foreach ($i in @($Items)) {
        if (-not $i) { continue }
        $mech += Get-WDItemMechanics -Item $i
    }

    $sb = New-Object System.Text.StringBuilder
    $w  = { param([string]$Line = '') $null = $sb.AppendLine($Line) }

    # The kinds of change, and the word each mechanics line starts with. Used
    # twice: to count them for the summary, and to split a line into a label
    # and the machine detail that follows it.
    # Longest prefix first: "Store packages:" does not start with
    # "Store package:", but a shorter key that DID match first would win, and
    # this table is walked in order.
    $kinds = [ordered]@{
        'Registry:'           = 'registry values'
        'Store packages:'     = 'Store packages removed'
        'Store package:'      = 'Store packages removed'
        'Policy:'             = 'packages deprovisioned by policy'
        'Service:'            = 'services'
        'Scheduled task:'     = 'scheduled tasks'
        'Windows feature:'    = 'Windows features'
        'Windows capability:' = 'Windows capabilities'
        'File:'               = 'files and folders'
        'Shortcut:'           = 'shortcuts'
        'winget:'             = 'winget packages'
    }
    $tally = [ordered]@{}
    foreach ($m in $mech) {
        foreach ($l in @($m.Lines)) {
            foreach ($k in $kinds.Keys) {
                if (-not ([string]$l).StartsWith($k)) { continue }
                if (-not $tally.Contains($kinds[$k])) { $tally[$kinds[$k]] = 0 }
                $tally[$kinds[$k]]++
                break
            }
        }
    }

    # One mechanics line as markdown. The detail after the label goes in a code
    # span, which is not decoration: these are registry paths, and markdown
    # treats a backslash as an escape character. `C:\*` and `\_` both come out
    # wrong as plain text, and a document about paths that mangles paths is
    # worse than a plain one.
    $bullet = {
        param([string]$Line)
        foreach ($k in $kinds.Keys) {
            if (-not ([string]$Line).StartsWith($k)) { continue }
            $rest = ([string]$Line).Substring($k.Length).Trim()
            return "- **$($k.TrimEnd(':'))** - ``$rest``"
        }
        # A handler's own sentence. Prose, so it stays prose.
        "- $Line"
    }

    & $w '# What this run did'
    & $w
    & $w "Windows Setup Toolkit, run ``$runId``$(if ($PresetName) { ", **$PresetName** selection" } else { '' })."
    # When the RUN happened, not when this file was written. They are the same
    # thing on a real run and they are not when the document is regenerated,
    # and the date somebody wants is the one their machine changed.
    & $w "Applied $($Started.ToString('d MMMM yyyy')) at $($Started.ToString('HH:mm'))."
    & $w
    & $w "**$(@($mech).Count) options were selected.** Every one of them is below, with what it"
    & $w 'changed and how to put that one thing back.'
    & $w

    if ($tally.Count) {
        & $w '| What was touched | How many |'
        & $w '| --- | ---: |'
        foreach ($k in $tally.Keys) { & $w "| $k | $($tally[$k]) |" }
        & $w
    }

    & $w '## If you need to undo something'
    & $w
    & $w '**One option, from the toolkit.** Open Windows Setup Toolkit and press'
    & $w '**Revert past changes**. It lists everything this run did, with a tick beside'
    & $w 'each one - untick the rest and press Revert, and only that option goes back.'
    & $w 'This is the easiest way to undo a single change and it needs no editing of'
    & $w 'anything.'
    & $w
    & $w '**One option, by hand.** Open *Common issues lookup and reversion instructions.txt*,'
    & $w 'in this same folder, and press ctrl+F for whatever is wrong. It names the option'
    & $w 'responsible and gives every way to reverse that one option, step by step,'
    & $w 'including the value each setting held before the run.'
    & $w
    & $w '**Everything at once.** The same Revert past changes screen has a Select all, or'
    & $w 'right-click the file below and choose Run with PowerShell, saying Yes to the'
    & $w 'prompt.'
    & $w
    & $w "``$undoRef``"
    & $w
    & $w '**By hand.** Every registry path below can be put back yourself: press Win+R,'
    & $w 'type `regedit`, press Enter, and paste the path into the address bar at the top.'
    & $w 'The same goes for `services.msc` and `taskschd.msc` where an option names one.'
    & $w
    & $w '> The values shown below are what this run **wrote**, not what was there before.'
    & $w '> The rollback script holds the previous value for every one of them, and the'
    & $w '> lookup document spells each one out as numbered steps.'
    & $w

    # Grouped by category, because a hundred and fifty headings in a row is a
    # list rather than a document, and the categories are the same ones the
    # option list on screen is arranged by - so somebody who picked these knows
    # where to look.
    $order = New-Object System.Collections.Generic.List[string]
    $byCat = @{}
    foreach ($m in $mech) {
        $c = [string]$m.Category
        if (-not $c) { $c = 'Other' }
        if (-not $byCat.ContainsKey($c)) {
            $byCat[$c] = New-Object System.Collections.Generic.List[psobject]
            $order.Add($c)
        }
        $byCat[$c].Add($m)
    }

    & $w '## What changed, option by option'
    # A rule before every OPTION, not between categories. Two levels of heading
    # already separate the categories, and a rule is the only separator markdown
    # has that survives being read as plain text - which this file has to,
    # because half the people who open it will do so in Notepad.
    #
    # Indentation was tried first and buys nothing: a list indented by two
    # spaces is still a top-level list to every renderer, so it reads as
    # structure in the raw file and as nothing at all once formatted.
    foreach ($cat in $order) {
        & $w
        & $w "### $cat"
        & $w
        & $w "*$(@($byCat[$cat]).Count) option$(if (@($byCat[$cat]).Count -ne 1) { 's' }) in this category.*"
        foreach ($m in $byCat[$cat]) {
            & $w
            & $w '---'
            & $w
            & $w "#### $($m.Name)"
            & $w
            & $w "``id: $($m.Id)`` - reversing the run puts this back **$($m.Revert)**"
            if ($m.RiskNote) {
                & $w
                & $w "> **Why it matters.** $($m.RiskNote)"
            }
            & $w
            if (@($m.Lines).Count) {
                foreach ($l in @($m.Lines)) { & $w (& $bullet $l) }
            } else {
                & $w '- (nothing recorded)'
            }
            # The one-line pointer, and the reason the old file needed fixing:
            # for an item that writes three policy values and has no Settings
            # page, "By hand:" was blank and the only advice on offer was to
            # undo the whole run. Anybody can open regedit, and the paths are
            # right there in the list above.
            #
            # The regedit sentence is NOT repeated per item - it is stated once
            # at the top, because it is true of every registry line in the file
            # and a hundred and fifty copies of one fact is how a document
            # stops being read. What is named per item is the thing that is
            # specific to it: the Settings page somebody wrote down, or a
            # console other than regedit. Only an item with neither falls back
            # to naming regedit, which is exactly the case that used to say
            # nothing at all.
            $undoBits = New-Object System.Collections.Generic.List[string]
            $said = ([string]$m.Settings).ToLower()
            if ($m.Settings) { $undoBits.Add([string]$m.Settings) }
            $elsewhere = New-Object System.Collections.Generic.List[string]
            foreach ($c in @($m.Consoles)) {
                if ([string]$c.Label -match 'regedit') { continue }
                # Already named in the authored line above it. "Task Scheduler,
                # or undo the run. By hand in Task Scheduler (taskschd.msc)."
                $known = $false
                foreach ($k in @($c.Keys)) { if ($said -like "*$k*") { $known = $true; break } }
                if (-not $known) { $elsewhere.Add([string]$c.Label) }
            }
            if ($elsewhere.Count) { $undoBits.Add("By hand in $($elsewhere -join ', or ').") }
            if (-not $undoBits.Count) {
                if (@($m.Consoles).Count) {
                    $undoBits.Add('Windows has no page for this one. Put the values above back in regedit - the lookup document beside this file quotes what each one held before the run.')
                } else {
                    $undoBits.Add('Use Revert past changes in the toolkit, or the rollback script.')
                }
            }
            & $w
            & $w "**Undo just this:** $($undoBits -join ' ')"
        }
    }

    try {
        Set-Content -LiteralPath $Path -Value $sb.ToString() -Encoding UTF8
    } catch {
        Write-WDLog "Could not write the run notes: $($_.Exception.Message)" -Level Warn
        return
    }
    Write-WDLog "What this run did written to $Path" -Level Success
    $Path
}

function Get-WDWrapUpLines {
    <#
        Everything somebody has to be told once an apply is over.

        Written once and read twice, which is the whole reason it is a function
        rather than prose in the interface. The GUI shows these in the card at
        the end of the run page; a run started from SetupComplete.cmd has no
        GUI at all and puts the same words in a text file. Two copies of this
        drift, and the half that drifts is the one nobody is looking at.

        Takes plain values rather than a session, because the second caller is
        assembling them from a report on disk rather than from a live run.
    #>
    param(
        [string]$KeepDir = '',
        [string]$RunDir = '',
        [bool]$HasUndo = $false,
        [string]$RestorePoint = '',
        [int]$RestartCount = 0,
        [bool]$Reboot = $false
    )

    $out = New-Object System.Collections.Generic.List[string]
    # How many, not whether. "A restart is required" over a list of ninety
    # changes does not say whether that is one of them or all of them, and one
    # is the usual answer.
    if ($RestartCount -gt 0) {
        $out.Add("$RestartCount change$(if ($RestartCount -ne 1) { 's' }) need$(if ($RestartCount -eq 1) { 's' } else { '' }) a restart to take effect. Everything else is already in force.")
    } elseif ($Reboot) {
        $out.Add('A restart is needed to finish.')
    }
    # Generate rollback script is a row that can be unticked, so every line
    # below has to describe the run that happened rather than the run this
    # toolkit would rather have had.
    $holds = $(if ($HasUndo) { 'the rollback script, a list of every change this run made, and a file to search when something breaks' }
               else { 'a list of every change this run made, and a file to search when something breaks' })
    if ($KeepDir) {
        $out.Add("A folder named '$(Split-Path -Leaf $KeepDir)' is now on your desktop. It holds $holds. 'Read me first.txt' inside says what each one is for.")
    } else {
        $out.Add("The log and a list of every change are in $RunDir.")
    }
    $out.Add('If something stops working days or weeks from now, open "Common issues lookup and reversion instructions" from that folder and press ctrl+F for whatever is wrong - "no sound", "camera not working", "updates broken". It names the option responsible and how to undo that one option.')
    if ($HasUndo) {
        $out.Add('To undo the whole run instead: run Undo-WinSetupToolkit.ps1 as an administrator, or open this toolkit and use Revert past changes.')
    } else {
        $out.Add('There is no rollback script for this run - "Generate rollback script" was not selected. To undo the whole run, open this toolkit and use Revert past changes, which reads the same journal the script would have been written from.')
    }
    # Windows has its own way back, and it is worth naming - both when it
    # worked, because nobody thinks to look, and when it did not, because the
    # confirmation before the run said there would be one.
    switch ([string]$RestorePoint) {
        'ok' {
            $out.Add('Windows also took a system restore point immediately before the run. Search Windows for "Create a restore point" and press System Restore to roll the whole machine back to it - that undoes anything else you did since, so the rollback script above is the narrower and usually better answer.')
        }
        'failed' {
            $out.Add('Windows would NOT create a system restore point for this run - System Protection is off or unavailable on this machine. That means System Restore is not a way back from it, and the rollback script above is. Keep it.')
        }
    }
    ,$out
}

function Get-WDDesktopRunFolder {
    <#
        Where Export-WDRunFolder is going to put the copy, worked out without
        creating anything.

        This exists so a preview can name the real destination. The two document
        items - the rollback script and the common issues lookup - are written
        into the run directory under %ProgramData% and copied here afterwards,
        so their preview rows quoted the ProgramData path: technically true,
        useless as an answer to "where will I find this", and directly at odds
        with what both descriptions promise ("the run folder left on your
        desktop").

        Returns Ok, Path and Why. Ok is false when there is no desktop to write
        to, which is a real case on a service account or a stripped image - and
        a preview that says "your desktop" on a machine that has none is the
        same defect one step further on.

        -Public forces C:\Users\Public\Desktop, and the run that needs it is the
        one launched from SetupComplete.cmd: that runs as Local System before
        any account has signed in, so there is no per-user desktop to write to
        and no way to know which account will eventually want this. The public
        desktop is on every account's, which is the closest thing to "their
        desktop" that exists at that moment.

        It is also a trap this has to defend against rather than an option to
        offer. Asked as SYSTEM, GetFolderPath('Desktop') answers
        C:\Windows\system32\config\systemprofile\Desktop - a folder that
        genuinely exists, so every check here would pass and the whole run
        folder would be written somewhere no human being will ever look. So the
        system profile is detected and redirected whether or not -Public was
        asked for.
    #>
    param($Session, [string]$Desktop = '', [switch]$Public)

    if (-not $Session) { $Session = $script:Session }
    $publicDesktop = ''
    try { $publicDesktop = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) '' } catch { }
    if (-not $publicDesktop) { $publicDesktop = Join-Path ([string]$env:PUBLIC) 'Desktop' }
    $publicDesktop = $publicDesktop.TrimEnd('\')

    if (-not $Desktop) {
        $Desktop = [Environment]::GetFolderPath('Desktop')
        # SYSTEM, or any service account whose profile lives under system32.
        if ($Public -or ($Desktop -and $Desktop -like "$([Environment]::GetFolderPath('System'))*")) {
            $Desktop = $publicDesktop
        }
    }

    $stamp = $null
    if ($Session) { $stamp = $Session.Started }
    if (-not $stamp) { $stamp = Get-Date }
    # Colons are illegal in a path, so the time is dashed.
    $name = 'Windows Setup Toolkit apply ' + $stamp.ToString('yyyy-MM-dd HH-mm')

    if (-not $Desktop -or -not (Test-Path -LiteralPath $Desktop)) {
        $fallback = ''
        if ($Session) { $fallback = [string](Get-Prop $Session 'RunDir' '') }
        return [pscustomobject]@{
            Ok   = $false
            Path = $fallback
            Why  = 'No desktop folder was found on this machine, so the copy cannot be made there. The file is still written to the run folder.'
        }
    }
    [pscustomobject]@{ Ok = $true; Path = (Join-Path $Desktop $name); Why = '' }
}

function Read-WDSetupResult {
    <#
        The finished setup run, read back off disk, or $null.

        Here rather than beside the window that shows it, because it is the half
        that is not interface: it reads two files and answers questions about
        them, and the self test can drive that without a desktop or a message
        pump. Every failure answers $null rather than throwing - the caller is
        started by RunOnce at somebody's first sign-in, has nowhere to report a
        problem, and no business trying.
    #>
    param([string]$RunDir)

    if (-not $RunDir) { return $null }
    try { if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) { return $null } } catch { return $null }

    $report = $null
    try {
        $rp = Join-Path $RunDir 'report.json'
        if (Test-Path -LiteralPath $rp) { $report = Get-Content -LiteralPath $rp -Raw | ConvertFrom-Json }
    } catch { $report = $null }
    if (-not $report) { return $null }
    # A preview leaves a report too, and offering to show somebody the results
    # of a run that changed nothing is worse than showing them nothing.
    if ([bool](Get-Prop $report 'preview' $false)) { return $null }

    $extra = $null
    try {
        $sp = Join-Path $RunDir 'setup-result.json'
        if (Test-Path -LiteralPath $sp) { $extra = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json }
    } catch { $extra = $null }

    $counts = Get-Prop $report 'counts' $null
    # The desktop folder may have been moved or deleted between the run and the
    # sign-in - people tidy. Checked rather than assumed, so the button that
    # opens it is only offered when there is something to open.
    $keep = [string](Get-Prop $extra 'keepDir' '')
    if ($keep) { try { if (-not (Test-Path -LiteralPath $keep)) { $keep = '' } } catch { $keep = '' } }
    $summary = [string](Get-Prop $extra 'summaryFile' '')
    if ($summary) { try { if (-not (Test-Path -LiteralPath $summary)) { $summary = '' } } catch { $summary = '' } }

    [pscustomobject]@{
        RunDir       = [string]$RunDir
        Report       = $report
        Counts       = $counts
        KeepDir      = $keep
        SummaryFile  = $summary
        Label        = [string](Get-Prop $extra 'label' '')
        HasUndo      = [bool](Get-Prop $extra 'hasUndo' $false)
        RestorePoint = [string](Get-Prop $extra 'restorePoint' '')
        RestartCount = [int](Get-Prop $extra 'restartCount' 0)
        Reboot       = [bool](Get-Prop $report 'reboot' $false)
        Changed      = ([int](Get-Prop $counts 'removed' 0) + [int](Get-Prop $counts 'changed' 0) +
                        [int](Get-Prop $counts 'partial' 0))
        Failed       = [int](Get-Prop $counts 'failed' 0)
    }
}

function Register-WDSetupPrompt {
    <#
        Asks Windows to show the finished run to the first person who signs in.

        HKLM RunOnce, and every part of that is deliberate:

        - **RunOnce, not Run.** Windows deletes the value before it executes it,
          so a command that crashes cannot come back tomorrow, and a machine
          whose owner ignores it once is never asked again. That is the right
          behavior for a courtesy: there is no state to protect and the report
          is on the desktop either way.
        - **HKLM, not HKCU.** The run happens as Local System before any profile
          exists, so there is no HKCU to write into that belongs to anybody.
        - **Unelevated.** The entry runs in the signing-in user's own context at
          their normal token. -SetupResult is exempt from this script's own
          elevation gate for that reason - see the note there.

        Refused, rather than half-done, in the states where it cannot be honest:
        no run folder, no script to point at, or a script somewhere the machine
        will not still have after Setup. Returns $true only if the value is
        actually there afterwards - the write is verified by reading it back,
        because a policy or a locked-down image can refuse it silently.
    #>
    param([string]$RunDir, [string]$ScriptPath)

    if (-not $RunDir -or -not (Test-Path -LiteralPath $RunDir)) {
        Write-WDLog 'No run folder to point the first sign-in at, so no prompt was registered.' -Level Warn
        return $false
    }
    if (-not $ScriptPath -or -not (Test-Path -LiteralPath $ScriptPath)) {
        Write-WDLog 'The toolkit could not find its own script, so no prompt was registered.' -Level Warn
        return $false
    }
    # The medium is gone by the time anybody signs in. Pointing the entry at a
    # script on a drive that will not be there is worse than not registering
    # one: it is an error at first sign-in, from a program with no name on it.
    $sys = ''
    try { $sys = [IO.Path]::GetPathRoot([Environment]::GetFolderPath('System')) } catch { }
    if ($sys -and [IO.Path]::GetPathRoot($ScriptPath) -ne $sys) {
        Write-WDLog "The toolkit is running from $([IO.Path]::GetPathRoot($ScriptPath)), which may not be attached at the first sign-in, so no prompt was registered." -Level Warn
        return $false
    }

    $key  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $name = 'WinSetupToolkitSetupResult'
    # -STA because the prompt is WPF. powershell.exe already defaults to it,
    # and a default is not a thing to rely on in a command line written into
    # the registry and read back a reboot later.
    $cmd  = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden ' +
            "-File `"$ScriptPath`" -SetupResult `"$RunDir`""
    try {
        if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force -ErrorAction Stop }
        Set-ItemProperty -LiteralPath $key -Name $name -Value $cmd -Type String -Force -ErrorAction Stop
        $back = [string](Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop).$name
        if ($back -ne $cmd) { throw 'the value did not read back' }
    } catch {
        Write-WDLog "Could not ask Windows to show this run at the first sign-in: $($_.Exception.Message). The report on the desktop is unaffected." -Level Warn
        return $false
    }
    Write-WDLog 'The first person to sign in will be offered this run to read.' -Level Success
    $true
}

function Export-WDSetupResult {
    <#
        The two things a run with no interface has to leave behind.

        A run started from SetupComplete.cmd happens in session 0, before
        anybody signs in, with no desktop to draw on. Everything the finished
        Run page would have said - the counts, every item and what happened to
        it, what needs a restart, where the way back is - has nowhere to go. So
        it goes in a text file, in the same folder as the rollback script, in
        the same words $wrapUpText uses on screen.

        And a small JSON beside it, which is the same facts in the form the
        interface can read back: -ShowRun replays it into the real Run page, so
        the person who signs in can be shown the finished run rather than a
        transcript of it. The text file is the fallback and is written first -
        if anything about the second half fails, what is left is still a
        complete account of the run in a file anybody can open.

        Returns the text file's path, or '' if even that could not be written.
    #>
    param(
        $Session,
        $Report,
        [string]$Label = '',
        [string]$KeepDir = '',
        [int]$RestartCount = 0,
        [string]$RestorePoint = ''
    )

    if (-not $Session) { $Session = $script:Session }
    if (-not $Session -or -not $Report) { return '' }

    $hasUndo = $false
    try { $hasUndo = [bool](Test-Path -LiteralPath $Session.UndoFile) } catch { }
    $reboot = [bool](Get-Prop $Report 'reboot' $false)
    $counts = Get-Prop $Report 'counts' $null
    $items  = @(Get-Prop $Report 'items' @())

    $sb = New-Object System.Text.StringBuilder
    $w  = { param([string]$Line = '') $null = $sb.AppendLine($Line) }

    & $w 'WHAT THE TOOLKIT DID DURING SETUP'
    & $w '================================'
    & $w ''
    & $w 'This ran automatically while Windows was finishing its installation, before'
    & $w 'anybody signed in. There was no window to show it in and nothing to press, so'
    & $w 'this file is the whole of what the toolkit would have told you on screen.'
    & $w ''
    $started = Get-Prop $Report 'started' ''
    if ($started) {
        try { & $w "Run at $([DateTime]::Parse($started).ToString('dddd d MMMM yyyy \a\t HH:mm'))." } catch { }
    }
    if ($Label) { & $w "Selection: $Label" }
    $machine = Get-Prop $Report 'machine' $null
    if ($machine) { & $w "Machine: $(Get-Prop $machine 'model' '') - $(Get-Prop $machine 'os' '')" }
    & $w ''

    & $w 'THE HEADLINE'
    & $w '------------'
    & $w ''
    if ($counts) {
        foreach ($pair in @(
            @{ K = 'removed';    T = 'removed' }
            @{ K = 'changed';    T = 'changed' }
            @{ K = 'notPresent'; T = 'were not on this machine, so there was nothing to do' }
            @{ K = 'partial';    T = 'partly worked - see the list below' }
            @{ K = 'blocked';    T = 'were refused by Windows' }
            @{ K = 'skipped';    T = 'were skipped, because a guard ruled them out' }
            @{ K = 'failed';     T = 'failed' })) {
            $n = [int](Get-Prop $counts $pair.K 0)
            if ($n) { & $w ("  {0,-5} {1}" -f $n, $pair.T) }
        }
        & $w ''
        & $w "  $([int](Get-Prop $counts 'total' 0)) item(s) in total."
    }
    & $w ''

    & $w 'WHAT TO DO NOW'
    & $w '--------------'
    & $w ''
    # Assigned first, because Get-WDWrapUpLines ends in ,@(...): @() around its
    # pipeline output is one element holding all five paragraphs, and $w takes
    # [string], so they arrived space-joined as a single 900-character block -
    # in the one document a machine set up unattended ever shows its owner,
    # including the paragraph saying how to undo the run.
    $wrapUp = Get-WDWrapUpLines -KeepDir $KeepDir -RunDir ([string]$Session.RunDir) `
                                -HasUndo $hasUndo -RestorePoint $RestorePoint `
                                -RestartCount $RestartCount -Reboot $reboot
    foreach ($line in $wrapUp) {
        & $w $line
        & $w ''
    }

    & $w 'EVERY ITEM, AND WHAT HAPPENED TO IT'
    & $w '-----------------------------------'
    & $w ''
    & $w 'This is the list the interface shows on the run page. Nothing is left out:'
    & $w 'items that had nothing to do are here as well, because "it was already gone"'
    & $w 'and "it was not attempted" are different answers.'
    & $w ''
    foreach ($it in $items) {
        $nm = [string](Get-Prop $it 'Name' (Get-Prop $it 'Id' '?'))
        & $w ("[{0}] {1}" -f [string](Get-Prop $it 'Status' '?'), $nm)
        $msg = [string](Get-Prop $it 'Message' '')
        if ($msg) { & $w "    $msg" }
        $det = [string](Get-Prop $it 'Detail' '')
        if ($det) { & $w "    $det" }
    }

    $path = Join-Path ([string]$Session.RunDir) 'What Windows Setup Toolkit did during setup.txt'
    try {
        Set-Content -LiteralPath $path -Value $sb.ToString() -Encoding UTF8
    } catch {
        Write-WDLog "Could not write the setup summary: $($_.Exception.Message)" -Level Warn
        return ''
    }

    # The machine-readable half, and everything here is something the report
    # itself cannot answer: where the desktop copy went, whether the rollback
    # script exists, how many changes want a restart, and whether Windows took
    # a restore point. Best effort - the text file above is what the promise
    # rests on, and a failure here must not cost it.
    try {
        ([pscustomobject]@{
            runDir       = [string]$Session.RunDir
            keepDir      = [string]$KeepDir
            summaryFile  = [string]$path
            label        = [string]$Label
            hasUndo      = [bool]$hasUndo
            restorePoint = [string]$RestorePoint
            restartCount = [int]$RestartCount
            reboot       = [bool]$reboot
        } | ConvertTo-Json -Depth 4) |
            Set-Content -LiteralPath (Join-Path ([string]$Session.RunDir) 'setup-result.json') -Encoding UTF8
    } catch {
        Write-WDLog "Could not write setup-result.json: $($_.Exception.Message)" -Level Warn
    }

    Write-WDLog "What the run did, in full, written to $path" -Level Success
    $path
}

function Export-WDRunFolder {
    <#
        Copies everything worth keeping out of the run directory and onto the
        desktop, in a folder named for the run.

        The run directory is under %ProgramData% on the machine that was
        debloated, which is the right place for it and the wrong place for
        somebody to find it. This exists because of how the toolkit is actually
        used: from a USB stick, on somebody else's machine, once. The stick goes
        home in a pocket and the person left behind has a rollback script they
        do not know exists, in a folder they would have to be told about, under
        a directory Explorer hides by default.

        So: on the desktop, named in plain words, with a note at the top saying
        what each file is for. Unconditional - there is no option for it,
        because the case for one is "I do not want a way back" and nobody means
        that until it is too late to say so.

        Preview runs are excluded. There is nothing to keep and a folder called
        "Windows Setup Toolkit run" containing a rollback script for a run
        that never happened is worse than no folder.
    #>
    param($Session, [string]$Desktop = '', [switch]$Public)

    if (-not $Session) { $Session = $script:Session }
    if (-not $Session) { return }
    if ([bool]$Session.Preview) { return }

    # A machine with no desktop folder - a service account, a stripped image -
    # is not a reason to fail a run that has already finished. The run directory
    # still holds everything; this is a second copy.
    #
    # The name and the check both come from Get-WDDesktopRunFolder, so what a
    # preview promises and what an apply produces cannot drift apart.
    $where = Get-WDDesktopRunFolder -Session $Session -Desktop $Desktop -Public:$Public
    if (-not $where.Ok) {
        Write-WDLog 'No desktop folder was found, so no copy was made there.' -Level Warn
        return
    }
    $stamp = $Session.Started
    if (-not $stamp) { $stamp = Get-Date }
    $dir = [string]$where.Path
    try {
        $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
    } catch {
        Write-WDLog "Could not create $dir : $($_.Exception.Message)" -Level Warn
        return
    }

    # Source, destination name, and the line the read-me says about it. A file
    # that was not written - the issues document when its option is unticked -
    # is skipped silently rather than reported: not selecting an option is not
    # an error.
    $wanted = @(
        # The launcher first, because it is the one to double-click. Windows
        # associates .ps1 with a text editor, so the script on its own opened in
        # Notepad for anybody who did what the note told them to.
        @{ From = (Join-Path (Split-Path ([string]$Session.UndoFile) -Parent) 'Undo-WinSetupToolkit.cmd')
           To   = 'Undo-WinSetupToolkit.cmd'
           What = 'Double-click this to undo the run. It asks for administrator rights and opens a window listing every option below, saying which of them are still in place, so you can put back all of it or one thing.' }
        @{ From = [string]$Session.UndoFile
           To   = 'Undo-WinSetupToolkit.ps1'
           What = 'The script the launcher above runs. Keep the two together. From a terminal it also takes -Console to put everything back without a window, and -ListOnly to report what is still in place and change nothing.' }
        @{ From = [string]$Session.NotesFile
           To   = 'What this run did.md'
           What = 'Start here. Every change, grouped by category: what it altered, whether it can be undone, and where the setting lives if you would rather change one thing by hand. Written to be read straight through.' }
        @{ From = [string]$Session.IssuesFile
           To   = 'Common issues lookup and reversion instructions.txt'
           What = 'Search this one with ctrl+F when something stops working. It lists the phrases people use for each problem this run could cause, and how to undo the option behind it.' }
        # Only exists for a run that had no interface to report through, which
        # is the SetupComplete.cmd one. Skipped silently otherwise, like the
        # issues document when its option is unticked.
        @{ From = (Join-Path ([string]$Session.RunDir) 'What Windows Setup Toolkit did during setup.txt')
           To   = 'What Windows Setup Toolkit did during setup.txt'
           What = 'This run happened during Windows Setup, before anybody signed in, so there was no window to show it in. This is everything the toolkit would have said on screen: the totals, what to do next, and every item with what happened to it.' }
        @{ From = [string]$Session.LogFile
           To   = 'Run log.txt'
           What = 'The full technical log, for when one of the above is not enough.' }
        @{ From = [string]$Session.ReportFile
           To   = 'Run report.json'
           What = 'The same run as machine-readable data. Nothing needs it; it is here so nothing is only in a format this toolkit can read.' }
    )

    $copied = New-Object System.Collections.Generic.List[psobject]
    foreach ($f in $wanted) {
        if (-not $f.From -or -not (Test-Path -LiteralPath $f.From)) { continue }
        try {
            Copy-Item -LiteralPath $f.From -Destination (Join-Path $dir $f.To) -Force -ErrorAction Stop
            $copied.Add([pscustomobject]@{ Name = [string]$f.To; What = [string]$f.What })
        } catch {
            Write-WDLog "Could not copy $($f.From): $($_.Exception.Message)" -Level Warn
        }
    }

    $sb = New-Object System.Text.StringBuilder
    $w  = { param([string]$Line) $null = $sb.AppendLine($Line) }
    & $w 'READ ME FIRST'
    & $w '============='
    & $w ''
    & $w "This folder was put here by the Windows Setup Toolkit on $($stamp.ToString('dddd d MMMM yyyy')) at $($stamp.ToString('HH:mm'))."
    & $w ''
    & $w 'It is a copy. The originals are in:'
    & $w "  $($Session.RunDir)"
    & $w 'They are copied here because the toolkit is often run from a USB stick that'
    & $w 'then leaves with whoever brought it, and everything you need to undo the run'
    & $w 'or work out what it did should stay on the machine it was run on.'
    & $w ''
    & $w 'Deleting this folder does not undo anything and does not break anything. It'
    & $w 'only means you no longer have the easy way back.'
    & $w ''
    & $w 'WHAT EACH FILE IS FOR'
    & $w '---------------------'
    & $w ''
    foreach ($c in $copied) {
        & $w $c.Name
        & $w "  $($c.What)"
        & $w ''
    }
    & $w 'You can also open the toolkit again and use Revert past changes, which is the'
    & $w 'same rollback with a list you can pick from.'

    try {
        Set-Content -LiteralPath (Join-Path $dir 'Read me first.txt') -Value $sb.ToString() -Encoding UTF8
    } catch {
        Write-WDLog "Could not write the read-me: $($_.Exception.Message)" -Level Warn
    }

    Write-WDLog "Run folder copied to $dir" -Level Success
    [pscustomobject]@{ Path = $dir; Files = @($copied | ForEach-Object { $_.Name }) }
}

Export-ModuleMember -Function *-WD*, Get-WDSession, Test-WDAdmin, ConvertTo-WDRegParts
