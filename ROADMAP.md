# tcDeploy — Roadmap

> **Living document.** Update it in the same change as the work. Status: ⬜ todo · 🔲 needs a
> decision. Release history lives in [`CHANGELOG.md`](CHANGELOG.md).

## Verification

- [ ] ⬜ **Tests for the Linux side.** The pieces with real logic and no hardware dependency:
      `tcpreflight` (plcproj registration, BOM stability, generated files), the TwinCAT-line →
      XML-line mapping in `tcbuild`, the LF→CRLF staging and manifest in `tcsync`, and the
      `tcanalytics` verdict logic against recorded broker traffic.
- [ ] ⬜ **CI:** shellcheck, `bash -n`, `py_compile`, and PSScriptAnalyzer for `windows/`.
- [ ] ⬜ **Exercise the rarely-hit deploy refusals live:** rc 7 (wrong platform), rc 8 (identity),
      rc 9 (health) and rc 10 (incomplete configuration) have only been reached by construction.
- [ ] ⬜ **TcUnit as a gate.** Run a project's TcUnit tests on a spare runtime (VM or second IPC, never
      the production machine) as part of `tcbuild`, so "it compiles" is not the only check.

## Features

- [ ] ⬜ **Analytics Storage Provider restart.** Capture the Recorder's start command with
      `tcanalytics capture` and restart a stopped recording automatically after a deploy.
- [ ] ⬜ **MQTT credentials and TLS** for the Analytics watch.
- [ ] 🔲 **Other agents' global pointer.** `install.sh` writes the discovery pointer for Claude Code
      (`~/.claude/CLAUDE.md` and the skill). Decide whether to also install for other agents that
      have a user-level instruction file.
- [ ] 🔲 **Build account.** Recommend a local account (isolated from domain policy) or support a
      domain account as a first-class option.

## Known gaps

- Pre-existing compiler warnings are itemised on every build; read errors first.
- `bootstrap.ps1 -EnableAutologon` stores the password in the registry in clear text (see
  [SECURITY.md](SECURITY.md)).
