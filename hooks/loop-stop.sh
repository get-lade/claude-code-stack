#!/usr/bin/env bash
# Stop hook for the loop-engineering control plane.
# Blocks the session from stopping while a loop's goal is unmet and bounds
# remain; releases (allows stop) when met, bound-tripped, or anything is
# ambiguous. FAIL-CLOSED: on doubt, allow the stop.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
[[ -f "$LIB" ]] || { LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"; }
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
CMD="$(echo "$STATE" | jq -r '.success_criterion.command // empty' 2>/dev/null)"
if [[ -n "$CMD" ]]; then
  if bash -c "$CMD" >/dev/null 2>&1; then mark "met"; exit 0; fi
fi

# 2) No-progress: compare state hash; bump count if unchanged.
PREV="$(echo "$STATE" | jq -r '.last_state_hash // empty' 2>/dev/null)"
CUR="$(loop_state_hash "$PWD")"
NPC="$(echo "$STATE" | jq -r '.no_progress_count // 0' 2>/dev/null)"
if [[ -n "$PREV" && "$PREV" == "$CUR" ]]; then NPC=$((NPC+1)); else NPC=0; fi

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
