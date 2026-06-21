#!/usr/bin/env bash
# PreToolUse hook: live mid-flight cost monitor for the loop-engineering control
# plane (ADR-019 Phase 2 — closes the within-iteration runaway gap that the
# between-iteration Stop-hook accrual leaves open).
#
# During an ACTIVE loop with a per_run_budget_usd, on every tool call it sums the
# real logged cost for this loop_id (loop_live_cost) and, if it has reached the
# budget, DENIES the call and marks the loop budget_exceeded so the next Stop
# releases. Outside a loop, or with no budget, it stays silent. Fail-OPEN: any
# error allows the tool (never crash the session over a monitoring failure).
#
# This complements (does not replace) the Stop-hook's between-iteration accrual:
# the Stop-hook catches overruns between iterations; this catches a single
# iteration that blows the budget without ever stopping.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
if [[ ! -f "$LIB" ]]; then
  [[ -n "${HOME:-}" ]] && LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
fi
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

STATE="$(loop_read_state 2>/dev/null || echo '{}')"
[[ "$(echo "$STATE" | jq -r '.active // false' 2>/dev/null)" == "true" ]] || exit 0

BUDGET="$(echo "$STATE" | jq -r '.bounds.per_run_budget_usd // empty' 2>/dev/null)"
[[ -z "$BUDGET" ]] && exit 0
# Only act on a valid positive number.
[[ "$BUDGET" =~ ^[0-9]+(\.[0-9]+)?$ ]] || exit 0

LID="$(echo "$STATE" | jq -r '.loop_id // empty' 2>/dev/null)"
[[ -z "$LID" ]] && exit 0
STARTED="$(echo "$STATE" | jq -r '.started_at // empty' 2>/dev/null)"

TOTAL="$(loop_live_cost "$LID" "$STARTED" 2>/dev/null || echo 0)"
[[ "$TOTAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] || exit 0

# Phase-3 (ADR-022): best-effort real token signal. If this tool-call payload
# carries usage, convert to USD and add it to the logged-row sum so a costly call
# is caught immediately, not one log row later. Absent usage -> logged sum only.
INPUT_RAW="$(cat 2>/dev/null || echo '{}')"
_IN="$(echo "$INPUT_RAW"  | jq -r '(.tool_response.usage.input_tokens  // .usage.input_tokens  // 0)' 2>/dev/null)"
_OUT="$(echo "$INPUT_RAW" | jq -r '(.tool_response.usage.output_tokens // .usage.output_tokens // 0)' 2>/dev/null)"
_MODEL="$(echo "$INPUT_RAW" | jq -r '(.model // .tool_response.model // "claude-opus-4-8")' 2>/dev/null)"
if [[ "$_IN" =~ ^[0-9]+$ && "$_OUT" =~ ^[0-9]+$ ]] && [[ "$_IN" != "0" || "$_OUT" != "0" ]]; then
  _LIVE="$(loop_cost_from_usage "$_IN" "$_OUT" "$_MODEL" 2>/dev/null || echo 0)"
  [[ "$_LIVE" =~ ^[0-9]+(\.[0-9]+)?$ ]] && TOTAL="$(awk -v a="$TOTAL" -v b="$_LIVE" 'BEGIN{printf "%.6f", a+b}' 2>/dev/null || echo "$TOTAL")"
fi

# Over (or at) budget? -> deny + mark budget_exceeded so the loop ends cleanly.
if awk -v t="$TOTAL" -v b="$BUDGET" 'BEGIN{exit !(t >= b)}'; then
  loop_write_state "$(echo "$STATE" | jq -c --argjson t "$TOTAL" \
    '.cost_so_far_usd=$t | .active=false | .status="budget_exceeded"')" 2>/dev/null || true
  jq -nc --arg t "$TOTAL" --arg b "$BUDGET" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny",
      permissionDecisionReason:("loop-cost-monitor: live loop cost $\($t) has reached the per-run budget $\($b). The loop is halted (budget_exceeded). Raise per_run_budget_usd or clear the loop, then continue.")}}' \
    2>/dev/null || true
fi
exit 0
