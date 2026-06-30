#!/usr/bin/env bash
# DeepSeek-v4 third-voice adversarial reviewer (ADR-026).
#
# WHY: adversarial review (ADR-011) is delegated to a NON-Claude family so it
# carries different blind spots than the Claude implementer. Today that is Codex
# (OpenAI/GPT-5.5) on high stakes and local Qwen (Alibaba) on routine. ADR-026
# adds DeepSeek-v4 (DeepSeek) as a THIRD, INDEPENDENT advisory voice on
# HIGH-stakes diffs only — three distinct families catch more than two, at the
# cost of one extra cloud call per high-stakes review.
#
# This voice is ADVISORY and ADDITIVE: it never replaces the Codex pass and never
# auto-blocks. The orchestrating agent relays its findings as a distinct voice
# alongside Codex's. A missing key or unreachable API degrades to "voice
# unavailable" (exit non-zero) — it does NOT fail the overall review (the Codex
# pass remains the mandated cross-family gate).
#
# DeepSeek's API is OpenAI-compatible: base https://api.deepseek.com, endpoint
# /chat/completions, model deepseek-v4-pro (top reasoning/agentic tier). Verified
# 2026-06-30 (api-docs.deepseek.com). The older deepseek-chat/reasoner ids retire
# 2026-07-24 — pin v4 ids.
#
# KEY RESOLUTION (never hardcoded, never logged):
#   1. $DEEPSEEK_API_KEY            (cloud / CI — the intended cloud mechanism)
#   2. macOS Keychain item 'deepseek-api-key' via `security find-generic-password`
#      (local default; matches the anthropic-api-key pattern in model-routing.json)
#
# USAGE
#   source "$DIR/deepseek-review.sh"
#   dsr_available                 # 0 if a key resolves, non-zero otherwise
#   dsr_run <agent> [base] [head] # prints the DeepSeek voice block; exit 0 ok / non-zero degraded
#
# Cross-family rule (ADR-011): DeepSeek is non-Claude — it MUST NOT be pointed at
# a Claude model. The model id is pinned below and to a DeepSeek-only base URL.

set -uo pipefail

DSR_API_BASE="${DEEPSEEK_BASE_URL:-https://api.deepseek.com}"
DSR_ENDPOINT="${DSR_API_BASE%/}/chat/completions"
DSR_MODEL="${DEEPSEEK_REVIEW_MODEL:-deepseek-v4-pro}"
DSR_TIMEOUT="${DSR_TIMEOUT:-120}"
DSR_MAX_DIFF_BYTES="${DSR_MAX_DIFF_BYTES:-200000}"   # bound the prompt; oversized diffs are truncated with a marker

# --- key resolution (no echo of the secret anywhere) --------------------------

dsr_key() {
  if [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then
    printf '%s' "$DEEPSEEK_API_KEY"; return 0
  fi
  if command -v security >/dev/null 2>&1; then
    local k
    k="$(security find-generic-password -s deepseek-api-key -w 2>/dev/null)" || return 1
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  fi
  return 1
}

dsr_available() { dsr_key >/dev/null 2>&1; }

# --- diff resolution (mirrors review-router.sh defaults) ----------------------

dsr_default_base() {
  local def
  def="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" && { echo "$def"; return; }
  for b in main master; do
    git rev-parse --verify --quiet "$b" >/dev/null 2>&1 && { echo "$b"; return; }
  done
  echo "HEAD~1"
}

DSR_PROMPT='Adversarially review the diff below. Read the code COLD — you do NOT have the architect plan, the implementer commentary, or the other reviewers findings; you are an independent third voice whose value is the blind spots the others share. Check: correctness, edge cases (empty/null/boundary/malformed), security (injection, auth bypass, secret leakage, RLS holes), error handling, performance (N+1, unbounded loops, missing indexes), concurrency/idempotency, and dependency risk. Output findings as BLOCKING / NON-BLOCKING / NIT with file:line and a one-line why. If you find nothing material, say so plainly — do not invent findings.'

# --- run ----------------------------------------------------------------------

dsr_run() {
  local agent="${1:-unknown}"
  local base="${2:-$(dsr_default_base)}"
  local head="${3:-HEAD}"

  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "=== DeepSeek third voice (ADR-026): UNAVAILABLE — curl/jq missing ==="; return 3
  fi

  local key
  if ! key="$(dsr_key)"; then
    cat <<'EOF'
=== DeepSeek third voice (ADR-026): UNAVAILABLE — no key ===
Set it once (local): security add-generic-password -a "$USER" -s deepseek-api-key -w 'YOUR_KEY'
Or export DEEPSEEK_API_KEY (cloud/CI). This voice is advisory — the Codex pass remains the gate.
EOF
    return 2
  fi

  # Resolve diff; any git failure → degrade (advisory voice, never aborts the review).
  if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 \
     || ! git rev-parse --verify --quiet "${head}^{commit}" >/dev/null 2>&1; then
    echo "=== DeepSeek third voice (ADR-026): UNAVAILABLE — unresolved refs ${base}..${head} ==="; return 4
  fi
  local mb diff
  mb="$(git merge-base "$base" "$head" 2>/dev/null)" || { echo "=== DeepSeek third voice: UNAVAILABLE — merge-base failed ==="; return 4; }
  diff="$(git diff "$mb..$head" 2>/dev/null)" || { echo "=== DeepSeek third voice: UNAVAILABLE — git diff failed ==="; return 4; }
  if [[ -z "$diff" ]]; then
    echo "=== DeepSeek third voice (ADR-026): empty diff ${base}..${head} — nothing to review ==="; return 0
  fi
  if (( ${#diff} > DSR_MAX_DIFF_BYTES )); then
    diff="${diff:0:DSR_MAX_DIFF_BYTES}
[...diff truncated at ${DSR_MAX_DIFF_BYTES} bytes for the review prompt...]"
  fi

  # jq builds the JSON body so the diff is safely encoded (no shell interpolation into JSON).
  local body
  body="$(jq -nc \
    --arg model "$DSR_MODEL" \
    --arg sys "$DSR_PROMPT" \
    --arg diff "$diff" \
    '{model:$model, messages:[{role:"system",content:$sys},{role:"user",content:("Diff under review:\n\n"+$diff)}], temperature:0, stream:false}')"

  local resp http
  resp="$(curl -sS --max-time "$DSR_TIMEOUT" -w '\n%{http_code}' \
    -H "Authorization: Bearer ${key}" \
    -H 'Content-Type: application/json' \
    -d "$body" \
    "$DSR_ENDPOINT" 2>/dev/null)" || { echo "=== DeepSeek third voice: UNAVAILABLE — request failed (network/timeout) ==="; return 5; }
  http="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"

  if [[ "$http" != "200" ]]; then
    # Surface status only — never the key. Body may carry a provider error message.
    local err; err="$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null)"
    echo "=== DeepSeek third voice (ADR-026): UNAVAILABLE — HTTP ${http}${err:+ ($err)} ==="; return 6
  fi

  local content; content="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
  if [[ -z "$content" ]]; then
    echo "=== DeepSeek third voice (ADR-026): UNAVAILABLE — empty response ==="; return 7
  fi

  cat <<EOF
=== DeepSeek third voice (ADR-026) — ${DSR_MODEL} ===
agent : $agent
diff  : ${base}..${head}
--- findings (advisory; does not block) ---
$content
==============================================
EOF
  return 0
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  dsr_run "${1:-cli}" "${2:-}" "${3:-}"
fi
