#!/usr/bin/env bash
# Regression suite for the loop-engineering Phase-1 control plane.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/skills/loop-engineer/loop_lib.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
[[ -f "$LIB" ]] || { echo "FAIL: loop_lib.sh not found at $LIB"; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Isolate state dir per run; guard mktemp failure; clean up on exit.
_tmp_home="$(mktemp -d)" || { echo "FAIL: mktemp failed"; exit 1; }
trap 'rm -rf "$_tmp_home"' EXIT
export HOME="$_tmp_home"
# shellcheck disable=SC1090
source "$LIB"

# --- happy-path tests ---

# read on empty -> {}
[[ "$(loop_read_state)" == "{}" ]] && ok "read empty -> {}" || bad "read empty"

# write then read roundtrip
loop_write_state '{"active":true,"iteration":2}'
got="$(loop_read_state | jq -r '.iteration')"
[[ "$got" == "2" ]] && ok "write/read roundtrip" || bad "roundtrip got=$got"

# --- error-path tests ---

# zero-arg write: must not crash and must be idempotent
loop_write_state && ok "zero-arg write survives" || bad "zero-arg write crashed"

# invalid JSON: must silently discard, state file unchanged or absent
prev="$(loop_read_state)"
loop_write_state 'not-json' && ok "invalid JSON write survives" || bad "invalid JSON write crashed"
cur="$(loop_read_state)"
[[ "$cur" == "$prev" ]] && ok "invalid JSON does not corrupt state" || bad "state corrupted: was=$prev now=$cur"

# unset HOME: must not crash (re-source with no HOME set)
(
  unset HOME
  # shellcheck disable=SC1090
  source "$LIB"
  loop_write_state '{"test":1}'
  loop_read_state >/dev/null
  echo "unset-home-ok"
) | grep -q "unset-home-ok" && ok "unset HOME survives" || bad "unset HOME crashed"

# set -e caller: return 0 on mkdir failure must not kill set -e subshell
(
  set -e
  export LOOP_STATE_DIR="/proc/nonexistent-dir-for-test"
  # shellcheck disable=SC1090
  source "$LIB"
  loop_write_state '{"x":1}'
  echo "set-e-ok"
) | grep -q "set-e-ok" && ok "set -e caller not terminated on mkdir failure" || bad "set -e caller terminated"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ $FAIL -eq 0 ]]
