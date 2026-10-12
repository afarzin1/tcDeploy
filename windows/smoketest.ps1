<#
    smoketest.ps1 -- design §7 step 1, the experiment the architecture hinges on.

    Question: can a NETWORK LOGON (SSH) drive the XAE Shell's DTE, or does
    Session 0 isolation (§2.2) force us into the autologon + worker model?

    Run it twice: once over SSH, once in the console session. Compare.
    Every stage prints PASS/FAIL so a hang is attributable to a specific call
    rather than just "it stopped".
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $WorkDir,
    [Parameter(Mandatory)][string] $Solution,
    [switch] $TryBuild,
    [switch] $Json
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$lib = Join-Path $PSScriptRoot 'lib'
. (Join-Path $lib 'Common.ps1')
. (Join-Path $lib 'MessageFilter.ps1')
. (Join-Path $lib 'DteHelper.ps1')
. (Join-Path $lib 'BuildOps.ps1')
Initialize-TcLog

$stages = [ordered]@{}
function Stage {
    param([string] $Name, [scriptblock] $Body)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $v = & $Body
        $sw.Stop()
        $stages[$Name] = @{ ok = $true; ms = $sw.ElapsedMilliseconds; value = "$v" }
        Write-TcLog ("PASS  {0,-24} {1,6}ms  {2}" -f $Name, $sw.ElapsedMilliseconds, $v)
        return $v
    } catch {
        $sw.Stop()
        $stages[$Name] = @{ ok = $false; ms = $sw.ElapsedMilliseconds; error = $_.Exception.Message }
        Write-TcLog ("FAIL  {0,-24} {1,6}ms  {2}" -f $Name, $sw.ElapsedMilliseconds, $_.Exception.Message)
        throw
    }
}

$s = Get-TcSessionInfo
Write-TcLog "=== environment ==="
Write-TcLog "user=$($s.user) session=$($s.sessionId) interactive=$($s.interactive)"
Write-TcLog "apartment=$($s.apartment) admin=$($s.isAdmin) ps=$($s.psVersion)"
Write-TcLog "session0=$($s.isSession0)  <- if True, GUI COM is expected to hang"
Write-TcLog "=== stages ==="

$dte = $null
$verdict = 'unknown'
try {
    Stage 'message-filter'  { Enable-TcMessageFilter; 'registered' } | Out-Null
    $progId = Stage 'resolve-progid' { Resolve-TcDteProgId }
    $dte    = Stage 'create-dte'     { New-TcDte -ProgId $progId }
    Stage 'dte-version'     { $dte.Version } | Out-Null
    Stage 'open-solution'   { Open-TcSolution -Dte $dte -SolutionPath (Join-Path $WorkDir $Solution); 'opened' } | Out-Null
    $n = Stage 'project-count' { $dte.Solution.Projects.Count }
    Stage 'sysmanager'      { $null = Get-TcSysManager -Dte $dte; 'ITcSysManager OK' } | Out-Null

    if ($TryBuild) {
        $b = Stage 'build' { $r = Invoke-TcBuild -Dte $dte -SolutionPath (Join-Path $WorkDir $Solution)
                             "rc=$($r.rc) errors=$(@($r.errors | Where-Object severity -eq 'error').Count) in $($r.elapsed)s" }
    }
    $verdict = 'direct'
}
catch {
    $verdict = 'worker'
}
finally {
    if ($dte) { try { Close-TcDte -Dte $dte } catch { } }
    Disable-TcMessageFilter
}

Write-TcLog "=== verdict ==="
if ($verdict -eq 'direct') {
    Write-TcLog "DTE driven successfully from this session type."
    Write-TcLog "If this ran over SSH, you can set TC_MODE=direct and skip most of design §4.2."
} else {
    Write-TcLog "Could not drive the DTE from this session."
    Write-TcLog "Use TC_MODE=worker: autologon session + worker.ps1 (design §4.2)."
}

if ($Json) {
    [pscustomobject]@{ verdict = $verdict; environment = $s; stages = $stages } | ConvertTo-Json -Depth 6
}
exit $(if ($verdict -eq 'direct') { 0 } else { 1 })
