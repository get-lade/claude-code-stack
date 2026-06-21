#!/usr/bin/env bash
# Cross-family review preflight probe (ADR-022).
#
# WHY: the adversarial-review agents (reviewer, security-auditor, product-critic)
# reach a non-Claude model family — OpenAI/GPT-5.5 via the `codex` CLI or the
# OpenAI API (ADR-011/015). In cloud/sandboxed sessions that path can be broken
# in four distinct ways, and the agents historically discovered the break ~5
# minutes in (mid-`codex exec`) and then hard-STOPped, stranding the PR:
#
#   1. key not in the SUBAGENT shell env       → 401 "Missing bearer"
#   2. key present but api.openai.com is        → sandbox classifier DENY
#      hard-denied by the auto-mode classifier     (correct: repo source = exfil)
#   3. in-session settings.local.json edits to  → also DENY (classifier-bypass)
#      arm the path are themselves denied
#   4. net: agent exhausts its ladder and STOPs → held PR, no decision
#
# This probe runs FIRST and cheaply: it classifies which (if any) of those
# failure modes is active and prints a structured verdict the agent relays
# up front — before doing any review work. It does NOT arm anything, weaken any
# classifier, or send repo content anywhere (deliverable D: plumbing-only).
#
# The reachability check is an UNAUTHENTICATED GET to the API base. It carries
# no key and no repo data, so it is not an exfiltration vector — a 401/200
# proves the endpoint is reachable under the network policy; a refused/timed-out
# connection proves the policy (or classifier) is blocking it.
#
# USAGE
#   source "$DIR/cross-family-preflight.sh"
#   cfp_run            # prints the verdict block to stdout, sets $CFP_VERDICT
#   cfp_log_deviation <agent> <verdict> <decision> [note]
#
# VERDICTS (also the exit status of cfp_run: 0 READY, non-zero otherwise)
#   READY            a usable path exists (CLI reachable, or key + reachable API)
#   BLOCKED_NETWORK  a credential exists but api.openai.com is NOT reachable
#                    (failure mode 2 — environment/network-policy fix required)
#   BLOCKED_NOCREDS  no codex CLI and no OPENAI_API_KEY (failure mode 1)
#   PROBE_SKIPPED    no curl/tooling to probe with (treat as unknown → degrade)

set -uo pipefail

# Endpoint the OpenAI family (CLI and API) talks to. Unauthenticated GET.
CFP_API_BASE="${OPENAI_BASE_URL:-https://api.openai.com}"
CFP_PROBE_URL="${CFP_API_BASE%/}/v1/models"
CFP_PROBE_TIMEOUT="${CFP_PROBE_TIMEOUT:-6}"

# --- individual checks (each prints a yes/no token, no side effects) ----------

cfp_have_cli() { command -v codex >/dev/null 2>&1 && echo yes || echo no; }

cfp_have_key() {
  # The key must reach THIS (the subagent's) shell — printenv, not a settings
  # file. Empty or unset both count as absent.
  [[ -n "${OPENAI_API_KEY:-}" ]] && echo yes || echo no
}

cfp_api_reachable() {
  # Unauthenticated GET. We only care that bytes flow back (any HTTP status),
  # which proves the network policy + classifier permit the connection. No key,
  # no repo data on the wire.
  if ! command -v curl >/dev/null 2>&1; then echo unknown; return; fi
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' \
            --max-time "$CFP_PROBE_TIMEOUT" \
            "$CFP_PROBE_URL" 2>/dev/null)" || code="000"
  # 000 = could not connect (DNS/refused/timeout/classifier-deny). Any real
  # HTTP status (200/401/403/429/5xx) means the endpoint answered → reachable.
  if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && [[ "$code" != "000" ]]; then
    echo yes
  else
    echo no
  fi
}

# --- verdict ------------------------------------------------------------------

cfp_run() {
  local cli key reach verdict fix
  cli="$(cfp_have_cli)"
  key="$(cfp_have_key)"

  if [[ "$cli" == "no" && "$key" == "no" ]]; then
    # No credential of any kind reaches this shell. Reachability is moot.
    verdict="BLOCKED_NOCREDS"
    reach="n/a"
    fix="Set OPENAI_API_KEY in the cloud ENVIRONMENT's variables (it must reach the subagent shell — printenv, not settings.local.json). See docs/runbooks/cross-family-review-cloud.md."
  else
    reach="$(cfp_api_reachable)"
    if [[ "$reach" == "yes" ]]; then
      verdict="READY"
      fix="none"
    elif [[ "$reach" == "unknown" ]]; then
      verdict="PROBE_SKIPPED"
      fix="curl not available to probe; treat cross-family as unverified."
    else
      verdict="BLOCKED_NETWORK"
      fix="Allow api.openai.com at the ENVIRONMENT / network-policy layer (NOT settings.local.json — that is classifier-blocked by design). See docs/runbooks/cross-family-review-cloud.md."
    fi
  fi

  CFP_VERDICT="$verdict"

  cat <<EOF
=== cross-family preflight (ADR-022) ===
codex CLI on PATH : $cli
OPENAI_API_KEY    : $key   (in THIS shell's env)
api.openai.com    : $reach
VERDICT           : $verdict
FIX               : $fix
========================================
EOF

  [[ "$verdict" == "READY" ]]
}

# --- deviation logging (best-effort; never fails the caller) ------------------
# Appends one row to the same log subagent-log.sh writes, so /handoff and
# reviews can surface "N cross-family deviations this session."
cfp_log_deviation() {
  local agent="${1:-unknown}" verdict="${2:-unknown}" decision="${3:-unknown}" note="${4:-}"
  command -v jq >/dev/null 2>&1 || return 0
  local log_dir="$HOME/.claude/logs"; mkdir -p "$log_dir" 2>/dev/null || return 0
  local project
  project="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg project "$project" \
    --arg agent "$agent" \
    --arg verdict "$verdict" \
    --arg decision "$decision" \
    --arg note "${note:0:300}" \
    '{event:"cross_family_deviation", ts:$ts, project:$project, agent:$agent,
      preflight_verdict:$verdict, decision:$decision, note:$note}' \
    >> "$log_dir/subagent-runs.jsonl" 2>/dev/null || true
}

# Allow direct execution for the preflight probe (CI / manual / agent one-shot).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cfp_run
fi
