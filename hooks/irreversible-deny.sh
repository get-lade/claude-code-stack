#!/usr/bin/env bash
# PreToolUse[Bash] hook: during an ACTIVE loop, deny irreversible commands so
# an unattended loop cannot push/merge/deploy/delete/move money. Outside a
# loop, stays silent. Red-team owns the pattern list. Best-effort: exit 0.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
[[ -f "$LIB" ]] || LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

[[ "$(loop_read_state | jq -r '.active // false' 2>/dev/null)" == "true" ]] || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -z "$CMD" ]] && CMD="${CLAUDE_TOOL_INPUT_command:-}"
[[ -z "$CMD" ]] && exit 0

# Irreversible patterns (word-boundary-ish; conservative).
PATTERN='git[[:space:]]+push|git[[:space:]]+merge|git[[:space:]]+reset[[:space:]]+--hard|rm[[:space:]]+-rf|deploy-edge|supabase[[:space:]].*delete|supabase[[:space:]].*drop|drop[[:space:]]+table|truncate[[:space:]]|stripe[[:space:]]|gh[[:space:]]+pr[[:space:]]+merge'

if echo "$CMD" | grep -qiE "$PATTERN"; then
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny",
    permissionDecisionReason:"irreversible-deny: an active loop may not run irreversible actions (push/merge/deploy/delete/money). Pause the loop or get a human checkpoint, then run this outside the loop."}}' 2>/dev/null || true
fi
exit 0
