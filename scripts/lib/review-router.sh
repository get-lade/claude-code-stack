#!/usr/bin/env bash
# Adversarial-review model router (ADR-025).
#
# WHY: the adversarial-review agents (reviewer, security-auditor, product-critic)
# used to run EVERY review on the most expensive tier — gpt-5.5 @ reasoning
# effort=high via the Codex CLI, over a WHOLE-REPO cold read. Logs showed ~210
# review runs/month at ~950K tokens each (~$200). Most diffs are routine; paying
# frontier-tier-high-effort on all of them is the cost driver.
#
# This router classifies a diff's STAKES (cheaply, deterministically, from
# changed paths + domain-mode/sensitivity signals) and selects a tier:
#
#   high     → Codex / gpt-5.5 @ high     (auth, crypto, payment, migration, RLS…)
#   routine  → local Qwen first, escalate → Codex / gpt-5.4 @ medium
#
# Cross-family integrity (ADR-011) is preserved on BOTH tiers: local Qwen
# (Alibaba) and gpt-5.x (OpenAI) are each a different model family than the
# Claude implementer. The router never routes review to a Claude model.
#
# It also fixes SCOPE: every tier reviews the DIFF (base..head), not the whole
# repo — the single biggest token lever, applied even to high-stakes reviews.
#
# CONFIG-DRIVEN MODELS (ADR-025 + Tier-5 forward-compat): the tier model IDs are
# NOT hardcoded. Resolution order, highest first:
#   1. environment variable  (REVIEW_HIGH_MODEL, REVIEW_ROUTINE_MODEL, …)
#   2. config/model-routing.json  ".review_tiers.*"  (via jq, if present)
#   3. built-in default
# So when the Tier-5 box lands, repoint the routine/escalation/high models in
# config (or via env) — no edit to this script.
#
# USAGE
#   source "$DIR/review-router.sh"
#   rr_run <agent> [base] [head]   # prints verdict block, sets RR_* vars
#   rr_log_route <agent> <stakes> <engine> <model> <scope> <escalated>
#
# After rr_run, the caller obeys:
#   RR_STAKES      high | routine
#   RR_ENGINE      local | codex          (initial engine to invoke)
#   RR_MODEL       <resolved routine/high model id>
#   RR_EFFORT      high | medium | n/a    (reasoning effort for codex tiers)
#   RR_SCOPE       diff                   (always diff — scope fix)
#   RR_ESC_ENGINE  codex                  (escalation target for routine)
#   RR_ESC_MODEL   <resolved escalation model id>
#   RR_ESC_EFFORT  medium
#   RR_REASON      one-line why this stakes class was chosen

set -uo pipefail

# Paths whose presence in a diff marks it high-stakes. Matched case-insensitively
# against changed file paths. Keep this list conservative — a false "high" only
# costs money; a false "routine" sends risky code to the cheap tier.
RR_HIGH_STAKES_RE='(auth|login|oauth|session|token|passwd|password|secret|credential|crypto|encrypt|decrypt|signing|payment|billing|invoice|charge|stripe|financ|ledger|payroll|migration|/migrations/|schema|\.sql$|rls|policy|\.env|security|webhook)'

# --- config resolution --------------------------------------------------------

rr_config_file() {
  # $RR_CONFIG wins; else <repo>/config/model-routing.json; else empty.
  if [[ -n "${RR_CONFIG:-}" && -f "${RR_CONFIG}" ]]; then echo "$RR_CONFIG"; return; fi
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  [[ -n "$root" && -f "$root/config/model-routing.json" ]] && { echo "$root/config/model-routing.json"; return; }
  echo ""
}

# rr_resolve <env_var_name> <jq_path> <default>
# env override > config value > default. Empty/null config values fall through.
rr_resolve() {
  local env_name="$1" jq_path="$2" def="$3"
  local env_val="${!env_name:-}"
  [[ -n "$env_val" ]] && { echo "$env_val"; return; }
  local cfg; cfg="$(rr_config_file)"
  if [[ -n "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    local v; v="$(jq -r "${jq_path} // empty" "$cfg" 2>/dev/null)"
    [[ -n "$v" && "$v" != "null" ]] && { echo "$v"; return; }
  fi
  echo "$def"
}

# --- diff resolution ----------------------------------------------------------

rr_default_base() {
  # Merge target: origin default branch if resolvable, else main/master, else HEAD~1.
  local def
  def="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" && { echo "$def"; return; }
  for b in main master; do
    git rev-parse --verify --quiet "$b" >/dev/null 2>&1 && { echo "$b"; return; }
  done
  echo "HEAD~1"
}

rr_changed_files() {
  local base="$1" head="$2"
  local mb; mb="$(git merge-base "$base" "$head" 2>/dev/null || echo "$base")"
  git diff --name-only "$mb..$head" 2>/dev/null
}

# --- classification -----------------------------------------------------------

rr_classify_stakes() {
  # Echoes "high <reason>" or "routine <reason>". Env overrides win first so
  # tests and operators can force a tier.
  local base="$1" head="$2"

  if [[ -n "${REVIEW_TIER_FORCE:-}" ]]; then
    echo "${REVIEW_TIER_FORCE} forced via REVIEW_TIER_FORCE"; return
  fi
  case "${STACK_DOMAIN_MODE:-}" in
    security|schema-migration)
      echo "high domain-mode=${STACK_DOMAIN_MODE}"; return ;;
  esac
  if [[ "${STACK_SENSITIVITY:-}" == "high" ]]; then
    echo "high sensitivity=high"; return
  fi

  local files hit
  files="$(rr_changed_files "$base" "$head")"
  if [[ -n "$files" ]]; then
    hit="$(printf '%s\n' "$files" | grep -iE "$RR_HIGH_STAKES_RE" | head -1)"
    if [[ -n "$hit" ]]; then
      echo "high risk-path: ${hit}"; return
    fi
  fi
  echo "routine no high-stakes paths in diff"
}

# --- tier selection -----------------------------------------------------------

rr_run() {
  local agent="${1:-unknown}"
  local base="${2:-$(rr_default_base)}"
  local head="${3:-HEAD}"

  local classified stakes reason
  classified="$(rr_classify_stakes "$base" "$head")"
  stakes="${classified%% *}"
  reason="${classified#* }"

  RR_STAKES="$stakes"
  RR_REASON="$reason"
  RR_SCOPE="diff"
  RR_ESC_ENGINE=""
  RR_ESC_MODEL=""
  RR_ESC_EFFORT=""

  if [[ "$stakes" == "high" ]]; then
    RR_ENGINE="$(rr_resolve REVIEW_HIGH_ENGINE  '.review_tiers.high.engine'  codex)"
    RR_MODEL="$(rr_resolve  REVIEW_HIGH_MODEL   '.review_tiers.high.model'   gpt-5.5)"
    RR_EFFORT="$(rr_resolve REVIEW_HIGH_EFFORT  '.review_tiers.high.effort'  high)"
  else
    RR_ENGINE="$(rr_resolve REVIEW_ROUTINE_ENGINE '.review_tiers.routine.engine' local)"
    RR_MODEL="$(rr_resolve  REVIEW_ROUTINE_MODEL  '.review_tiers.routine.model'  qwen2.5-coder:32b)"
    RR_EFFORT="n/a"
    RR_ESC_ENGINE="$(rr_resolve REVIEW_ESCALATION_ENGINE '.review_tiers.routine.escalation_engine' codex)"
    RR_ESC_MODEL="$(rr_resolve  REVIEW_ESCALATION_MODEL  '.review_tiers.routine.escalation_model'  gpt-5.4)"
    RR_ESC_EFFORT="$(rr_resolve REVIEW_ESCALATION_EFFORT '.review_tiers.routine.escalation_effort' medium)"
  fi

  cat <<EOF
=== review router (ADR-025) ===
agent      : $agent
diff       : ${base}..${head}
stakes     : $RR_STAKES   ($RR_REASON)
engine     : $RR_ENGINE
model      : $RR_MODEL
effort     : $RR_EFFORT
scope      : $RR_SCOPE
escalation : ${RR_ESC_ENGINE:-none}${RR_ESC_MODEL:+/$RR_ESC_MODEL}${RR_ESC_EFFORT:+@$RR_ESC_EFFORT} (routine only: on low-confidence / non-trivial diff)
===============================
EOF
}

# --- route logging (best-effort; never fails the caller) ----------------------
# Appends one row to subagent-runs.jsonl so /handoff and a quick jq query can
# verify the high/routine split and confirm projected savings.
rr_log_route() {
  local agent="${1:-unknown}" stakes="${2:-unknown}" engine="${3:-unknown}" \
        model="${4:-unknown}" scope="${5:-diff}" escalated="${6:-no}"
  command -v jq >/dev/null 2>&1 || return 0
  local log_dir="$HOME/.claude/logs"; mkdir -p "$log_dir" 2>/dev/null || return 0
  local project; project="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg project "$project" \
    --arg agent "$agent" \
    --arg stakes "$stakes" \
    --arg engine "$engine" \
    --arg model "$model" \
    --arg scope "$scope" \
    --arg escalated "$escalated" \
    '{event:"review_route", ts:$ts, project:$project, agent:$agent,
      stakes:$stakes, engine:$engine, model:$model, scope:$scope, escalated:$escalated}' \
    >> "$log_dir/subagent-runs.jsonl" 2>/dev/null || true
}

# Allow direct execution for manual / CI inspection.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rr_run "${1:-cli}" "${2:-}" "${3:-}"
fi
