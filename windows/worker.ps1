<#
    worker.ps1 -- the queue worker (design §4.2).

    Runs inside the tcbuild autologon session, which is the whole point: COM
    automation of the XAE Shell needs an interactive window station (§2.2), and
    SSH cannot provide one. SSH only ever drops job files into $Root\queue and
    reads results out of $Root\out ($Root = C:\_tcDeploy by default).

    MUST run under Windows PowerShell 5.1 (STA). pwsh 7 defaults to MTA and
    CoRegisterMessageFilter will refuse -- see MessageFilter.ps1.

    Start with:  powershell -NoProfile -ExecutionPolicy Bypass -File C:\_tcDeploy\scripts\worker.ps1

    Two hardening rules, both from docs/field-notes.md ("Wedged shell"):
      * The solution is CLOSED at the end of every build/deploy job. Files
        changing under an open solution wedge the shell's next COM call. The
        shell process stays warm; the ~60s solution load is paid per job.
      * Every build/deploy job is armed with a watchdog. If it overruns its
        budget the shell is killed from a timer thread, the stuck COM call
        fails, and the client gets a real result instead of a silent timeout.
#>

[CmdletBinding()]
param(
    [string] $Root       = 'C:\_tcDeploy',
    [string] $WorkDir    = '',      # every job carries its own workdir and solution
    [string] $Solution   = '',
    [int]    $PollMs     = 1000,
    [int]    $DefaultTimeoutSeconds = 900,
    [switch] $VisibleShell
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$lib = Join-Path $PSScriptRoot 'lib'
. (Join-Path $lib 'Common.ps1')
. (Join-Path $lib 'MessageFilter.ps1')
. (Join-Path $lib 'DteHelper.ps1')
. (Join-Path $lib 'BuildOps.ps1')
. (Join-Path $lib 'AdsOps.ps1')
. (Join-Path $lib 'DeployOps.ps1')

$QueueDir = Join-Path $Root 'queue'
$OutDir   = Join-Path $Root 'out'
$StateDir = Join-Path $Root 'state'
foreach ($d in @($QueueDir, $OutDir, $StateDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

Initialize-TcLog -Path (Join-Path $StateDir 'worker.log')

$session = Get-TcSessionInfo
Write-TcLog "worker starting -- user=$($session.user) session=$($session.sessionId) interactive=$($session.interactive) apartment=$($session.apartment) ps=$($session.psVersion)"
if ($session.isSession0) {
    Write-TcLog "FATAL: running in Session 0. COM automation of the XAE Shell will hang here (design §2.2)."
    Write-TcLog "The worker must run inside the tcbuild autologon desktop session."
    exit 2
}

Enable-TcMessageFilter
Write-TcLog "COM message filter registered"

# A shell left over from a previous worker poisons every build after it (§4.2).
Stop-StaleTcShells

$script:Dte      = $null
$script:ProgId   = Resolve-TcDteProgId
Write-TcLog "DTE ProgID: $script:ProgId"

# Load the DTE2 interop up front so a failure to find envdte80.dll shows in the
# worker log at startup, not in the middle of the first failed build.
$null = Import-TcDteInterop

$script:DteMode = ''
function Get-WarmDte {
    <#  Reuse the warm instance, but prove it is alive before trusting it.
        A different start mode / SuppressUI than the warm one gets a fresh shell. #>
    param([string] $StartMode = 'com', [bool] $SuppressUI = $true, [bool] $Visible = [bool]$VisibleShell)
    $mode = "$StartMode|$SuppressUI"
    if ($script:Dte -and $script:DteMode -ne $mode) {
        Write-TcLog "shell mode change ($script:DteMode -> $mode) -- restarting the shell"
        Reset-WarmDte
    }
    if ($script:Dte) {
        try { $null = $script:Dte.Version; return $script:Dte }
        catch { Write-TcLog "warm DTE is dead ($(Get-TcExceptionText $_)) -- recreating"; $script:Dte = $null }
    }
    Stop-StaleTcShells
    $script:Dte = New-TcDte -ProgId $script:ProgId -Visible:$Visible -StartMode $StartMode -SuppressUI $SuppressUI
    $script:DteMode = $mode
    return $script:Dte
}

function Reset-WarmDte {
    Write-TcLog "resetting DTE"
    try { Close-TcDte -Dte $script:Dte -Force } catch { }
    $script:Dte = $null
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}

function Get-JobField {
    <#  $Job.<name> if present, else $Default. StrictMode throws on absent
        members, and the client does not always send every field. #>
    param([Parameter(Mandatory)] $Job, [Parameter(Mandatory)][string] $Name, $Default = $null)
    if ($Job.PSObject.Properties.Name -contains $Name) { return $Job.$Name }
    return $Default
}

function Get-JobStringList {
    <#  A JSON array field as [string[]] -- @() when absent, null or empty.
        ConvertFrom-Json hands back object[] and a function return unrolls it,
        so both ends are pinned down here. #>
    param([Parameter(Mandatory)] $Job, [Parameter(Mandatory)][string] $Name)
    $raw = Get-JobField $Job $Name $null
    if ($null -eq $raw) { return ,[string[]]@() }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($raw)) { $s = [string]$x; if ($s.Trim()) { $list.Add($s.Trim()) } }
    return ,[string[]]$list.ToArray()
}

function Invoke-Job {
    param([Parameter(Mandatory)] $Job, [Parameter(Mandatory)][string] $JobId)

    switch ($Job.type) {

        'build' {
            $mode  = [string](Get-JobField $Job 'shellMode' 'com')
            $sup   = [bool](Get-JobField $Job 'suppressUI' $true)
            $dte   = Get-WarmDte -StartMode $mode -SuppressUI $sup -Visible ([bool](Get-JobField $Job 'visible' $false) -or [bool]$VisibleShell)
            # Multi-project: the job names its tree and solution ($Root\projects\<PROJECT>);
            # the worker's own parameters are only the fallback.
            $wd    = [string](Get-JobField $Job 'workdir'  $WorkDir)
            $sln   = Join-Path $wd ([string](Get-JobField $Job 'solution' $Solution))
            $clean = [bool](Get-JobField $Job 'clean' $false)
            $cfg   = [string](Get-JobField $Job 'configuration' '')
            $plat  = [string](Get-JobField $Job 'platform' '')
            if ([bool](Get-JobField $Job 'visible' $false)) {
                # Diagnostic: some System Manager extensions are VS packages that
                # only initialise with a UI. Show the shell for this job.
                try { $dte.MainWindow.Visible = $true; Write-TcLog "shell main window made visible for this job" } catch { Write-TcLog "could not show the shell window: $(Get-TcExceptionText $_)" }
            }
            $tsp   = [string](Get-JobField $Job 'tsproj' '')
            $mc    = Get-JobStringList $Job 'mustContain'
            try {
                $r = Invoke-TcBuild -Dte $dte -SolutionPath $sln -Clean:$clean -Configuration $cfg -Platform $plat -Tsproj $tsp -MustContain $mc
            } finally {
                Close-TcSolution -Dte $dte
            }
            return @{ rc = $r.rc; data = $r }
        }

        'probe' {
            $dte = Get-WarmDte -StartMode ([string](Get-JobField $Job 'shellMode' 'com')) -SuppressUI ([bool](Get-JobField $Job 'suppressUI' $true)) -Visible ([bool](Get-JobField $Job 'visible' $false) -or [bool]$VisibleShell)
            $wd  = [string](Get-JobField $Job 'workdir' $WorkDir)
            $sln = Join-Path $wd ([string](Get-JobField $Job 'solution' $Solution))
            try {
                $r = Invoke-TcProbe -Dte $dte -SolutionPath $sln -Configuration ([string](Get-JobField $Job 'configuration' '')) -Platform ([string](Get-JobField $Job 'platform' '')) -Tsproj ([string](Get-JobField $Job 'tsproj' ''))
            } finally { Close-TcSolution -Dte $dte }
            return @{ rc = $r.rc; data = $r }
        }

        'status' {
            $port = [int](Get-JobField $Job 'plcport' 851)
            $gb   = Get-JobStringList $Job 'guardBools'
            $gs   = Get-JobStringList $Job 'guardStrings'
            $hb   = Get-JobStringList $Job 'healthBools'
            $hn   = [string](Get-JobField $Job 'hostnameSymbol' '')
            $st = Get-TcAdsStatus -NetId $Job.netid -PlcPort $port -GuardBools $gb -GuardStrings $gs -HostnameSymbol $hn -HealthBools $hb
            return @{ rc = $(if ($st.error) { 1 } else { 0 }); data = $st }
        }

        'deploy' {
            # Deploys the SYNCED tree. tcdeploy on Linux has already proven the
            # tree is clean at a pushed sha, synced with --full and confirmed with the operator. The box verifies the
            # bytes against the sync manifest, clean-builds, guards, activates.
            $dte      = Get-WarmDte -StartMode ([string](Get-JobField $Job 'shellMode' 'com')) -SuppressUI ([bool](Get-JobField $Job 'suppressUI' $true))
            $port     = [int](Get-JobField $Job 'plcport' 851)
            $wd       = [string](Get-JobField $Job 'workdir'  $WorkDir)
            $slnName  = [string](Get-JobField $Job 'solution' $Solution)
            $manifest = [string](Get-JobField $Job 'manifest' (Join-Path $StateDir 'manifest.sha256'))
            $sha      = [string](Get-JobField $Job 'sha' '')
            $gb       = Get-JobStringList $Job 'guardBools'
            $gs       = Get-JobStringList $Job 'guardStrings'
            $cfg      = [string](Get-JobField $Job 'configuration' 'Release')
            $plat     = [string](Get-JobField $Job 'platform' '')
            $hnSym    = [string](Get-JobField $Job 'hostnameSymbol' '')
            $hnExp    = [string](Get-JobField $Job 'expectedHostname' '')
            $hb       = Get-JobStringList $Job 'healthBools'
            $hto      = 60; try { $hto = [int](Get-JobField $Job 'healthTimeout' 60) } catch { }
            try {
                $r = Invoke-TcDeploy -Dte $dte -WorkDir $wd -SolutionName $slnName -Sha $sha `
                                     -NetId $Job.netid -PlcPort $port -ManifestPath $manifest `
                                     -GuardBools $gb -GuardStrings $gs -Configuration $cfg -Platform $plat `
                                     -Tsproj ([string](Get-JobField $Job 'tsproj' '')) -MustContain (Get-JobStringList $Job 'mustContain') `
                                     -HostnameSymbol $hnSym -ExpectedHostname $hnExp -HealthBools $hb -HealthTimeoutSeconds $hto
            } finally {
                Close-TcSolution -Dte $dte
            }
            return @{ rc = $r.rc; data = $r }
        }

        default { throw "unknown job type: '$($Job.type)'" }
    }
}

Write-TcLog "watching $QueueDir"

while ($true) {
    $files = @(Get-ChildItem -Path $QueueDir -Filter '*.job' -File -ErrorAction SilentlyContinue |
               Sort-Object CreationTimeUtc)

    if ($files.Count -eq 0) { Start-Sleep -Milliseconds $PollMs; continue }

    foreach ($f in $files) {
        $jobId = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $rc    = 1
        $data  = $null
        $running = Join-Path $StateDir "$jobId.running"
        $watchdogSeconds = 0

        # Per-job log, separate from the worker's own rolling log.
        Initialize-TcLog -Path (Join-Path $OutDir "$jobId.log")

        try {
            $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop
            $job = $raw | ConvertFrom-Json
            Set-Content -LiteralPath $running -Value ((Get-Date).ToString('o')) -Encoding ASCII

            Write-TcLog "job $jobId type=$($job.type)"

            # Arm the watchdog just inside the client's own timeout, so the
            # client sees a result (rc=1 + reason) rather than its own timeout.
            if ($job.type -in @('build', 'deploy', 'probe')) {
                $budget = $DefaultTimeoutSeconds
                try { $budget = [int](Get-JobField $job 'timeout' $DefaultTimeoutSeconds) } catch { }
                $watchdogSeconds = [Math]::Max(60, $budget - 30)
                Start-TcWatchdog -Seconds $watchdogSeconds
                Write-TcLog "watchdog armed: ${watchdogSeconds}s"
            }

            $res  = Invoke-Job -Job $job -JobId $jobId
            $rc   = [int]$res.rc
            $data = $res.data
        }
        catch {
            $msg = Get-TcExceptionText $_
            $wedged = Test-TcWatchdogFired
            if ($wedged) {
                $msg = ("job exceeded the ${watchdogSeconds}s watchdog -- the XAE Shell was killed " +
                        "($([TcWorkflow.Watchdog]::KilledCount) process(es)) to unblock the worker. " +
                        "Wedged-shell pattern (docs/field-notes.md): did files change under an open solution? " +
                        "Stuck call reported: $msg")
            }
            Write-TcLog "job $jobId FAILED: $msg"
            Write-TcLog ($_.ScriptStackTrace | Out-String)
            $rc   = 1
            $data = [pscustomobject]@{ error = $msg; errors = @(); wedged = $wedged }
            # A COM-level failure means the shell is suspect; do not let it
            # poison the next job (§4.2 try/finally + kill stale shells).
            if ($wedged -or (Test-TcComFailure $_)) { Reset-WarmDte }
        }
        finally {
            Stop-TcWatchdog
            # Always publish a result. A job that dies silently would otherwise
            # hang the client until its wall-clock timeout.
            try { Write-TcResult -OutDir $OutDir -JobId $jobId -ExitCode $rc -Data $data } catch { }
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $running    -Force -ErrorAction SilentlyContinue
            Initialize-TcLog -Path (Join-Path $StateDir 'worker.log')
            Write-TcLog "job $jobId done rc=$rc"
        }
    }
}
