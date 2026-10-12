# tcDeploy — Field notes

What bringing tcDeploy up on real TwinCAT 3.1.4026 systems taught, with the evidence. Each of these
is already encoded in the scripts; this file is the "why" for the next person who is tempted to
simplify one away. The code refers to these sections by name.

## Session 0: the DTE opens, the build does nothing

A Session 0 network logon (SSH, WinRM) **can** create the XAE Shell's DTE and open a solution. It does
not hang, as is often predicted. But the TwinCAT project system does not initialise there, so builds
are no-ops that still report success. The interactive worker session (`TC_MODE=worker`) is
required. `tools/smoketest.sh` runs the probe so a new box can be judged on evidence.

## Wedged shell

**Any file change under an open solution wedges the shell's current or next COM call**, between jobs
or mid-build. Reproduced on purpose: a `tcsync --force` during `BuildProject()` hung it for the whole
job budget. The process burns CPU and never returns. The COM message filter is irrelevant, because
the call is never rejected, just never answered.

Two layers, both in the worker:

- **Avoid it.** Close the solution at the end of every build and deploy job (2–4 s). The shell
  *process* stays warm, so the next job skips the shell start and reopens the solution in about 26 s
  instead of about 51 s cold. `tcsync` refuses to run while a job's `.running` marker exists.
- **Survive it.** Every build and deploy job is armed with a watchdog: a threadpool timer, pure
  .NET, so it runs while the STA thread is blocked. At `timeout − 30 s` it kills `TcXaeShell`, the
  pending COM call fails with `0x800706BE`, the worker publishes rc 1 with `wedged: true`, resets the
  DTE, and the next job starts a fresh shell. No `tcreset` needed.

## Compiler diagnostics

Two problems stacked on top of each other:

1. **`ToolWindows` is invisible from PowerShell.** `New-Object -ComObject` gives PowerShell an RCW
   whose members it discovers through the type info of the coclass's *default* interface,
   `EnvDTE._DTE`. `ToolWindows` lives on `EnvDTE80.DTE2`. Casting in PowerShell does not help. A
   small C# helper compiled at worker start with `Add-Type` does `(DTE2)dte`, a real
   `QueryInterface`. It must be built against the shell's own interop assemblies in
   `Common7\IDE\PublicAssemblies` (they are not in the GAC), and on the VS2022-based shell
   `envdte80.dll` is only a type forwarder to `Microsoft.VisualStudio.Interop.dll`, which must be
   referenced too. In-memory `Add-Type` assemblies cannot bind to `LoadFrom`-loaded interop
   assemblies by identity; an `AssemblyResolve` handler answers those binds.
2. **The Error List does not carry PLC compiler output on 4026.** It holds HMI package chatter,
   Analytics notices and a "Project 'PLC' build failed" summary, sometimes thousands of items that
   take seconds to walk. The compiler's located diagnostics are in the **Output window's Build
   pane**:

   ```
   C:\_tcDeploy\projects\Machine\PLC\POUs\MAIN.TcPOU(18) : error: C0046: Identifier 'x' not defined
   C:\_tcDeploy\projects\Machine\PLC\POUs\MAIN.TcPOU@runStep(163) : warning: C0197: Implicit conversion from 'LREAL' to 'REAL'
   ```

   The Build pane is cleared before each build, so a warm shell cannot leak the previous job's text.
   The Error List is read only when a build failed and the Build pane produced no error.

**Line numbers are not XML lines.** `MAIN.TcPOU(18)` means 17 declaration lines + implementation line
1; `@runStep(163)` is the same rule inside that method's element. `tcbuild` parses the file on the
Linux side and maps to the XML line the agent edits.

Also: `vsBuildErrorLevel` is Low = 1, Medium = 2, **High = 4**. Output panes other than `Build` and
`TwinCAT*` (e.g. `Debug`, `Source Control`) throw `E_FAIL` on `TextDocument` until they have been
shown.

## Line endings

`.gitattributes` with `* text=auto` stores LF and writes CRLF only on a Windows *checkout*. A tar copy
from Linux lands LF files on Windows, and **Visual Studio cannot parse an LF `.sln`**: every project
loads as `vsProjectKindUnmodeled`, `SolutionContexts` goes to 0, `Build()` becomes a silent no-op, and
`LastBuildInfo` returns 0 — "success". `tcsync` stages and converts text files (binaries detected by
a NUL byte and copied verbatim), and the worker refuses to build when `SolutionContexts` is 0.

## Solution configuration and platform

Without an explicit selection the shell builds whatever its saved user state says. One box had
`Release|TwinCAT OS (ARMV8-A)` saved for an x64 target. The deploy still ran x64 code, only because
TwinCAT generates the boot project for the *selected target's* platform at activation. A deploy tool
must not rely on that, so `BUILD_PLATFORM` is required for deploys, the worker selects the
configuration before building (through `SolutionConfiguration2` with indexed access; the
collection's enumerator handed back a null element), and the deploy refuses (rc 7) unless the build
wrote a fresh `_Boot\<BUILD_PLATFORM>\Plc\*.app`.

## Boot repository: the Analytics node needs its driver TMX

The TF3500 Analytics Logger System Manager extension only generates its stream TcCOM objects when the
driver's TMX for the target platform already exists in the **project's** boot repository:

    _Boot\TwinCAT RT (x64)\Repository\Beckhoff Automation GmbH\TcAnalytics\<version>\TcAnalytics.tmx

An interactive first activation leaves that file behind. A fresh clone or synced tree never has it
(`_Boot/` is ignored by git), and the extension then silently emits nothing: no warning, no error,
the Analytics node has zero children, and the generated configuration has no `<Analytics>` element.
The target then has no stream objects, the PLC's stream function blocks never initialise, and MQTT
goes dark after an otherwise successful deploy.

Found by building a developer's working clone and the synced tree through the same worker, then
copying ignored folders across one at a time until the difference was isolated. Ruled out along the
way, each by test: PLC code, persistent data, platform, COM-started vs process-started shell,
`SuppressUI`, hidden window, the project's `_Repository`, extension registration, and the Windows
account.

The fix: before every build, `Initialize-TcBootRepository` copies each TMX the `.tsproj` asks for
from the machine repository (`C:\ProgramData\Beckhoff\TwinCAT\3.1\Repository\…`) into the project's
`_Boot`, and warns if the machine repository lacks that version. `Test-TcBootConfigComplete` is the
backstop: a build warning, and a deploy refusal (rc 10).

## TMC reload

A clean or freshly synced build regenerates `PLC.tmc` mid-pass. The System Manager logs "Unknown TMC
file version found - ignoring the file and waiting for a new one", and the Analytics extension, which
resolves its symbols against the TMC, emits nothing. A rebuild in the same open solution does not fix
it; the System Manager only re-reads `PLC.tmc` when the solution is reloaded. `Invoke-TcBuild` detects
the incomplete generation, closes and reopens the solution, and builds once more.

## Analytics Storage Provider

After an activation, the TwinCAT Analytics Storage Provider (TF3520) sometimes stops recording the
machine's stream to its database and does not restart, although the PLC keeps publishing. Two failure
paths show up in the provider's own log on the broker:

- **"New SymbolInfo received. Symbolinfo differs from current SymbolInfo. Stopping recording."** Seen
  even when the symbol list was unchanged, plausibly when the running configuration was last built on
  a different machine.
- **"Logger Device not online" → "cancelled during initialization. Record not Started."** The stream
  was offline for a long time, e.g. while the XAE sat at its "restart in Run mode?" prompt after a
  manual activation. tcDeploy activates and restarts back to back (about 5 s offline), which avoids
  this path.

An auto-start entry for the recording does not restart it. The Recorder's start/stop command is
undocumented, so tcDeploy observes rather than repairs: `tcanalytics watch` records the offline gap,
the provider's log lines and each recording's message count across every deploy, and `tcdeploy`
exits 11 if a recording stopped. To learn the start command, run `tcanalytics capture` while pressing
Stop/Start in the Recorder. Do not restart the provider service to fix one recording; it usually
carries other machines' recordings too.

## Post-restart streams that never start

A related failure that is *not* tcDeploy's: PLC code that starts its MQTT streams once, on the first
scan, gated on something read over ADS with a short timeout (e.g. the IPC hostname). After a full
runtime restart the system service can miss that window; the gate never opens and the streams stay
silent while everything else runs. The fix belongs in the PLC: retry the lookup until it succeeds,
and restart a stream that is wanted but not running. On the tcDeploy side, `ADS_HEALTH_BOOLS` makes
the deploy fail loudly (rc 9) instead of reporting success.

## Domain-joined build boxes

If the build identity is a domain account, three standing risks apply to an unattended agent:

- **Password rotation silently breaks autologon and SSH.** Exempt the account from rotation, or plan
  to re-run bootstrap on every change.
- **Lockout policy applies to the build agent.** Repeated bad authentication locks out the thing that
  builds your PLC.
- **Group Policy can override** the autologon and lock-screen settings. Check `gpresult /r` after a
  reboot.

`tools/diagnose-box.ps1` separates the three usual reasons a local account cannot authenticate over
WinRM (account state, NTLM restrictions, remote UAC token filtering), which look identical from the
network.

## SSH and PowerShell plumbing

- The OpenSSH login shell on Windows is `cmd.exe`, with an **8191-character command-line limit**,
  hit long before the 32767 `CreateProcess` limit. `-EncodedCommand` inflates a script about 2.7×.
  `tc_ps` refuses above about 7.8 KB of encoded payload; `tc_ps_file` ships a script by tar and runs
  it with `-File`.
- A non-interactive `powershell.exe` serialises progress records as CLIXML onto stderr; set
  `$ProgressPreference='SilentlyContinue'`. `Write-Host` output can be duplicated the same way;
  `6>&1` on the invocation stops it.
- A box can hold 20+ copies of `TwinCAT.Ads.dll`. The v6/v7 builds are .NET Standard and do not load
  in Windows PowerShell 5.1 without dependencies that are not installed; the v4.x .NET Framework
  builds do. Reflection-only loading to sniff the framework does not work either; the assembly
  version from the file header is the usable discriminator.
- PowerShell wraps COM failures in `MethodInvocationException`; walk the `InnerException` chain to
  decide whether the shell is suspect.
- On 4026 the static-routes file may not be at either documented `StaticRoutes.xml` path while
  routes work fine. Do not diagnose routing from the file's absence.
- Over RDP as the build user, hand the session back before leaving, from an **elevated** PowerShell:
  `tscon 1 /dest:console`. Closing the RDP window leaves the worker's session disconnected.

## Lessons

- **Compare against a known-good instance first.** One diff of two trees beat hours of reasoning.
- **Get the raw data before designing the parser.** Dumping the Output panes into the job log turned
  "the Error List is empty" from a mystery into a one-regex fix.
- **Make the failure path prove itself.** Inject a real error after every change to the build path;
  a build that cannot fail is worse than no build.
- **Do not run speculative repair commands against a production install.**
