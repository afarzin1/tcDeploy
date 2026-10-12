#!/usr/bin/env python3
"""
winrm-run.py -- run PowerShell on the build box over WinRM.

BOOTSTRAP ONLY. WinRM is a network logon and lands in a non-interactive session
(design §2.2), so it is exactly the wrong transport for driving the XAE Shell.
It exists here for one job: configuring the box before OpenSSH is installed.
Once bootstrap.ps1 has run, everything goes over SSH.

Password comes from $TCWIN_PASSWORD or an interactive prompt -- never argv, so
it does not land in shell history or the process table.

  export TCWIN_PASSWORD=...
  ./tools/winrm-run.py --user Administrator --script windows/bootstrap.ps1 \
      --arg PublicKey="$(cat ~/.ssh/id_rsa.pub)"
  ./tools/winrm-run.py --user Administrator --command 'Get-Service sshd'
"""
import argparse, base64, getpass, os, sys

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=os.environ.get("BUILD_HOST"), required="BUILD_HOST" not in os.environ,
                    help="build box address (default: $BUILD_HOST)")
    ap.add_argument("--user", required=True, help="local admin on the build box")
    ap.add_argument("--transport", default="ntlm", choices=["ntlm", "kerberos", "basic"])
    ap.add_argument("--script", help="local .ps1 to execute remotely")
    ap.add_argument("--command", help="inline PowerShell instead of --script")
    ap.add_argument("--arg", action="append", default=[], metavar="NAME=VALUE",
                    help="named parameter for --script (repeatable)")
    ap.add_argument("--timeout", type=int, default=1800)
    args = ap.parse_args()

    if not args.script and not args.command:
        ap.error("one of --script or --command is required")

    try:
        import winrm
    except ImportError:
        print("pywinrm not installed. pip install --target <dir> pywinrm requests-ntlm",
              file=sys.stderr)
        return 2

    password = os.environ.get("TCWIN_PASSWORD") or getpass.getpass(
        f"password for {args.user}@{args.host}: ")
    if not password:
        print("no password supplied", file=sys.stderr)
        return 2

    if args.script:
        with open(args.script, encoding="utf-8-sig") as fh:
            body = fh.read()
        # Splat named params so quoting never has to survive a second shell.
        params = {}
        for a in args.arg:
            if "=" not in a:
                ap.error(f"--arg must be NAME=VALUE, got: {a}")
            k, v = a.split("=", 1)
            params[k] = v
        if params:
            lines = ["$TcArgs = @{"]
            for k, v in params.items():
                esc = v.replace("'", "''")
                lines.append(f"  '{k}' = '{esc}'")
            lines.append("}")
            body = "\n".join(lines) + "\n" + body
        ps = body
    else:
        ps = args.command

    session = winrm.Session(
        f"http://{args.host}:5985/wsman",
        auth=(args.user, password),
        transport=args.transport,
        read_timeout_sec=args.timeout + 30,
        operation_timeout_sec=args.timeout,
    )

    print(f"[winrm] {args.user}@{args.host} -- "
          f"{'script ' + args.script if args.script else 'inline command'}",
          file=sys.stderr)
    try:
        r = session.run_ps(ps)
    except Exception as e:                       # noqa: BLE001 -- surface anything
        print(f"[winrm] connection/auth failed: {type(e).__name__}: {e}", file=sys.stderr)
        return 3

    out = r.std_out.decode("utf-8", errors="replace")
    err = r.std_err.decode("utf-8", errors="replace")
    if out:
        sys.stdout.write(out if out.endswith("\n") else out + "\n")
    if err.strip():
        sys.stderr.write("--- stderr ---\n" + err)
    print(f"[winrm] exit={r.status_code}", file=sys.stderr)
    return r.status_code

if __name__ == "__main__":
    sys.exit(main())
