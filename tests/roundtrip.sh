#!/usr/bin/env bash
# Round-trip test for kg-setup on a throwaway fixture (never touches ~/.copilot).
#   bash tests/roundtrip.sh            -> exits 0 when every check passes
set -u
KIT=$(cd "$(dirname "$0")/.." && pwd)
K="$KIT/bin/kg-setup"
T=$(mktemp -d /tmp/kgkit-test.XXXXXX)
export KG_KIT_BACKUP_DIR="$T/backups"
FAIL=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAIL=1; }

snap() {   # <fixture> <out>: worktree contents (minus graph data) + hook config
  (cd "$1" && find . -path '*/.git' -prune -o -path '*/graphify-out' -prune -o -path '*/.code-review-graph' -prune \
     -o -type f -print | LC_ALL=C sort | while read -r f; do echo "== $f"; cat "$f"; done
   for r in ws/repo-a repo-b; do echo "hooksPath[$r]=$(git -C "$r" config --get core.hooksPath)"; done) > "$2"
}

run() { "$K" "$@" --yes --no-user --no-tools "$T/f/ws/fixture.code-workspace" > "$T/last.log" 2>&1; }

# 1. install -> uninstall returns to the original tree
sh "$KIT/tests/make-fixture.sh" "$T/f" > /dev/null
snap "$T/f" "$T/orig"
run install && pass "install" || { fail "install"; cat "$T/last.log"; }
run install; grep -q 'Everything already up to date' "$T/last.log" && pass "idempotent re-run" || { fail "idempotent re-run"; cat "$T/last.log"; }
run doctor && pass "doctor" || { fail "doctor"; grep -E 'FAIL|!!' "$T/last.log"; }
(cd "$T/f/ws/repo-a" && echo 'x' > src/x.js && git add src/x.js \
  && git -c user.email=t@t -c user.name=t commit -qm x 2>&1 | grep -q 'existing pre-commit ran') \
  && pass "carried-over pre-commit still runs" || fail "carried-over pre-commit still runs"
(cd "$T/f/ws/repo-a" && git reset -q --hard HEAD~1)
run uninstall && pass "uninstall" || { fail "uninstall"; cat "$T/last.log"; }
snap "$T/f" "$T/after-uninstall"
# uninstall intentionally keeps chat.useClaudeHooks=false and the workspace setting
# .claude/settings.json is compared separately: graph hooks (old ones too) are removed by design.
C="$T/f/ws/repo-a/.claude/settings.json"
jq -e '.permissions.allow == ["Bash(npm test)"]
       and ([.hooks[][] .hooks[] .command] == ["node agentmemory/session-start.mjs"])' "$C" > /dev/null \
  && pass "claude settings keep non-graph hooks only" || { fail "claude settings keep non-graph hooks only"; cat "$C"; }
strip_claude() { awk '/^== .*\.claude\/settings.json/ { s = 1; next } /^== / { s = 0 } !s' "$1"; }
diff <(strip_claude "$T/orig") <(strip_claude "$T/after-uninstall") | grep '^[<>]' | grep -v 'chat.useClaudeHooks' > "$T/d1"
[ -s "$T/d1" ] && { fail "uninstall leaves original tree"; cat "$T/d1"; } || pass "uninstall leaves original tree"

# 2. install -> restore <backup> returns to the original tree exactly
sh "$KIT/tests/make-fixture.sh" "$T/f" > /dev/null
rm -rf "$T/backups"
run install
B=$(ls -d "$T/backups"/*/ | head -n 1)
"$K" restore --yes "$B" > "$T/last.log" 2>&1 && pass "restore" || { fail "restore"; cat "$T/last.log"; }
snap "$T/f" "$T/after-restore"
diff "$T/orig" "$T/after-restore" > "$T/d2" && pass "restore leaves original tree" || { fail "restore leaves original tree"; cat "$T/d2"; }

[ "$FAIL" = 0 ] && { echo "all round-trip checks passed"; rm -rf "$T"; } || echo "artifacts kept in $T"
exit "$FAIL"
