<#  build.ps1 -- direct-mode entry point (TC_MODE=direct). Invoked over SSH.
    In worker mode this file is unused; the worker calls Invoke-TcBuild itself
    against its warm DTE.  #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $JobId,
    [Parameter(Mandatory)][string] $WorkDir,
    [Parameter(Mandatory)][string] $Solution,
    [string] $Root     = 'C:\_tcDeploy',
    [switch] $Clean,
    [switch] $FullSolution
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$lib = Join-Path $PSScriptRoot 'lib'
. (Join-Path $lib 'Common.ps1'); . (Join-Path $lib 'MessageFilter.ps1')
. (Join-Path $lib 'DteHelper.ps1'); . (Join-Path $lib 'BuildOps.ps1')

$OutDir = Join-Path $Root 'out'
Initialize-TcLog -Path (Join-Path $OutDir "$JobId.log")

$rc = 1; $data = $null; $dte = $null
try {
    Enable-TcMessageFilter
    # Direct mode pays a cold shell start per build unless a previous one is
    # still in the ROT -- reuse it when we can.
    $dte = New-TcDte -ReuseRunning
    $data = Invoke-TcBuild -Dte $dte -SolutionPath (Join-Path $WorkDir $Solution) `
                           -Clean:$Clean -FullSolution:$FullSolution
    $rc = $data.rc
}
catch {
    Write-TcLog "build.ps1 FAILED: $($_.Exception.Message)"
    $data = [pscustomobject]@{ error = $_.Exception.Message; errors = @() }
    $rc = 1
}
finally {
    # Leave the shell running so the next direct build can attach to it.
    Disable-TcMessageFilter
    Write-TcResult -OutDir $OutDir -JobId $JobId -ExitCode $rc -Data $data
}
exit $rc
