# tcDeploy

Build and deploy Beckhoff TwinCAT 3 projects from Linux. TwinCAT has no headless compiler, so
tcDeploy drives the XAE Shell on a Windows build box over SSH, returns compiler errors as
`file:line: severity: message` with a real exit code, and — behind an approval gate — activates the
configuration onto the target controller.

**One build box serves many projects.** Every TwinCAT repo you work on is a project: it carries a
`tcdeploy.conf` at its root, gets its own tree on the build box under
`C:\_tcDeploy\projects\<PROJECT>`, and targets its own controller. The same verbs (`tcbuild`,
`tcdeploy`, …) work in every repo; they find the right project from the directory you run them in.

It was built so an AI coding agent (Claude Code, Codex, …) can edit PLC code on Linux and check that
it compiles, without putting the agent on the Windows box and without a CI pipeline. It works just as
well from a terminal.

```
Linux: any number of TwinCAT repos      Windows build box (XAE)                      controllers (XAR)
  repoA/tcdeploy.conf ──tcsync──▶       C:\_tcDeploy\projects\repoA
  repoB/tcdeploy.conf ──tcbuild─▶       queue ─▶ worker ─▶ XAE Shell (COM)
                      ◀───────────      file:line: severity: message + exit code
                      ──tcdeploy▶       verify ─▶ clean build ─▶ ActivateConfiguration ──ADS──▶ repoA's target
```

- **[docs/design.md](docs/design.md)** — how it works and why: the constraints, the worker, the
  build and deploy paths.
- **[docs/field-notes.md](docs/field-notes.md)** — the TwinCAT/Windows behaviour behind the less
  obvious decisions (Session 0, wedged shells, LF `.sln` files, the Analytics boot repository, …).
- **[ROADMAP.md](ROADMAP.md)** — known gaps and what is planned.

> **Safety.** tcDeploy restarts PLCs attached to physical machines. It is not a safety system and
> does not replace one: interlocks belong in the PLC and safety functions in certified safety
> hardware (e.g. TwinSAFE). It never deploys the TwinSAFE project. See [SECURITY.md](SECURITY.md)
> for the security model of the build box.

## Requirements

- **Linux side:** bash, Python 3, OpenSSH client, `tar`, `iconv`, git. `tcanalytics` needs
  `paho-mqtt` only for projects with an Analytics Logger.
- **Build box:** Windows 10 1803+ / Server 2019+ with TwinCAT 3.1 XAE (developed against 4026),
  OpenSSH Server, Windows PowerShell 5.1, and a build account that is logged on automatically.
- **Network:** SSH from Linux to the build box; an ADS route from the build box to each target.

## Layout

| Path | What |
|---|---|
| `bin/` | the verbs you run from Linux (put on PATH by `tools/install.sh`) |
| `etc/tcworkflow.conf` | **site** defaults; your values go in `etc/tcworkflow.local.conf` (untracked) |
| `skill/` | the agent skill: the full build/deploy procedure, loaded on demand |
| `windows/` | what runs on the build box (pushed to `C:\_tcDeploy\scripts` by `tcscripts`) |
| `windows/lib/` | `Common` · `MessageFilter` · `DteHelper` · `BuildOps` · `AdsOps` · `DeployOps` |
| `tools/` | `install.sh`, the Session 0 smoke test, WinRM bootstrap helper, box diagnostics |

The repo contains no projects. Projects live in their own repos (see [Adding a project](#adding-a-project)).

## Setting up

### 1. The build box (once)

On the Windows machine, elevated, with TwinCAT XAE already installed:

```powershell
.\windows\bootstrap.ps1 -PublicKey "ssh-ed25519 AAAA... you@devbox" `
                        -TcBuildPassword (Read-Host -AsSecureString) -EnableAutologon
```

It creates the build account (or verifies an existing domain account), enables OpenSSH, autologon
and the worker's logon task, and creates `C:\_tcDeploy\` (`-Root` to put it elsewhere). If OpenSSH is
not there yet, `tools/winrm-run.py` can run the bootstrap over WinRM.

### 2. Linux (once per user)

```bash
git clone https://github.com/afarzin1/tcDeploy.git ~/tcDeploy
~/tcDeploy/tools/install.sh                       # idempotent; re-run after moving the checkout
cat > ~/tcDeploy/etc/tcworkflow.local.conf <<'EOF'
BUILD_HOST="buildbox.example.local"
BUILD_USER="tcbuild"
BUILD_SSH_KEY="$HOME/.ssh/id_ed25519"
EOF
tcscripts                                         # push the PowerShell to the box
```

`tools/smoketest.sh` (run from inside a project, once the first one is added) decides `TC_MODE`;
`worker`, the default, is what TwinCAT 4026 needs.

## Adding a project

A project is a TwinCAT repo plus a `tcdeploy.conf` at its root. Add as many as you like; they share
the build box and never touch each other's files.

**1. Write `tcdeploy.conf`** at the root of the TwinCAT repo, next to the `.sln`, and commit it. It
is a shell-syntax key file. Only `SOLUTION` is required to build; a deploy also needs the target and
its platform:

```bash
SOLUTION="<name>.sln"                 # the .sln at the repo root; its stem is the PROJECT name
BUILD_PLATFORM="TwinCAT RT (x64)"     # the TARGET's runtime platform -- ask, do not guess
TARGET_NETID="<AmsNetId of the target>"
SYNC_PATHS="PLC"                      # what the inner loop sends: PLC source, plus any library
                                      # submodule and SafetyPLC if the .tsproj references them
ADS_GUARD_BOOLS="<symbols that mean 'busy', space-separated>"
```

Every key is in the [reference](#tcdeployconf-reference) below. The project's name (`PROJECT`,
default: the `.sln` stem) must be unique on the build box; set it explicitly if two repos have
solutions with the same name.

**2. Prepare the build box, once per project** (a person, as the build user):

- put the repo's **full** tree at `C:\_tcDeploy\projects\<PROJECT>` (a clone or a copy: the inner
  loop only syncs source, so packages, HMI and the rest must already be there);
- open the solution in the XAE Shell once and accept every first-run prompt;
- add a static ADS route to the project's target.

**3. Prove it** from inside the repo: `tcbuild` must go green, then inject an undefined identifier
and confirm it comes back red with the right `file:line`, then revert.

**Agent rules.** The `tcdeploy` skill already carries the mechanical rules for editing a TwinCAT
project from Linux (register new files in the `.plcproj`, never touch `Id="{guid}"` attributes or
CDATA blocks, keep line endings and BOMs, never hand-edit the `.tsproj` or `_Config/`). If the repo
has its own `AGENTS.md`, add a line there saying it is built with tcDeploy and that `tcdeploy` is
never run unprompted.

### How the verbs find the project

Every verb walks up from the current directory to the nearest `tcdeploy.conf` (or uses
`TC_PROJECT_CONF=<path>`) and refuses to run without one. There is deliberately no default project:
building "the default project" from the wrong directory is worse than an error. Run the verbs from
anywhere inside the repo.

### How an agent session finds tcDeploy

Nothing is copied into the project repos. `tools/install.sh` puts three things in place:

| Layer | Where | Loaded | Purpose |
|---|---|---|---|
| Global pointer | a marker-delimited block in `~/.claude/CLAUDE.md` | every Claude Code session | says tcDeploy exists, the verbs are on PATH, load the skill before PLC work, never deploy unprompted |
| Skill | `~/.claude/skills/tcdeploy` → `skill/` | on demand ("use tcDeploy", "does this compile", build errors, deploy) | the full procedure: build loop, output format, deploy rules and exit codes, adding a project |
| Verbs on PATH | `~/.local/bin/tc*` → `bin/` | always | `tcbuild` means the same thing in every repo |

Other agents: point them at `skill/SKILL.md`.

## Commands

| Command | Does |
|---|---|
| `tcbuild` | sync + build this project; prints `file:line: severity: [scope] message` with **XML** line numbers, exits non-zero on error. `--clean`, `--raw` (full log), `--no-sync`, `--visible` |
| `tcsync` | push this project's source to its tree on the build box (pre-flight checked; refuses while any job is running). `--full` adds the system project |
| `tcstatus` | this project's target: run state, deploy guards, identity and health over ADS |
| `tcdeploy <sha>` | **gated** — clean tree at a pushed sha, full sync, manifest check, clean build, guard, activate, verify, tag. `--dry-run` does everything but submit |
| `tcpreflight` | the working-tree checks alone, no network |
| `tcscreen` | screenshot and window text of the build box's desktop; `--click`, `--type`, `--key` to answer a dialog |
| `tcanalytics` | `status`: is the Analytics Storage Provider recording this machine. `capture`: record broker traffic to a file. `watch` is what `tcdeploy` runs |
| `tcreset` | kill the XAE Shell and restart the worker (rarely needed; the watchdog does this per job) |
| `tcscripts` | push `windows/` to the box after editing it |

The box runs **one job at a time, across all projects**: a build of one project waits for a build or
deploy of another to finish. A build takes about 45–65 s with a warm shell and 85–95 s cold.

## `tcdeploy.conf` reference

Only `SOLUTION` is required. Defaults in brackets.

| Key | Meaning |
|---|---|
| `SOLUTION` | the `.sln` at the repo root |
| `PROJECT` | the project's name on the build box; its tree is `C:\_tcDeploy\projects\<PROJECT>`. Must be unique per box [`.sln` stem] |
| `BUILD_CONFIGURATION`, `BUILD_PLATFORM` | the solution configuration the box builds and activates. The platform **must be the target's runtime platform** (`TwinCAT RT (x64)` = Windows x64 XAR, `TwinCAT OS (x64)` = TwinCAT/BSD x64, `TwinCAT OS (ARMV8-A)` = ARM64). `tcdeploy` refuses without it and refuses to activate unless the build produced `_Boot\<BUILD_PLATFORM>\Plc\*.app` [`Release`, none] |
| `TSPROJ` | the system project; never synced except `--full`, never hand-edited [`<PROJECT>.tsproj`] |
| `PLC_PROJ` | the `.plcproj` whose `<Compile Include>` list `tcpreflight` checks [`PLC/PLC.plcproj`] |
| `SYNC_PATHS` | what the inner loop sends, space-separated. Include `SafetyPLC` if the `.tsproj` references it: it is needed to build, never downloaded [`PLC`] |
| `FULL_SYNC_EXTRA` | added by `tcsync --full`, which `tcdeploy` always uses [`_Config <TSPROJ> <SOLUTION>`] |
| `TARGET_NETID`, `TARGET_HOST` | the controller's AmsNetId (required for `tcstatus`/`tcdeploy`) and its address, for humans |
| `ADS_PLC_PORT` | PLC runtime port [`851`] |
| `ADS_GUARD_BOOLS`, `ADS_GUARD_STRINGS` | symbols read before activating; any TRUE bool, non-empty string or unreadable symbol refuses the deploy. Name whatever means "busy": a running sequence, a loaded test, high voltage up [none] |
| `ADS_HOSTNAME_SYMBOL`, `EXPECTED_HOSTNAME` | the STRING symbol holding the IPC hostname the PLC publishes, and the name this target must report. `tcdeploy` refuses (rc 8) on mismatch or if unreadable. Identical machines run identical code, so the NetId alone does not prove which machine you are on [none] |
| `ADS_HEALTH_BOOLS`, `ADS_HEALTH_TIMEOUT` | BOOLs that must all read TRUE within the timeout after Run, or `tcdeploy` exits 9 naming the ones that did not [none, `60`] |
| `DEPLOY_TAG_PREFIX` | deploy record tags `<prefix>/<UTC timestamp>` [`deployed/<PROJECT>`] |
| `ANALYTICS_WATCH`, `ANALYTICS_BROKER`, `ANALYTICS_TOPIC`, `ANALYTICS_SETTLE` | the Analytics Storage Provider watch is **automatic** for a project whose `.tsproj` has an Analytics Logger; broker and MainTopics are read from it. `ANALYTICS_WATCH=off` disables it; the others override the `.tsproj` or bound the wait [`auto`, from `.tsproj`, from `.tsproj`, `110` s] |
| `BOOT_CONFIG_MUST_CONTAIN` | extra strings that must appear in the generated `CurrentConfig.xml` (Analytics streams are checked automatically) [none] |
| `REPO_LOCAL` | only when the conf does not sit in the repo it describes [the conf's directory] |

Site settings — build box, SSH user and key, `TC_MODE`, `REMOTE_ROOT`, timeouts — live in
`etc/tcworkflow.conf` (defaults) and `etc/tcworkflow.local.conf` (yours), and apply to every project.

## What lives where on the build box

```
C:\_tcDeploy\
  scripts\               windows/ from this repo (pushed by tcscripts)
  queue\   out\          job files in; .log / .json / .rc out (one worker, jobs serialised)
  state\                 worker.log, <PROJECT>.manifest.txt / .sha256, <job>.running markers
  tmp\                   transient scripts shipped by tc_ps_file, deleted after use
  projects\
    <PROJECT>\           one tree per project; tcbuild AND tcdeploy build here
    <PROJECT>\
    ...
```

`REMOTE_ROOT` in the site config (and `-Root` for `bootstrap.ps1`) moves the whole thing.

## `tcdeploy` exit codes

| rc | Meaning | Anything activated? |
|---|---|---|
| 0 | deployed, target back in Run and healthy, tag pushed | yes |
| 1 | clean build failed | no |
| 2 | refused on Linux: tree not clean, HEAD ≠ sha, or sha not on origin | no |
| 4 | ADS guard: machine busy, or a guard symbol unreadable | no |
| 5 | activated but the target did not return to Run within 60 s — look at the machine now | **yes** |
| 6 | tree on the box did not match the sync manifest | no |
| 7 | the build produced no boot project under `_Boot\<BUILD_PLATFORM>` | no |
| 8 | the target does not identify as `EXPECTED_HOSTNAME` | no |
| 9 | in Run, but a health symbol stayed FALSE for `ADS_HEALTH_TIMEOUT` s — look at the machine now | **yes** |
| 10 | the XAE generated a configuration missing parts of the project (e.g. the Analytics node) | no |
| 11 | deployed and in Run, but the Analytics Storage Provider stopped recording the machine — press Start in the Recorder | **yes** |
| 124 | client timed out waiting for the job (the worker's watchdog normally fires first, giving 1) | unknown — `tcstatus` |

rc 3 is unused.

## Seeing the build box: `tcscreen`

The worker drives an **invisible** XAE Shell, so a build that hangs on a modal dialog (first open of
a solution, a licence prompt, "file changed outside the editor") looks from Linux like a job that
never finishes, until the watchdog kills the shell and the dialog disappears unread. `tcscreen`
looks at that desktop directly, without the job queue (the worker is the thing that is stuck) and
without RDP (which would steal the autologon session).

```bash
tcscreen                               # desktop.png, win-<n>.png per visible XAE window, and their text
tcscreen --click "Yes"                 # press a button in an XAE dialog, then capture again
tcscreen --type "ABC12" [--field Code] # fill an edit box
tcscreen --key "{ENTER}"               # SendKeys syntax
tcscreen --process notepad             # any process, not just TcXaeShell
```

Over SSH it registers a one-off interactive scheduled task, which runs in the build user's session (an
SSH logon is session 0 and cannot see it), and runs `windows/screen.ps1`. Windows are rendered with
`PrintWindow`, so a dialog behind another window still shows. Text comes from UI Automation (with a
timeout, because UIA can hang on a wedged shell) and from Win32 child windows. Nothing is installed
and no port is opened; it needs the autologon desktop to be up and unlocked.

It types what a person gives it. It does **not** read and solve a Beckhoff licence CAPTCHA: that check
exists to put a human in the loop, so a person reads the code from the screenshot and passes it to
`--type`. A licence on the machine is the real fix.

## Analytics Storage Provider

After an activation, the TwinCAT Analytics Storage Provider sometimes stops recording the machine
(MQTT → database) and does not restart, although the PLC keeps publishing. For every project whose
`.tsproj` has an Analytics Logger, `tcdeploy` collects the evidence, read-only over MQTT (the provider
publishes its log, statistics and recordings on the same broker):

- a watcher starts before the job is submitted and records when the stream went offline and came
  back, and every provider log line about the topic;
- after Run it waits (up to `ANALYTICS_SETTLE`) for two statistics updates and decides: recording
  (message count rising), **STOPPED**, or unknown;
- the verdict goes into the deploy tag's message, a line into
  `~/.local/state/tcdeploy/analytics/history.tsv`, and the full evidence into a `.jsonl` next to it.
  STOPPED exits **11**.

There is no automatic restart: the Recorder's start command is undocumented. Next time a recording
has to be restarted by hand, run `tcanalytics capture` while pressing Stop/Start. Background:
[field notes](docs/field-notes.md#analytics-storage-provider).

## The approval gate

`tcdeploy` restarts a PLC attached to physical hardware. It must stay a human decision:

- **Do not** add `tcdeploy` to an agent's permission allowlist.
- **Do not** run an agent that can reach it in a bypass-permissions mode.
- It refuses non-interactively unless you pass `--yes`, and independently refuses if the machine is
  busy.

```jsonc
// .claude/settings.json in a project repo — allow the safe verbs, never the deploy
{ "permissions": { "allow": [
    "Bash(tcsync*)", "Bash(tcbuild*)", "Bash(tcstatus*)", "Bash(tcpreflight*)"
] } }
```

## License

MIT — see [LICENSE](LICENSE). TwinCAT, TwinSAFE and XAE are trademarks of Beckhoff Automation GmbH;
tcDeploy is not affiliated with Beckhoff.
