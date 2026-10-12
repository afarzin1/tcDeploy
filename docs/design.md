# tcDeploy — Design

How tcDeploy builds and deploys TwinCAT projects from Linux, and why it is shaped the way it is.
The [README](../README.md) is the operating manual; [field notes](field-notes.md) has the evidence
behind the less obvious decisions. Section numbers are referenced from the code (`design §4.2`), so
keep them stable.

---

## 1. Goal

Let an AI agent (or a person) working on a Linux machine modify TwinCAT PLC code, build it to verify
there are no errors, and — behind an explicit approval gate — activate the configuration onto the
physical machine.

The agent already edits code in a git working tree and pushes it. What is missing is the **build +
deploy** half, which needs a Windows machine with TwinCAT XAE. tcDeploy bridges that gap **without**
putting the agent on the Windows box and **without** a CI pipeline.

It does so for **many projects at once**: one build box, any number of TwinCAT repos, each with its
own tree on the box and its own target controller. Nothing in tcDeploy is specific to a project;
everything project-specific lives in the project's own repo (`tcdeploy.conf`).

### Non-goals

- HMI deployment — HMIs have their own pipelines.
- TwinSAFE deployment — deliberately manual. tcDeploy never downloads, diffs or gates on the safety
  project; `ActivateConfiguration()` ships the PLC and I/O configuration only.
- No-downtime / online-change deploys — not achievable through the Automation Interface (§8).

---

## 2. Key constraints

These facts force the architecture.

### 2.1 There is no headless TwinCAT build

TwinCAT has no command-line PLC compiler. The only way to build and activate is the **TE1000
Automation Interface** — a COM/DTE API exposed by the XAE Shell (a Visual Studio shell). `tcpkg` is
package management only. Driving the shell over COM is unavoidable.

The Automation Interface calls tcDeploy relies on (`ITcSysManager` and the DTE):

- `SolutionBuild.BuildProject(...)` / `SolutionBuild.Build($true)`, then `LastBuildInfo` (the count
  of failed projects).
- `ActivateConfiguration()` — takes the solution out of edit mode, builds the runtime
  configuration, and pushes it to the target (XAR).
- `StartRestartTwinCAT()` — brings the target's system service back into Run.

TE1000 has **no** login / online-change / download-to-running-PLC API.

### 2.2 COM automation of the XAE Shell needs an interactive session

A network logon (SSH, WinRM) lands in **Session 0**, which has no interactive desktop. The DTE can
be created there and a solution opened, but the TwinCAT project system does not initialise: builds
become silent no-ops that still report success. (Microsoft documents the same class of problem as
"Office automation from a service is unsupported".)

Therefore: **SSH is the transport, but the build executes in a logged-on desktop session.**

### 2.3 The privilege boundary is real, not a bug to defeat

Placing a process onto the interactive desktop from a privileged context is done with
`CreateProcessAsUser` and the console session's token, a documented API that needs
`SeAssignPrimaryToken`/`SeTcbPrivilege`. tcDeploy does **not** build anything that evades the
security model (token theft, session hijacking, injection, hidden persistence); such a tool is
indistinguishable from malware to EDR and to the next administrator.

The simplest form avoids `CreateProcessAsUser` entirely: the worker runs **inside** an autologon
session (§4.2), started by a scheduled task at logon.

---

## 3. Architecture overview

```
Linux (agent)                              Windows build box (TwinCAT XAE)
                                           build user, auto-logged-on
  ┌────────────────────────┐               ┌──────────────────────────────┐
  │ edit .TcPOU/.TcGVL      │               │  worker.ps1 (PowerShell, STA)│
  │ in any project repo     │  tar over ssh │  watches C:\_tcDeploy\queue  │
  │  ────────────────────▶  │──────────────▶│  …\projects\<PROJECT>\       │
  │                         │               │            │                 │
  │  ssh: drop job file     │  ssh          │            ▼                 │
  │  ────────────────────▶  │──────────────▶│  XAE Shell (COM/DTE): build, │
  │                         │               │            │       activate  │
  │  ssh: read results      │  ssh          │            ▼                 │
  │  ◀────────────────────  │◀──────────────│  .log/.json/.rc ── ADS ───┐  │
  └────────────────────────┘               └───────────────────────────┼──┘
                                                                        ▼
                                                   that project's target controller (XAR)
```

The worker is plain PowerShell running in the already-logged-on desktop session, so COM works. SSH
stays non-interactive: it only ships files, drops job files and reads results. RDP is for bootstrap
and for looking at a wedged shell, never the normal transport (and `tcscreen` usually makes even
that unnecessary).

---

## 4. Components

### 4.1 Windows build box — one-time setup

Done by `windows/bootstrap.ps1` (idempotent), plus a few manual steps it prints:

- TwinCAT 3.1 XAE, pinned to the version the engineering workstations use.
- A build account. Either a dedicated **local** user (`tcbuild`, the default), or an existing
  **domain** account (`DOMAIN\account`). A local account is isolated from domain policy; a domain
  account is centrally managed but subject to password rotation, lockout and Group Policy, any of
  which can silently break autologon (see [field notes](field-notes.md), "Domain-joined build boxes").
- **Autologon** for that account, with the lock screen and screensaver lock disabled, so an
  interactive desktop always exists and survives reboots.
- OpenSSH Server, with the Linux machine's public key authorised.
- The worker registered as a scheduled task that starts at logon, interactive, highest privileges.
- `C:\_tcDeploy\` with `scripts\`, `queue\`, `out\`, `state\`, `tmp\` and `projects\` (`-Root` moves
  it). The repo contains no projects; each is added later (README, "Adding a project").
- **No git.** The box builds exactly what `tcsync` sends (§4.4).
- Manual, once per project: put the project's full tree at `C:\_tcDeploy\projects\<PROJECT>`, open its solution in
  the XAE Shell as the build user and accept every first-run prompt (`SuppressUI` does not cover
  them all), and add a static ADS route to the target.

The box is effectively single-tenant with an auto-logged-on session. Do not make it a casual RDP
target.

### 4.2 The worker (runs in the autologon session)

`windows/worker.ps1`, a long-lived Windows PowerShell 5.1 process (STA; `pwsh` 7 defaults to MTA and
cannot register the message filter):

1. Watches `C:\_tcDeploy\queue\` for `*.job` files (JSON). Jobs are written as `.tmp` and renamed,
   so the worker never sees half a job. One job at a time, across all projects: each job names its
   project's tree, solution, platform and target, so the worker itself holds no project settings.
2. Dispatches by type: `build`, `deploy`, `status`, `probe`.
3. Keeps the **shell process** warm between jobs, but **closes the solution after every job**: a
   file change under an open solution wedges the shell's next COM call. Reopening costs about 26 s;
   a cold shell start about 50 s.
4. Arms a **watchdog** per job. If the job overruns its budget, a threadpool timer kills the shell,
   the stuck COM call fails, and the worker publishes rc 1 with the reason instead of leaving the
   client to time out. The next job starts a fresh shell.
5. Writes `C:\_tcDeploy\out\<jobid>.log`, then `.json`, then `.rc` last; the `.rc` file is the completion
   barrier the client polls for.
6. Hardening: a COM `IOleMessageFilter` against `RPC_E_CALL_REJECTED`, stale `TcXaeShell` processes
   killed on start, `try/finally` that always releases the DTE, `SuppressUI`.

`TC_MODE=direct` runs the same build code straight over SSH instead of through the queue. It exists
for boxes where a network logon can drive the DTE; on TwinCAT 4026 it cannot (§2.2), and
`tools/smoketest.sh` tells you which mode a box needs.

### 4.3 Builds

- Pin the solution configuration and platform (`BUILD_CONFIGURATION|BUILD_PLATFORM`). Without
  this the shell builds whatever its saved user state says, which need not match the target.
- Prime the project's boot repository: copy the driver TMX files the `.tsproj` needs (e.g. the
  TF3500 Analytics driver) from the machine repository into `_Boot\<platform>\Repository\…` if
  missing. Without them the System Manager silently generates an incomplete configuration.
- Build the TwinCAT project (`tcbuild`), or the whole solution clean (`tcdeploy`).
- Read diagnostics from the Output window's **Build** pane, where the PLC compiler writes
  `file[@scope](line) : severity: message`. The Error List does not carry PLC compiler messages on
  4026; it is consulted only when a build failed and the Build pane produced no error. Reading
  either needs a compiled `(DTE2)` cast, because PowerShell's COM adapter only sees `EnvDTE._DTE`.
- The compiler's line numbers count from the top of the object's declaration into its
  implementation. `tcbuild` translates them to XML line numbers in the file on the Linux side, so
  the agent lands on the right line.
- Check the generated configuration is complete (`Test-TcBootConfigComplete`): everything the
  project asks for (e.g. every Analytics stream) must appear in `CurrentConfig.xml`. If it does not
  because the PLC's TMC was regenerated mid-pass, reload the solution and build once more.
- `rc` comes from `LastBuildInfo`; a failure to scrape diagnostics never turns a good build red.

### 4.4 Deploys (the gated path)

On Linux (`bin/tcdeploy`):

1. The working tree must be clean (submodules included) and checked out at `<sha>`.
2. `<sha>` must be reachable from `origin`: the deploy record points at history others can see.
3. `tcsync --full` ships the tree plus a per-file SHA-256 manifest of exactly the staged bytes.
4. A pre-flight `tcstatus`, then an interactive confirmation (or `--yes`).

On the box (`windows/lib/DeployOps.ps1`), every refusal has its own exit code:

1. Verify the tree against the manifest (rc 6).
2. Clean build (rc 1); boot project for `BUILD_PLATFORM` freshly written (rc 7); generated
   configuration complete (rc 10).
3. Identity: the target's published hostname is `EXPECTED_HOSTNAME` (rc 8).
4. ADS guard, as late as possible: target reachable, guard BOOLs FALSE, guard STRINGs empty; an
   unreadable guard refuses (rc 4). This holds even when a human approved the deploy.
5. `SetTargetNetId` → `ActivateConfiguration()` → `StartRestartTwinCAT()`.
6. Both system and PLC must read Run on consecutive polls, after the restart has been observed
   (rc 5 if not).
7. Health: every `ADS_HEALTH_BOOLS` symbol TRUE within `ADS_HEALTH_TIMEOUT` (rc 9 if not).

Back on Linux: the annotated tag `<DEPLOY_TAG_PREFIX>/<UTC timestamp>` is created and pushed; its
message carries the manifest hash. If the project has an Analytics Logger, the Storage Provider
watch result goes into the tag message too (rc 11 if a recording stopped).

### 4.5 Linux-side wrappers

Thin verbs on PATH (installed by `tools/install.sh`) so the agent has a clean interface instead of
improvising SSH. Each reads the site config (`etc/`, shared by all projects) and the current
project's `tcdeploy.conf`, found by walking up from the current directory. There is deliberately no
default project.

| Verb | Does |
|---|---|
| `tcsync` | pre-flight (§6), then a gzipped tar of `SYNC_PATHS` over SSH, with LF→CRLF conversion and a manifest-driven prune |
| `tcbuild` | sync, drop a `build` job, wait, print `file:line: severity: message` |
| `tcdeploy` | the gated path (§4.4) |
| `tcstatus` | ADS read of run state, guards, identity and health, done on the box |

`tar.exe` ships with Windows 10 1803 and later; Windows has no rsync. Line endings are converted in
flight because git stores LF, a tar copy preserves it, and Visual Studio cannot parse an LF `.sln`.

---

## 5. The workflow

### Inner loop (nothing committed until it compiles)

1. **Edit** `.TcPOU` / `.TcGVL` in the repo.
2. **Build** — `tcbuild` syncs the source, the worker builds in the interactive session, and the
   terse diagnostics come back with a real exit code.
3. **Read and fix**, loop.

### Deploy (gated)

4. **Commit and push.**
5. **`tcdeploy <sha>`** — §4.4.

### The approval gate

`tcdeploy` restarts a PLC attached to physical hardware. It must stay a human decision:

- Never add it to an agent's permission allowlist, and never run an agent that can reach it in a
  bypass-permissions mode.
- It refuses non-interactively unless given `--yes`, and independently refuses if the machine is
  busy.
- The agent has git-push rights; the deploy rights (the ADS route to the target) live on the build
  box.

---

## 6. Working-tree rules (`tcpreflight`)

Checked before every sync, offline:

- New `.TcPOU`/`.TcGVL`/`.TcDUT` files must be registered in the `.plcproj` (`<Compile Include>`).
  TwinCAT silently ignores unregistered files.
- An edit must not **flip** a file's UTF-8 BOM state relative to `HEAD`. TwinCAT reads files with and
  without a BOM, and real codebases contain both; what breaks review is a rewrite that silently
  changes the encoding and turns a two-line change into a whole-file diff.
- Generated files (`*.tsproj`, `_Config/*.xti`) must not be modified. I/O mapping, task
  configuration and safety are edited in the XAE by a person. They are also outside the inner-loop
  sync set, so they cannot be pushed by accident.

Rules that need judgment rather than a check (never touch `Id="{guid}"` attributes, never break a
CDATA block) are in the skill (`skill/SKILL.md`).

---

## 7. Bring-up order (prove assumptions before building on them)

1. Bootstrap the box (§4.1), push the scripts (`tcscripts`).
2. **`tools/smoketest.sh`** — can a network logon drive the DTE, or does Session 0 force the worker
   model? Set `TC_MODE` from the verdict.
3. Clear first-run dialogs by hand.
4. `tcbuild` on good source (rc 0), then inject an undefined identifier and confirm it comes back
   red with the right `file:line`. A build that cannot fail is worse than no build.
5. Only then `tcdeploy --dry-run`, then a real deploy with someone watching the machine.
6. Confirm the approval gate: the deploy is not auto-approved.

---

## 8. Known limitations

- **Restart, not online change.** `ActivateConfiguration()` restarts the runtime: the PLC stops,
  outputs drop, non-persistent state is lost. The ADS guard exists because a deploy restarts a
  machine that may be mid-test.
- **"It compiles" is a thin gate.** Structured Text compiles fine with an inverted interlock or a
  wrong scaling constant. TcUnit against a spare runtime (a VM or a second IPC, never the production
  machine) is what would let an agent be trusted with less review.
- **Boot-folder deploys were considered and rejected.** Same downtime, but it moves the "process
  image and hardware config unchanged" precondition onto the tool instead of letting
  `ActivateConfiguration()` validate it.
- **Licensing.** A trial licence's CAPTCHA would block unattended activation; use licensed hardware.
  `tcscreen` will type a CAPTCHA a person reads, but never solves one itself.

---

## 9. Decisions

- **One tool, many projects.** The scripts live in this repo and contain no project. A project repo
  carries only its `tcdeploy.conf`; on the box each project has its own tree under
  `projects\<PROJECT>` and its own manifest in `state\`, so projects share the worker but nothing
  else. `PROJECT` must be unique per box.
- **The box runs no git.** Traceability comes from the clean-tree and pushed-sha checks on Linux plus
  the manifest verification on the box, without a clone or credentials on an auto-logged-on machine.
- **Sync is a subset, not the tree.** A TwinCAT repo can be hundreds of MB (packages, HMI); the
  inner loop sends only PLC source.
- **`tcbuild` builds the TwinCAT project, not the solution.** HMI (TE2000) and Scope (TE1300)
  projects in the same solution would otherwise become bring-up dependencies. `tcdeploy` builds the
  whole solution clean before activating.
