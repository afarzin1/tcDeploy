<#
    AdsOps.ps1 -- ADS reads against the target (design §4.4 pre-flight).

    The guard is FAIL-SAFE by construction: if the target cannot be reached, or
    a guard symbol cannot be read, Test-TcDeployGuard REFUSES the deploy. An
    unreadable rig is not a safe rig -- it is an unknown one, and this restarts
    a PLC attached to physical hardware.
#>

Set-StrictMode -Version Latest

$script:TcAdsLoaded = $false

function Test-TcAdsAssemblyUsable {
    <#
        TwinCAT.Ads 4.x/5.x are .NET Framework builds; 6.x and 7.x are .NET
        Standard 2.0 builds whose dependency set is not installed here. The
        assembly version is readable from the file header without loading
        anything (reflection-only loading was tried and needs every dependency
        resolved by hand, which defeats the purpose).
    #>
    param([Parameter(Mandatory)][string] $Path)
    try {
        $v = [Reflection.AssemblyName]::GetAssemblyName($Path).Version
        return ($v.Major -ge 4 -and $v.Major -lt 6)
    } catch { return $false }
}

function Import-TcAdsAssembly {
    <#
        Loads a TwinCAT.Ads.dll that Windows PowerShell 5.1 can actually use.

        Learned on 4026.27: a typical box holds 20+ copies. The newest
        (v6/v7) are .NET Standard 2.0 builds whose dependencies (System.Memory,
        TwinCAT.Ads.Abstractions, Microsoft.Extensions.*) are NOT installed, so
        Add-Type on them dies with "Unable to load one or more of the requested
        types". The v4.3.x .NET Framework builds under Components\Base\v1xx
        load and run. Pick by API generation, not by highest version.
    #>
    if ($script:TcAdsLoaded) { return }
    $roots = @('C:\Program Files (x86)\Beckhoff\TwinCAT\3.1', 'C:\Program Files\Beckhoff\TwinCAT\3.1', 'C:\TwinCAT')
    $preferred = @()
    foreach ($r in $roots) {
        $preferred += (Join-Path $r 'Components\Base\v170\TwinCAT.Ads.dll')
        $preferred += (Join-Path $r 'Components\Base\v160\TwinCAT.Ads.dll')
        $preferred += (Join-Path $r 'Components\Base\v150\TwinCAT.Ads.dll')
        $preferred += (Join-Path $r 'AdsApi\.NET\v4.0.30319\TwinCAT.Ads.dll')
    }
    $preferred += 'C:\TwinCAT\AdsApi\.NET\v4.0.30319\TwinCAT.Ads.dll'

    $dll = $null
    foreach ($c in $preferred) {
        if ((Test-Path -LiteralPath $c) -and (Test-TcAdsAssemblyUsable -Path $c)) { $dll = $c; break }
    }
    if (-not $dll) {
        # Unknown layout: search, keep only 4.x/5.x builds, newest first.
        $found = foreach ($root in @('C:\Program Files (x86)\Beckhoff', 'C:\Program Files\Beckhoff', 'C:\TwinCAT')) {
            if (Test-Path $root) { Get-ChildItem -Path $root -Filter 'TwinCAT.Ads.dll' -Recurse -ErrorAction SilentlyContinue }
        }
        $dll = $found |
               Where-Object { Test-TcAdsAssemblyUsable -Path $_.FullName } |
               Sort-Object { [version]$_.VersionInfo.FileVersion } -Descending |
               Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $dll) { throw "no TwinCAT.Ads.dll 4.x/5.x (.NET Framework) found -- the 6.x/7.x .NET Standard builds cannot load under Windows PowerShell 5.1" }

    Write-TcLog "loading ADS assembly: $dll (v$([Diagnostics.FileVersionInfo]::GetVersionInfo($dll).FileVersion))"
    Add-Type -Path $dll -ErrorAction Stop
    $script:TcAdsLoaded = $true
}

function New-TcAdsClient {
    param([Parameter(Mandatory)][string] $NetId, [Parameter(Mandatory)][int] $Port)
    Import-TcAdsAssembly
    # TwinCAT.Ads 6.x renamed TcAdsClient -> AdsClient; support both.
    $type = @('TwinCAT.Ads.AdsClient', 'TwinCAT.Ads.TcAdsClient') |
            ForEach-Object { $_ -as [type] } | Where-Object { $_ } | Select-Object -First 1
    if (-not $type) { throw "neither TwinCAT.Ads.AdsClient nor TcAdsClient present in the loaded assembly" }

    $client = [Activator]::CreateInstance($type)
    $client.Connect($NetId, $Port)
    return $client
}

function Read-TcSymbol {
    <#  Reads one symbol by name. Returns $null and logs if it cannot be read. #>
    param(
        [Parameter(Mandatory)] $Client,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][type]   $Type,
        [int] $StringLength = 255
    )
    $handle = $null
    try {
        $handle = $Client.CreateVariableHandle($Name)
        if ($Type -eq [string]) {
            return $Client.ReadAny($handle, [string], @([int]$StringLength))
        }
        return $Client.ReadAny($handle, $Type)
    } catch {
        Write-TcLog "symbol read FAILED '$Name': $($_.Exception.Message)"
        return $null
    } finally {
        if ($null -ne $handle) { try { $Client.DeleteVariableHandle($handle) } catch { } }
    }
}

function Get-TcAdsStatus {
    <#
        Reads system state (port 10000), PLC state (port 851) and the guard
        symbols. Never throws -- returns an object with .error set instead, so
        tcstatus can report a down target rather than blowing up.
    #>
    param(
        [Parameter(Mandatory)][string] $NetId,
        [int] $PlcPort = 851,
        [string[]] $GuardBools   = @(),
        [string[]] $GuardStrings = @(),
        [string]   $HostnameSymbol = '',
        [string[]] $HealthBools  = @()
    )

    $result = [ordered]@{
        netId       = $NetId
        systemState = 'unknown'
        plcState    = 'unknown'
        hostname    = $null
        guards      = [ordered]@{}
        health      = [ordered]@{}
        error       = $null
    }

    # --- system service (port 10000): Run vs Config ------------------------
    $sys = $null
    try {
        $sys = New-TcAdsClient -NetId $NetId -Port 10000
        $result.systemState = [string]$sys.ReadState().AdsState
    } catch {
        $result.error = "system state unreadable: $($_.Exception.Message)"
    } finally {
        if ($sys) { try { $sys.Dispose() } catch { } }
    }

    # --- PLC runtime (port 851): Run/Stop + guard symbols ------------------
    $plc = $null
    try {
        $plc = New-TcAdsClient -NetId $NetId -Port $PlcPort
        $result.plcState = [string]$plc.ReadState().AdsState

        foreach ($sym in $GuardBools)   { if ($sym) { $result.guards[$sym] = Read-TcSymbol -Client $plc -Name $sym -Type ([bool]) } }
        foreach ($sym in $GuardStrings) { if ($sym) { $result.guards[$sym] = Read-TcSymbol -Client $plc -Name $sym -Type ([string]) } }
        if ($HostnameSymbol) { $h = Read-TcSymbol -Client $plc -Name $HostnameSymbol -Type ([string]); if ($null -ne $h) { $result.hostname = ([string]$h).Trim() } }
        foreach ($sym in $HealthBools)  { if ($sym) { $result.health[$sym] = Read-TcSymbol -Client $plc -Name $sym -Type ([bool]) } }
    } catch {
        $msg = "plc state unreadable: $($_.Exception.Message)"
        $result.error = if ($result.error) { "$($result.error); $msg" } else { $msg }
    } finally {
        if ($plc) { try { $plc.Dispose() } catch { } }
    }

    return [pscustomobject]$result
}

function Read-TcHostname {
    <#  The machine's identity as the PLC sees it: one STRING symbol (the IPC
        hostname, published by fb_Machine). $null if unreadable. #>
    param([Parameter(Mandatory)][string] $NetId, [int] $PlcPort = 851, [Parameter(Mandatory)][string] $Symbol)
    $plc = $null
    try {
        $plc = New-TcAdsClient -NetId $NetId -Port $PlcPort
        $v = Read-TcSymbol -Client $plc -Name $Symbol -Type ([string])
        if ($null -eq $v) { return $null }
        return ([string]$v).Trim()
    } catch {
        Write-TcLog "hostname read failed: $($_.Exception.Message)"
        return $null
    } finally { if ($plc) { try { $plc.Dispose() } catch { } } }
}

function Wait-TcHealth {
    <#
        Post-activation health: every BOOL in $Symbols must read TRUE within
        $TimeoutSeconds. Returns @{ ok; pending; elapsed }. 'pending' lists the
        symbols still FALSE or unreadable when time ran out. This is what
        "in Run" does not tell you -- e.g. MQTT streams that PLC code starts
        can fail to come back after a cold restart.
    #>
    param(
        [Parameter(Mandatory)][string] $NetId,
        [int] $PlcPort = 851,
        [string[]] $Symbols = @(),
        [int] $TimeoutSeconds = 60
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $pending = @($Symbols | Where-Object { $_ })
    if ($pending.Count -eq 0) { return [pscustomobject]@{ ok = $true; pending = @(); elapsed = 0 } }
    $plc = $null
    try {
        $plc = New-TcAdsClient -NetId $NetId -Port $PlcPort
        while ($true) {
            $still = New-Object System.Collections.Generic.List[string]
            foreach ($s in $pending) {
                $v = Read-TcSymbol -Client $plc -Name $s -Type ([bool])
                if ($v -ne $true) { $still.Add($s) }
            }
            $pending = @($still.ToArray())
            if ($pending.Count -eq 0 -or $sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
            Start-Sleep -Seconds 2
        }
    } catch {
        Write-TcLog "health poll failed: $($_.Exception.Message)"
    } finally { if ($plc) { try { $plc.Dispose() } catch { } } }
    return [pscustomobject]@{ ok = ($pending.Count -eq 0); pending = $pending; elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function Test-TcDeployGuard {
    <#
        Design §4.4: refuse to activate if a test is running or the rig is live.
        Returns @{ ok; reasons; status }. ok=$false means DO NOT DEPLOY.

        This holds even when a human approved the deploy -- the human approved
        deploying the code, not deploying it into a running test.
    #>
    param(
        [Parameter(Mandatory)][string] $NetId,
        [int] $PlcPort = 851,
        [string[]] $GuardBools   = @(),
        [string[]] $GuardStrings = @()
    )

    $status  = Get-TcAdsStatus -NetId $NetId -PlcPort $PlcPort `
                               -GuardBools $GuardBools -GuardStrings $GuardStrings
    $reasons = @()

    if ($status.error) { $reasons += "target not fully readable ($($status.error))" }

    if ($status.plcState -ne 'Run') {
        # Not necessarily unsafe, but it means the rig is not in a known-good
        # state; say so and let the operator decide from the log.
        Write-TcLog "note: PLC state is '$($status.plcState)', not 'Run'"
    }

    foreach ($sym in $GuardBools) {
        if (-not $status.guards.Contains($sym)) { continue }
        $v = $status.guards[$sym]
        if ($null -eq $v)   { $reasons += "guard '$sym' could not be read"; continue }
        if ($v -eq $true)   { $reasons += "guard '$sym' is TRUE -- the rig is busy or energised" }
    }
    foreach ($sym in $GuardStrings) {
        if (-not $status.guards.Contains($sym)) { continue }
        $v = $status.guards[$sym]
        if ($null -eq $v)              { $reasons += "guard '$sym' could not be read"; continue }
        if ([string]$v -ne '')         { $reasons += "guard '$sym' = '$v' -- a test is selected/active" }
    }

    return [pscustomobject]@{
        ok      = ($reasons.Count -eq 0)
        reasons = $reasons
        status  = $status
    }
}
