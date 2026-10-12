# Contributing to tcDeploy

Thanks for helping.

## Before you start

- Read [`docs/design.md`](docs/design.md) and [`docs/field-notes.md`](docs/field-notes.md). Most
  "simplifications" have been tried; the field notes say what broke.
- For anything larger than a fix, open an issue first so the approach can be agreed.

## Making a change

- Linux side: `bash -n` every shell script you touch, and `python3 -m py_compile` the Python ones.
- Windows side: the scripts must run under **Windows PowerShell 5.1** (STA), not only `pwsh` 7.
- Test on a real build box: a green build, a deliberately red build (an undefined identifier must
  come back with the right `file:line`), and, if you touched the deploy path, a `tcdeploy --dry-run`.
  Say in the pull request what you tested and on which TwinCAT version.
- Keep exit codes stable; agents and scripts depend on them. A new refusal gets a new code, listed in
  the README and the skill.
- Update the docs in the same change: README for anything a user runs, `docs/design.md` for how it
  works, `docs/field-notes.md` for a new TwinCAT behaviour you had to work around, `CHANGELOG.md`.
- **No site data.** Never commit real hostnames, IP addresses, NetIds, credentials, customer or
  machine names. Use `example.local` names and the documentation ranges (`192.0.2.x`).

## AI-assisted contributions

Welcome. You are responsible for what you submit: review it and test it on a build box. Keep agent
instructions in `AGENTS.md` only; do not add tool-specific instruction files (`CLAUDE.md`,
`.cursorrules`, …) to this repo.

## Sign-off and license

tcDeploy is licensed under the [MIT License](LICENSE). By contributing you agree that your
contribution is licensed under the same terms. Please sign off each commit to certify the
[Developer Certificate of Origin](https://developercertificate.org/):

```bash
git commit -s -m "Fix the thing"
```

## Safety

tcDeploy restarts PLCs attached to machines. Contributions must not weaken the deploy gate (the
clean-tree and pushed-sha checks, the ADS guard, the identity check, the interactive confirmation)
without an issue that agrees on it first.
