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
  # Arg 4 (transport, default api) pins REVIEW_CODEX_TRANSPORT so cfp_run resolves
  # deterministically without reading a project stack-config (ADR-030).
  local t_cli="$1" t_key="$2" t_reach="$3" t_transport="${4:-api}"
  (
    export REVIEW_CODEX_TRANSPORT="$t_transport"
    # shellcheck disable=SC1090
    source "$LIB"
    cfp_have_cli() { echo "$t_cli"; }
    cfp_have_key() { echo "$t_key"; }
    cfp_api_reachable() { echo "$t_reach"; }
    cfp_run >/dev/null
    echo "$CFP_VERDICT"
  )
}

# --- api mode (default, ADR-030): a runnable CLI does NOT count — key + API only ---

# 1. api: CLI runnable but NO key => BLOCKED_NOCREDS  (THE malware-block regression guard)
[[ "$(run_verdict yes no yes api)" == "BLOCKED_NOCREDS" ]] \
  && pass "api: CLI-only (no key) => BLOCKED_NOCREDS" || fail "api: CLI-only (no key) => BLOCKED_NOCREDS"

# 2. api: key present + reachable => READY
[[ "$(run_verdict no yes yes api)" == "READY" ]] \
  && pass "api: key + reachable => READY" || fail "api: key + reachable => READY"

# 3. api: key present but NOT reachable => BLOCKED_NETWORK
[[ "$(run_verdict no yes no api)" == "BLOCKED_NETWORK" ]] \
  && pass "api: key + blocked => BLOCKED_NETWORK" || fail "api: key + blocked => BLOCKED_NETWORK"

# 4. api: CLI runnable, no key, unreachable => BLOCKED_NOCREDS (key is the only path)
[[ "$(run_verdict yes no no api)" == "BLOCKED_NOCREDS" ]] \
  && pass "api: CLI-only unreachable => BLOCKED_NOCREDS" || fail "api: CLI-only unreachable => BLOCKED_NOCREDS"

# 5. api: neither CLI nor key => BLOCKED_NOCREDS
[[ "$(run_verdict no no no api)" == "BLOCKED_NOCREDS" ]] \
  && pass "api: no creds => BLOCKED_NOCREDS" || fail "api: no creds => BLOCKED_NOCREDS"

# 6. api: key present, probe unknown (no curl) => PROBE_SKIPPED
[[ "$(run_verdict no yes unknown api)" == "PROBE_SKIPPED" ]] \
  && pass "api: unknown reach => PROBE_SKIPPED" || fail "api: unknown reach => PROBE_SKIPPED"

# --- cli mode: a runnable CLI counts (ADR-022 behavior preserved) ---

# 6a. cli: runnable CLI, no key, reachable => READY
[[ "$(run_verdict yes no yes cli)" == "READY" ]] \
  && pass "cli: runnable CLI + reachable => READY" || fail "cli: runnable CLI + reachable => READY"

# 6b. cli: key fallback (no runnable CLI), reachable => READY
[[ "$(run_verdict no yes yes cli)" == "READY" ]] \
  && pass "cli: key fallback => READY" || fail "cli: key fallback => READY"

# 6c. cli: neither runnable CLI nor key => BLOCKED_NOCREDS
[[ "$(run_verdict no no no cli)" == "BLOCKED_NOCREDS" ]] \
  && pass "cli: no creds => BLOCKED_NOCREDS" || fail "cli: no creds => BLOCKED_NOCREDS"

# 6d. default (transport unset) behaves as api => CLI-only, no key => BLOCKED_NOCREDS
[[ "$(run_verdict yes no yes)" == "BLOCKED_NOCREDS" ]] \
  && pass "default transport = api (CLI-only => BLOCKED_NOCREDS)" || fail "default transport = api"

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

# 9. Verdict block is human-readable (VERDICT + FIX + transport line, ADR-030)
out="$(
  export REVIEW_CODEX_TRANSPORT=api
  source "$LIB"
  cfp_have_cli() { echo no; }
  cfp_have_key() { echo yes; }
  cfp_api_reachable() { echo no; }
  cfp_run
)"
grep -q "VERDICT" <<<"$out" && grep -q "FIX" <<<"$out" && grep -q "codex_transport" <<<"$out" \
  && pass "verdict block formatted (+transport line)" || fail "verdict block formatted (+transport line)"

echo
echo "cross-family-preflight: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
