#!/usr/bin/env bash
# Stop hook for the loop-engineering control plane.
# Blocks the session from stopping while a loop's goal is unmet and bounds
# remain; releases (allows stop) when met, bound-tripped, or anything is
# ambiguous. FAIL-CLOSED: on doubt, allow the stop.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Guard $HOME before using it as a fallback so set -u does not abort.
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
[[ -f "$LIB" ]] || { LIB="${HOME:-/tmp}/.claude/skills/loop-engineer/loop_lib.sh"; }
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0   # no lib -> allow stop

INPUT="$(cat 2>/dev/null || echo '{}')"
SHA="$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[[ "$SHA" == "true" ]] && exit 0       # never re-block: allow stop

STATE="$(loop_read_state)"
ACTIVE="$(echo "$STATE" | jq -r '.active // false' 2>/dev/null)"
[[ "$ACTIVE" == "true" ]] || exit 0    # no active loop -> allow stop

# Malformed (read returned {} but file exists non-empty) -> fail-closed
echo "$STATE" | jq -e '.bounds' >/dev/null 2>&1 || exit 0

mark() { loop_write_state "$(echo "$STATE" | jq -c --arg s "$1" '.active=false | .status=$s')" 2>/dev/null || true; }

# 1) External termination: run the success criterion command.
# Wrapped in a timeout (default 120 s) so a hanging criterion never stalls
# the hook. If the `timeout` binary is absent (rare), fall back to plain bash.
# Timeout or non-zero exit => criterion NOT met; 0 => met.
CMD="$(echo "$STATE" | jq -r '.success_criterion.command // empty' 2>/dev/null)"
if [[ -n "$CMD" ]]; then
  _TIMEOUT="${LOOP_CRITERION_TIMEOUT:-120}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_TIMEOUT" bash -c "$CMD" >/dev/null 2>&1 && { mark "met"; exit 0; }
  else
    # timeout not available; run plain (best-effort, may block)
    bash -c "$CMD" >/dev/null 2>&1 && { mark "met"; exit 0; }
  fi
fi

# 2) No-progress: compare state hash; bump count if unchanged.
PREV="$(echo "$STATE" | jq -r '.last_state_hash // empty' 2>/dev/null)"
CUR="$(loop_state_hash "$PWD")"
# Guard NPC so an empty value can't break arithmetic under set -u.
NPC="$(echo "$STATE" | jq -r '.no_progress_count // 0' 2>/dev/null)"
[[ "$NPC" =~ ^[0-9]+$ ]] || NPC=0
if [[ -n "$PREV" && "$PREV" == "$CUR" ]]; then NPC=$((NPC+1)); else NPC=0; fi

# 2b) Accrue per-iteration cost from subagent-runs.jsonl.
# Sum cost_usd of event=="loop_iteration" rows since started_at (if present),
# falling back to LOOP_EST_COST_PER_ITER (default 0) when no data exists.
# This is between-iteration and advisory (Phase 1); Phase 2 adds live monitoring.
_STARTED="$(echo "$STATE" | jq -r '.started_at // empty' 2>/dev/null)"
_LOG="${HOME:-/tmp}/.claude/logs/subagent-runs.jsonl"
_ITER_COST=0
if [[ -f "$_LOG" && -n "$_STARTED" ]]; then
  # Sum cost_usd from rows with event==loop_iteration since the loop's started_at.
  _ITER_COST="$(jq -rs --arg s "$_STARTED" \
    '[.[] | select(.event=="loop_iteration") | .cost_usd // 0] | add // 0' \
    "$_LOG" 2>/dev/null)" || _ITER_COST=0
  [[ "$_ITER_COST" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _ITER_COST=0
elif [[ -f "$_LOG" ]]; then
  # No started_at — sum all iteration rows as a best-effort estimate.
  _ITER_COST="$(jq -rs '[.[] | select(.event=="loop_iteration") | .cost_usd // 0] | add // 0' \
    "$_LOG" 2>/dev/null)" || _ITER_COST=0
  [[ "$_ITER_COST" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _ITER_COST=0
else
  _ITER_COST="${LOOP_EST_COST_PER_ITER:-0}"
fi
# Update cost_so_far_usd in state (keep honest: zero when no data).
_PREV_COST="$(echo "$STATE" | jq -r '.cost_so_far_usd // 0' 2>/dev/null)"
[[ "$_PREV_COST" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _PREV_COST=0
_NEW_COST="$(awk -v a="$_ITER_COST" -v b="$_PREV_COST" 'BEGIN{printf "%.6f", a+b}' 2>/dev/null)" || _NEW_COST="$_PREV_COST"
STATE="$(echo "$STATE" | jq -c --argjson c "$_NEW_COST" '.cost_so_far_usd=$c' 2>/dev/null)" || true

# 3) Advance iteration + hash, then check bounds on the advanced state.
STATE="$(echo "$STATE" | jq -c --arg h "$CUR" --argjson n "$NPC" \
  '.iteration=((.iteration//0)+1) | .last_state_hash=$h | .no_progress_count=$n')"
TRIP="$(loop_check_bounds "$STATE")"
if [[ "$TRIP" != "ok" ]]; then
  loop_write_state "$(echo "$STATE" | jq -c --arg s "$TRIP" '.active=false | .status=$s')" 2>/dev/null || true
  exit 0   # bound tripped -> allow stop (escalation surfaced via status)
fi

# 4) Unmet + bounds remain + progress -> keep working.
loop_write_state "$STATE" 2>/dev/null || true
REM="$(echo "$STATE" | jq -r '"iter \(.iteration)/\(.bounds.max_iterations // "∞")"' 2>/dev/null)"
jq -nc --arg r "Loop '$(echo "$STATE" | jq -r '.loop_id // "loop"')' goal unmet ($REM). Continue toward: $(echo "$STATE" | jq -r '.goal // ""')" \
  '{decision:"block", reason:$r}' 2>/dev/null || true
exit 0
