# Changelog

All notable changes to tcDeploy are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/). The `tcdeploy` exit codes and the `tcdeploy.conf` keys
are the public interface.

## [1.0.0] — 2026-10-11

First open-source release, under the MIT License.

- Verbs: `tcsync`, `tcbuild`, `tcstatus`, `tcdeploy`, `tcpreflight`, `tcscreen`, `tcanalytics`,
  `tcreset`, `tcscripts`.
- Build box: autologon worker with a per-job watchdog, solution closed after every job, solution
  configuration pinned per build, boot-repository priming and generated-configuration completeness
  check, compiler diagnostics from the Output window's Build pane mapped to XML line numbers.
- Deploy: clean tree at a pushed sha, SHA-256 manifest verified on the box, clean build, platform,
  identity and ADS guard checks, activation with a verified return to Run, health symbols, deploy tag.
- Analytics Storage Provider watch across every deploy for projects with an Analytics Logger.
- One build box serves many projects: everything lives under `C:\_tcDeploy`, with one tree per project
  under `projects\<PROJECT>`.
- Site settings can live in an untracked `etc/tcworkflow.local.conf`.

[1.0.0]: https://github.com/afarzin1/tcDeploy/releases/tag/v1.0.0
