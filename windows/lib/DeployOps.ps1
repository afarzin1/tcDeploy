<#
    DeployOps.ps1 -- the gated path (design §4.4).

    The box does NOT run git. Every git question -- is the tree clean, is the
    sha pushed, tag the deploy -- is answered on Linux
    by `tcdeploy`, where the repo and the credentials already live. What
    reaches this box is the synced working tree plus a per-file SHA-256
    manifest of exactly the bytes tcsync staged. Verifying the tree against
    that manifest before building is the on-box half of the traceability
    chain: Linux vouches "clean at <sha>", the box proves "and these are
    those bytes". No clone, no credentials, no PATH dependency.
#>

Set-StrictMode -Version Latest

function Test-TcSyncIntegrity {
    <#
        Compares the synced tree with tcsync's manifest.sha256
        ("<sha256>  <relative/path>" per line, forward slashes, staged bytes
        i.e. AFTER CRLF conversion -- so the hashes match what is on disk here).
        Returns @{ ok; checked; missing; mismatched } with the offending paths.
    #>
    param(
        [Parameter(Mandatory)][string] $WorkDir,
        [Parameter(Mandatory)][string] $ManifestPath
    )
    $result = [ordered]@{ ok = $false; checked = 0; missing = @(); mismatched = @(); manifest = $ManifestPath }
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "sync manifest not found: $ManifestPath -- run tcsync (tcdeploy does this for you) before deploying"
    }
    $missing = New-Object System.Collections.Generic.List[string]
    $bad     = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $ManifestPath)) {
        if (-not ($line -match '^(?<h>[0-9a-fA-F]{64})\s+(?<p>.+)$')) { continue }
        $rel  = $Matches['p'].Trim().Replace('/', '\')
        $full = Join-Path $WorkDir $rel
        $result.checked++
        if (-not (Test-Path -LiteralPath $full)) { $missing.Add($rel); continue }
        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        if ($actual -ne $Matches['h'].ToUpperInvariant()) { $bad.Add($rel) }
    }
    $result.missing    = @($missing.ToArray())
    $result.mismatched = @($bad.ToArray())
    $result.ok = ($result.checked -gt 0 -and $missing.Count -eq 0 -and $bad.Count -eq 0)
    return [pscustomobject]$result
}

function Invoke-TcDeploy {
    <#
        Full gated deploy from the SYNCED tree. Returns
        @{ rc; sha; integrity; build; guard; verified; netId }.
        Every refusal path returns a distinct rc so the agent can tell "the rig
        was busy" from "it did not compile".

          0  deployed and verified in Run
          1  build failed
          4  ADS pre-flight guard refused
          5  activated but did not come back to Run
          6  synced tree does not match the manifest tcsync sent
          7  no fresh boot project for the configured platform after the build
          8  the target does not identify as EXPECTED_HOSTNAME (wrong machine?)
         10  the generated configuration is missing parts of the project (e.g. the Analytics node)
          9  in Run, but a health symbol did not go TRUE within the timeout
    #>
    param(
        [Parameter(Mandatory)] $Dte,
        [Parameter(Mandatory)][string] $WorkDir,
        [Parameter(Mandatory)][string] $NetId,
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $SolutionName,
        [string] $Sha = '',
        [int]    $PlcPort = 851,
        [string[]] $GuardBools   = @(),
        [string[]] $GuardStrings = @(),
        [string] $Configuration = 'Release',
        [string] $Platform = '',
        [string] $Tsproj = '',
        [string[]] $MustContain = @(),
        [string] $HostnameSymbol = '',
        [string] $ExpectedHostname = '',
        [string[]] $HealthBools = @(),
        [int] $HealthTimeoutSeconds = 60
    )
    if (-not $Platform) {
        throw ("BUILD_PLATFORM is not set in tcdeploy.conf. A deploy must name the target's runtime platform " +
               "(e.g. 'TwinCAT RT (x64)' for a Windows x64 XAR) so the boot project can be verified before activation.")
    }

    $result = [ordered]@{
        rc = 1; sha = $Sha; netId = $NetId; integrity = $null
        build = $null; hostname = $null; guard = $null; verified = $false; health = $null
    }

    # 1. the bytes are the bytes Linux vouched for ---------------------------
    Write-TcLog "verifying $WorkDir against $ManifestPath"
    $integrity = Test-TcSyncIntegrity -WorkDir $WorkDir -ManifestPath $ManifestPath
    $result.integrity = $integrity
    if (-not $integrity.ok) {
        Write-TcLog "REFUSED: synced tree does not match the manifest -- $($integrity.missing.Count) missing, $($integrity.mismatched.Count) mismatched of $($integrity.checked)"
        foreach ($p in ($integrity.missing    | Select-Object -First 10)) { Write-TcLog "  missing    $p" }
        foreach ($p in ($integrity.mismatched | Select-Object -First 10)) { Write-TcLog "  mismatched $p" }
        $result.rc = 6
        return [pscustomobject]$result
    }
    Write-TcLog "integrity OK -- $($integrity.checked) file(s) match the sync manifest (sha $Sha)"

    # 2. clean build of the TwinCAT project from that tree -------------------
    # Project-only, like tcbuild: ActivateConfiguration() ships the tsproj
    # (system manager + PLC + I/O). HMI and Scope are not part of what is
    # activated and have their own pipelines.
    $sln = Join-Path $WorkDir $SolutionName
    $buildStart = Get-Date
    $build = Invoke-TcBuild -Dte $Dte -SolutionPath $sln -Clean -Configuration $Configuration -Platform $Platform -Tsproj $Tsproj -MustContain $MustContain
    $result.build = $build
    if ($build.rc -ne 0) {
        Write-TcLog "REFUSED: clean rebuild failed -- not activating"
        $result.rc = 1
        return [pscustomobject]$result
    }

    # 2b. the boot project the build just generated must be for the configured
    #     platform. TwinCAT writes it under _Boot\<platform>\; a folder for a
    #     different platform, or stale files, means the shell built something
    #     other than what tcdeploy.conf says the target is. Learned the hard way:
    #     a shell's saved default was 'TwinCAT OS (ARMV8-A)' for an x64 rig.
    $bootRoot = Join-Path $WorkDir '_Boot'
    $bootDir  = Join-Path $bootRoot $Platform
    $bootApp  = Get-ChildItem (Join-Path $bootDir 'Plc') -Filter '*.app' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $have = @(Get-ChildItem $bootRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if (-not $bootApp -or $bootApp.LastWriteTime -lt $buildStart) {
        Write-TcLog "REFUSED: no boot project newer than the build start under _Boot\$Platform (platform folders present: $($have -join ', '))"
        $result.rc = 7
        return [pscustomobject]$result
    }
    Write-TcLog "boot project OK -- _Boot\$Platform\Plc\$($bootApp.Name) written $($bootApp.LastWriteTime.ToString('HH:mm:ss')), $([int]($bootApp.Length/1KB)) KB (folders present: $($have -join ', '))"

    # 2c. and the generated configuration must contain everything the project
    #     asks for -- see Test-TcBootConfigComplete for the outage this caught.
    if ($build.bootConfig -and -not $build.bootConfig.ok) {
        Write-TcLog "REFUSED: the configuration this XAE generated is missing: $($build.bootConfig.missing -join '; '). Activating it would put an incomplete configuration on the target."
        $result.rc = 10
        return [pscustomobject]$result
    }

    # 3a. identity: identical machines run identical code, so the NetId alone
    #     does not prove which rig this is. The PLC publishes its IPC hostname;
    #     it must be the one the operator asked for. Unreadable counts as wrong.
    if ($ExpectedHostname) {
        $hn = Read-TcHostname -NetId $NetId -PlcPort $PlcPort -Symbol $HostnameSymbol
        $result.hostname = $hn
        if (-not $hn -or $hn -ne $ExpectedHostname) {
            Write-TcLog "REFUSED: target $NetId identifies as '$hn' but tcdeploy.conf expects EXPECTED_HOSTNAME='$ExpectedHostname'"
            $result.rc = 8
            return [pscustomobject]$result
        }
        Write-TcLog "identity OK -- target is '$hn'"
    }

    # 3. pre-flight guard, as late as possible -------------------------------
    Write-TcLog "ADS pre-flight guard against $NetId"
    if ($GuardBools.Count -eq 0 -and $GuardStrings.Count -eq 0) {
        Write-TcLog "note: this project defines no guard symbols -- only reachability and state are checked"
    }
    $guard = Test-TcDeployGuard -NetId $NetId -PlcPort $PlcPort -GuardBools $GuardBools -GuardStrings $GuardStrings
    $result.guard = $guard
    if (-not $guard.ok) {
        Write-TcLog "REFUSED by pre-flight guard:"
        $guard.reasons | ForEach-Object { Write-TcLog "  - $_" }
        $result.rc = 4
        return [pscustomobject]$result
    }
    Write-TcLog "guard clear -- rig is idle"

    # 4. the irreversible part -----------------------------------------------
    $null = Invoke-TcActivate -Dte $Dte -SolutionPath $sln -NetId $NetId -Platform $Platform

    # 5. verify it came back --------------------------------------------------
    # Both states must read Run, on consecutive polls. The restart is
    # asynchronous: a poll right after StartRestartTwinCAT() can still see the
    # OLD runtime ('system=unknown plc=Run' was once taken as success).
    # Once the restart has been seen (any poll not Run/Run), two in a row
    # suffice; if it never was, demand four, so a pre-restart reading cannot pass.
    Write-TcLog "waiting for target to return to Run"
    $verified = $false; $sawRestart = $false; $okStreak = 0
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        $st = Get-TcAdsStatus -NetId $NetId -PlcPort $PlcPort
        Write-TcLog "  system=$($st.systemState) plc=$($st.plcState)"
        if ($st.systemState -eq 'Run' -and $st.plcState -eq 'Run') { $okStreak++ } else { $okStreak = 0; $sawRestart = $true }
        if (($sawRestart -and $okStreak -ge 2) -or $okStreak -ge 4) { $verified = $true; break }
    }
    $result.verified = $verified
    if (-not $verified) {
        Write-TcLog "ACTIVATED but target did not reach Run within 60s -- inspect the rig"
        $result.rc = 5
        return [pscustomobject]$result
    }

    # 6b. health: Run is necessary, not sufficient. The project names the
    #     symbols that prove the machine came back whole (streams started,
    #     identity acquired, ...). Wait for them; report which did not.
    if (@($HealthBools | Where-Object { $_ }).Count -gt 0) {
        Write-TcLog "waiting up to ${HealthTimeoutSeconds}s for health symbols: $($HealthBools -join ', ')"
        $health = Wait-TcHealth -NetId $NetId -PlcPort $PlcPort -Symbols $HealthBools -TimeoutSeconds $HealthTimeoutSeconds
        $result.health = $health
        if (-not $health.ok) {
            Write-TcLog "ACTIVATED and in Run, but not healthy after $($health.elapsed)s -- still FALSE/unreadable: $($health.pending -join ', ')"
            $result.rc = 9
            return [pscustomobject]$result
        }
        Write-TcLog "health OK after $($health.elapsed)s"
    }

    $result.rc = 0
    Write-TcLog "DEPLOY OK -- $Sha is live on $NetId (tcdeploy records the tag on Linux)"
    return [pscustomobject]$result
}
