<#
    screen.ps1 -- eyes (and a finger) on the build user's desktop, for tcscreen.

    Runs INSIDE the interactive worker session (session 1), launched by a
    one-off scheduled task that tcscreen registers over SSH -- an SSH logon is
    session 0 and cannot see or touch that desktop. It never goes through the
    job queue, because the moment you need it is when the worker is wedged.

    Reads <Dir>\request.json, writes into <Dir>:
      desktop.png          the whole desktop
      win-<n>.png          each visible top-level window of the target process,
                           rendered with PrintWindow, so a window that is
                           off-screen or behind Server Manager still shows
      windows.txt          every such window: title, class, rect, and the
                           text/buttons/edit boxes inside it (UI Automation)
      action.txt           what the requested action did (if one was asked)
      done.txt             written LAST; its content is the exit code

    The shell the worker drives is invisible (visible=False), so its modal
    dialogs are separate top-level windows, often untitled WPF HwndWrappers.
    UI Automation is how their text is read, and it can hang against a shell
    that is stuck in a COM call -- so every UIA walk runs in its own runspace
    with a timeout.

    Actions (one per run, followed by a fresh capture so the result is visible):
      click  press the button whose name matches (case-insensitive, '&' ignored)
      type   set the text of an edit box (ValuePattern; the first enabled one,
             or the one whose name/automation id matches 'field')
      key    SendKeys syntax to the target window ({ENTER}, {ESC}, %{F4})
#>
param([Parameter(Mandatory)][string]$Dir)

$ErrorActionPreference = 'Stop'
$req = Get-Content -LiteralPath (Join-Path $Dir 'request.json') -Raw | ConvertFrom-Json
$procName    = if ($req.process) { [string]$req.process } else { 'TcXaeShell' }
$windowMatch = [string]$req.window
$uiaTimeout  = if ($req.uiaTimeout) { [int]$req.uiaTimeout } else { 8 }
$rc = 0

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class TcScreenW32 {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc p, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr SendMessageStr(IntPtr h, uint msg, IntPtr w, string l);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
    public static string Text(IntPtr h)  { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
    public static string Class(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256);  return s.ToString(); }
    public static List<IntPtr> TopLevel() { var l = new List<IntPtr>(); EnumWindows((h, x) => { l.Add(h); return true; }, IntPtr.Zero); return l; }
    public static List<IntPtr> Children(IntPtr p) { var l = new List<IntPtr>(); EnumChildWindows(p, (h, x) => { l.Add(h); return true; }, IntPtr.Zero); return l; }
}
'@

$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s) }

# --- the windows that matter: visible top-level windows of the target process
function Get-TargetWindows {
    $pids = @(Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object Id)
    $out = @()
    foreach ($h in [TcScreenW32]::TopLevel()) {
        if (-not [TcScreenW32]::IsWindowVisible($h)) { continue }
        $procId = [uint32]0; [void][TcScreenW32]::GetWindowThreadProcessId($h, [ref]$procId)
        if ($pids -notcontains [int]$procId) { continue }
        $r = New-Object TcScreenW32+RECT; [void][TcScreenW32]::GetWindowRect($h, [ref]$r)
        $w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
        if ($w -le 1 -or $hgt -le 1) { continue }
        $out += [pscustomobject]@{ Handle = $h; Pid = [int]$procId; Title = [TcScreenW32]::Text($h)
                                   Class = [TcScreenW32]::Class($h); Rect = $r; W = $w; H = $hgt }
    }
    $out
}

# --- UI Automation in a runspace with a timeout: never let a wedged shell hang us
function Invoke-Uia([scriptblock]$Body, [object[]]$ArgList) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript('Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes').AddStatement()
    [void]$ps.AddScript($Body.ToString())
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    $async = $ps.BeginInvoke()
    if (-not $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($uiaTimeout))) {
        # Stop() would block on the same hung call; abandon the runspace instead.
        return [pscustomobject]@{ TimedOut = $true; Output = @(); Error = "UI Automation did not answer within ${uiaTimeout}s (the shell is probably stuck in a call)" }
    }
    $o = @($ps.EndInvoke($async))
    $e = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
    $ps.Dispose()
    [pscustomobject]@{ TimedOut = $false; Output = $o; Error = $e }
}

$DumpBody = {
    param([long]$hwnd)
    $ae = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd)
    $all = $ae.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $n = 0
    foreach ($e in $all) {
        if (++$n -gt 400) { '  ... (truncated at 400 elements)'; break }
        $c = $e.Current
        $type = $c.ControlType.ProgrammaticName -replace '^ControlType\.', ''
        $val = ''
        if ($type -eq 'Edit') {
            $vp = $null
            if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { $val = " = '$($vp.Current.Value)'" }
        }
        if (-not $c.Name -and -not $val -and $type -notin 'Button', 'Edit') { continue }
        $id = if ($c.AutomationId) { " #$($c.AutomationId)" } else { '' }
        $dis = if ($c.IsEnabled) { '' } else { ' (disabled)' }
        "  [$type]$id '$($c.Name)'$val$dis"
    }
}

function Save-Bitmap($bmp, [string]$name) { $bmp.Save((Join-Path $Dir $name), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose() }

function Capture([string]$prefix) {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size); $g.Dispose()
    Save-Bitmap $bmp "${prefix}desktop.png"

    $wins = @(Get-TargetWindows)
    Say "== ${prefix}capture $(Get-Date -Format 'HH:mm:ss')  process=$procName  visible windows=$($wins.Count)"
    $i = 0
    foreach ($w in $wins) {
        $i++
        $png = "${prefix}win-$i.png"
        try {
            $bmp = New-Object System.Drawing.Bitmap $w.W, $w.H
            $g = [System.Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
            $ok = [TcScreenW32]::PrintWindow($w.Handle, $hdc, 2)   # PW_RENDERFULLCONTENT: WPF renders too
            $g.ReleaseHdc($hdc); $g.Dispose()
            if ($ok) { Save-Bitmap $bmp $png } else { $bmp.Dispose(); $png = '(PrintWindow failed)' }
        } catch { $png = "(capture failed: $($_.Exception.Message))" }
        $r = $w.Rect
        Say ""
        Say "[$i] '$($w.Title)'  class=$($w.Class)  pid=$($w.Pid)  rect=($($r.Left),$($r.Top)) $($w.W)x$($w.H)  -> $png"
        foreach ($c in [TcScreenW32]::Children($w.Handle)) {      # classic Win32 dialogs (#32770) answer here, even when UIA hangs
            if (-not [TcScreenW32]::IsWindowVisible($c)) { continue }
            $t = [TcScreenW32]::Text($c); $cls = [TcScreenW32]::Class($c)
            if ($t -or $cls -match 'edit') { Say "  {$cls} '$t'" }
        }
        $d = Invoke-Uia $DumpBody @([long]$w.Handle)
        if ($d.TimedOut) { Say "  ! $($d.Error)" }
        else { $d.Output | ForEach-Object { Say $_ }; if ($d.Error) { Say "  ! UIA: $($d.Error)" } }
    }
    $wins
}

$ActBody = {
    param([long[]]$hwnds, [string]$action, [string]$name, [string]$text, [string]$field)
    $A = [System.Windows.Automation.AutomationElement]
    $norm = { param($s) ($s -replace '&', '').Trim() }
    foreach ($h in $hwnds) {
        $root = $A::FromHandle([IntPtr]$h)
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($e in $all) {
            $c = $e.Current
            if ($action -eq 'click' -and $c.ControlType -eq [System.Windows.Automation.ControlType]::Button -and (& $norm $c.Name) -ieq (& $norm $name)) {
                if (-not $c.IsEnabled) { "FAIL button '$($c.Name)' is disabled"; return }
                $p = $null
                if ($e.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); "OK clicked '$($c.Name)'"; return }
                "FAIL button '$($c.Name)' has no Invoke pattern"; return
            }
            if ($action -eq 'type' -and $c.ControlType -in [System.Windows.Automation.ControlType]::Edit, [System.Windows.Automation.ControlType]::Document -and $c.IsEnabled -and
                (-not $field -or $c.Name -ieq $field -or $c.AutomationId -ieq $field)) {
                $p = $null
                if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p) -and -not $p.Current.IsReadOnly) {
                    $p.SetValue($text); "OK set '$($c.Name)$(if ($c.AutomationId) { " #$($c.AutomationId)" })' ($($text.Length) chars)"; return
                }
            }
        }
    }
    'NOTFOUND'
}

try {
    $action = [string]$req.action
    $wins = @(Capture '')
    if ($action) {
        $targets = @($wins | Where-Object { -not $windowMatch -or $_.Title -like "*$windowMatch*" })
        $result = ''
        if (-not $targets) { $result = "FAIL no visible $procName window$(if ($windowMatch) { " titled *$windowMatch*" })" }
        elseif ($action -eq 'key') {
            $t = $targets[-1]
            [void][TcScreenW32]::SetForegroundWindow($t.Handle); Start-Sleep -Milliseconds 300
            [System.Windows.Forms.SendKeys]::SendWait([string]$req.keys)
            $result = "OK sent keys to '$($t.Title)' [$($t.Class)]"
        } else {
            $a = Invoke-Uia $ActBody @([long[]]@($targets | ForEach-Object { [long]$_.Handle }), $action, [string]$req.name, [string]$req.text, [string]$req.field)
            if ($a.TimedOut) { $result = "FAIL $($a.Error)" }
            else { $result = [string]($a.Output | Select-Object -Last 1); if ($a.Error) { $result += "  ($($a.Error))" } }
            if ($result -eq 'NOTFOUND' -and $action -eq 'click') {
                # Win32 fallback: a classic dialog button, pressed with BM_CLICK
                foreach ($t in $targets) {
                    foreach ($c in [TcScreenW32]::Children($t.Handle)) {
                        if ([TcScreenW32]::Class($c) -eq 'Button' -and ([TcScreenW32]::Text($c) -replace '&', '').Trim() -ieq ([string]$req.name -replace '&', '').Trim()) {
                            [void][TcScreenW32]::SendMessage($c, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
                            $result = "OK clicked '$([TcScreenW32]::Text($c))' (Win32)"; break
                        }
                    }
                    if ($result -ne 'NOTFOUND') { break }
                }
            }
            if ($result -eq 'NOTFOUND' -and $action -eq 'type' -and -not $req.field) {
                # Win32 fallback: an edit box UIA only sees as a bare pane (classic
                # Edit, some WinForms), set with WM_SETTEXT
                foreach ($t in $targets) {
                    $c = [TcScreenW32]::Children($t.Handle) | Where-Object {
                        [TcScreenW32]::Class($_) -match 'edit' -and [TcScreenW32]::IsWindowVisible($_) -and [TcScreenW32]::IsWindowEnabled($_) } | Select-Object -First 1
                    if ($c) {
                        [void][TcScreenW32]::SendMessageStr($c, 0x000C, [IntPtr]::Zero, [string]$req.text)
                        $result = "OK set {$([TcScreenW32]::Class($c))} ($(([string]$req.text).Length) chars, Win32)"; break
                    }
                }
            }
            if ($result -eq 'NOTFOUND') { $result = "FAIL no matching $(if ($action -eq 'click') { "button '$($req.name)'" } else { "editable field$(if ($req.field) { " '$($req.field)'" })" }) in the target window(s)" }
        }
        Set-Content -LiteralPath (Join-Path $Dir 'action.txt') -Value $result
        if ($result -notlike 'OK*') { $rc = 3 }
        Start-Sleep -Milliseconds 1500
        Say ""; Say "== action: $action -> $result"; Say ""
        [void](Capture 'after-')
    }
} catch {
    Say "! screen.ps1 failed: $($_.Exception.Message)"
    $rc = 1
} finally {
    $lines | Set-Content -LiteralPath (Join-Path $Dir 'windows.txt') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Dir 'done.txt') -Value $rc
    [Environment]::Exit($rc)   # abandoned UIA runspaces must not keep the process alive
}
