<#  ads-status.ps1 -- direct-mode entry point for tcstatus. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $JobId,
    [Parameter(Mandatory)][string] $NetId,
    [int]    $PlcPort = 851,
    [string] $Root = 'C:\_tcDeploy',
    [string] $GuardBools   = '',
    [string] $GuardStrings = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$lib = Join-Path $PSScriptRoot 'lib'
. (Join-Path $lib 'Common.ps1'); . (Join-Path $lib 'AdsOps.ps1')

$OutDir = Join-Path $Root 'out'
Initialize-TcLog -Path (Join-Path $OutDir "$JobId.log")

$rc = 1; $data = $null
try {
    $data = Get-TcAdsStatus -NetId $NetId -PlcPort $PlcPort `
            -GuardBools   ($GuardBools   -split '\s+' | Where-Object { $_ }) `
            -GuardStrings ($GuardStrings -split '\s+' | Where-Object { $_ })
    $rc = if ($data.error) { 1 } else { 0 }
}
catch {
    $data = [pscustomobject]@{ error = $_.Exception.Message }
}
finally { Write-TcResult -OutDir $OutDir -JobId $JobId -ExitCode $rc -Data $data }
exit $rc
