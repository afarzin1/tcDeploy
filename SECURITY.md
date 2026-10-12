# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/afarzin1/tcDeploy/security/advisories/new)
rather than in a public issue. Include the affected script, the TwinCAT and Windows versions, and
steps to reproduce. You should get a reply within a week.

## Deployment model

tcDeploy gives whoever can SSH to the build box the ability to build and **activate PLC
configurations on every target that box has an ADS route to**. Treat it accordingly:

- **The build box is a privileged machine.** It is logged on automatically, its build account is a
  local administrator, and it holds ADS routes to production controllers. Keep it on the machine
  network, off general-purpose use, and do not make it a casual RDP target.
- **SSH is key-only.** Authorise only the keys that should be able to deploy. Anyone with a key can
  run any job, including a deploy; the interactive confirmation and the agent's permission prompt
  are on the Linux side.
- **Autologon stores a password.** `bootstrap.ps1 -EnableAutologon` writes it to the registry in
  clear text, readable by any local administrator. Prefer Sysinternals `Autologon.exe`, which keeps
  it in an LSA secret, and use an account that exists only for this.
- **Domain build accounts** are subject to password rotation, lockout and Group Policy; see
  [docs/field-notes.md](docs/field-notes.md#domain-joined-build-boxes).
- **`winrm-run.py`** is for bootstrap only. It reads the password from `TCWIN_PASSWORD` or a prompt,
  never from the command line. Disable WinRM afterwards if you do not otherwise need it.
- **The Analytics watch** reads the MQTT broker the PLC streams to, without credentials or TLS
  (it never publishes). It cannot watch a broker that requires authentication.

## The deploy gate is not a safety system

The clean-tree and pushed-sha checks, the ADS guard, the identity check and the health check reduce
the chance of deploying the wrong thing at the wrong time. They do not make a restart safe. Interlocks
belong in the PLC, and safety functions in certified safety hardware and logic.
