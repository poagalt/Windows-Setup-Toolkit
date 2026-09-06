# StrictMode is off toolkit-wide: manifest and journal data is JSON full of
# optional properties, and a missing one must degrade rather than abort a run
# halfway through changing a machine.

$script:Session = $null

# The one way this toolkit reads a property that may not be there, and the
# reason StrictMode can be off: it collapses a null object, a missing property,
# and a present-but-null value into one default.
function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    $p.Value
}

# The status vocabulary every executor shares. Anything not in this list is a
# bug.
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

# Every Add-Type is a csc run: ~400 ms for the first in a process, 150-200 for
# each one after. One shared type for what the launch path needs, compiled
# off-thread.
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
    # BeginInvoke costs the caller 33-49 ms and the compile it starts takes
    # about 400, which the nine module imports behind it more than cover.
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
    # Waits for the warm-up if one is in flight, compiles here if it never
    # started, and answers whether [WD.Native] can be used.
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
    # New-Object cannot pick between HashSet's IEnumerable and IEqualityComparer
    # constructors without a non-empty value to look at, and throws on an
    # ambiguous overload.
    param([string[]]$From)
    $set = New-Object System.Collections.Generic.HashSet[string]
    foreach ($s in $From) { $null = $set.Add($s) }
    ,$set
}

function New-WDResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Removed','Changed','AlreadySet','NotPresent','Skipped','Obstruction','Partial','Blocked','Failed')]
        [string]$Status,
        [string]$Message = '',
        [string]$Detail  = '',
        # Set only when a first attempt was refused and a second route worked -
        # and the status stays a success. A red row for something that worked
        # teaches people to ignore red rows.
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
    param(
        [string]$Root,
        [switch]$Preview,
        # GUI bookkeeping session only, and worth ~4s of every launch. The
        # environment record exists to reconstruct a run that went wrong, and
        # the window's session runs nothing.
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
        # For what the rollback script cannot serve: one option back rather than
        # the run, or somebody chasing a problem weeks later who does not yet
        # know this run caused it.
        NotesFile   = Join-Path $runDir 'What-this-run-did.md'
        # Named here rather than by the handler, so the handler, the desktop
        # copy, and anything else that wants it agree on one path.
        IssuesFile  = Join-Path $runDir 'Common-issues.txt'
        # The flight recorder. Separate from the journal because the journal is
        # the undo and every line in it is a promise - see Add-WDTrace.
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
    # This function's contract is that it runs before anything touches the
    # machine, so this is the only correct place for it.
    if ($QuickEnvironment) {
        Write-WDLog 'Interface session - the environment record is written by the run itself.' -Level Debug
    } else {
        $null = Write-WDRunEnvironment
    }
    $script:Session
}

function Get-WDSession { $script:Session }

function Set-WDLogSink {
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
    # HKCU: is not an address - it means "whichever user is asking" - so no
    # journal entry may contain one. A rollback is not necessarily run by the
    # same person.
    param([string]$Path)
    if (-not $Path) { return $Path }
    if ($Path -notmatch '^(HKCU:|HKEY_CURRENT_USER)') { return $Path }
    $sid = ''
    try { $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value } catch { }
    # No SID means no better answer than the one we were given, and an ambiguous
    # journal line beats none.
    if (-not $sid) { return $Path }
    $Path -replace '^(HKCU:|HKEY_CURRENT_USER)', "HKU:\$sid"
}

function Add-WDJournal {
    # JSON Lines, so a half-finished run is still valid.
    param(
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Status,
        [hashtable]$Undo
    )
    if (-not $script:Session) { return }

    # Every executor and handler that records an undo comes through here, so
    # this is the one place the hive is pinned down.
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
        # Error, not Warn: every line in this file is a promise, so one that
        # could not be written is a change already made that can no longer be
        # undone.
        Write-WDLog ("Journal write FAILED for $ItemId ($Type -> $Target): " +
                     "$($_.Exception.Message). That change is now applied with no way back - " +
                     'the rollback script will not offer to reverse it.') -Level Error -Item $ItemId
    }
}

function Add-WDTrace {
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
        # The HRESULT is what makes a COM or DISM failure searchable -
        # 0x800f080c and "the operation failed" are the same event and only one
        # is useful.
        hresult    = if ($ex -and $ex.PSObject.Properties['HResult']) { '0x{0:X8}' -f $ex.HResult } else { $null }
        stack      = [string]$ErrorRecord.ScriptStackTrace
        inner      = $inner
    }
}

function Get-WDMachineIdentity {
    # A run folder is portable on purpose, so "journals I can see" and "journals
    # about this machine" are different sets. MachineGuid decides; the SMBIOS
    # UUID is recorded, never decided on.
    if ($script:MachineIdentity) { return $script:MachineIdentity }
    $g = { param([scriptblock]$B) try { & $B } catch { $null } }

    # Firmware that was never programmed reports one of these, and two machines
    # off the same line then look like one.
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

# One string, because two would disagree in silence: the shortcut's stamp and
# the process's own id have to match or the shell finds no window for the
# button.
$script:WDAppId = 'WinSetupToolkit.Toolkit'

function Get-WDAppUserModelId {
    $script:WDAppId
}

# IShellLink plus IPropertyStore, because WScript.Shell cannot reach the second
# and the second is the whole point. Compiled by its first caller, never at
# import.
$script:WDShellLinkSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace WD {

    [StructLayout(LayoutKind.Sequential)]
    public struct ShortcutPropertyKey {
        public Guid fmtid; public uint pid;
        public ShortcutPropertyKey(Guid g, uint p) { fmtid = g; pid = p; }
    }

    // Only ever holds a VT_LPWSTR here. Declared wide enough for the real
    // 16-byte union so the marshaller lays the pointer at the right offset.
    [StructLayout(LayoutKind.Sequential)]
    public struct ShortcutPropVariant {
        public ushort vt;
        public ushort r1, r2, r3;
        public IntPtr p;
        public IntPtr p2;
    }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder f, int c, IntPtr fd, uint fl);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder n, int c);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string n);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder d, int c);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string d);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder a, int c);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string a);
        void GetHotkey(out ushort w);
        void SetHotkey(ushort w);
        void GetShowCmd(out int c);
        void SetShowCmd(int c);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder p, int c, out int i);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string p, int i);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string p, uint r);
        void Resolve(IntPtr hwnd, uint fl);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string p);
    }

    [ComImport, Guid("0000010b-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPersistFile {
        void GetClassID(out Guid c);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string f, uint m);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string f, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string f);
        void GetCurFile([Out, MarshalAs(UnmanagedType.LPWStr)] out string f);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        void GetCount(out uint c);
        void GetAt(uint i, out ShortcutPropertyKey k);
        void GetValue(ref ShortcutPropertyKey k, out ShortcutPropVariant v);
        void SetValue(ref ShortcutPropertyKey k, ref ShortcutPropVariant v);
        void Commit();
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    public class ShellLinkObject { }

    public static class ShellLink {
        [DllImport("ole32.dll")] static extern void CoTaskMemFree(IntPtr p);
        [DllImport("shell32.dll")] static extern void SHChangeNotify(int e, uint f, IntPtr a, IntPtr b);

        // PKEY_AppUserModel_ID
        static readonly Guid AppUserModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

        public static void Write(string lnk, string target, string args, string workdir,
                                 string icon, int iconIndex, string desc, string aumid) {
            IShellLinkW sl = (IShellLinkW)new ShellLinkObject();
            try {
                sl.SetPath(target);
                if (args    != null) sl.SetArguments(args);
                if (workdir != null) sl.SetWorkingDirectory(workdir);
                if (desc    != null) sl.SetDescription(desc);
                if (icon    != null) sl.SetIconLocation(icon, iconIndex);

                if (aumid != null) {
                    IPropertyStore ps = (IPropertyStore)sl;
                    ShortcutPropertyKey key = new ShortcutPropertyKey(AppUserModel, 5);
                    ShortcutPropVariant pv = new ShortcutPropVariant();
                    pv.vt = 31; // VT_LPWSTR
                    pv.p  = Marshal.StringToCoTaskMemUni(aumid);
                    // We allocated it, so we free it. PropVariantClear lives in
                    // ole32 rather than propsys and is not needed for a string
                    // whose memory never left this method.
                    try { ps.SetValue(ref key, ref pv); ps.Commit(); }
                    finally { CoTaskMemFree(pv.p); }
                }

                ((IPersistFile)sl).Save(lnk, true);
            } finally {
                Marshal.FinalReleaseComObject(sl);
            }
            // Explorer caches an icon by path and never looks again on its own.
            SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero);
        }

        public static string ReadAppId(string lnk) {
            IShellLinkW sl = (IShellLinkW)new ShellLinkObject();
            try {
                ((IPersistFile)sl).Load(lnk, 0);
                IPropertyStore ps = (IPropertyStore)sl;
                ShortcutPropertyKey key = new ShortcutPropertyKey(AppUserModel, 5);
                ShortcutPropVariant pv;
                ps.GetValue(ref key, out pv);
                string s = (pv.vt == 31 && pv.p != IntPtr.Zero) ? Marshal.PtrToStringUni(pv.p) : null;
                if (pv.p != IntPtr.Zero) CoTaskMemFree(pv.p);
                return s;
            } finally {
                Marshal.FinalReleaseComObject(sl);
            }
        }
    }
}
'@

function Use-WDShellLink {
    if (-not ('WD.ShellLink' -as [type])) {
        try { Add-Type -ErrorAction SilentlyContinue -TypeDefinition $script:WDShellLinkSource } catch { }
    }
    [bool]('WD.ShellLink' -as [type])
}

function Set-WDShellShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [string]$Arguments        = '',
        [string]$WorkingDirectory = '',
        [string]$IconPath         = '',
        [int]   $IconIndex        = 0,
        [string]$Description      = '',
        [string]$AppUserModelId   = ''
    )
    if (-not (Use-WDShellLink)) {
        throw 'Could not build the shortcut helper, so no shortcut was written.'
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Force -Path $dir
    }
    # An empty string means "leave it alone" and has to reach the interop as
    # null, or SetIconLocation('') writes an icon path of nothing and the
    # shortcut draws blank.
    $nz = { param($s) if ([string]::IsNullOrEmpty($s)) { $null } else { $s } }
    [WD.ShellLink]::Write($Path, $Target,
                          (& $nz $Arguments), (& $nz $WorkingDirectory),
                          (& $nz $IconPath), $IconIndex,
                          (& $nz $Description), (& $nz $AppUserModelId))
}

function Get-WDShortcutAppUserModelId {
    # The stamp is invisible in Explorer's own property sheet, so nothing else
    # can answer for it and a write has to be read back.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Use-WDShellLink)) { return $null }
    try { [WD.ShellLink]::ReadAppId($Path) } catch { $null }
}

# The name is shared with the generated rollback script on purpose: a rollback
# is exactly the thing that must not run while the Revert page is open.
$script:WDInstanceName  = 'Global\WinSetupToolkit.Toolkit.1'
$script:WDInstanceMutex = $null

function Enter-WDSingleInstance {
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
    # Let go of ours, so we are not the reason the next process to ask gets the
    # same answer.
    try { $script:WDInstanceMutex.Dispose() } catch { }
    $script:WDInstanceMutex = $null
    @{ Ok = $false; Holder = @(Get-WDRunningToolkits) }
}

function Exit-WDSingleInstance {
    if (-not $script:WDInstanceMutex) { return }
    try { $script:WDInstanceMutex.Dispose() } catch { }
    $script:WDInstanceMutex = $null
}

function Get-WDRunningToolkits {
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
    param($Holder, [string]$Me = 'This')
    # Where-Object, not @($Holder).Count: an empty array arrives at a parameter
    # as $null, and @($null) is a one-element array holding nothing - so the
    # count passed and this printed "Already running: , process ".
    $seen  = @($Holder | Where-Object { $_ })
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('For your own safety, having two instances of the Windows Setup Toolkit or its reversion script open is not allowed. There is no reason why you should need two instances, and it can only do harm. Close the other instance to open a new one, or just use the existing one.')
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
    param($Recorded)

    if ($null -eq $Recorded) { return $null }
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
    param([string]$Root = '')
    if (-not $Root) {
        if ($script:Session) { $Root = [string]$script:Session.Root }
        else                 { $Root = Join-Path $env:ProgramData 'WinSetupToolkit' }
    }
    Join-Path $Root 'runs.jsonl'
}

function Register-WDRunRecord {
    # At the root of the data folder rather than inside the run folder it
    # describes, so "Delete old run logs" cannot leave the machine changed by
    # runs it holds no record of.
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
        # One line, no indentation: appended to for the life of the machine and
        # read a line at a time.
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

    # 2 means on mains. hasBattery is recorded separately: "plugged in" and
    # "there is no battery to unplug" are different facts and only one is
    # reassuring.
    $bat = & $g { @(Get-CimInstance Win32_Battery -ErrorAction Stop) }
    $hasBattery = [bool]($bat -and @($bat).Count)
    $onMains = $true
    $batteryPct = $null
    if ($hasBattery) {
        $onMains = [bool](@($bat | Where-Object { $_.BatteryStatus -eq 2 }).Count)
        $batteryPct = ($bat | Select-Object -First 1).EstimatedChargeRemaining
    }

    # Three-valued. Unelevated this throws, and a null the caller compares
    # against 0 silently means "no warning" - on exactly the machines least
    # likely to have a restore point.
    $rpCount = $null
    $rpError = $null
    try { $rpCount = @(Get-ComputerRestorePoint -ErrorAction Stop).Count }
    catch { $rpError = $_.Exception.Message }

    # Matched on the script, not the word: 'WinSetupToolkit' alone matches any
    # shell whose command line merely mentions the folder, and a false alarm
    # about corrupted undo data is unanswerable.
    $others = & $g {
        @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
          Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'WinSetupToolkit\.ps1' } |
          ForEach-Object { [ordered]@{ pid = $_.ProcessId; cmd = [string]$_.CommandLine } })
    }

    # Which code actually ran. .ps1 too, or the rollback window is not covered.
    $modules = & $g {
        @(Get-ChildItem (Join-Path $PSScriptRoot '*.ps*1') -ErrorAction Stop | ForEach-Object {
            [ordered]@{
                name  = $_.Name
                bytes = $_.Length
                wrote = $_.LastWriteTime.ToString('o')
                sha256 = (Get-FileHash $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
            }
        })
    }

    [ordered]@{
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

        # The identity block, so a journal read back later can be checked
        # against the machine it is about to be replayed on.
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

        restorePoints = $rpCount
        restorePointsError = $rpError
        srDisabled    = & $g { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name DisableSR -ErrorAction Stop).DisableSR }
        srFrequency   = & $g { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name SystemRestorePointCreationFrequency -ErrorAction Stop).SystemRestorePointCreationFrequency }
        tamperProtect = & $g { (Get-MpComputerStatus -ErrorAction Stop).IsTamperProtected }

        otherInstances = $others
        modules        = $modules
    }
}

function Write-WDRunEnvironment {
    if (-not $script:Session) { return $null }
    # Not $env: that is the environment-variable provider's prefix, and
    # "$env.field" inside a double-quoted string interpolates as the provider
    # rather than as this.
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
    # read", which is not zero and must not read as a safety net checked and
    # found empty.
    if ($null -ne $info.restorePointsError) {
        Write-WDLog "Could not read the restore point list ($($info.restorePointsError)). Whether there is a way back is unknown." -Level Warn
    } elseif ($info.restorePoints -eq 0) {
        Write-WDLog 'There are no system restore points on this machine. The rollback script is the only way back.' -Level Warn
    } else {
        Write-WDLog "System restore points on this machine: $($info.restorePoints)." -Level Info
    }
    # Guarded rather than assumed: Core loads first and must not depend on a
    # module that comes after it, and the background runspaces each import their
    # own subset.
    if (Get-Command Write-WDToolHealthLog -ErrorAction SilentlyContinue) {
        try { $null = Write-WDToolHealthLog } catch {
            Write-WDLog "The tool check could not run: $($_.Exception.Message)" -Level Warn
        }
    }

    if ($info.otherInstances -and @($info.otherInstances).Count) {
        Write-WDLog ("ANOTHER COPY OF THE TOOLKIT MAY BE RUNNING ({0} process(es)). Two runs at once corrupt each other's undo data - each reads the other's changes as the 'previous value' and both rollbacks then restore the wrong thing." -f `
                     @($info.otherInstances).Count) -Level Error
        # The command line, not only the pid: this matches the word
        # WinSetupToolkit anywhere in it, and a false alarm nobody can check is
        # worse than no alarm.
        foreach ($o in @($info.otherInstances)) {
            $cmd = [string]$o.cmd
            if ($cmd.Length -gt 160) { $cmd = $cmd.Substring(0, 157) + '...' }
            Write-WDLog "  pid $($o.pid): $cmd" -Level Error
        }
    }
    $info
}

function New-WDRestorePoint {
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

    # Restoring a saved setting has three cases, not two: it was this, it was
    # something else, or it was not there at all.
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
        # Journalled as well as restored in the finally: a finally covers an
        # exception, not the process being killed, and Checkpoint-Computer holds
        # this window open for tens of seconds.
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
                # It was not there, so putting it back means taking it away
                # again rather than leaving this run's zero standing.
                Remove-ItemProperty -Path $srKey -Name $freqName -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    $result
}

function Backup-WDRegistryKey {
    # Deduped per run, so a manifest touching one hive fifty times pays once.
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

    # reg.exe prints failures to the console, so capture both streams or a
    # refused export looks like the tool crashing.
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

# TrustedInstaller-owned objects deny an administrator, so seizing the owner is
# the only way through. Only ever reported as success when the retry actually
# succeeds.

# Compiled by Enable-WDOwnershipPrivileges rather than at import: it is only
# wanted part-way into a run that is escalating.
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
    # SeTakeOwnership and SeRestore are present in an admin token but disabled
    # by default, and .NET will not enable them for you.
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

# Recorded at uninstall time because the registry key holding InstallLocation
# goes with the program - by the time the leftover sweep runs there is nothing
# left to ask.
$script:UninstalledThisRun = New-Object System.Collections.Generic.List[psobject]

# Set by the 'irreversible' item at the start of the plan. File deletions stop
# going to the Recycle Bin, and the bin is emptied when the run finishes.
$script:Irreversible = $false

function Set-WDIrreversible { $script:Irreversible = $true }
function Test-WDIrreversible { $script:Irreversible }

function Clear-WDRecycleBin {
    if (-not (Initialize-WDRecycleType)) { return $false }
    try {
        # SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND
        $rc = [WD.Shell]::SHEmptyRecycleBin([IntPtr]::Zero, $null, 0x07)
        # 0 is done; -2147418113 (E_UNEXPECTED) is what an already-empty bin
        # returns on some builds.
        if ($rc -eq 0 -or $rc -eq -2147418113) { return $true }
        Write-WDLog "Emptying the Recycle Bin returned $rc" -Level Warn
        $false
    } catch {
        Write-WDLog "Emptying the Recycle Bin failed: $($_.Exception.Message)" -Level Warn
        $false
    }
}

function Write-WDFinding {
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
    # File deletion is the one thing a journal cannot reverse. SHFileOperation
    # rather than the VisualBasic helper, which can raise a shell dialog on a
    # runspace with nobody to dismiss it.
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
    param([string]$Path)
    if (-not $Path) { return $null }
    $p = ''
    try   { $p = [Environment]::ExpandEnvironmentVariables($Path).Trim().Trim('"').TrimEnd('\') }
    catch { return $null }
    # Four characters rules out a bare drive root: "C:\" normalizes to "C:" and
    # nothing shorter can name a folder inside one.
    if (-not $p -or $p.Length -lt 4) { return $null }
    $forbidden = @(
        $env:SystemRoot, $env:SystemDrive, "$env:SystemDrive\",
        $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
        $env:LOCALAPPDATA, $env:APPDATA, $env:USERPROFILE, $env:PUBLIC,
        (Join-Path $env:ProgramFiles 'Common Files'),
        (Join-Path ${env:ProgramFiles(x86)} 'Common Files'),
        (Join-Path $env:ProgramFiles 'WindowsApps'),
        (Join-Path $env:SystemRoot 'System32'),
        # C:\Users. Derived rather than written out, so relocated profiles are
        # covered - the list named USERPROFILE and PUBLIC but not the folder
        # holding them.
        (Split-Path -Parent $env:USERPROFILE)
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }
    if ($forbidden -contains $p.ToLowerInvariant()) { return $null }
    $p
}

# Services no run may switch off, whatever asked for it. Enforced in the
# executor on the resolved name, so a manifest wildcard cannot reach one
# sideways.
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
    param([string]$Name)
    if (-not $Name) { return $false }
    foreach ($s in $script:CriticalServices) {
        if ($Name -ieq $s) { return $true }
    }
    $false
}

function Stop-WDProcessesUnder {
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
    param(
        [string]$Path = '',
        [string[]]$AlsoNamed = @(),
        [string]$Because = 'it could be removed'
    )
    if (-not $Path -and -not @($AlsoNamed).Count) { return ,@() }
    # Assigned, never wrapped in @(). Stop-WDProcessesUnder ends in ,@(...) so
    # assigning does not unroll, which means @() around it gives one element
    # holding the array - Count 1 whether it closed anything or nothing.
    $shut = Stop-WDProcessesUnder -Path $Path -AlsoNamed $AlsoNamed
    if ($shut.Count) {
        Write-WDLog "Closed $($shut -join ', ') so $Because." -Level Info
        Start-Sleep -Milliseconds 700
    }
    ,@($shut)
}

function Remove-WDStubbornDirectory {
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

        # Give a killed process time to drop its handles. Ramps, because the
        # usual reason a second attempt fails is a service restart that has not
        # finished.
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

        # Files first, deepest last, one at a time: a recursive delete stops at
        # the first locked file and leaves everything after it.
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

    # MOVEFILE_DELAY_UNTIL_REBOOT. Files before their directories, deepest
    # first, or a queued directory delete finds itself non-empty and is skipped.
    # Sorted on real path depth - Sort-Object { $_.Length } sorts on string
    # length.
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

# Export-WDUndoScript lives in WD.Revert now. This file is the session, the log,
# and the journal - what a rollback reads, not what reads it.

function Export-WDRunNotes {
    param(
        [Parameter(Mandatory)]$Items,
        [string]$PresetName = '',
        [string]$Path = '',
        # Parameters rather than reads off the session, because -Path has to
        # work without one.
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
    # Asked of the file, not of the selection: "generate rollback script" is a
    # row that can be unticked and a step that can fail, so a path is not a
    # promise something is at the end of it.
    $undoRef = '(no rollback script was written)'
    if ($UndoFile -and (Test-Path -LiteralPath $UndoFile)) { $undoRef = $UndoFile }

    $mech = @()
    foreach ($i in @($Items)) {
        if (-not $i) { continue }
        $mech += Get-WDItemMechanics -Item $i
    }

    $sb = New-Object System.Text.StringBuilder
    $w  = { param([string]$Line = '') $null = $sb.AppendLine($Line) }

    # Used twice: to count the kinds for the summary, and to split a mechanics
    # line into a label and the machine detail after it.
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

    # The detail goes in a code span, which is not decoration: these are
    # registry paths, and markdown treats a backslash as an escape - C:\* and \_
    # both come out wrong as plain text.
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
    # When the run happened, not when this file was written: the date somebody
    # wants is the one their machine changed.
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
    # list rather than a document.
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
    # A rule before every option, not between categories: two heading levels
    # already separate those, and a rule is the only markdown separator that
    # survives being read as plain text.
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
            # The regedit instruction is stated once at the top: it is true of
            # every registry line here, and 150 copies of one fact is how a
            # document stops being read.
            $undoBits = New-Object System.Collections.Generic.List[string]
            $said = ([string]$m.Settings).ToLower()
            if ($m.Settings) { $undoBits.Add([string]$m.Settings) }
            $elsewhere = New-Object System.Collections.Generic.List[string]
            foreach ($c in @($m.Consoles)) {
                if ([string]$c.Label -match 'regedit') { continue }
                # Already named in the authored line above it.
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
    param(
        [string]$KeepDir = '',
        [string]$RunDir = '',
        [bool]$HasUndo = $false,
        [string]$RestorePoint = '',
        [int]$RestartCount = 0,
        [bool]$Reboot = $false
    )

    $out = New-Object System.Collections.Generic.List[string]
    # How many, not whether: "a restart is required" over ninety changes does
    # not say whether that is one of them or all of them.
    if ($RestartCount -gt 0) {
        $out.Add("$RestartCount change$(if ($RestartCount -ne 1) { 's' }) need$(if ($RestartCount -eq 1) { 's' } else { '' }) a restart to take effect. Everything else is already in force.")
    } elseif ($Reboot) {
        $out.Add('A restart is needed to finish.')
    }
    # The rollback script is a row that can be unticked, so every line below
    # describes the run that happened rather than the run this toolkit would
    # rather have had.
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
    # Worth naming both when it worked, because nobody thinks to look, and when
    # it did not, because the confirmation promised one.
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
    param([string]$RunDir)

    if (-not $RunDir) { return $null }
    try { if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) { return $null } } catch { return $null }

    $report = $null
    try {
        $rp = Join-Path $RunDir 'report.json'
        if (Test-Path -LiteralPath $rp) { $report = Get-Content -LiteralPath $rp -Raw | ConvertFrom-Json }
    } catch { $report = $null }
    if (-not $report) { return $null }
    # A preview leaves a report too, and offering somebody the results of a run
    # that changed nothing is worse than showing them nothing.
    if ([bool](Get-Prop $report 'preview' $false)) { return $null }

    $extra = $null
    try {
        $sp = Join-Path $RunDir 'setup-result.json'
        if (Test-Path -LiteralPath $sp) { $extra = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json }
    } catch { $extra = $null }

    $counts = Get-Prop $report 'counts' $null
    # The desktop folder may have moved between the run and the sign-in - people
    # tidy - so the button is only offered when there is something to open.
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
    param([string]$RunDir, [string]$ScriptPath)

    if (-not $RunDir -or -not (Test-Path -LiteralPath $RunDir)) {
        Write-WDLog 'No run folder to point the first sign-in at, so no prompt was registered.' -Level Warn
        return $false
    }
    if (-not $ScriptPath -or -not (Test-Path -LiteralPath $ScriptPath)) {
        Write-WDLog 'The toolkit could not find its own script, so no prompt was registered.' -Level Warn
        return $false
    }
    # The medium is gone by the time anybody signs in, so an entry pointing at a
    # script on a drive that will not be there is worse than none: an error at
    # first sign-in from a program with no name on it.
    $sys = ''
    try { $sys = [IO.Path]::GetPathRoot([Environment]::GetFolderPath('System')) } catch { }
    if ($sys -and [IO.Path]::GetPathRoot($ScriptPath) -ne $sys) {
        Write-WDLog "The toolkit is running from $([IO.Path]::GetPathRoot($ScriptPath)), which may not be attached at the first sign-in, so no prompt was registered." -Level Warn
        return $false
    }

    $key  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $name = 'WinSetupToolkitSetupResult'
    # -STA because the prompt is WPF. powershell.exe defaults to it, and a
    # default is not a thing to rely on in a command line read back a reboot
    # later.
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
    # Assigned first, because Get-WDWrapUpLines ends in ,@(): @() around it is
    # one element holding all five paragraphs, and $w takes [string], so they
    # arrive space-joined as one block.
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

    # The machine-readable half: where the desktop copy went, whether the
    # rollback script exists, how many changes want a restart. None of it is in
    # the report.
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
    param($Session, [string]$Desktop = '', [switch]$Public)

    if (-not $Session) { $Session = $script:Session }
    if (-not $Session) { return }
    if ([bool]$Session.Preview) { return }

    # A machine with no desktop folder is not a reason to fail a run that has
    # already finished - the run directory still holds everything and this is a
    # second copy.
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

    # A file that was not written is skipped silently: not selecting an option
    # is not an error.
    $wanted = @(
        # The launcher first, because it is the one to double-click - Windows
        # associates .ps1 with a text editor.
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
        # is the SetupComplete.cmd one.
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

Export-ModuleMember -Function *-WD*, Get-WDSession, Test-WDAdmin, ConvertTo-WDRegParts, Get-Prop
