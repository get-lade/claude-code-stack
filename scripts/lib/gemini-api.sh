#!/usr/bin/env bash
# Gemini API caller (ADR-012 revised 2026-06-30 — CLI is dead, use the API).
#
# WHY: the Gemini CLI free tier returns IneligibleTierError ("client no longer
# supported … migrate to Antigravity") as of 2026-06-30, so the CLI rung of the
# ADR-012 ladder is gone. The non-Claude Gemini family is now reached ONLY via
# the REST API. This helper is that path for the three Gemini roles (red-team,
# architecture-critic, historian).
#
# KEY DIFFERENCE FROM THE CLI: the API has NO filesystem access. The CLI used to
# read the repo itself (`gemini --skip-trust -p`). The orchestrating agent must
# now ASSEMBLE the context (diff, files, archived docs) and pipe it in on stdin;
# the helper appends stdin to the prompt before sending.
#
# Gemini 3.1 Pro API (verified 2026-06-30, ai.google.dev):
#   POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent
#   header  x-goog-api-key: <key>
#   body    {contents:[{parts:[{text:<prompt>}]}]}
#   text    .candidates[0].content.parts[0].text
# Model id: gemini-3.1-pro-preview (audit 2026-06-30; "preview" — revisit at /model-audit).
#
# KEY RESOLUTION (never logged): $GEMINI_API_KEY, else macOS Keychain item
# 'gemini-api-key'. All whitespace is stripped (a trailing newline / paste wrap
# would corrupt the header — the DeepSeek 401 lesson, ADR-026).
#
# USAGE
#   source "$DIR/gemini-api.sh"
#   gmn_available                      # 0 if a key resolves
#   echo "<context>" | gmn_call "<prompt>"   # prints model text; exit 0 ok / non-zero degraded
#   gmn_call "<prompt>"                # prompt only, no piped context
#
# Cross-family rule (ADR-011/012): Gemini is non-Claude — never point this at a
# Claude model. The model id + Google-only endpoint are pinned here.

set -uo pipefail
{ set +x; } 2>/dev/null   # never echo the key under a caller's xtrace (ADR-026 lesson)

GMN_API_BASE="${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com/v1beta}"
GMN_MODEL="${GEMINI_API_MODEL:-gemini-3.1-pro-preview}"
GMN_TIMEOUT="${GMN_TIMEOUT:-180}"
GMN_MAX_INPUT_BYTES="${GMN_MAX_INPUT_BYTES:-700000}"   # bound the prompt+context

gmn_trim() { local s="$1"; printf '%s' "${s//[$' \t\r\n']/}"; }

gmn_key() {
  if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    local k; k="$(gmn_trim "$GEMINI_API_KEY")"
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  fi
  if command -v security >/dev/null 2>&1; then
    local k; k="$(security find-generic-password -s gemini-api-key -w 2>/dev/null)" || return 1
    k="$(gmn_trim "$k")"
    [[ -n "$k" ]] && { printf '%s' "$k"; return 0; }
  fi
  return 1
}

gmn_available() { gmn_key >/dev/null 2>&1; }

# gmn_call <prompt>  — optional context on stdin is appended to the prompt.
gmn_call() {
  local prompt="${1:-}"
  if [[ -z "$prompt" ]]; then echo "=== Gemini API: ERROR — empty prompt ===" >&2; return 9; fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "=== Gemini API: UNAVAILABLE — curl/jq missing ==="; return 3
  fi

  local key
  if ! key="$(gmn_key)"; then
    cat <<'EOF'
=== Gemini API: UNAVAILABLE — no key ===
Set it once (local): security add-generic-password -a "$USER" -s gemini-api-key -w 'YOUR_KEY'
Or export GEMINI_API_KEY (cloud/CI). Get a key at https://aistudio.google.com/apikey
EOF
    return 2
  fi

  # Append piped context (if any) so the agent can feed repo content the API can't read itself.
  local ctx=""
  if [[ ! -t 0 ]]; then ctx="$(cat)"; fi
  local full="$prompt"
  [[ -n "$ctx" ]] && full="${prompt}"$'\n\n--- context ---\n'"${ctx}"
  if (( ${#full} > GMN_MAX_INPUT_BYTES )); then
    full="${full:0:GMN_MAX_INPUT_BYTES}"$'\n[...input truncated for the request...]'
  fi

  local body resp http
  body="$(jq -nc --arg t "$full" '{contents:[{parts:[{text:$t}]}]}')"
  resp="$(curl -sS --max-time "$GMN_TIMEOUT" -w '\n%{http_code}' \
    -H "x-goog-api-key: ${key}" \
    -H 'Content-Type: application/json' \
    -d "$body" \
    "${GMN_API_BASE%/}/models/${GMN_MODEL}:generateContent" 2>/dev/null)" \
    || { echo "=== Gemini API: UNAVAILABLE — request failed (network/timeout) ==="; return 5; }
  http="${resp##*$'\n'}"; resp="${resp%$'\n'*}"

  if [[ "$http" != "200" ]]; then
    local err; err="$(printf '%s' "$resp" | jq -r '.error.message // empty' 2>/dev/null)"
    echo "=== Gemini API: UNAVAILABLE — HTTP ${http}${err:+ ($err)} ==="; return 6
  fi
  local text; text="$(printf '%s' "$resp" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)"
  if [[ -z "$text" ]]; then echo "=== Gemini API: UNAVAILABLE — empty response (check safety blocks) ==="; return 7; fi
  printf '%s\n' "$text"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  gmn_call "${1:-Reply OK.}"
fi
