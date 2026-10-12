---
name: tcdeploy
description: Build, check and deploy TwinCAT 3 PLC projects from Linux with tcDeploy (tcbuild, tcstatus, tcdeploy). Use when the user says "use tcDeploy", asks whether TwinCAT or PLC code compiles, wants build errors for .TcPOU/.TcGVL edits, wants the PLC or rig status, asks to deploy/activate/push PLC code to a controller, or wants to onboard a TwinCAT repo to tcDeploy.
---

# tcDeploy

TwinCAT has no headless compiler. tcDeploy drives the XAE Shell on a Windows
build box from Linux, so a session editing `.TcPOU`/`.TcGVL` files here can
compile, read errors, and (when asked) activate onto the PLC. The verbs are
plain commands on PATH; run them from **inside the TwinCAT repo**. They find
the repo's `tcdeploy.conf`, which says what to build and which controller it
targets. The tcDeploy checkout (its README is the operating manual) is wherever the
verbs link to: `TCD="$(dirname "$(dirname "$(readlink -f "$(command -v tcbuild)")")")"`.

## First, check the setup

```bash
command -v tcbuild            # empty -> tcDeploy is not installed: run tools/install.sh in its checkout
git rev-parse --show-toplevel && test -f "$(git rev-parse --show-toplevel)/tcdeploy.conf" && echo conf-ok
```

No `tcdeploy.conf` → this repo is not onboarded; see **Onboarding** below.

## The loop: edit → build → read → fix

```bash
tcbuild            # syncs the source to the box, builds, prints diagnostics, exit code is the verdict
tcbuild --clean    # when results look stale
tcbuild --raw      # the full job log, for when the parsed output is not enough
```

Output, errors first, then warnings:

```
PLC/POUs/MAIN.TcPOU:22: error: C0046: Identifier 'undefinedSymbolXYZ' not defined
PLC/POUs/MAIN.TcPOU:261: warning: [runStep] C0197: Implicit conversion from 'LREAL' to 'REAL'
```

- Path is repo-relative and the line is the **XML line in that file**. Open it, go there.
- `[name]` is the method/action/property containing the diagnostic.
- Exit 0 means it compiles. Warnings do not fail the build; many are pre-existing, do not "fix" them as a side effect.
- `tcbuild` refuses to sync if a new file is not registered in the `.plcproj`, if an edit flipped a file's UTF-8 BOM state, or if a generated file (`*.tsproj`, `_Config/*.xti`) was touched. Fix the cause; never bypass with `--no-preflight`.
- Builds take about 45–65 s warm, 85–95 s cold. Never run two at once.
- `error: job exceeded the … watchdog`: the shell wedged and was killed. Just run `tcbuild` again. `tcreset` exists for a worker that stays stuck.
- A job running far past ~100 s is usually a **modal dialog** in the invisible shell. While it is still running, `tcscreen` captures the box's desktop (a PNG per XAE window, and their text) — look at the PNGs with Read. Answer with `tcscreen --click "<button>"` / `--type` / `--key` only when the right answer is unambiguous and harmless (e.g. trusting the solution folder); otherwise show the user and ask. Never read and enter a licence CAPTCHA yourself: show the user the screenshot and `--type` the code they give you.

Mechanical rules for editing: register new files in the `.plcproj` (`<Compile Include>`), never touch `Id="{guid}"` attributes or break `<![CDATA[…]]>` blocks, keep line endings and BOM as found, never hand-edit `*.tsproj` or `_Config/`.

## Status

```bash
tcstatus           # system/PLC state and the deploy-guard symbols, read over ADS from the box
```

## Deploy — only when the user explicitly asks in this session

`tcdeploy` restarts the PLC: outputs drop, non-persistent state is lost. Never run it unprompted; propose it and wait. When asked:

1. `tcbuild` is green.
2. Commit and **push**; the working tree must be clean and HEAD must be the commit to deploy.
3. `tcdeploy HEAD --dry-run` runs every check and the sync without touching the rig. Show the result.
4. `tcdeploy HEAD --yes` (no terminal for the typed confirmation here; the user's request is the approval).

Exit codes: 0 deployed, in Run and healthy · 1 build failed · 2 tree not clean / not at sha / not pushed · 4 rig busy (guard) · 5 activated but not back in Run — tell the user immediately · 6 tree on the box did not match the sync manifest · 7 no boot project for the configured platform · 8 target does not identify as the expected hostname (wrong machine) · 9 in Run but a health symbol never went TRUE — tell the user immediately · 11 in Run, but the Analytics Storage Provider stopped recording the machine to the database — tell the user immediately: someone presses Start in the Storage Provider Recorder. Offer `tcanalytics capture` while they do it (learns the undocumented start command for a future automatic restart). The evidence path is in the output; the verdict is also in the deploy tag.

tcDeploy deploys the PLC project only; it never downloads or gates on TwinSAFE. `--allow-unpushed` deploys history only this machine has; avoid it.

On success a tag `deployed/<project>/<timestamp>` is created and pushed; it is the deploy record.

`tcdeploy` waits for the project's health symbols (`ADS_HEALTH_BOOLS`) after Run, and `tcstatus` shows them next to the machine's hostname. If a project has none configured, "in Run" is all you know; say so.

## Adding a project (onboarding a TwinCAT repo)

One build box serves many projects; each TwinCAT repo is one.

1. Write `tcdeploy.conf` at the repo root (shell `KEY="value"` lines; every key is in the README's reference, `$TCD/README.md`): `SOLUTION` (required), `BUILD_PLATFORM` (the target's runtime platform, e.g. `TwinCAT RT (x64)` for a Windows x64 controller — ask, do not guess), `TARGET_NETID`, `SYNC_PATHS`, `ADS_GUARD_BOOLS`/`ADS_GUARD_STRINGS` (ask the user which symbols mean "busy"). `PROJECT` defaults to the `.sln` stem and must be unique on the build box. Commit it.
2. One-time, by a human on the build box: put the repo's full tree at `C:\_tcDeploy\projects\<PROJECT>`, open the solution in the XAE Shell once as the build user and accept every first-run prompt, and add an ADS route to the target.
3. `tcbuild` from the repo. Then verify the failure path: inject an undefined identifier, confirm `tcbuild` goes red with the right `file:line`, revert.
