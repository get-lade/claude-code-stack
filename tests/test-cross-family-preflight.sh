#!/usr/bin/env bash
# Tests for scripts/lib/cross-family-preflight.sh (ADR-022).
# Covers the verdict matrix (READY / BLOCKED_NETWORK / BLOCKED_NOCREDS) and the
# deviation logger. Network reachability is stubbed so the suite never makes a
# real outbound call.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/cross-family-preflight.sh"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Stub HOME so the deviation log goes to a temp location.
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/logs"
LOG="$HOME/.claude/logs/subagent-runs.jsonl"

# --- helper: run cfp_run with stubbed checks, echo the verdict ---------------
# Args: have_cli(yes/no) have_key(yes/no) reachable(yes/no/unknown)
run_verdict() {
  # Use distinct names — cfp_run declares `local cli/key/reach`, which would
  # shadow same-named stub vars under bash dynamic scoping.
  local t_cli="$1" t_key="$2" t_reach="$3"
  (
    # shellcheck disable=SC1090
    source "$LIB"
    cfp_have_cli() { echo "$t_cli"; }
    cfp_have_key() { echo "$t_key"; }
    cfp_api_reachable() { echo "$t_reach"; }
    cfp_run >/dev/null
    echo "$CFP_VERDICT"
  )
}

# 1. CLI present + reachable => READY
[[ "$(run_verdict yes no yes)" == "READY" ]] \
  && pass "CLI + reachable => READY" || fail "CLI + reachable => READY"

# 2. Key present + reachable => READY
[[ "$(run_verdict no yes yes)" == "READY" ]] \
  && pass "key + reachable => READY" || fail "key + reachable => READY"

# 3. Key present but NOT reachable => BLOCKED_NETWORK (failure mode 2)
[[ "$(run_verdict no yes no)" == "BLOCKED_NETWORK" ]] \
  && pass "key + blocked => BLOCKED_NETWORK" || fail "key + blocked => BLOCKED_NETWORK"

# 4. CLI present but NOT reachable => BLOCKED_NETWORK (codex also hits the API)
[[ "$(run_verdict yes no no)" == "BLOCKED_NETWORK" ]] \
  && pass "CLI + blocked => BLOCKED_NETWORK" || fail "CLI + blocked => BLOCKED_NETWORK"

# 5. Neither CLI nor key => BLOCKED_NOCREDS (failure mode 1), reachability moot
[[ "$(run_verdict no no no)" == "BLOCKED_NOCREDS" ]] \
  && pass "no creds => BLOCKED_NOCREDS" || fail "no creds => BLOCKED_NOCREDS"

# 6. Probe could not run (no curl) but creds exist => PROBE_SKIPPED
[[ "$(run_verdict no yes unknown)" == "PROBE_SKIPPED" ]] \
  && pass "unknown reach => PROBE_SKIPPED" || fail "unknown reach => PROBE_SKIPPED"

# 7. cfp_have_key reads the real env (empty => no, set => yes)
( source "$LIB"; OPENAI_API_KEY=""; [[ "$(cfp_have_key)" == "no" ]] ) \
  && pass "empty key => no" || fail "empty key => no"
( source "$LIB"; export OPENAI_API_KEY="sk-test"; [[ "$(cfp_have_key)" == "yes" ]] ) \
  && pass "set key => yes" || fail "set key => yes"

# 8. cfp_log_deviation appends a well-formed row
(
  source "$LIB"
  cd "$TMP"
  cfp_log_deviation reviewer BLOCKED_NETWORK proceed-with-deviation "design already cross-family reviewed"
)
if [[ -s "$LOG" ]] && jq -e 'select(.event=="cross_family_deviation" and .agent=="reviewer" and .decision=="proceed-with-deviation")' "$LOG" >/dev/null 2>&1; then
  pass "deviation row logged"
else
  fail "deviation row logged"
fi

# 9. Verdict block is human-readable (contains VERDICT + FIX lines)
out="$(
  source "$LIB"
  cfp_have_cli() { echo no; }
  cfp_have_key() { echo yes; }
  cfp_api_reachable() { echo no; }
  cfp_run
)"
grep -q "VERDICT" <<<"$out" && grep -q "FIX" <<<"$out" \
  && pass "verdict block formatted" || fail "verdict block formatted"

echo
echo "cross-family-preflight: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
