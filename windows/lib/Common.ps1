<#
    Common.ps1 -- logging and the job-result contract shared by every script.

    Result-writing order matters and is load-bearing: .log and .json are written
    FIRST, .rc LAST. The Linux client polls for .rc, so its appearance is the
    completion barrier -- a client can never read a half-written log.
#>

Set-StrictMode -Version Latest

$script:TcLogPath = $null
$script:TcLogBuffer = [System.Text.StringBuilder]::new()

function Initialize-TcLog {
    param([string] $Path)
    $script:TcLogPath = $Path
    $null = $script:TcLogBuffer.Clear()
    if ($Path) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }
}

function Write-TcLog {
    param([Parameter(ValueFromPipeline)][string] $Message)
    process {
        $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message
        Write-Host $line
        $null = $script:TcLogBuffer.AppendLine($line)
        if ($script:TcLogPath) {
            try { Add-Content -LiteralPath $script:TcLogPath -Value $line -Encoding UTF8 } catch { }
        }
    }
}

function Get-TcLogText { return $script:TcLogBuffer.ToString() }

function Write-TcResult {
    <#
        Publishes a job result. Always call this exactly once per job, from a
        finally block, so a crashed job still produces an .rc the client can see
        instead of hanging until the wrapper's timeout.
    #>
    param(
        [Parameter(Mandatory)][string] $OutDir,
        [Parameter(Mandatory)][string] $JobId,
        [Parameter(Mandatory)][int]    $ExitCode,
        [object] $Data = $null
    )
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

    $logPath  = Join-Path $OutDir "$JobId.log"
    $jsonPath = Join-Path $OutDir "$JobId.json"
    $rcPath   = Join-Path $OutDir "$JobId.rc"

    try {
        if (-not (Test-Path $logPath)) {
            Set-Content -LiteralPath $logPath -Value (Get-TcLogText) -Encoding UTF8
        }
    } catch { }

    if ($null -ne $Data) {
        try {
            $Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
        } catch {
            Write-Host "WARN: could not serialise result JSON: $($_.Exception.Message)"
        }
    }

    # LAST. This is the completion signal.
    Set-Content -LiteralPath $rcPath -Value ([string]$ExitCode) -Encoding ASCII
}

function Test-TcAdmin {
    # Never throws: this feeds the startup diagnostics, and a diagnostic that
    # dies tells you nothing about the environment you were trying to diagnose.
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-TcSessionInfo {
    <#
        Reports whether this process can actually drive a GUI COM server
        (design §2.2). Session 0 or no visible window station == the automation
        will hang on the first modal dialog.
    #>
    $sid = -1
    try { $sid = (Get-Process -Id $PID).SessionId } catch { }
    $apt = 'Unknown'
    try { $apt = [System.Threading.Thread]::CurrentThread.GetApartmentState().ToString() } catch { }
    return [pscustomobject]@{
        sessionId   = $sid
        interactive = [Environment]::UserInteractive
        isSession0  = ($sid -eq 0)
        apartment   = $apt
        user        = [Environment]::UserName
        isAdmin     = (Test-TcAdmin)
        psVersion   = $PSVersionTable.PSVersion.ToString()
    }
}

function Get-TcExceptionText {
    <#
        The whole InnerException chain on one line. PowerShell wraps COM and
        .NET failures in MethodInvocationException and friends, so the outer
        message alone is usually just "Exception calling X with N argument(s)".
        Not Mandatory on purpose: a Mandatory parameter that receives $null
        PROMPTS, and a prompt inside the worker is a hang.
    #>
    param($ErrorRecordOrException)
    $e = $ErrorRecordOrException
    if ($e -is [System.Management.Automation.ErrorRecord]) { $e = $e.Exception }
    $parts = New-Object System.Collections.Generic.List[string]
    while ($e) {
        if ($e.Message) { $parts.Add($e.Message.Trim()) }
        $e = $e.InnerException
    }
    if ($parts.Count -eq 0) { return '<no message>' }
    return ($parts -join ' <- ')
}

function Test-TcComFailure {
    <#
        True if a COMException sits anywhere in the chain -- the signal that
        the XAE Shell, not our script, is what failed, and that the warm DTE
        must not be trusted for the next job.
    #>
    param($ErrorRecordOrException)
    $e = $ErrorRecordOrException
    if ($e -is [System.Management.Automation.ErrorRecord]) { $e = $e.Exception }
    while ($e) {
        if ($e -is [System.Runtime.InteropServices.COMException]) { return $true }
        $e = $e.InnerException
    }
    return $false
}
