#!/usr/bin/env bash
# tools/smoketest.sh -- design §7 step 1, driven from Linux.
#
# Runs the probe over SSH under a hard wall-clock timeout, because the failure
# mode we are testing for IS a hang: a GUI COM call with no desktop to render on
# blocks forever rather than returning an error.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../bin/_tclib.sh"
tc_load_config

TIMEOUT="${SMOKE_TIMEOUT:-180}"
try_build=0
[[ "${1:-}" == "--build" ]] && try_build=1

tc_ssh_check
tc_log "running smoke test on ${BUILD_HOST} (timeout ${TIMEOUT}s) ..."

set +e
timeout "$TIMEOUT" bash -c "$(declare -f tc_ps tc_ssh _tc_ssh_opts tc_die tc_err); \
  BUILD_USER='$BUILD_USER' BUILD_HOST='$BUILD_HOST' BUILD_SSH_KEY='${BUILD_SSH_KEY:-}' \
  REMOTE_ROOT='$REMOTE_ROOT' TMPDIR='${TMPDIR:-/tmp}' \
  tc_ps \"& '${REMOTE_ROOT}\\\\scripts\\\\smoketest.ps1' -WorkDir '${REMOTE_WORK}' -Solution '${SOLUTION}'$( ((try_build)) && printf ' -TryBuild' )\""
rc=$?
set -e

echo
case "$rc" in
  0)   tc_log "${C_GRN}verdict: direct${C_OFF} -- a network logon CAN drive the DTE."
       tc_log "Set TC_MODE=direct in etc/tcworkflow.conf to skip the worker."
       ;;
  124) tc_err "verdict: HUNG after ${TIMEOUT}s."
       tc_err "This is the Session 0 signature (design §2.2): the COM call is waiting"
       tc_err "on a desktop that does not exist. Keep TC_MODE=worker."
       tc_err "Run 'tcreset' to clear the stranded shell process."
       ;;
  *)   tc_err "verdict: worker -- the probe failed (rc=$rc). See the stage that said FAIL above."
       tc_err "Keep TC_MODE=worker (design §4.2)."
       ;;
esac
exit "$rc"
