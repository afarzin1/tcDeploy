#!/usr/bin/env bash
# Shared plumbing for the tc* wrappers (design §4.5). Sourced, not executed.

set -o pipefail

TC_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# ---------------------------------------------------------------- output ----
if [[ -t 2 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_DIM=$'\033[2m';  C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_DIM=; C_BLD=; C_OFF=
fi
tc_log()  { printf '%s\n' "${C_DIM}[tc]${C_OFF} $*" >&2; }
tc_warn() { printf '%s\n' "${C_YEL}[tc] warning:${C_OFF} $*" >&2; }
tc_err()  { printf '%s\n' "${C_RED}[tc] error:${C_OFF} $*" >&2; }
tc_die()  { tc_err "$*"; exit 1; }

# ---------------------------------------------------------------- config ----
# Two layers, so one tcDeploy checkout serves every TwinCAT repo on this box:
#   etc/tcworkflow.conf   -- the SITE: build box, SSH, remote root, timeouts.
#   <repo>/tcdeploy.conf  -- the PROJECT: solution, sync set, target, guards.
# The project file is found by walking UP from the current directory, so the
# same `tcbuild` does the right thing inside any repo that carries one.
# TC_PROJECT_CONF=<path> overrides discovery (scripts, or a repo you cannot
# commit to yet). No project file and no override is an error, on purpose:
# silently building "the default project" from the wrong directory is worse.
tc_find_project_conf() {
  local d="$PWD"
  while :; do
    if [[ -f "$d/tcdeploy.conf" ]]; then printf '%s' "$d/tcdeploy.conf"; return 0; fi
    [[ "$d" == "/" ]] && return 1
    d=$(dirname "$d")
  done
}

# Site only -- for verbs that talk to the box but not to a project
# (tcscripts, tcreset). Everything else uses tc_load_config.
tc_load_site_config() {
  local conf="${TC_CONF:-$TC_ROOT/etc/tcworkflow.conf}"
  [[ -r "$conf" ]] || tc_die "site config not readable: $conf"
  # shellcheck disable=SC1090
  source "$conf"
  # Your site's values live in an untracked file next to it, so a git pull of
  # tcDeploy never collides with them.
  local local_conf="${conf%.conf}.local.conf"
  # shellcheck disable=SC1090
  [[ -r "$local_conf" ]] && source "$local_conf"
  [[ -n "${BUILD_HOST:-}" ]] || tc_die "BUILD_HOST is not set. Put BUILD_HOST=<build box address> in $local_conf (see $conf), or export it."
  : "${REMOTE_ROOT:=C:\\_tcDeploy}"
}

tc_load_config() {
  tc_load_site_config

  local pconf="${TC_PROJECT_CONF:-}"
  if [[ -z "$pconf" ]]; then
    pconf=$(tc_find_project_conf) || tc_die "no tcdeploy.conf found in $PWD or any parent directory.
      Run this from inside a TwinCAT repo that has one, or set TC_PROJECT_CONF=<path>.
      To add a project: create <repo>/tcdeploy.conf as described in $TC_ROOT/README.md (\"Adding a project\")."
  fi
  [[ -r "$pconf" ]] || tc_die "project config not readable: $pconf"
  TC_PROJECT_CONF="$pconf"
  local pdir; pdir="$(cd "$(dirname "$pconf")" && pwd)"
  # shellcheck disable=SC1090
  source "$pconf"
  REPO_LOCAL="${REPO_LOCAL:-$pdir}"
  [[ -d "$REPO_LOCAL" ]] || tc_die "REPO_LOCAL is not a directory: $REPO_LOCAL (from $pconf)"

  [[ -n "${SOLUTION:-}" ]] || tc_die "SOLUTION unset in $pconf (the .sln at the repo root, e.g. SOLUTION=MyMachine.sln)"
  PROJECT="${PROJECT:-${SOLUTION%.sln}}"
  [[ "$PROJECT" =~ ^[A-Za-z0-9._-]+$ ]] || tc_die "PROJECT must be a plain name (letters, digits, . _ -), got '$PROJECT'"
  TSPROJ="${TSPROJ:-${PROJECT}.tsproj}"
  PLC_PROJ="${PLC_PROJ:-PLC/PLC.plcproj}"
  SYNC_PATHS="${SYNC_PATHS:-PLC}"
  FULL_SYNC_EXTRA="${FULL_SYNC_EXTRA:-_Config $TSPROJ $SOLUTION}"
  DEPLOY_TAG_PREFIX="${DEPLOY_TAG_PREFIX:-deployed/${PROJECT}}"
  ADS_HOSTNAME_SYMBOL="${ADS_HOSTNAME_SYMBOL:-}"   # STRING symbol holding the IPC hostname (fb_Machine.stsMachineName)
  EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-}"       # tcdeploy refuses (rc 8) unless the target reports exactly this
  ADS_HEALTH_BOOLS="${ADS_HEALTH_BOOLS:-}"         # must all read TRUE within ADS_HEALTH_TIMEOUT s after Run (rc 9)
  ADS_HEALTH_TIMEOUT="${ADS_HEALTH_TIMEOUT:-60}"
  # Analytics Storage Provider watch (tcanalytics). Broker and topics come from
  # the .tsproj's Analytics Logger; these only override or switch it off.
  ANALYTICS_WATCH="${ANALYTICS_WATCH:-auto}"       # off = never watch this project
  ANALYTICS_BROKER="${ANALYTICS_BROKER:-}"         # host[:port] instead of the .tsproj's
  ANALYTICS_TOPIC="${ANALYTICS_TOPIC:-}"           # MainTopic(s) instead of the .tsproj's
  ANALYTICS_SETTLE="${ANALYTICS_SETTLE:-110}"      # max seconds after the deploy to wait for a verdict
  BOOT_CONFIG_MUST_CONTAIN="${BOOT_CONFIG_MUST_CONTAIN:-}"   # strings that must appear in the generated CurrentConfig.xml (Analytics streams are checked automatically)
  BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-Release}"
  BUILD_PLATFORM="${BUILD_PLATFORM:-}"        # e.g. 'TwinCAT RT (x64)'; required by tcdeploy"
  ADS_PLC_PORT="${ADS_PLC_PORT:-851}"
  ADS_GUARD_BOOLS="${ADS_GUARD_BOOLS:-}"
  ADS_GUARD_STRINGS="${ADS_GUARD_STRINGS:-}"
  TARGET_NETID="${TARGET_NETID:-}"
  TARGET_HOST="${TARGET_HOST:-}"

  # One build box serves many projects. Each gets its own tree under projects\
  # and its own manifest under state\, both named by PROJECT, so repos never
  # trample each other. PROJECT must therefore be unique per build box.
  REMOTE_WORK="${REMOTE_WORK:-${REMOTE_ROOT}\\projects\\${PROJECT}}"
  REMOTE_STATE="${REMOTE_ROOT}\\state"
  REMOTE_MANIFEST="${REMOTE_STATE}\\${PROJECT}.manifest.sha256"
  REMOTE_MANIFEST_TXT="${REMOTE_STATE}\\${PROJECT}.manifest.txt"
}

tc_require_target() {
  [[ -n "${TARGET_NETID:-}" ]] || tc_die "TARGET_NETID unset in $TC_PROJECT_CONF -- needed to talk to the PLC"
}
tc_require_platform() {
  [[ -n "${BUILD_PLATFORM:-}" ]] || tc_die "BUILD_PLATFORM unset in $TC_PROJECT_CONF. A deploy must name the target's runtime platform, e.g. BUILD_PLATFORM='TwinCAT RT (x64)' (Windows x64 XAR) or 'TwinCAT OS (x64)' (TwinCAT/BSD x64), so the boot project can be verified before activation."
}

# JSON helpers for job files: a Windows path with escaped backslashes, and a
# space-separated word list as an array of strings.
tc_json_win()   { printf '%s' "${1//\\/\\\\}"; }
tc_json_array() {
  local out="[" first=1 w
  for w in $1; do
    (( first )) || out+=","
    first=0
    out+="\"${w//\"/\\\"}\""
  done
  printf '%s]' "$out"
}

# ------------------------------------------------------------------- ssh ----
# ControlMaster keeps one connection alive across the whole poll loop, so
# waiting on a build costs ~0 instead of a TCP+auth handshake every 2s.
_tc_ssh_opts() {
  printf '%s\n' \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    -o ControlMaster=auto \
    -o "ControlPath=${TMPDIR:-/tmp}/.tcssh-%r@%h-%p" \
    -o ControlPersist=300
  [[ -n "${BUILD_SSH_KEY:-}" && -r "${BUILD_SSH_KEY}" ]] && printf '%s\n' -i "$BUILD_SSH_KEY"
}

tc_ssh() {
  local -a opts; mapfile -t opts < <(_tc_ssh_opts)
  ssh "${opts[@]}" "${BUILD_USER}@${BUILD_HOST}" "$@"
}

# Run PowerShell on the build box. The remote default shell is cmd.exe, and
# nesting quotes through cmd + ssh + PowerShell is a reliable way to lose an
# afternoon -- so the script goes over as UTF-16LE base64 via -EncodedCommand.
tc_ps() {
  local script="$1" enc
  # $ProgressPreference: a non-interactive powershell.exe serialises progress
  # records as CLIXML onto stderr ("Preparing modules for first use"), which
  # otherwise lands in the middle of the .rc / JSON we are trying to parse.
  # -NonInteractive stops it blocking on an unexpected prompt.
  script="\$ProgressPreference='SilentlyContinue'
\$ErrorActionPreference='Stop'
$script"
  enc=$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0) \
    || tc_die "failed to encode PowerShell payload"
  # The remote login shell is cmd.exe, which caps a command line at 8191
  # chars ("The command line is too long."); CreateProcess itself caps at
  # ~32767 and fails as ssh exit 255 with no message. -EncodedCommand inflates
  # the payload ~2.7x (UTF-16LE then base64), so ~3KB of script is the real
  # budget. Fail with something actionable; anything bigger goes via tc_ps_file.
  if (( ${#enc} > 7800 )); then
    tc_die "PowerShell payload too large for -EncodedCommand (${#enc} chars, cmd.exe limit 8191). Use tc_ps_file to ship it as a script file."
  fi
  tc_ssh "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc"
}

# Run a LOCAL PowerShell script file on the build box: tar it into <REMOTE_ROOT>\tmp,
# execute with -File, delete. No command-line size limit, no quoting through
# cmd.exe. Extra arguments are passed to the script verbatim.
tc_ps_file() {
  local script="$1"; shift
  [[ -r "$script" ]] || tc_die "tc_ps_file: script not readable: $script"
  local name="tc-$(tc_jobid).ps1"
  local dir; dir=$(mktemp -d) || tc_die "tc_ps_file: mktemp failed"
  cp "$script" "$dir/$name"
  local remote_tmp_fs; remote_tmp_fs="$(printf '%s' "$REMOTE_ROOT" | tr '\\' '/')/tmp"
  tc_ssh "if not exist ${REMOTE_ROOT}\\tmp mkdir ${REMOTE_ROOT}\\tmp" >/dev/null 2>&1
  if ! tar -C "$dir" -czf - "$name" | tc_ssh "tar -xzf - -C $remote_tmp_fs"; then
    rm -rf "$dir"; tc_die "tc_ps_file: failed to ship $script"
  fi
  rm -rf "$dir"
  local rc=0
  tc_ssh "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ${REMOTE_ROOT}\\tmp\\${name} $*" || rc=$?
  tc_ssh "del /q ${REMOTE_ROOT}\\tmp\\${name}" >/dev/null 2>&1 || true
  return $rc
}

tc_ssh_check() {
  tc_ssh "exit 0" 2>/dev/null \
    || tc_die "cannot SSH to ${BUILD_USER}@${BUILD_HOST}. Is OpenSSH Server running and the key authorized? (run windows/bootstrap.ps1 on the box first; tools/winrm-run.py can do it before SSH exists)"
}

# ------------------------------------------------------------------ jobs ----
tc_jobid() { printf '%s-%s' "$(date -u +%Y%m%d-%H%M%S)" "$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"; }

# Atomic drop: write .tmp, then rename to .job. The worker only ever globs
# *.job, so it can never observe a half-written job file.
tc_submit_job() {
  local jobid="$1" json="$2"
  local enc; enc=$(printf '%s' "$json" | base64 -w0)
  tc_ps "\$ErrorActionPreference='Stop'
\$q = '${REMOTE_ROOT}\\queue'
New-Item -ItemType Directory -Force -Path \$q | Out-Null
\$bytes = [Convert]::FromBase64String('$enc')
\$tmp = Join-Path \$q '${jobid}.tmp'
[IO.File]::WriteAllBytes(\$tmp, \$bytes)
Move-Item -LiteralPath \$tmp -Destination (Join-Path \$q '${jobid}.job') -Force" >/dev/null \
    || tc_die "failed to submit job $jobid"
}

# Poll for <jobid>.rc. The worker writes .rc LAST, after .log and .json, so its
# existence is the completion barrier -- no partial-result races.
tc_wait_job() {
  local jobid="$1" timeout="${2:-$JOB_TIMEOUT}"
  local waited=0 rc spin='|/-\' i=0
  while (( waited < timeout )); do
    rc=$(tc_ps "\$p='${REMOTE_ROOT}\\out\\${jobid}.rc'
if (Test-Path \$p) { (Get-Content -LiteralPath \$p -Raw).Trim() } else { '' }" 2>/dev/null | tr -d '\r\n ')
    if [[ -n "$rc" ]]; then
      [[ -t 2 ]] && printf '\r\033[K' >&2
      printf '%s' "$rc"; return 0
    fi
    [[ -t 2 ]] && printf '\r%s waiting on %s (%ss)' "${spin:i++%4:1}" "$jobid" "$waited" >&2
    # A warm build is ~60 s, a cold one ~95 s. Far past that, the usual cause is
    # a modal dialog in the invisible shell -- and the watchdog will close it
    # unseen, so say how to look NOW, once.
    if (( waited == 240 )); then
      [[ -t 2 ]] && printf '\r\033[K' >&2
      tc_warn "$jobid still running after ${waited}s -- if a dialog is blocking the shell, 'tcscreen' shows it (and can --click it) before the watchdog kills it"
    fi
    sleep "$POLL_INTERVAL"; waited=$(( waited + POLL_INTERVAL ))
  done
  [[ -t 2 ]] && printf '\r\033[K' >&2
  tc_err "job $jobid timed out after ${timeout}s"
  return 124
}

tc_fetch_log()  { tc_ps "\$p='${REMOTE_ROOT}\\out\\${1}.log';  if (Test-Path \$p) { Get-Content -LiteralPath \$p -Raw }" 2>/dev/null | tr -d '\r'; }
tc_fetch_json() { tc_ps "\$p='${REMOTE_ROOT}\\out\\${1}.json'; if (Test-Path \$p) { Get-Content -LiteralPath \$p -Raw }" 2>/dev/null | tr -d '\r'; }

# ------------------------------------------------------------- repo facts ---
tc_git() { git -C "$REPO_LOCAL" "$@"; }
tc_head_sha() { tc_git rev-parse HEAD 2>/dev/null; }
