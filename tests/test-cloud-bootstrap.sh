#!/usr/bin/env bash
# Test: cloud-bootstrap.sh behaves safely without ever hard-failing a session.
# Offline-only — covers the no-network decision paths (remote guard, marker
# short-circuit, missing token). The actual clone+install path is exercised by
# test-install.sh / the CI install matrix.

set -euo pipefail

cd "$(dirname "$0")/.."
SCRIPT="./scripts/cloud-bootstrap.sh"
MARKER="/tmp/.claude-stack-cloud-bootstrap.done"

failures=0
check() { # desc, expected_rc, actual_rc
  if [[ "$2" == "$3" ]]; then echo "  [PASS] $1"; else
    echo "  [FAIL] $1 (expected rc=$2, got rc=$3)"; failures=$((failures + 1)); fi
}

# 1. No-op (rc 0) when not in a remote/cloud container.
rm -f "$MARKER"
( unset CLAUDE_CODE_REMOTE; bash "$SCRIPT" ) >/dev/null 2>&1; check "no-op outside cloud" 0 $?
[[ ! -f "$MARKER" ]] && echo "  [PASS] no marker written outside cloud" || { echo "  [FAIL] marker written outside cloud"; failures=$((failures + 1)); }

# 2. Public repo: no token needed, and an unreachable clone still exits 0
#    (best-effort, never breaks the session). 127.0.0.1 fails fast, no DNS wait.
rm -f "$MARKER"
out="$(CLAUDE_CODE_REMOTE=true CLAUDE_STACK_REPO_TOKEN="" \
      CLAUDE_STACK_REPO="127.0.0.1:9/nope" bash "$SCRIPT" 2>&1)"; rc=$?
check "tokenless unreachable clone exits 0" 0 "$rc"
grep -q "could not clone" <<<"$out" && echo "  [PASS] clone-failure warning printed" || { echo "  [FAIL] no clone-failure warning"; failures=$((failures + 1)); }

# 3. Marker present → short-circuit (rc 0), even with a token set.
: > "$MARKER"
( CLAUDE_CODE_REMOTE=true CLAUDE_STACK_REPO_TOKEN="dummy" bash "$SCRIPT" ) >/dev/null 2>&1; check "marker short-circuits" 0 $?
rm -f "$MARKER"

if [[ "$failures" -gt 0 ]]; then echo "FAILED: $failures"; exit 1; fi
echo "All cloud-bootstrap tests passed."
