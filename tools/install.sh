#!/usr/bin/env bash
# install.sh -- make tcDeploy discoverable and usable from ANY directory for this user.
#
# Three layers, each idempotent (re-run after moving the checkout):
#   1. ~/.claude/CLAUDE.md  -- a short pointer every Claude Code session loads,
#                              so a session knows tcDeploy exists before it is named
#   2. ~/.claude/skills/tcdeploy -> skill/   -- the full procedure, loaded on demand
#                              when a session sees "use tcDeploy", "does this compile", ...
#   3. ~/.local/bin/tc*     -- the verbs on PATH, so "run tcbuild" means the same thing
#                              in every repo
# Project-specific settings are NOT installed anywhere: each TwinCAT repo carries
# its own tcdeploy.conf (see README, "Adding a project").
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# --- 3. verbs on PATH ---------------------------------------------------------
BIN="${HOME}/.local/bin"; mkdir -p "$BIN"
n=0
for f in "$ROOT"/bin/tc*; do
  [[ -x "$f" ]] || continue
  ln -sfn "$f" "$BIN/$(basename "$f")"; n=$((n+1))
done
echo "verbs : $n linked into $BIN"

# --- 2. the skill ---------------------------------------------------------------
SK="${HOME}/.claude/skills"; mkdir -p "$SK"
ln -sfn "$ROOT/skill" "$SK/tcdeploy"
echo "skill : $SK/tcdeploy -> $ROOT/skill"

# --- 1. the global pointer ----------------------------------------------------
# Marker-delimited so re-running replaces the block instead of appending twice,
# and so a hand-edited CLAUDE.md around it is left alone.
GC="${HOME}/.claude/CLAUDE.md"; mkdir -p "$(dirname "$GC")"; touch "$GC"
BEGIN='<!-- tcdeploy:begin (managed by tcDeploy/tools/install.sh) -->'
END='<!-- tcdeploy:end -->'
block=$(cat <<BLOCK
$BEGIN
## TwinCAT PLC work → tcDeploy
Any TwinCAT 3 PLC repo (\`.TcPOU\`, \`.TcGVL\`, \`.plcproj\`, \`.tsproj\`) is built,
checked and deployed with **tcDeploy**: the verbs \`tcbuild\`, \`tcstatus\`,
\`tcdeploy\` are on PATH and read the repo's \`tcdeploy.conf\`. Load the \`tcdeploy\`
skill (say "use tcDeploy") before compiling or deploying PLC code. Source and
manual: \`$ROOT\`. Never run \`tcdeploy\` unless the user asks for a deploy.
$END
BLOCK
)
if grep -qF "$BEGIN" "$GC"; then
  python3 - "$GC" "$BEGIN" "$END" "$block" <<'PY'
import sys, re
path, b, e, block = sys.argv[1:5]
s = open(path).read()
s = re.sub(re.escape(b) + r".*?" + re.escape(e), lambda m: block, s, count=1, flags=re.S)
open(path, 'w').write(s)
PY
  echo "claude: refreshed the tcDeploy block in $GC"
else
  { [[ -s "$GC" ]] && printf '\n'; printf '%s\n' "$block"; } >> "$GC"
  echo "claude: added the tcDeploy block to $GC"
fi

command -v tcbuild >/dev/null 2>&1 || echo "NOTE: $BIN is not on PATH in this shell. Add to ~/.bashrc:  export PATH=\"\$HOME/.local/bin:\$PATH\""
