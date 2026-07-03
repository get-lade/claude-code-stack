#!/usr/bin/env bash
# Tests for scripts/lib/openai-review.sh (ADR-030): codex_transport resolution +
# precedence (env > project stack-config > default api) and the ADR-011
# Claude-family model guard. No network calls — oair_call itself is not invoked.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/openai-review.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 (got: '${2:-}')"; FAIL=$((FAIL+1)); }

# transport <env-or-empty> [project-transport-or-empty]
# Resolves oair_transport in an ISOLATED temp git repo so the project-config
# layer is controllable and the real repo's config never leaks in.
transport() {
  local envval="$1" proj="${2:-}"
  local d; d="$(mktemp -d)"
  (
    cd "$d" || exit 1
    git init -q
    local root; root="$(git rev-parse --show-toplevel)"
    if [[ -n "$proj" ]]; then
      mkdir -p "$root/.claude"
      printf '{"review":{"codex_transport":"%s"}}\n' "$proj" > "$root/.claude/stack-config.json"
    fi
    if [[ -n "$envval" ]]; then export REVIEW_CODEX_TRANSPORT="$envval"; else unset REVIEW_CODEX_TRANSPORT; fi
    # shellcheck disable=SC1090
    source "$LIB"
    oair_transport
  )
  rm -rf "$d"
}

check() { # check <label> <expected> <actual>
  [[ "$3" == "$2" ]] && pass "$1" || fail "$1" "$3"
}

# --- precedence + defaults ---------------------------------------------------
check "default (no env, no project) => api"        api "$(transport '' '')"
check "env=cli => cli"                             cli "$(transport cli '')"
check "project=cli (no env) => cli"                cli "$(transport '' cli)"
check "project=api (no env) => api"                api "$(transport '' api)"
check "env=api BEATS project=cli"                  api "$(transport api cli)"
check "env=cli BEATS project=api"                  cli "$(transport cli api)"

# --- invalid values fall through, never a novel transport --------------------
check "invalid env => api"                          api "$(transport grpc '')"
check "invalid project => api"                      api "$(transport '' bogus)"
check "invalid env, valid project => project"       cli "$(transport grpc cli)"

# --- ADR-011 Claude-family model guard ---------------------------------------
( source "$LIB"; oair_guard_model claude-opus-4-8 2>/dev/null ) \
  && fail "guard refuses claude model" "allowed" || pass "guard refuses claude model"
( source "$LIB"; oair_guard_model claude-sonnet-5 2>/dev/null ) \
  && fail "guard refuses sonnet" "allowed" || pass "guard refuses sonnet"
( source "$LIB"; oair_guard_model gpt-5.5 2>/dev/null ) \
  && pass "guard allows gpt-5.5" || fail "guard allows gpt-5.5" "refused"

# --- oair_call refuses a Claude model up front (exit 10, no network) ---------
( source "$LIB"; oair_call "review this" claude-opus-4-8 </dev/null >/dev/null 2>&1 )
[[ "$?" -eq 10 ]] && pass "oair_call refuses claude model (exit 10)" || fail "oair_call refuses claude model" "exit $?"

# --- empty prompt => exit 9 --------------------------------------------------
( source "$LIB"; oair_call "" </dev/null >/dev/null 2>&1 )
[[ "$?" -eq 9 ]] && pass "oair_call empty prompt => exit 9" || fail "oair_call empty prompt" "exit $?"

# --- bounded run: a hanging command is killed non-zero within the timeout ----
# (guards the cli→api fallback against a quarantined codex that HANGS, ADR-030)
( source "$LIB"; _oair_timeout 1 sleep 5 )
[[ "$?" -ne 0 ]] && pass "_oair_timeout kills a hang (non-zero)" || fail "_oair_timeout kills a hang"

# --- zsh portability of the resolver (the review-router bad-substitution class)
if command -v zsh >/dev/null 2>&1; then
  z="$(zsh -c "unset REVIEW_CODEX_TRANSPORT; source '$LIB'; oair_transport" 2>/dev/null)"
  check "zsh: default => api" api "$z"
else
  echo "SKIP: zsh not available"
fi

echo
echo "openai-review: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
