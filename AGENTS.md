# AGENTS.md — tcDeploy

This file is the single entry point for **every** AI coding agent working in this repository
(Claude Code, Codex, Cursor, Copilot, Gemini CLI, …). There is deliberately no tool-specific
instruction file — no `CLAUDE.md`, no `.cursorrules` — so there is one set of instructions to keep
current.

**tcDeploy** builds and deploys Beckhoff TwinCAT 3 projects from Linux by driving the XAE Shell on a
Windows build box over SSH. It is the tool itself — if you are working *in a TwinCAT repo* and want
to compile, load the `tcdeploy` skill (`skill/SKILL.md`) instead of reading this.

## Read before editing

1. [`docs/design.md`](docs/design.md) — how it works. The code cites its sections (`design §4.2`);
   keep section numbers stable.
2. [`docs/field-notes.md`](docs/field-notes.md) — the TwinCAT/Windows behaviour behind the less
   obvious code. Read the relevant section before "simplifying" anything: most simplifications have
   been tried and broke.
3. [`README.md`](README.md) — the operating manual, verbs, `tcdeploy.conf` keys, exit codes.

## Layout

- `bin/` — the Linux verbs (bash, plus `tcanalytics` and `tcpreflight` in Python 3). Shared plumbing
  is `bin/_tclib.sh`: config loading, SSH, `tc_ps` / `tc_ps_file`, job submit and wait.
- `windows/` — what runs on the build box. `worker.ps1` is the queue worker; `lib/` holds the
  operations (`DteHelper`, `BuildOps`, `AdsOps`, `DeployOps`).
- `skill/SKILL.md` — the procedure an agent follows in a TwinCAT repo. User-facing; keep it in step
  with the verbs and exit codes.

The repo contains **no projects** and must not: one install serves many TwinCAT repos, each of which
carries its own `tcdeploy.conf`. Keep project names, NetIds and symbols out of code defaults and docs.

## Working rules

- **You cannot test the Windows side here.** It needs a build box with TwinCAT XAE. Keep PowerShell
  changes small and reviewable, make sure they run under **Windows PowerShell 5.1** (no `pwsh`-only
  syntax such as `??`, ternaries or `ForEach-Object -Parallel`), and tell the user what needs a run on
  a real box.
- Check what you can: `bash -n` for shell scripts, `python3 -m py_compile` for Python.
- **Exit codes are a contract** with agents and scripts. Never renumber; a new refusal gets a new
  code, documented in README, `skill/SKILL.md` and `bin/tcdeploy --help`.
- **Never weaken the deploy gate** (clean tree at a pushed sha, manifest check, ADS guard, identity,
  confirmation) as a side effect. It restarts PLCs attached to machines.
- **Docs are part of the change**: README for what users run, `docs/design.md` for how it works,
  `docs/field-notes.md` for a newly discovered TwinCAT behaviour, `CHANGELOG.md` and `ROADMAP.md`.
- **Files:** LF line endings everywhere (`.gitattributes` enforces it); keep the UTF-8 BOM on the
  `windows/*.ps1` files that have one (Windows PowerShell 5.1 reads BOM-less files as ANSI). Keep
  `bin/tc*` and `tools/*.sh`/`*.py` executable.
- **No site data:** never commit real hostnames, IP addresses, NetIds, credentials, customer or
  machine names. Use `example.local` and `192.0.2.x`.
