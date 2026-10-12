<#
    BuildOps.ps1 -- build and activate, as functions so the worker can drive
    them against a warm DTE (design §4.2 item 3) instead of paying the tsproj
    load on every job.
#>

Set-StrictMode -Version Latest

function Write-TcOutputPaneNotes {
    <#  Logs the notable lines of an Output pane: everything that is not a
        routine variable-link message -- extension loading, TcCOM objects,
        versions, warnings, errors. #>
    param([Parameter(Mandatory)] $Dte, [string] $PaneName = 'TwinCAT', [string] $Label = 'pane', [int] $Max = 60)
    try {
        foreach ($pane in (Read-TcOutputPanes -Dte $Dte)) {
            if ($pane.name -ne $PaneName) { continue }
            $lines = @(($pane.text -split "`r?`n") | Where-Object { $_.Trim() })
            $notable = @($lines | Where-Object { $_ -notmatch "linked with" -and $_ -match '(?i)analytic|error|warn|fail|not (supported|found|loaded|registered|installed)|extension|version|unknown|ignored|skipp|TcCom|object|license' })
            Write-TcLog "$Label : $($lines.Count) line(s), $($notable.Count) notable"
            foreach ($ln in ($notable | Select-Object -First $Max)) { Write-TcLog "  [$PaneName] $ln" }
        }
    } catch { Write-TcLog "$Label unreadable: $(Get-TcExceptionText $_)" }
}

function Initialize-TcBootRepository {
    <#
        Root cause of a real outage, found by bisecting a developer's working
        clone against the synced tree: the TF3500 Analytics Logger
        extension only generates its stream TcCOM objects when the driver's TMX
        for the target platform already exists in the PROJECT's boot repository,
            _Boot\<platform>\Repository\<vendor>\<module>\<version>\<module>.tmx
        An interactive first activation leaves that file behind; a fresh tree or
        clone never has it, and the extension then silently emits nothing. So,
        before every build: for each driver the .tsproj asks for, copy its TMX
        from the machine repository (C:\ProgramData\Beckhoff\TwinCAT\3.1\Repository)
        into the project's boot repository if it is not there yet.
        Today this knows the Analytics node (<SelectedDriverVersion>); extend the
        table when another extension turns out to behave the same way.
    #>
    param(
        [Parameter(Mandatory)][string] $WorkDir,
        [Parameter(Mandatory)][string] $Platform,
        [string] $TsprojPath = ''
    )
    $machineRepo = 'C:\ProgramData\Beckhoff\TwinCAT\3.1\Repository'
    $wanted = New-Object System.Collections.Generic.List[object]
    if ($TsprojPath -and (Test-Path -LiteralPath $TsprojPath)) {
        $ts = [IO.File]::ReadAllText($TsprojPath)
        $aly = [regex]::Match($ts, '(?s)<Analytics\b.*?</Analytics>')
        if ($aly.Success) {
            foreach ($vm in [regex]::Matches($aly.Value, '<SelectedDriverVersion>([^<]+)</SelectedDriverVersion>')) {
                $wanted.Add([pscustomobject]@{ vendor = 'Beckhoff Automation GmbH'; module = 'TcAnalytics'; version = $vm.Groups[1].Value.Trim() })
            }
        }
    }
    $done = 0
    foreach ($w in ($wanted | Sort-Object { "$($_.vendor)|$($_.module)|$($_.version)" } -Unique)) {
        $dst = Join-Path $WorkDir ("_Boot\$Platform\Repository\$($w.vendor)\$($w.module)\$($w.version)\$($w.module).tmx")
        if (Test-Path -LiteralPath $dst) { Write-TcLog "boot repository: $($w.module) $($w.version) already present"; continue }
        $src = Join-Path $machineRepo "$($w.vendor)\$($w.module)\$($w.version)\$Platform\$($w.module).tmx"
        if (-not (Test-Path -LiteralPath $src)) {
            Write-TcLog "WARNING: boot repository needs $($w.module) $($w.version) for '$Platform' but the machine repository has no $src -- the Analytics node will be dropped (install/upgrade the TMX package on this box)"
            continue
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-TcLog "boot repository primed: $($w.module) $($w.version) for '$Platform' ($([int]((Get-Item $dst).Length/1KB)) KB from the machine repository)"
        $done++
    }
    return $done
}

function Test-TcBootConfigComplete {
    <#
        Compares what the project asks for with what the System Manager actually
        wrote into _Boot\<Platform>\CurrentConfig.xml. Learned the hard way: this
        shell silently dropped the ENTIRE <Analytics> node (33 streams) -- the
        activated target had no stream objects, the PLC's FB_ALYC_MqttStream
        instances never initialised, MQTT went dark. Nothing failed, nothing
        was logged. So: every Analytics stream in the .tsproj must be findable
        (by name or object id) in the generated configuration, plus whatever
        strings the project lists in BOOT_CONFIG_MUST_CONTAIN.
        Returns @{ ok; missing; checked; config }.
    #>
    param(
        [Parameter(Mandatory)][string] $WorkDir,
        [Parameter(Mandatory)][string] $Platform,
        [Parameter(Mandatory)][string] $TsprojPath,
        [string[]] $MustContain = @()
    )
    $cfgPath = Join-Path $WorkDir ("_Boot\" + $Platform + "\CurrentConfig.xml")
    $r = [ordered]@{ ok = $false; missing = @(); checked = 0; config = $cfgPath }
    if (-not (Test-Path -LiteralPath $cfgPath)) { $r.missing = @('CurrentConfig.xml (not generated)'); return [pscustomobject]$r }
    $cfg = [IO.File]::ReadAllText($cfgPath)
    $missing = New-Object System.Collections.Generic.List[string]
    $checked = 0
    foreach ($m in $MustContain) {
        if (-not $m) { continue }
        $checked++
        if ($cfg.IndexOf($m, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $missing.Add("'$m' (BOOT_CONFIG_MUST_CONTAIN)") }
    }
    if (Test-Path -LiteralPath $TsprojPath) {
        $ts  = [IO.File]::ReadAllText($TsprojPath)
        $aly = [regex]::Match($ts, '(?s)<Analytics\b.*?</Analytics>')
        if ($aly.Success) {
            $checked++
            if ($cfg.IndexOf('Analytics', [StringComparison]::OrdinalIgnoreCase) -lt 0) { $missing.Add('the <Analytics> node (no Analytics content at all in CurrentConfig.xml)') }
            foreach ($sm in [regex]::Matches($aly.Value, '(?s)<Stream\b([^>]*)>\s*<Name>([^<]+)</Name>(.*?)</Stream>')) {
                # A stream with no symbols (<SymbolNames/>) is a placeholder the
                # extension rightly turns into nothing; only populated streams
                # must show up in the generated configuration.
                if ($sm.Groups[3].Value -notmatch '<SymbolNames>[^<]{8,}</SymbolNames>') { continue }
                $checked++
                $name = $sm.Groups[2].Value.Trim()
                $oid  = ''
                $om = [regex]::Match($sm.Groups[1].Value, '(?i)oid="#?x?0*([0-9a-f]+)"')
                if ($om.Success) { $oid = $om.Groups[1].Value }
                $found = ($cfg.IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($oid -and ($cfg -match ('(?i)0*' + [regex]::Escape($oid))))
                if (-not $found) { $missing.Add("Analytics stream '$name'") }
            }
        }
    }
    $r.checked = $checked
    $r.missing = @($missing.ToArray())
    $r.ok = ($missing.Count -eq 0)
    return [pscustomobject]$r
}

function Invoke-TcBuild {
    <#
        Design §4.3. Returns @{ rc; errors; elapsed; builtProject }.

        Default builds ONLY the TwinCAT project, not the whole solution. The
        solution also contains HMI (TE2000) and Scope (TE1300); the agent never
        edits those, they roughly double inner-loop time, and requiring their
        toolchains on the build box is an avoidable bring-up dependency.
        -FullSolution restores the design's literal SolutionBuild.Build().
    #>
    param(
        [Parameter(Mandatory)] $Dte,
        [Parameter(Mandatory)][string] $SolutionPath,
        [string] $Configuration = '',
        [string] $Platform = '',
        [string] $Tsproj = '',
        [string[]] $MustContain = @(),
        [switch] $Clean,
        [switch] $FullSolution
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    Open-TcSolution -Dte $Dte -SolutionPath $SolutionPath
    # What the System Manager said while LOADING the project (extensions,
    # unknown nodes, versions). The shell clears this pane when a build starts,
    # so it has to be read here, not after the build.
    Write-TcOutputPaneNotes -Dte $Dte -PaneName 'TwinCAT' -Label 'TwinCAT pane at load'

    $sb = $Dte.Solution.SolutionBuild
    if ($Configuration -and $Platform) {
        Set-TcSolutionConfiguration -Dte $Dte -Configuration $Configuration -Platform $Platform
    } else {
        Write-TcLog "WARNING: no BUILD_CONFIGURATION/BUILD_PLATFORM given -- building the shell's saved default: $(Get-TcActiveSolutionConfiguration -Dte $Dte)"
    }
    $active = Get-TcActiveSolutionConfiguration -Dte $Dte      # "Name|Platform"
    $config = ($active -split '\|', 2)[0]
    $platformName = ''
    if ($active -match '\|(.*)$') { $platformName = $Matches[1] }
    $target = 'solution'

    # ---- BUILDABILITY GUARD -------------------------------------------------
    # Learned the hard way: with the TwinCAT project system not loaded, VS loads
    # every project as vsProjectKindUnmodeled, ActiveConfiguration.SolutionContexts
    # is empty, Build() quietly does NOTHING, and LastBuildInfo returns 0 --
    # which reads as success. A deliberate syntax error passed a "clean" build.
    # A build that cannot fail is worse than no build, so refuse to run one.
    $UNMODELED = '{67294A52-A4F0-11D2-AA88-00C04F688DDE}'
    $contexts = 0
    try { $contexts = [int]$sb.ActiveConfiguration.SolutionContexts.Count } catch { }
    $unmodeled = @()
    for ($i = 1; $i -le $Dte.Solution.Projects.Count; $i++) {
        try {
            $pj = $Dte.Solution.Projects.Item($i)
            if ([string]$pj.Kind -eq $UNMODELED) { $unmodeled += [string]$pj.Name }
        } catch { }
    }
    if ($contexts -eq 0 -or $unmodeled.Count -gt 0) {
        throw ("REFUSING TO BUILD -- this solution cannot actually be built, so a " +
               "'success' here would be meaningless.`n" +
               "  SolutionContexts   : $contexts (expected >0)`n" +
               "  unmodeled projects : $($unmodeled -join ', ')`n" +
               "The TwinCAT project system did not load, so Build() is a no-op and " +
               "LastBuildInfo always returns 0. Fix: log in as the build user, open " +
               "$SolutionPath in the XAE Shell GUI once and accept every first-run " +
               "prompt (design §4.1 step 1), then retry.")
    }
    Write-TcLog "buildability OK -- $contexts solution context(s), no unmodeled projects"

    if ($Clean) {
        Write-TcLog "cleaning ($config)"
        $sb.Clean($true)
    }

    # Prime the project's boot repository with the driver TMX files the project
    # asks for -- without them the Analytics extension generates nothing. Done
    # after Clean on purpose (Clean may wipe _Boot).
    if ($platformName) {
        $tsPath = if ($Tsproj) { Join-Path (Split-Path -Parent $SolutionPath) $Tsproj } else { $null }
        if (-not $tsPath -or -not (Test-Path -LiteralPath $tsPath)) {
            $cand = Get-ChildItem (Split-Path -Parent $SolutionPath) -Filter '*.tsproj' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cand) { $tsPath = $cand.FullName }
        }
        try { $null = Initialize-TcBootRepository -WorkDir (Split-Path -Parent $SolutionPath) -Platform $platformName -TsprojPath $tsPath }
        catch { Write-TcLog "boot repository priming failed: $(Get-TcExceptionText $_)" }
    }

    # The Build pane is the primary diagnostics source and the shell process
    # is warm across jobs -- never let last job's text be read as this one's.
    Clear-TcBuildPane -Dte $Dte

    if ($FullSolution) {
        Write-TcLog "building solution ($config)"
        $sb.Build($true)
    } else {
        # Project.FileName comes back EMPTY in this shell; UniqueName is the
        # field that actually carries '<Project>.tsproj'. Check both.
        $tcProj = $null
        for ($i = 1; $i -le $Dte.Solution.Projects.Count; $i++) {
            $p = $Dte.Solution.Projects.Item($i)
            $u = ''; try { $u = [string]$p.UniqueName } catch { }
            $f = ''; try { $f = [string]$p.FileName }   catch { }
            if ($u -like '*.tsproj' -or $f -like '*.tsproj') { $tcProj = $p; break }
        }
        if (-not $tcProj) {
            Write-TcLog "no .tsproj project found; falling back to full solution build"
            $sb.Build($true); $FullSolution = $true
        } else {
            $target = $tcProj.UniqueName
            # EnvDTE accepts "Config|Platform" here; pass it so the build cannot
            # drift to another platform of the same configuration name.
            $cfgArg = if ($platformName) { "$config|$platformName" } else { $config }
            Write-TcLog "building project '$target' ($cfgArg)"
            try { $sb.BuildProject($cfgArg, $tcProj.UniqueName, $true) }
            catch {
                if ($cfgArg -eq $config) { throw }
                Write-TcLog "BuildProject('$cfgArg') rejected ($(Get-TcExceptionText $_)); retrying with '$config' (configuration already activated)"
                $sb.BuildProject($config, $tcProj.UniqueName, $true)
            }
        }
    }

    $sw.Stop()
    if (-not (Get-Variable -Name tcProj -ErrorAction SilentlyContinue)) { $tcProj = $null }

    # LastBuildInfo = number of projects that FAILED. 0 means success.
    $failed = 0
    try { $failed = [int]$sb.LastBuildInfo } catch { Write-TcLog "LastBuildInfo unreadable: $($_.Exception.Message)" }

    # Diagnostics extraction must never take the build result down with it:
    # rc comes from LastBuildInfo regardless, and a scraper bug becomes a
    # logged line instead of a failed job (that happened once).
    $errors = @(); $notes = @()
    try {
        $diag   = Get-TcBuildErrors -Dte $Dte -FailedProjects $failed
        $errors = @($diag.items)
        $notes  = @($diag.notes)
    } catch {
        Write-TcLog "diagnostics extraction FAILED (build result still valid): $(Get-TcExceptionText $_)"
    }
    $hardErrs = @($errors | Where-Object { $_.severity -eq 'error' })

    # Echo the itemised diagnostics into the job log too, so `tcbuild --raw`
    # shows exactly what the shell reported (file/line semantics included).
    $shown = 0
    foreach ($e in $errors) {
        if ($shown -ge 40) { Write-TcLog "  ... $($errors.Count - $shown) more"; break }
        $where = $e.file
        if ($e.scope) { $where = "$where@$($e.scope)" }
        Write-TcLog ("  [{0}] {1}({2}) <{3}>: {4}" -f $e.severity, $where, $e.line, $e.source, $e.message)
        $shown++
    }
    if ($notes.Count -gt 0) { Write-TcLog "  ($($notes.Count) non-compiler Error List item(s) kept in .json 'notes')" }

    # The 'TwinCAT' Output pane is where the System Manager reports what it
    # did or could not do with the project (extensions, TcCOM, boot project).
    # Its last lines go into every job log, because the Analytics node was once
    # silently dropped from the generated configuration and nothing else said so.
    Write-TcOutputPaneNotes -Dte $Dte -PaneName 'TwinCAT' -Label 'TwinCAT pane after build'

    # Trust LastBuildInfo over the Error List: the list can lag or come back
    # empty, but a non-zero failed-project count is unambiguous.
    $rc = if ($failed -ne 0 -or $hardErrs.Count -gt 0) { 1 } else { 0 }

    Write-TcLog ("build finished in {0:N1}s -- failedProjects={1} errors={2} warnings={3}" -f `
        $sw.Elapsed.TotalSeconds, $failed, $hardErrs.Count,
        @($errors | Where-Object { $_.severity -eq 'warning' }).Count)

    # Did the System Manager generate everything the project asked for? A
    # warning here on every build is how that outage would have been caught
    # weeks earlier. The deploy turns it into a refusal (rc 10).
    $bootConfig = $null
    if ($platformName -and $rc -eq 0) {
        $tsPath = if ($Tsproj) { Join-Path (Split-Path -Parent $SolutionPath) $Tsproj } else { $null }
        if (-not $tsPath -or -not (Test-Path -LiteralPath $tsPath)) {
            $cand = Get-ChildItem (Split-Path -Parent $SolutionPath) -Filter '*.tsproj' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cand) { $tsPath = $cand.FullName }
        }
        if ($tsPath) {
            try {
                $bootConfig = Test-TcBootConfigComplete -WorkDir (Split-Path -Parent $SolutionPath) -Platform $platformName -TsprojPath $tsPath -MustContain $MustContain
                if (-not $bootConfig.ok -and $tcProj) {
                    # When the PLC is recompiled in this pass (after a clean, or after
                    # a sync changed the sources) PLC.tmc is rewritten while the System
                    # Manager is generating; it logs "Unknown TMC file version found -
                    # ignoring the file and waiting for a new one" and the Analytics
                    # extension, which resolves its symbols against the PLC's TMC, emits
                    # nothing (seen as a deploy refused with rc 10). A rebuild in the SAME
                    # open solution is not enough -- the SM only re-reads PLC.tmc when
                    # the solution is reloaded. So do what a developer does between
                    # building and activating: close the solution, reopen it (now the
                    # TMC on disk is current), and build once more.
                    Write-TcLog "generated configuration incomplete -- reloading the solution to re-read PLC.tmc, then rebuilding"
                    try { $Dte.Solution.Close($false) } catch { Write-TcLog "close before reload failed: $(Get-TcExceptionText $_)" }
                    Open-TcSolution -Dte $Dte -SolutionPath $SolutionPath
                    if ($Configuration -and $Platform) { Set-TcSolutionConfiguration -Dte $Dte -Configuration $Configuration -Platform $Platform }
                    $sb2 = $Dte.Solution.SolutionBuild
                    $tcProj2 = $null
                    for ($j = 1; $j -le $Dte.Solution.Projects.Count; $j++) {
                        $pp = $Dte.Solution.Projects.Item($j); $uu = ''; try { $uu = [string]$pp.UniqueName } catch { }
                        if ($uu -like '*.tsproj') { $tcProj2 = $pp; break }
                    }
                    $active2 = Get-TcActiveSolutionConfiguration -Dte $Dte
                    if ($tcProj2) {
                        try { $sb2.BuildProject($active2, $tcProj2.UniqueName, $true) } catch { $sb2.BuildProject((($active2 -split '\|',2)[0]), $tcProj2.UniqueName, $true) }
                    }
                    $bootConfig = Test-TcBootConfigComplete -WorkDir (Split-Path -Parent $SolutionPath) -Platform $platformName -TsprojPath $tsPath -MustContain $MustContain
                }
                if ($bootConfig.ok) { Write-TcLog "generated configuration complete -- $($bootConfig.checked) check(s)" }
                else { Write-TcLog "WARNING: generated configuration is MISSING: $($bootConfig.missing -join '; ')  (the box's XAE dropped part of the project)" }
            } catch { Write-TcLog "boot config check failed: $(Get-TcExceptionText $_)" }
        }
    }

    return [pscustomobject]@{
        rc             = $rc
        failedProjects = $failed
        errors         = $errors
        notes          = $notes
        bootConfig     = $bootConfig
        elapsed        = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        builtProject   = $target
        config         = $config
        platform       = $platformName
    }
}

function Invoke-TcProbe {
    <#
        Diagnostic job: what does the System Manager's model contain after the
        solution loads, does the Analytics node exist in Solution Explorer, and
        does selecting it (as a user would) change what gets generated?
    #>
    param(
        [Parameter(Mandatory)] $Dte,
        [Parameter(Mandatory)][string] $SolutionPath,
        [string] $Configuration = '', [string] $Platform = '', [string] $Tsproj = ''
    )
    Open-TcSolution -Dte $Dte -SolutionPath $SolutionPath
    if ($Configuration -and $Platform) { Set-TcSolutionConfiguration -Dte $Dte -Configuration $Configuration -Platform $Platform }
    $workDir = Split-Path -Parent $SolutionPath
    $tsPath  = if ($Tsproj) { Join-Path $workDir $Tsproj } else { (Get-ChildItem $workDir -Filter '*.tsproj' | Select-Object -First 1).FullName }

    Write-TcLog "--- Solution Explorer, depth 3 ---"
    $items = @()
    try { $items = @([TcWorkflow.DteExt]::SolutionExplorerItems($Dte, 3)) } catch { Write-TcLog "Solution Explorer walk failed: $(Get-TcExceptionText $_)" }
    Write-TcLog "$($items.Count) item(s)"
    foreach ($i in ($items | Select-Object -First 50)) { Write-TcLog "  $i" }

    Write-TcLog "--- System Manager tree ---"
    $sysMan = Get-TcSysManager -Dte $Dte
    $root = $null
    try { $root = $sysMan.LookupTreeItem('TIRC').Parent } catch { Write-TcLog "root via TIRC.Parent failed: $(Get-TcExceptionText $_)" }
    $listRoot = {
        param($label)
        if ($root) {
            Write-TcLog "$label root '$($root.Name)' has $($root.ChildCount) child(ren):"
            for ($k = 1; $k -le $root.ChildCount; $k++) { $c = $root.Child($k); Write-TcLog ("  [{0}] {1}  type={2}  path={3}  children={4}" -f $k, $c.Name, $c.ItemType, $c.PathName, $c.ChildCount) }
        }
    }
    & $listRoot 'before'
    foreach ($guess in @('TIAC', 'TIAL', 'TIAN', 'TIRC^Analytics', 'ANALYTICS', 'TIRC^ANALYTICS')) {
        try { $t = $sysMan.LookupTreeItem($guess); Write-TcLog "LookupTreeItem('$guess') -> '$($t.Name)' type=$($t.ItemType) children=$($t.ChildCount)" } catch { Write-TcLog "LookupTreeItem('$guess'): not found" }
    }

    $aly = $items | Where-Object { $_ -match '(?i)\\ANALYTICS$' } | Select-Object -First 1
    if ($aly) {
        try {
            $ok = [TcWorkflow.DteExt]::SelectSolutionExplorerItem($Dte, $aly.TrimStart('\'))
            Write-TcLog "selected '$aly' in Solution Explorer: $ok -- waiting 10s for the extension to load"
            Start-Sleep -Seconds 10
        } catch { Write-TcLog "select failed: $(Get-TcExceptionText $_)" }
        & $listRoot 'after select'
    } else { Write-TcLog "no ANALYTICS node in Solution Explorer" }

    Write-TcLog "--- regenerate configuration after the probe ---"
    $sb = $Dte.Solution.SolutionBuild
    $active = Get-TcActiveSolutionConfiguration -Dte $Dte
    $tcProj = $null
    for ($i = 1; $i -le $Dte.Solution.Projects.Count; $i++) { $p = $Dte.Solution.Projects.Item($i); $u = ''; try { $u = [string]$p.UniqueName } catch { }; if ($u -like '*.tsproj') { $tcProj = $p; break } }
    $sb.BuildProject($active, $tcProj.UniqueName, $true)
    $plat = ($active -split '\|', 2)[1]
    $cc = Test-TcBootConfigComplete -WorkDir $workDir -Platform $plat -TsprojPath $tsPath
    Write-TcLog "completeness after probe: ok=$($cc.ok) checked=$($cc.checked) missing=$($cc.missing.Count)"
    return [pscustomobject]@{ rc = $(if ($cc.ok) { 0 } else { 1 }); solutionExplorer = $items; complete = $cc.ok; missing = $cc.missing }
}

function Invoke-TcActivate {
    <#
        Design §4.4. Assumes the caller has ALREADY: checked out the sha and passed the ADS pre-flight guard. This
        function does the irreversible part only.
    #>
    param(
        [Parameter(Mandatory)] $Dte,
        [Parameter(Mandatory)][string] $SolutionPath,
        [Parameter(Mandatory)][string] $NetId,
        [string] $Platform = ''
    )

    Open-TcSolution -Dte $Dte -SolutionPath $SolutionPath
    $sysMan = Get-TcSysManager -Dte $Dte

    Write-TcLog "setting target NetId -> $NetId"
    $sysMan.SetTargetNetId($NetId)

    $actual = ''
    try { $actual = [string]$sysMan.GetTargetNetId() } catch { }
    if ($actual -and $actual -ne $NetId) {
        throw "target NetId did not take: asked for $NetId, shell reports $actual"
    }

    # Selecting a target can switch the solution platform to the target's own.
    # If that moved us off the configured platform, the configuration describes
    # a different machine than the one we are about to restart. Refuse.
    $active = Get-TcActiveSolutionConfiguration -Dte $Dte
    Write-TcLog "solution configuration after target selection: $active"
    if ($Platform -and $active -match '\|(.*)$' -and $Matches[1] -and $Matches[1] -ne $Platform) {
        throw ("platform mismatch: tcdeploy.conf says BUILD_PLATFORM='$Platform' but after selecting target $NetId " +
               "the shell is on '$($Matches[1])'. Refusing to activate a boot project for the wrong platform.")
    }

    Write-TcLog "ActivateConfiguration() -- PLC WILL RESTART"
    $sysMan.ActivateConfiguration()

    Write-TcLog "StartRestartTwinCAT()"
    $sysMan.StartRestartTwinCAT()

    Write-TcLog "activation calls returned"
    return [pscustomobject]@{ netId = $NetId; activated = $true }
}
