<#
    DteHelper.ps1 -- everything that touches the XAE Shell's DTE object.

    Design refs: §2.1 (Automation Interface is the only build path), §4.2
    (hardening), §4.3 (terse error extraction).
#>

Set-StrictMode -Version Latest

# ProgIDs in preference order. 4026's XAE Shell is the VS2022 shell (17.0);
# 4024 was VS2017 (15.0). A full Visual Studio with the TwinCAT extension works
# too and is the last resort.
$script:TcProgIdCandidates = @(
    'TcXaeShell.DTE.17.0'
    'TcXaeShell.DTE.15.0'
    'VisualStudio.DTE.17.0'
    'VisualStudio.DTE.16.0'
)

function Resolve-TcDteProgId {
    <#  Picks the first ProgID actually registered under HKCR. #>
    param([string[]] $Candidates = $script:TcProgIdCandidates)
    foreach ($p in $Candidates) {
        if (Test-Path "Registry::HKEY_CLASSES_ROOT\$p") { return $p }
    }
    throw ("No TwinCAT XAE Shell / Visual Studio DTE ProgID found under HKCR. " +
           "Tried: $($Candidates -join ', '). Is TE1000 XAE installed on this box?")
}

function Get-TcShellIdeDir {
    <#
        The shell's Common7\IDE directory, derived from the ProgID's COM
        registration (HKCR\<ProgId>\CLSID -> HKCR\CLSID\{..}\LocalServer32).
        Typically C:\Program Files\Beckhoff\TcXaeShell\Common7\IDE.
    #>
    param([string] $ProgId = (Resolve-TcDteProgId))
    try {
        $clsid = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$ProgId\CLSID" -ErrorAction Stop).'(default)'
        $srv   = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\LocalServer32" -ErrorAction Stop).'(default)'
        if ($srv -match '^\s*"?([^"]+?\.exe)"?') { return (Split-Path -Parent $Matches[1]) }
    } catch { }
    return $null
}

# --- Running Object Table --------------------------------------------------
# Lets a short-lived process (direct mode) attach to an already-open shell
# instead of paying the ~9MB tsproj load on every single build.
if (-not ('TcWorkflow.Rot' -as [type])) {
@'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace TcWorkflow
{
    public static class Rot
    {
        [DllImport("ole32.dll")] private static extern int GetRunningObjectTable(int reserved, out IRunningObjectTable prot);
        [DllImport("ole32.dll")] private static extern int CreateBindCtx(int reserved, out IBindCtx ppbc);

        public static List<string> Names()
        {
            var result = new List<string>();
            IRunningObjectTable rot; IBindCtx ctx;
            if (GetRunningObjectTable(0, out rot) != 0) return result;
            if (CreateBindCtx(0, out ctx) != 0) return result;
            IEnumMoniker e; rot.EnumRunning(out e); e.Reset();
            var m = new IMoniker[1];
            while (e.Next(1, m, IntPtr.Zero) == 0)
            {
                string name; m[0].GetDisplayName(ctx, null, out name);
                result.Add(name);
            }
            return result;
        }

        public static object Get(string displayName)
        {
            IRunningObjectTable rot; IBindCtx ctx;
            if (GetRunningObjectTable(0, out rot) != 0) return null;
            if (CreateBindCtx(0, out ctx) != 0) return null;
            IEnumMoniker e; rot.EnumRunning(out e); e.Reset();
            var m = new IMoniker[1];
            while (e.Next(1, m, IntPtr.Zero) == 0)
            {
                string name; m[0].GetDisplayName(ctx, null, out name);
                if (name == displayName)
                {
                    object obj; rot.GetObject(m[0], out obj); return obj;
                }
            }
            return null;
        }
    }
}
'@ | ForEach-Object { Add-Type -TypeDefinition $_ -ErrorAction Stop }
}

# --- Watchdog ----------------------------------------------------------------
# docs/field-notes.md, "Wedged shell": a wedged shell blocks the worker's STA thread inside a COM
# call for as long as the client is willing to wait (observed: 900s, then the
# client gave up and the worker was still stuck). Nothing on the worker thread
# can interrupt that, so the escape hatch runs on a threadpool timer: when a
# job overruns its budget, kill the shell. The pending COM call then fails with
# RPC_S_SERVER_UNAVAILABLE / RPC_E_DISCONNECTED, the worker's catch publishes a
# real result, and the next job starts a fresh shell. Pure .NET on purpose --
# PowerShell cmdlets cannot run on a timer thread.
if (-not ('TcWorkflow.Watchdog' -as [type])) {
@'
using System;
using System.Diagnostics;
using System.Threading;

namespace TcWorkflow
{
    public static class Watchdog
    {
        private static Timer timer;
        private static readonly object gate = new object();
        public static volatile bool Fired;
        public static int KilledCount;
        public static string[] ProcessNames = new string[] { "TcXaeShell", "devenv" };

        public static void Start(int milliseconds)
        {
            lock (gate)
            {
                StopNoLock();
                Fired = false; KilledCount = 0;
                timer = new Timer(OnFire, null, milliseconds, Timeout.Infinite);
            }
        }

        public static void Stop() { lock (gate) { StopNoLock(); } }

        private static void StopNoLock()
        {
            if (timer != null) { timer.Dispose(); timer = null; }
        }

        private static void OnFire(object state)
        {
            Fired = true;
            foreach (string n in ProcessNames)
            {
                foreach (Process p in Process.GetProcessesByName(n))
                {
                    try { p.Kill(); KilledCount++; } catch { }
                }
            }
        }
    }
}
'@ | ForEach-Object { Add-Type -TypeDefinition $_ -ErrorAction Stop }
}

function Start-TcWatchdog {
    param([Parameter(Mandatory)][int] $Seconds)
    [TcWorkflow.Watchdog]::Start([int]($Seconds * 1000))
}
function Stop-TcWatchdog { [TcWorkflow.Watchdog]::Stop() }
function Test-TcWatchdogFired { return [bool][TcWorkflow.Watchdog]::Fired }

# --- DTE2 interop --------------------------------------------------------------
# docs/field-notes.md, "Compiler diagnostics". New-Object -ComObject hands PowerShell an RCW whose
# members PowerShell discovers through ITypeInfo of the DEFAULT interface,
# which for the DTE coclass is EnvDTE._DTE. ToolWindows, and with it the Error
# List, live on EnvDTE80.DTE2 -- a different interface on the same object --
# so from script they are simply "not found". Casting in PowerShell does not
# help either: member binding still goes by the runtime type (__ComObject).
#
# A C# cast of the RCW IS a QueryInterface for IID_DTE2, so the fix is a tiny
# compiled helper, built against the shell's own primary interop assemblies
# (Common7\IDE\PublicAssemblies\envdte.dll + envdte80.dll; they are NOT in the
# GAC on this box).
#
# Assembly binding: the PIAs are LoadFrom-loaded and the helper is an in-memory
# Add-Type assembly, so a plain identity bind for "EnvDTE80" at JIT time would
# fail. AsmResolver answers those binds from the already-loaded set.

$script:TcInterop = $null     # $null = not tried, $false = failed, hashtable = loaded

function Find-TcPublicAssemblies {
    $candidates = @()
    $ide = Get-TcShellIdeDir
    if ($ide) { $candidates += (Join-Path $ide 'PublicAssemblies') }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $pf) { continue }
        $candidates += Get-ChildItem -Path (Join-Path $pf 'Beckhoff') -Directory -Filter 'TcXaeShell*' -ErrorAction SilentlyContinue |
                       ForEach-Object { Join-Path $_.FullName 'Common7\IDE\PublicAssemblies' }
        $candidates += Get-ChildItem -Path (Join-Path $pf 'Microsoft Visual Studio') -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -eq 'Common7' } |
                       ForEach-Object { Join-Path $_.FullName 'IDE\PublicAssemblies' }
    }
    foreach ($c in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if ((Test-Path (Join-Path $c 'envdte.dll')) -and (Test-Path (Join-Path $c 'envdte80.dll'))) { return $c }
    }
    return $null
}

function Import-TcDteInterop {
    <#
        Loads the EnvDTE/EnvDTE80 PIAs and compiles TcWorkflow.DteExt against
        them. Idempotent; returns $true when [TcWorkflow.DteExt] is usable.
        Never throws -- callers fall back to late binding on $false.
    #>
    if ($null -ne $script:TcInterop) { return [bool]$script:TcInterop }

    try {
        if (-not ('TcWorkflow.AsmResolver' -as [type])) {
@'
using System;
using System.Reflection;

namespace TcWorkflow
{
    public static class AsmResolver
    {
        private static bool hooked;
        public static void Hook()
        {
            if (hooked) return;
            hooked = true;
            AppDomain.CurrentDomain.AssemblyResolve += delegate(object sender, ResolveEventArgs args)
            {
                string want = new AssemblyName(args.Name).Name;
                foreach (Assembly a in AppDomain.CurrentDomain.GetAssemblies())
                {
                    try
                    {
                        if (string.Equals(a.GetName().Name, want, StringComparison.OrdinalIgnoreCase)) return a;
                    }
                    catch { }
                }
                return null;
            };
        }
    }
}
'@ | ForEach-Object { Add-Type -TypeDefinition $_ -ErrorAction Stop }
        }
        [TcWorkflow.AsmResolver]::Hook()

        $envdte = $null; $envdte80 = $null; $vsInterop = $null
        # GAC first (a box with full Visual Studio has them there) ...
        foreach ($pair in @(@('EnvDTE', 'envdte'), @('EnvDTE80', 'envdte80'))) {
            try {
                $a = [Reflection.Assembly]::Load("$($pair[0]), Version=8.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a")
                if ($pair[1] -eq 'envdte') { $envdte = $a } else { $envdte80 = $a }
            } catch { }
        }
        # ... then the shell's PublicAssemblies.
        $dir = Find-TcPublicAssemblies
        if (-not $envdte -or -not $envdte80) {
            if (-not $dir) { throw "envdte.dll / envdte80.dll not found in the GAC or any PublicAssemblies directory" }
            if (-not $envdte)   { $envdte   = [Reflection.Assembly]::LoadFrom((Join-Path $dir 'envdte.dll')) }
            if (-not $envdte80) { $envdte80 = [Reflection.Assembly]::LoadFrom((Join-Path $dir 'envdte80.dll')) }
            Write-TcLog "DTE interop: loaded PIAs from $dir"
        } else {
            Write-TcLog "DTE interop: loaded PIAs from the GAC"
        }
        # VS 2022 (17.x) shells ship envdte*.dll as TYPE FORWARDERS: every type
        # now lives in Microsoft.VisualStudio.Interop.dll ("This type has been
        # forwarded to assembly ..." at compile time). Reference it too when it
        # is present; older shells simply do not have it.
        $refs = New-Object System.Collections.Generic.List[string]
        $refs.Add($envdte.Location); $refs.Add($envdte80.Location)
        $fwdCandidates = @()
        if ($dir) { $fwdCandidates += (Join-Path $dir 'Microsoft.VisualStudio.Interop.dll') }
        foreach ($f in $fwdCandidates) {
            if (Test-Path $f) {
                $vsInterop = [Reflection.Assembly]::LoadFrom($f)
                $refs.Add($vsInterop.Location)
                Write-TcLog "DTE interop: forwarders target $($vsInterop.GetName().Name) v$($vsInterop.GetName().Version)"
                break
            }
        }

        if (-not ('TcWorkflow.DteExt' -as [type])) {
            $src = @'
using System;
using System.Collections.Generic;
using EnvDTE;
using EnvDTE80;

namespace TcWorkflow
{
    public class BuildMessage
    {
        public string File; public int Line; public int Column;
        public string Severity; public string Message; public string Project;
    }

    public static class DteExt
    {
        // The whole point of this class: (DTE2) on an RCW is a QueryInterface.
        public static DTE2 AsDte2(object dte) { return (DTE2)dte; }

        public static List<BuildMessage> ReadErrorList(object dteObj)
        {
            return ReadErrorList(dteObj, int.MaxValue);
        }

        // maxItems bounds the walk: each ErrorItem costs ~5 cross-process COM
        // calls, and a fresh shell was seen holding 2283 items (14 s to read).
        public static List<BuildMessage> ReadErrorList(object dteObj, int maxItems)
        {
            DTE2 dte2 = (DTE2)dteObj;
            ErrorList el = dte2.ToolWindows.ErrorList;
            // ErrorItems reflects the window's filter toggles. TcUnit-Runner
            // does the same before reading; a user who once unticked
            // "Warnings" in this profile would otherwise hide them from us.
            try { el.ShowErrors = true; el.ShowWarnings = true; el.ShowMessages = true; } catch { }
            ErrorItems items = el.ErrorItems;
            List<BuildMessage> list = new List<BuildMessage>();
            int n = items.Count;
            if (n > maxItems) n = maxItems;
            for (int i = 1; i <= n; i++)
            {
                ErrorItem it = items.Item(i);
                BuildMessage m = new BuildMessage();
                try { m.Message = (it.Description ?? "").Trim(); } catch { m.Message = ""; }
                try { m.File    = it.FileName ?? ""; }            catch { m.File = ""; }
                try { m.Project = it.Project ?? ""; }             catch { m.Project = ""; }
                try { m.Line    = it.Line; }                      catch { m.Line = 0; }
                try { m.Column  = it.Column; }                    catch { m.Column = 0; }
                vsBuildErrorLevel lvl = vsBuildErrorLevel.vsBuildErrorLevelLow;
                try { lvl = it.ErrorLevel; } catch { }
                if (lvl == vsBuildErrorLevel.vsBuildErrorLevelHigh)        m.Severity = "error";
                else if (lvl == vsBuildErrorLevel.vsBuildErrorLevelMedium) m.Severity = "warning";
                else                                                       m.Severity = "message";
                list.Add(m);
            }
            return list;
        }

        // Solution configuration + platform. PlatformName lives on
        // EnvDTE80.SolutionConfiguration2, invisible to PowerShell's COM adapter.
        // Indexed access with null checks: enumerating the collection through
        // IEnumVARIANT handed back a null element for one of 20 configurations
        // (NullReferenceException).
        private static string PlatformOf(SolutionConfiguration sc)
        {
            try { SolutionConfiguration2 sc2 = sc as SolutionConfiguration2; if (sc2 != null) return sc2.PlatformName ?? ""; } catch { }
            return "";
        }

        private static SolutionConfigurations ConfigsOf(object dteObj)
        {
            DTE2 dte2 = (DTE2)dteObj;
            if (dte2.Solution == null) throw new InvalidOperationException("DTE has no Solution");
            SolutionBuild sb = dte2.Solution.SolutionBuild;
            if (sb == null) throw new InvalidOperationException("Solution has no SolutionBuild (is a solution open?)");
            SolutionConfigurations cfgs = sb.SolutionConfigurations;
            if (cfgs == null) throw new InvalidOperationException("SolutionBuild.SolutionConfigurations is null");
            return cfgs;
        }

        public static List<string> SolutionConfigurationNames(object dteObj)
        {
            SolutionConfigurations cfgs = ConfigsOf(dteObj);
            List<string> names = new List<string>();
            int n = cfgs.Count;
            for (int i = 1; i <= n; i++)
            {
                SolutionConfiguration sc = null;
                try { sc = cfgs.Item(i); } catch { continue; }
                if (sc == null) continue;
                string name = ""; try { name = sc.Name ?? ""; } catch { }
                names.Add(name + "|" + PlatformOf(sc));
            }
            return names;
        }

        public static string ActiveSolutionConfiguration(object dteObj)
        {
            DTE2 dte2 = (DTE2)dteObj;
            if (dte2.Solution == null || dte2.Solution.SolutionBuild == null) return "";
            SolutionConfiguration sc = dte2.Solution.SolutionBuild.ActiveConfiguration;
            if (sc == null) return "";
            string name = ""; try { name = sc.Name ?? ""; } catch { }
            return name + "|" + PlatformOf(sc);
        }

        public static bool ActivateSolutionConfiguration(object dteObj, string name, string platform)
        {
            SolutionConfigurations cfgs = ConfigsOf(dteObj);
            int n = cfgs.Count;
            for (int i = 1; i <= n; i++)
            {
                SolutionConfiguration sc = null;
                try { sc = cfgs.Item(i); } catch { continue; }
                if (sc == null) continue;
                string scName = ""; try { scName = sc.Name ?? ""; } catch { continue; }
                if (!string.Equals(scName, name, StringComparison.OrdinalIgnoreCase)) continue;
                if (!string.Equals(PlatformOf(sc), platform ?? "", StringComparison.OrdinalIgnoreCase)) continue;
                sc.Activate();
                return true;
            }
            return false;
        }

        // Solution Explorer (UIHierarchy) -- what the IDE shows a user, and the
        // way a user makes a lazily-loaded extension load: by touching its node.
        private static void WalkUi(UIHierarchyItems items, string prefix, int depth, List<string> acc)
        {
            if (items == null || depth < 0) return;
            int n = 0; try { n = items.Count; } catch { return; }
            for (int i = 1; i <= n; i++)
            {
                UIHierarchyItem it = null;
                try { it = items.Item(i); } catch { continue; }
                if (it == null) continue;
                string name = ""; try { name = it.Name ?? ""; } catch { }
                string path = prefix + "\\" + name;
                acc.Add(path);
                try { WalkUi(it.UIHierarchyItems, path, depth - 1, acc); } catch { }
            }
        }
        public static List<string> SolutionExplorerItems(object dteObj, int depth)
        {
            DTE2 dte2 = (DTE2)dteObj;
            List<string> acc = new List<string>();
            UIHierarchy uih = dte2.ToolWindows.SolutionExplorer;
            if (uih != null) WalkUi(uih.UIHierarchyItems, "", depth, acc);
            return acc;
        }
        public static bool SelectSolutionExplorerItem(object dteObj, string path)
        {
            DTE2 dte2 = (DTE2)dteObj;
            UIHierarchyItem it = dte2.ToolWindows.SolutionExplorer.GetItem(path);
            if (it == null) return false;
            try { it.UIHierarchyItems.Expanded = true; } catch { }
            it.Select(vsUISelectionType.vsUISelectionTypeSelect);
            return true;
        }

        public static List<string> OutputPaneNames(object dteObj)
        {
            DTE2 dte2 = (DTE2)dteObj;
            List<string> names = new List<string>();
            foreach (OutputWindowPane p in dte2.ToolWindows.OutputWindow.OutputWindowPanes)
            {
                try { names.Add(p.Name); } catch { }
            }
            return names;
        }

        public static bool ClearOutputPane(object dteObj, string paneNameExact)
        {
            DTE2 dte2 = (DTE2)dteObj;
            foreach (OutputWindowPane p in dte2.ToolWindows.OutputWindow.OutputWindowPanes)
            {
                string name = "";
                try { name = p.Name ?? ""; } catch { }
                if (string.Equals(name, paneNameExact, StringComparison.OrdinalIgnoreCase)) { p.Clear(); return true; }
            }
            return false;
        }

        public static string ReadOutputPane(object dteObj, string paneNameContains)
        {
            DTE2 dte2 = (DTE2)dteObj;
            OutputWindowPane pane = null;
            foreach (OutputWindowPane p in dte2.ToolWindows.OutputWindow.OutputWindowPanes)
            {
                string name = "";
                try { name = p.Name ?? ""; } catch { }
                if (name.IndexOf(paneNameContains, StringComparison.OrdinalIgnoreCase) >= 0) { pane = p; break; }
            }
            if (pane == null) return null;
            TextSelection sel = pane.TextDocument.Selection;
            sel.StartOfDocument(false);
            sel.EndOfDocument(true);
            return sel.Text;
        }
    }
}
'@
            Add-Type -TypeDefinition $src -ReferencedAssemblies $refs.ToArray() -ErrorAction Stop
        }

        $script:TcInterop = @{ envdte = $envdte.Location; envdte80 = $envdte80.Location
                               vsInterop = $(if ($vsInterop) { $vsInterop.Location } else { $null }) }
        Write-TcLog "DTE interop: TcWorkflow.DteExt ready"
        return $true
    }
    catch {
        $script:TcInterop = $false
        Write-TcLog "DTE interop unavailable ($(Get-TcExceptionText $_)) -- falling back to late binding"
        return $false
    }
}

function Invoke-TcCom {
    <#
        Late-bound member access straight through IDispatch::GetIDsOfNames,
        bypassing PowerShell's ITypeInfo-based member discovery. Second-choice
        path when the interop helper is unavailable.
    #>
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)][string] $Member,
        [object[]] $Arguments = @(),
        [switch] $Method
    )
    $flags = [Reflection.BindingFlags]::GetProperty
    if ($Method) { $flags = [Reflection.BindingFlags]::InvokeMethod }
    $raw = $Object
    try { $raw = $Object.PSObject.BaseObject } catch { }
    return [System.__ComObject].InvokeMember($Member, $flags, $null, $raw, $Arguments)
}

function Get-TcDteFromRot {
    <#  Returns a live DTE for the given ProgID if one is already running.
        With -ProcessId, only the instance registered by that process
        (ROT display names are "!<ProgId>:<pid>"). #>
    param([Parameter(Mandatory)][string] $ProgId, [int] $ProcessId = 0)
    $want = "!$ProgId"
    if ($ProcessId -gt 0) { $want = "!${ProgId}:$ProcessId" }
    foreach ($n in [TcWorkflow.Rot]::Names()) {
        if ($n -like "$want*") {
            try {
                $obj = [TcWorkflow.Rot]::Get($n)
                if ($obj) { $null = $obj.Version; return $obj }   # probe it is alive
            } catch { }
        }
    }
    return $null
}

function Stop-StaleTcShells {
    <#  §4.2: a wedged shell from a previous run poisons every build after it. #>
    param([int] $OlderThanMinutes = 0)
    $names = @('TcXaeShell', 'devenv')
    foreach ($n in $names) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            if ($OlderThanMinutes -gt 0 -and $_.StartTime -gt (Get-Date).AddMinutes(-$OlderThanMinutes)) { return }
            Write-TcLog "killing stale $($_.ProcessName) pid=$($_.Id)"
            try { $_.Kill(); $_.WaitForExit(15000) } catch { }
        }
    }
}

function New-TcDte {
    <#
        Two ways to get a DTE:
          com     -- New-Object -ComObject: COM launches the shell with /Embedding.
                     Fast and headless, but the instance is an automation server
                     first and an IDE second; extension services may never
                     initialise (the Analytics node was once silently dropped
                     from every configuration generated this way, while the
                     same shell driven interactively on the same box was fine).
          process -- Start-Process TcXaeShell.exe like a user would, then attach
                     to its DTE through the Running Object Table.
        -SuppressUI:$false leaves dialogs visible (in the autologon session
        nobody clicks them, but extensions that only ask questions with UI
        enabled behave as they do for a user).
    #>
    param(
        [string] $ProgId = (Resolve-TcDteProgId),
        [switch] $Visible,
        [switch] $ReuseRunning,
        [ValidateSet('com', 'process')][string] $StartMode = 'com',
        [bool] $SuppressUI = $true
    )
    if ($ReuseRunning) {
        $existing = Get-TcDteFromRot -ProgId $ProgId
        if ($existing) { Write-TcLog "attached to running $ProgId"; return $existing }
    }
    $dte = $null
    if ($StartMode -eq 'process') {
        $ide = Get-TcShellIdeDir -ProgId $ProgId
        $exe = if ($ide) { Join-Path $ide 'TcXaeShell.exe' } else { $null }
        if (-not $exe -or -not (Test-Path -LiteralPath $exe)) { throw "cannot find the shell executable for $ProgId (LocalServer32 lookup failed)" }
        Write-TcLog "starting $exe as a normal process"
        $p = Start-Process -FilePath $exe -PassThru
        $deadline = (Get-Date).AddSeconds(90)
        while (-not $dte -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 1000
            $dte = Get-TcDteFromRot -ProgId $ProgId -ProcessId $p.Id
        }
        if (-not $dte) { throw "shell pid $($p.Id) did not register a DTE in the Running Object Table within 90s" }
        Write-TcLog "attached to $ProgId in pid $($p.Id) via ROT"
        # The DTE is in the ROT before the IDE has finished starting; calls in
        # that window fail with E_ACCESSDENIED (0x80070005). Wait until it answers.
        $ready = $false; $deadline = (Get-Date).AddSeconds(120); $lastErr = ''
        while (-not $ready -and (Get-Date) -lt $deadline) {
            try { $null = $dte.Version; $ready = $true } catch { $lastErr = Get-TcExceptionText $_; Start-Sleep -Milliseconds 1000 }
        }
        if (-not $ready) { throw "shell pid $($p.Id) never became ready for automation: $lastErr" }
        Write-TcLog "shell ready for automation"
    } else {
        Write-TcLog "starting $ProgId via COM"
        $dte = New-Object -ComObject $ProgId
    }
    try { $dte.SuppressUI = $SuppressUI } catch { Write-TcLog "could not set SuppressUI: $(Get-TcExceptionText $_)" }   # §4.2 -- no modal dialogs (unless testing)
    if ($StartMode -eq 'com') { $dte.UserControl = $false }   # COM-created: we own the lifetime. Process-started: behaves like a user's IDE.
    try { $dte.MainWindow.Visible = [bool]$Visible } catch { }
    Write-TcLog "DTE ready: startMode=$StartMode suppressUI=$SuppressUI visible=$([bool]$Visible)"
    return $dte
}

function Open-TcSolution {
    param(
        [Parameter(Mandatory)] $Dte,
        [Parameter(Mandatory)][string] $SolutionPath
    )
    if (-not (Test-Path -LiteralPath $SolutionPath)) {
        throw "solution not found: $SolutionPath"
    }
    $full = (Resolve-Path -LiteralPath $SolutionPath).Path
    if ($Dte.Solution.IsOpen) {
        $open = ''
        try { $open = $Dte.Solution.FullName } catch { }
        if ($open -eq $full) { Write-TcLog "reusing warm solution"; return }
        Write-TcLog "closing previously open solution"
        $Dte.Solution.Close($false)
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-TcLog "opening $full"
    $Dte.Solution.Open($full)
    if (-not $Dte.Solution.IsOpen) { throw "solution failed to open: $full" }
    Write-TcLog ("solution open in {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}

function Close-TcSolution {
    <#
        docs/field-notes.md, "Wedged shell": files changing underneath an OPEN solution wedge
        the shell's next COM call (the TwinCAT project system reacts to the
        change and never comes back). Every sync changes files, so the worker
        closes the solution at the end of every job and pays the ~60s reopen
        on the next one. The shell PROCESS stays warm; only the solution is
        cold. Swallows errors: a dead shell must not mask the job's own result.
    #>
    param([Parameter(Mandatory)] $Dte)
    if (-not $Dte) { return }
    if (Test-TcWatchdogFired) { Write-TcLog "solution close skipped -- the watchdog already killed the shell"; return }
    try {
        if (-not $Dte.Solution.IsOpen) { return }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $Dte.Solution.Close($false)
        Write-TcLog ("solution closed in {0:N1}s (kept the shell process warm)" -f $sw.Elapsed.TotalSeconds)
    } catch {
        Write-TcLog "closing the solution failed: $(Get-TcExceptionText $_)"
    }
}

function Get-TcActiveSolutionConfiguration {
    <#  "Name|Platform" of the active solution configuration, '' if unknown. #>
    param([Parameter(Mandatory)] $Dte)
    if (Import-TcDteInterop) {
        try { return [string][TcWorkflow.DteExt]::ActiveSolutionConfiguration($Dte) } catch { }
    }
    try { return ([string]$Dte.Solution.SolutionBuild.ActiveConfiguration.Name) + '|' } catch { return '' }
}

function Set-TcSolutionConfiguration {
    <#
        Pins the solution configuration|platform before a build. Without this
        the shell builds whatever its saved user state says -- on one box
        that was 'Release|TwinCAT OS (ARMV8-A)' for an x64 target. TwinCAT
        still generates the boot project for the
        SELECTED TARGET's platform at activation, which is why that deploy
        ran, but a deploy tool must not depend on that. Throws on an unknown
        combination and lists what the solution offers.
    #>
    param(
        [Parameter(Mandatory)] $Dte,
        [Parameter(Mandatory)][string] $Configuration,
        [Parameter(Mandatory)][string] $Platform
    )
    if (-not (Import-TcDteInterop)) { throw "cannot select the solution configuration without the DTE2 interop helper" }
    $before = Get-TcActiveSolutionConfiguration -Dte $Dte
    $ok = [TcWorkflow.DteExt]::ActivateSolutionConfiguration($Dte, $Configuration, $Platform)
    if (-not $ok) {
        $have = @([TcWorkflow.DteExt]::SolutionConfigurationNames($Dte))
        throw ("solution configuration '$Configuration|$Platform' does not exist in this solution. " +
               "Check BUILD_CONFIGURATION / BUILD_PLATFORM in tcdeploy.conf. Available: " + ($have -join ', '))
    }
    $after = Get-TcActiveSolutionConfiguration -Dte $Dte
    if ($after -ne "$Configuration|$Platform") {
        throw "asked for '$Configuration|$Platform' but the shell reports '$after' active"
    }
    if ($before -ne $after) { Write-TcLog "solution configuration: $before -> $after" }
    else { Write-TcLog "solution configuration: $after" }
}

function Get-TcSysManager {
    <#
        ITcSysManager lives on the TwinCAT project's .Object (design §2.1).

        Two things learned the hard way on 4026:

        1. Project.FileName comes back EMPTY for all projects in this shell.
           UniqueName is the field that actually carries '<Project>.tsproj', so
           that is what we match on.

        2. .Object can be $null even when Solution.IsOpen is $true and the
           projects enumerate. The project system package loads separately from
           the solution, so we poll rather than reading once. If it never
           arrives, the two causes worth naming are a non-interactive session
           (§2.2) and a profile that has never completed TwinCAT's first-run
           setup (§4.1) -- they look identical from here.
    #>
    param(
        [Parameter(Mandatory)] $Dte,
        [int] $TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $sawTsproj = $false
    $announced = $false

    do {
        for ($i = 1; $i -le $Dte.Solution.Projects.Count; $i++) {
            $proj = $null
            try { $proj = $Dte.Solution.Projects.Item($i) } catch { continue }

            $unique = ''
            try { $unique = [string]$proj.UniqueName } catch { }
            $fname = ''
            try { $fname = [string]$proj.FileName } catch { }
            if ($unique -notlike '*.tsproj' -and $fname -notlike '*.tsproj') { continue }
            $sawTsproj = $true

            $obj = $null
            try { $obj = $proj.Object } catch { }
            if ($null -ne $obj) {
                # Confirm it really is ITcSysManager and not some other wrapper.
                try { $null = $obj.GetTargetNetId() } catch {
                    Write-TcLog "warning: .Object present but GetTargetNetId() failed: $($_.Exception.Message)"
                }
                return $obj
            }
        }
        if (-not $announced) {
            Write-TcLog "waiting for the TwinCAT project system to initialise (.Object is null) ..."
            $announced = $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    if (-not $sawTsproj) {
        throw ("no .tsproj project in the solution. Projects seen: " +
               ((1..$Dte.Solution.Projects.Count | ForEach-Object {
                   try { $Dte.Solution.Projects.Item($_).UniqueName } catch { '<unreadable>' }
                 }) -join ', '))
    }

    throw ("the TwinCAT project loaded but ITcSysManager never became available " +
           "within ${TimeoutSeconds}s (.Object stayed null). Two known causes, " +
           "indistinguishable from here:`n" +
           "  1. Non-interactive session (design §2.2) -- this process is in " +
           "session $((Get-Process -Id $PID).SessionId). Run the worker in the " +
           "tcbuild autologon desktop session instead.`n" +
           "  2. TwinCAT first-run setup never completed for this Windows profile " +
           "(design §4.1) -- log in as the build user once, open the solution in " +
           "the XAE Shell by hand and accept every prompt.")
}

function ConvertFrom-TcBuildOutputText {
    <#
        Parses the Output window "Build" pane. TwinCAT 4026's PLC compiler
        prints:

          C:\_tcDeploy\projects\Machine\PLC\POUs\MAIN.TcPOU(18) : error: C0046: Identifier 'x' not defined
          C:\_tcDeploy\projects\Machine\PLC\POUs\MAIN.TcPOU@runStep(163) : warning: C0197: Implicit conversion ...

        i.e.  <file>[@<scope>](<line>) : <severity>: <message>.  The line counts
        from the top of the object's DECLARATION and runs straight on into the
        implementation (18 = 17 declaration lines + implementation line 1), so
        it is NOT an XML line. tcbuild maps it on the Linux side, where the
        file is. MSBuild's  file(line,col): severity CODE: msg  is accepted too.

        Bare "Error: ..." lines are kept only when nothing located was found:
        the system-manager stage prints one whenever the PLC stage fails, and
        next to the real compiler errors that is pure noise.
    #>
    param([string] $Text)
    $found = New-Object System.Collections.Generic.List[object]
    $bare  = New-Object System.Collections.Generic.List[object]
    if (-not $Text) { return @() }
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line -match '^(?<f>[A-Za-z]:\\[^@(]+?|[^@(:]+?)(@(?<scope>[^(]+))?\((?<l>\d+)(,(?<c>\d+))?\)\s*:\s*(?<s>error|warning|message|info)\s*:?\s*(?<m>.*)$') {
            $col = 0;    if ($Matches.ContainsKey('c')     -and $Matches['c'])     { $col   = [int]$Matches['c'] }
            $scope = ''; if ($Matches.ContainsKey('scope') -and $Matches['scope']) { $scope = ([string]$Matches['scope']).Trim() }
            $sev = ([string]$Matches['s']).ToLower(); if ($sev -eq 'info') { $sev = 'message' }
            $found.Add([pscustomobject]@{
                file = ([string]$Matches['f']).Trim(); scope = $scope; line = [int]$Matches['l']; column = $col
                severity = $sev; message = ([string]$Matches['m']).Trim(); project = ''; source = 'Build'
            })
        } elseif ($line -match '^(?<s>error|Error|ERROR)\s*:\s*(?<m>.+)$') {
            $bare.Add([pscustomobject]@{
                file = ''; scope = ''; line = 0; column = 0
                severity = 'error'; message = ([string]$Matches['m']).Trim(); project = ''; source = 'Build'
            })
        }
    }
    if ($found.Count -eq 0) { foreach ($x in $bare) { $found.Add($x) } }
    return @($found.ToArray())
}

function Read-TcErrorListOnce {
    <#  One read of the Error List: typed DTE2 helper first, raw IDispatch
        second. Returns @() and the source name via -Source ref. #>
    param([Parameter(Mandatory)] $Dte, [ref] $Source, [int] $MaxItems = 500)
    $out = New-Object System.Collections.Generic.List[object]

    if (Import-TcDteInterop) {
        try {
            foreach ($m in [TcWorkflow.DteExt]::ReadErrorList($Dte, $MaxItems)) {
                $out.Add([pscustomobject]@{
                    file = [string]$m.File; scope = ''; line = [int]$m.Line; column = [int]$m.Column
                    severity = [string]$m.Severity; message = [string]$m.Message; project = [string]$m.Project
                    source = 'ErrorList'
                })
            }
            $Source.Value = 'ErrorList/DTE2'
            return @($out.ToArray())
        } catch {
            Write-TcLog "Error List via DTE2 failed: $(Get-TcExceptionText $_)"
        }
    }

    try {
        $tw    = Invoke-TcCom -Object $Dte -Member 'ToolWindows'
        $el    = Invoke-TcCom -Object $tw  -Member 'ErrorList'
        $items = Invoke-TcCom -Object $el  -Member 'ErrorItems'
        $n     = [int](Invoke-TcCom -Object $items -Member 'Count')
        if ($n -gt $MaxItems) { $n = $MaxItems }
        for ($i = 1; $i -le $n; $i++) {
            $it  = Invoke-TcCom -Object $items -Member 'Item' -Arguments @($i) -Method
            $lvl = [int](Invoke-TcCom -Object $it -Member 'ErrorLevel')
            # vsBuildErrorLevel: Low=1, Medium=2, High=4
            $sev = 'message'
            if ($lvl -eq 4) { $sev = 'error' } elseif ($lvl -eq 2) { $sev = 'warning' }
            $out.Add([pscustomobject]@{
                file     = [string](Invoke-TcCom -Object $it -Member 'FileName')
                scope    = ''
                line     = [int](Invoke-TcCom -Object $it -Member 'Line')
                column   = [int](Invoke-TcCom -Object $it -Member 'Column')
                severity = $sev
                message  = ([string](Invoke-TcCom -Object $it -Member 'Description')).Trim()
                project  = [string](Invoke-TcCom -Object $it -Member 'Project')
                source   = 'ErrorList'
            })
        }
        $Source.Value = 'ErrorList/IDispatch'
    } catch {
        Write-TcLog "Error List via IDispatch failed: $(Get-TcExceptionText $_)"
        $Source.Value = 'none'
    }
    return @($out.ToArray())
}

function Read-TcOutputPanes {
    <#
        The Output window panes that can carry compiler output, as
        @{ name; text }. Only 'Build' and TwinCAT-named panes are read: the
        others ('Debug', 'Source Control', 'Build Order') have no text
        document until shown and fail with E_FAIL. Needs the DTE2 helper --
        the late-bound Output window has no .Object on this shell.
    #>
    param([Parameter(Mandatory)] $Dte)
    $panes = New-Object System.Collections.Generic.List[object]
    if (-not (Import-TcDteInterop)) { return @() }
    try {
        foreach ($name in [TcWorkflow.DteExt]::OutputPaneNames($Dte)) {
            $n = [string]$name
            if ($n -ne 'Build' -and $n -notlike 'TwinCAT*' -and $n -notlike 'PLC*') { continue }
            $text = ''
            try { $text = [string][TcWorkflow.DteExt]::ReadOutputPane($Dte, $n) } catch {
                Write-TcLog "pane '$n' unreadable: $(Get-TcExceptionText $_)"
            }
            $panes.Add([pscustomobject]@{ name = $n; text = $text })
        }
    } catch {
        Write-TcLog "Output window unreadable: $(Get-TcExceptionText $_)"
    }
    return @($panes.ToArray())
}

function Clear-TcBuildPane {
    <#  Called before Build() so a warm shell cannot show us last job's text. #>
    param([Parameter(Mandatory)] $Dte)
    if (-not (Import-TcDteInterop)) { return }
    try { $null = [TcWorkflow.DteExt]::ClearOutputPane($Dte, 'Build') }
    catch { Write-TcLog "could not clear the Build pane: $(Get-TcExceptionText $_)" }
}

function Get-TcBuildErrors {
    <#
        Design §4.3: the build result as objects with file/line/severity/message.

        Sources, and why in this order (all verified on 4026.27):

        1. Output window 'Build' pane -- PRIMARY. This is where the PLC
           compiler's located diagnostics actually are.
        2. Error List (typed DTE2, else raw IDispatch), re-read until its
           count is stable. On this shell it carries VS-level items only --
           HMI package chatter and a 'Project PLC build failed' summary. It
           never contained a single compiler message across three failed
           builds, so it is secondary: its errors are kept, its warnings are
           kept only when they point at a PLC source file, everything else
           goes to 'notes' so nothing is lost but nothing drowns the agent.

        Returns @{ items; notes } -- both arrays, never $null.
    #>
    param(
        [Parameter(Mandatory)] $Dte,
        [int] $FailedProjects = 0,
        [int] $SettleSeconds = 20
    )
    $out   = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[object]

    # ---- 1. Build pane ---------------------------------------------------------
    foreach ($pane in (Read-TcOutputPanes -Dte $Dte)) {
        $text = $pane.text
        # Belt and braces with Clear-TcBuildPane: only the LAST build's text.
        if ($text) { $idx = $text.LastIndexOf('Build started at'); if ($idx -gt 0) { $text = $text.Substring($idx) } }
        $parsed = @(ConvertFrom-TcBuildOutputText -Text $text)
        Write-TcLog "pane '$($pane.name)': $($parsed.Count) located diagnostic(s)"
        foreach ($m in $parsed) { $out.Add($m) }
        if ($FailedProjects -gt 0 -and @($parsed | Where-Object { $_.severity -eq 'error' }).Count -eq 0 -and $text) {
            # The build failed and this pane did not say why in a form we parse.
            # Put its tail in the job log so the next person sees the raw text.
            $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
            $startAt = [Math]::Max(0, $lines.Count - 40)
            for ($k = $startAt; $k -lt $lines.Count; $k++) { Write-TcLog "  [$($pane.name)] $($lines[$k])" }
        }
    }

    # ---- 2. Error List, only when it might still explain a failure ----------------
    # Five builds on this shell: the Error List never held a compiler message,
    # and a fresh shell was seen with 2283 items of HMI/IntelliSense chatter
    # that took 14 s to walk. So it is consulted only when the build FAILED and
    # the Build pane produced no error -- re-read until stable, since TwinCAT
    # posts to it asynchronously. Otherwise it is not touched at all.
    $paneErrs = @($out | Where-Object { $_.severity -eq 'error' }).Count
    $source = 'skipped'; $items = @(); $reads = 0
    if ($FailedProjects -gt 0 -and $paneErrs -eq 0) {
        $prev = -1
        $deadline = (Get-Date).AddSeconds($SettleSeconds)
        do {
            $src = 'none'
            $items = @(Read-TcErrorListOnce -Dte $Dte -Source ([ref]$src))
            $source = $src
            $reads++
            if ($items.Count -eq $prev) { break }
            $prev = $items.Count
            Start-Sleep -Seconds 2
        } while ((Get-Date) -lt $deadline)
    }

    $kept = 0; $noteCap = 50; $dropped = 0
    foreach ($i in $items) {
        $dup = $out | Where-Object { $_.message -eq $i.message -and $_.line -eq $i.line -and $_.file -eq $i.file }
        if ($dup) { continue }
        $isSrc = ($i.file -match '\.(TcPOU|TcGVL|TcDUT|TcIO|TcTTO|TcVis|TcPRG|TcGTLO)$')
        if ($i.severity -eq 'error' -or ($i.severity -eq 'warning' -and $isSrc)) { $out.Add($i); $kept++ }
        elseif ($notes.Count -lt $noteCap) { $notes.Add($i) }
        else { $dropped++ }
    }
    if ($source -eq 'skipped') {
        Write-TcLog "Error List: not consulted (build pane already explains the result)"
    } else {
        Write-TcLog "Error List ($source): $($items.Count) item(s) after $reads read(s); $kept kept, $($notes.Count) to notes, $dropped dropped"
    }

    return [pscustomobject]@{ items = @($out.ToArray()); notes = @($notes.ToArray()); notesDropped = $dropped }
}

function Get-TcOutputWindow {
    <#  Late-bound fallback only. $Dte.Windows.Item(<kind guid>) is not reliable
        on the XAE Shell, so walk the window list by kind and then by caption. #>
    param([Parameter(Mandatory)] $Dte)
    $kind = '{34E76E81-EE4A-11D0-AE2E-00A0C90FFFC3}'   # vsWindowKindOutput
    try { $w = $Dte.Windows.Item($kind); if ($w) { return $w } } catch { }
    try {
        for ($i = 1; $i -le $Dte.Windows.Count; $i++) {
            $w = $null
            try { $w = $Dte.Windows.Item($i) } catch { continue }
            try { if ([string]$w.ObjectKind -eq $kind) { return $w } } catch { }
            try { if ([string]$w.Caption -like 'Output*') { return $w } } catch { }
        }
    } catch { }
    return $null
}

function Get-TcBuildOutput {
    param([Parameter(Mandatory)] $Dte)
    $win = Get-TcOutputWindow -Dte $Dte
    if (-not $win) { Write-TcLog "no Output window found on this DTE"; return '' }
    try {
        $ow = $null
        try { $ow = $win.Object } catch { }
        if (-not $ow) { Write-TcLog "Output window has no .Object"; return '' }
        $pane = $null
        foreach ($name in @('Build', 'Output')) {
            try { $pane = $ow.OutputWindowPanes.Item($name); if ($pane) { break } } catch { }
        }
        if (-not $pane) {
            try {
                for ($i = 1; $i -le $ow.OutputWindowPanes.Count; $i++) {
                    $c = $ow.OutputWindowPanes.Item($i)
                    if ([string]$c.Name -like '*Build*') { $pane = $c; break }
                }
            } catch { }
        }
        if (-not $pane) { Write-TcLog "no Build pane in the Output window"; return '' }
        $sel = $pane.TextDocument.Selection
        $sel.StartOfDocument()
        $sel.EndOfDocument($true)
        return [string]$sel.Text
    } catch {
        Write-TcLog "could not read Build output pane: $($_.Exception.Message)"
        return ''
    }
}

function Close-TcDte {
    param($Dte, [switch] $Force)
    if (-not $Dte) { return }
    try { if ($Dte.Solution.IsOpen) { $Dte.Solution.Close($false) } } catch { }
    try { $Dte.Quit() } catch { }
    try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Dte) } catch { }
    if ($Force) { Stop-StaleTcShells }
}
