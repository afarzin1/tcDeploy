<#  reset.ps1 -- unwedge the build box.

    The honest answer to "the XAE Shell hung". Kills every shell process and
    clears the queue so the worker (restarted by its scheduled task) comes back
    clean. Invoked from Linux by `tcreset`. #>
[CmdletBinding()]
param([string] $Root = 'C:\_tcDeploy', [switch] $KeepQueue)
$ErrorActionPreference = 'Continue'

$lib = Join-Path $PSScriptRoot 'lib'
. (Join-Path $lib 'Common.ps1'); . (Join-Path $lib 'DteHelper.ps1')
Initialize-TcLog

Stop-StaleTcShells
# Get-Process does NOT expose CommandLine on Windows PowerShell 5.1 -- that
# property only exists on the .NET Process object in PS 7+. Matching on it here
# silently matched nothing, so the worker was never actually killed and kept
# running stale dot-sourced code. Win32_Process is the 5.1-correct source.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*worker.ps1*' } |
    ForEach-Object {
        Write-TcLog "killing worker pid=$($_.ProcessId)"
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { Write-TcLog "  kill failed: $($_.Exception.Message)" }
    }

if (-not $KeepQueue) {
    Get-ChildItem (Join-Path $Root 'queue') -Filter '*.job' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Write-TcLog "discarding queued job $($_.Name)"; Remove-Item $_.FullName -Force }
}
Get-ChildItem (Join-Path $Root 'state') -Filter '*.running' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

$task = Get-ScheduledTask -TaskName 'TcWorkflowWorker' -ErrorAction SilentlyContinue
if ($task) { Write-TcLog "restarting TcWorkflowWorker scheduled task"; Start-ScheduledTask -TaskName 'TcWorkflowWorker' }
else       { Write-TcLog "no TcWorkflowWorker task registered -- start the worker by hand" }
Write-TcLog "reset complete"
