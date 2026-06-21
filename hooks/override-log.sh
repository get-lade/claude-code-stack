#!/usr/bin/env bash
# PreToolUse hook (matcher: Agent): log subagent dispatches made while the
# project is in a high-sensitivity context, so safety-relevant dispatches are
# auditable. ADR-007 follow-up #5. Best-effort observability (H3) — NEVER a
# gate; always exits 0 and never emits a permissionDecision.
#
# "High-sensitivity context" = the project's stack-config has any of:
#   - domain_mode == "financial-code"   (money/AR/AP/revenue code)
#   - domain_mode == "schema-migration" (one-way-door DB changes)
#   - sensitivity.level == "confidential"
#
# Each such dispatch appends an `override_context` row to subagent-runs.jsonl
# (same log subagent-log.sh writes) capturing the agent, orchestration_mode,
# and which context flag(s) made this a logged dispatch. /agent-performance-
# review and /handoff can then surface "N dispatches under <context>".
#
# This complements subagent-log.sh's plain `dispatch` row — that one logs every
# dispatch; this one tags the safety-relevant subset with WHY it mattered.

set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"

CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

# Only in stack-initialized Tier 2+ projects.
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
[[ -z "$CONFIG" ]] && exit 0
TIER="$(jq -r '.stack_tier // 0' "$CONFIG" 2>/dev/null)"
[[ "$TIER" =~ ^[0-9]+$ ]] || TIER=0
[[ "$TIER" -lt 2 ]] && exit 0

DOMAIN="$(jq -r '.domain_mode // empty' "$CONFIG" 2>/dev/null)"
SENS="$(jq -r '.sensitivity.level // "normal"' "$CONFIG" 2>/dev/null)"
MODE="$(jq -r '.orchestration_mode // "main-thread"' "$CONFIG" 2>/dev/null)"

# Build the list of context flags that make this a logged dispatch.
CONTEXTS=()
[[ "$DOMAIN" == "financial-code" ]] && CONTEXTS+=("financial-code")
[[ "$DOMAIN" == "schema-migration" ]] && CONTEXTS+=("schema-migration")
[[ "$SENS" == "confidential" ]] && CONTEXTS+=("sensitivity:confidential")

# Nothing high-sensitivity → silent (subagent-log.sh still logs the plain row).
[[ "${#CONTEXTS[@]}" -eq 0 ]] && exit 0

AGENT="$(echo "$INPUT" | jq -r '.tool_input.subagent_type // env.CLAUDE_TOOL_INPUT_subagent_type // "unknown"' 2>/dev/null)"
DESC="$(echo "$INPUT" | jq -r '.tool_input.description // env.CLAUDE_TOOL_INPUT_description // empty' 2>/dev/null)"
DESC_TRIMMED="${DESC:0:200}"

PROJECT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CONTEXTS_JSON="$(printf '%s\n' "${CONTEXTS[@]}" | jq -R . | jq -sc .)"

LOG_DIR="$HOME/.claude/logs"; mkdir -p "$LOG_DIR"
if command -v jq &>/dev/null; then
  jq -nc \
    --arg ts "$TS" \
    --arg project "$PROJECT" \
    --arg agent "$AGENT" \
    --arg desc "$DESC_TRIMMED" \
    --arg mode "$MODE" \
    --argjson contexts "$CONTEXTS_JSON" \
    '{event:"override_context", ts:$ts, project:$project, agent:$agent,
      desc:$desc, orchestration_mode:$mode, contexts:$contexts}' \
    >> "$LOG_DIR/subagent-runs.jsonl" 2>/dev/null || true
fi

exit 0
