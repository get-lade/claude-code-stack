#!/usr/bin/env bash
# Tests for scripts/lib/review-router.sh (ADR-025).
# Covers stakes classification (path / domain-mode / sensitivity / force),
# tier selection + model resolution order (env > config > default), the diff
# scope invariant, and the route logger. No network or model calls are made.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/review-router.sh"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
assert_eq() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

export HOME="$TMP/home"
mkdir -p "$HOME/.claude/logs"
LOG="$HOME/.claude/logs/subagent-runs.jsonl"

# --- a throwaway git repo with a base commit on main + a feature branch -------
# build_repo <changed_file_path> : commits base, then a feature commit changing
# the given path; leaves HEAD on the feature branch. Echoes nothing.
build_repo() {
  local changed="$1"
  local R="$TMP/repo"; rm -rf "$R"; mkdir -p "$R"
  (
    cd "$R"
    git init -q -b main
    git config user.email t@t.t; git config user.name t
    echo base > README.md
    git add -A; git commit -qm base
    git checkout -q -b feat
    mkdir -p "$(dirname "$changed")"
    echo change > "$changed"
    git add -A; git commit -qm feat
  )
  echo "$R"
}

# classify <repo> [env assignments...] -> echoes "high"/"routine"
classify() {
  local R="$1"; shift
  ( cd "$R"; env "$@" bash -c "source '$LIB'; rr_classify_stakes main HEAD" ) | awk '{print $1}'
}

# --- 1. classification: routine path ----------------------------------------
R="$(build_repo docs/notes.md)"
assert_eq "doc change -> routine" "routine" "$(classify "$R")"

R="$(build_repo src/utils/formatter.ts)"
assert_eq "plain refactor -> routine" "routine" "$(classify "$R")"

# --- 2. classification: high-stakes paths -----------------------------------
R="$(build_repo src/auth/login.ts)"
assert_eq "auth path -> high" "high" "$(classify "$R")"

R="$(build_repo supabase/migrations/0007_add_rls.sql)"
assert_eq "migration/.sql path -> high" "high" "$(classify "$R")"

R="$(build_repo services/billing/charge.ts)"
assert_eq "billing path -> high" "high" "$(classify "$R")"

R="$(build_repo .env.production)"
assert_eq "dotenv path -> high" "high" "$(classify "$R")"

# --- 3. overrides -----------------------------------------------------------
R="$(build_repo docs/notes.md)"
assert_eq "REVIEW_TIER_FORCE=high beats routine path" "high" "$(classify "$R" REVIEW_TIER_FORCE=high)"
assert_eq "STACK_DOMAIN_MODE=security -> high" "high" "$(classify "$R" STACK_DOMAIN_MODE=security)"
assert_eq "STACK_DOMAIN_MODE=schema-migration -> high" "high" "$(classify "$R" STACK_DOMAIN_MODE=schema-migration)"
assert_eq "STACK_SENSITIVITY=high -> high" "high" "$(classify "$R" STACK_SENSITIVITY=high)"
assert_eq "STACK_DOMAIN_MODE=frontend stays routine" "routine" "$(classify "$R" STACK_DOMAIN_MODE=frontend)"

# --- 4. tier selection vars (high) ------------------------------------------
R="$(build_repo src/auth/login.ts)"
eval_vars() { # <repo> [env...] -> prints "ENGINE|MODEL|EFFORT|SCOPE|ESC_MODEL"
  local R="$1"; shift
  ( cd "$R"; env "$@" bash -c "source '$LIB'; rr_run x main HEAD >/dev/null; echo \"\$RR_ENGINE|\$RR_MODEL|\$RR_EFFORT|\$RR_SCOPE|\$RR_ESC_MODEL\"" )
}
assert_eq "high tier = codex/gpt-5.5/high/diff" "codex|gpt-5.5|high|diff|" "$(eval_vars "$R")"

# --- 5. tier selection vars (routine) + escalation --------------------------
R="$(build_repo docs/notes.md)"
assert_eq "routine tier = local/qwen + gpt-5.4 escalation, diff scope" \
  "local|qwen2.5-coder:32b|n/a|diff|gpt-5.4" "$(eval_vars "$R")"

# --- 6. model resolution order: env > config > default ----------------------
# config file with a custom routine model; env should still win over it.
CFG="$TMP/custom-routing.json"
cat > "$CFG" <<'JSON'
{ "review_tiers": { "routine": { "model": "qwen2.5-coder:72b", "escalation_model": "gpt-5.4" },
                    "high": { "model": "gpt-5.5", "effort": "high" } } }
JSON
R="$(build_repo docs/notes.md)"
assert_eq "config repoints routine model" \
  "local|qwen2.5-coder:72b|n/a|diff|gpt-5.4" "$(eval_vars "$R" RR_CONFIG="$CFG")"
assert_eq "env beats config for routine model" \
  "local|kimi-k2|n/a|diff|gpt-5.4" "$(eval_vars "$R" RR_CONFIG="$CFG" REVIEW_ROUTINE_MODEL=kimi-k2)"

# --- 7. route logger appends one review_route row ---------------------------
rm -f "$LOG"
( cd "$R"; bash -c "source '$LIB'; rr_log_route reviewer routine local qwen2.5-coder:32b diff no" )
if [[ -f "$LOG" ]]; then
  n="$(grep -c '"event":"review_route"' "$LOG" 2>/dev/null || echo 0)"
  assert_eq "rr_log_route wrote 1 review_route row" "1" "$n"
  ev="$(jq -r '.stakes' "$LOG" 2>/dev/null)"
  assert_eq "logged stakes field" "routine" "$ev"
else
  fail "rr_log_route wrote 1 review_route row (no log file)"
fi

# --- 8. cross-family invariant: no tier resolves to a Claude/anthropic model -
R="$(build_repo src/auth/login.ts)"
hi="$(eval_vars "$R")"
R2="$(build_repo docs/notes.md)"
lo="$(eval_vars "$R2")"
if echo "$hi$lo" | grep -qiE 'claude|anthropic|opus|sonnet|haiku|fable'; then
  fail "cross-family invariant (a tier routed to a Claude model)"
else
  pass "cross-family invariant (no tier routes to a Claude model)"
fi

# --- 9. ADR-025 review hardening: fail-safe + cross-family enforcement -------

# 9a. expanded regex covers crypto/auth paths the original list missed
for p in src/lib/jwt.ts infra/kms/keyring.tf wallet/seed_phrase.ts auth/private_key.pem config/tls/cert.pem services/hmac/verify.ts; do
  R="$(build_repo "$p")"
  assert_eq "expanded regex: $p -> high" "high" "$(classify "$R")"
done

# 9b. invalid REVIEW_TIER_FORCE is IGNORED — must NOT downgrade a high-stakes diff
R="$(build_repo src/auth/login.ts)"
assert_eq "REVIEW_TIER_FORCE typo ignored -> still high" "high" "$(classify "$R" REVIEW_TIER_FORCE=hgih)"
assert_eq "REVIEW_TIER_FORCE=routine honored (by design)" "routine" "$(classify "$R" REVIEW_TIER_FORCE=routine)"

# 9c. git fail-safe: an unresolvable ref defaults HIGH, never silent routine
R="$(build_repo docs/notes.md)"
gb="$( cd "$R"; bash -c "source '$LIB'; rr_classify_stakes nonexistent-ref HEAD" | awk '{print $1}' )"
assert_eq "bad base ref -> high (fail-safe)" "high" "$gb"

# 9d. ADR-011 enforced at resolution: a Claude model via env OR config is refused
resolve() { ( cd "$R"; env "$@" bash -c "source '$LIB'; rr_resolve REVIEW_HIGH_MODEL '.review_tiers.high.model' gpt-5.5 2>/dev/null" ); }
assert_eq "env Claude model refused -> default" "gpt-5.5" "$(resolve REVIEW_HIGH_MODEL=claude-opus-4-8)"
CFGC="$TMP/claude-routing.json"
echo '{ "review_tiers": { "high": { "model": "claude-sonnet-4-6" } } }' > "$CFGC"
assert_eq "config Claude model refused -> default" "gpt-5.5" "$(resolve RR_CONFIG="$CFGC")"
assert_eq "non-Claude override still passes through" "gpt-5.4" "$(resolve REVIEW_HIGH_MODEL=gpt-5.4)"

echo "----------------------------------------"
echo "review-router: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
