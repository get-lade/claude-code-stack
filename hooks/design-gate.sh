#!/usr/bin/env bash
# PreToolUse[Edit|Write] hook: superpowers design-before-code gate (ADR-021).
#
# When ultracode is ON, deny edits to SOURCE files unless an approved design
# marker exists. With ultracode OFF (the default) this hook is silent — it never
# blocks normal work. It always allows docs / config / tests so the spec, plan,
# and tests that satisfy the gate can be written freely.
#
# Reuses the ADR-019 §3 governance base: session-state read, the
# permissionDecision:deny shape, the same registration mechanism as
# irreversible-deny.sh. Fail-OPEN: any error allows the edit (a gate failure must
# never brick editing).
#
# Marker: ~/.claude/session-state/design-approved.json -> {"active": true},
# written by /plan or /loop-engineer on approval. The gate is the enforcement;
# /plan is the authoring path (ADR-021 reconciliation).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
if [[ ! -f "$LIB" ]]; then
  [[ -n "${HOME:-}" ]] && LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
fi
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

# Gate is active only under ultracode (rides the autonomy risk dial).
loop_ultracode_active || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
FP="$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)"
[[ -z "$FP" ]] && FP="${CLAUDE_TOOL_INPUT_file_path:-}"
[[ -z "$FP" ]] && exit 0

# Always allow docs and tests (you must be able to author the design + tests).
case "$FP" in
  */docs/*|docs/*|*/tests/*|tests/*) exit 0 ;;
esac

# Only gate SOURCE files; allow everything else (markdown, config, data, ...).
case "$FP" in
  *.sh|*.bash|*.py|*.ts|*.tsx|*.js|*.jsx|*.go|*.rs|*.rb|*.java|*.c|*.h|*.cpp|*.php|*.sql) : ;;
  *) exit 0 ;;
esac

# Approved-design marker present? -> allow.
# Phase-3 (ADR-022): the marker may scope approval to paths via approved_paths
# (a glob array). Match rules:
#   - approved_paths present + non-empty -> allow only if the target matches a glob
#   - bare {"active":true} (no/empty approved_paths) -> allow all source (legacy)
STATE_DIR="${LOOP_STATE_DIR:-${HOME:-/tmp}/.claude/session-state}"
MARKER="$STATE_DIR/design-approved.json"
if [[ -f "$MARKER" ]] && [[ "$(jq -r '.active // false' "$MARKER" 2>/dev/null)" == "true" ]]; then
  _NPATHS="$(jq -r '(.approved_paths // []) | length' "$MARKER" 2>/dev/null)"
  if [[ -z "$_NPATHS" || "$_NPATHS" == "0" ]]; then
    exit 0   # legacy session-wide approval
  fi
  # Path-scoped: allow iff FP matches an approved glob (case-statement glob match).
  while IFS= read -r _glob; do
    [[ -z "$_glob" ]] && continue
    # shellcheck disable=SC2254
    case "$FP" in
      $_glob) exit 0 ;;
    esac
  done < <(jq -r '.approved_paths[]?' "$MARKER" 2>/dev/null)
  # marker exists but no glob matched -> fall through to deny
fi

# Ultracode on + source file + no approved design -> deny.
jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny",
  permissionDecisionReason:"design-before-code (ADR-021): ultracode is ON and no approved design exists for this work. Write a spec/plan (docs/superpowers/specs|plans or an ADR) and approve it via /plan — which sets ~/.claude/session-state/design-approved.json — before editing source. Docs, tests, and config are always editable."}}' \
  2>/dev/null || true
exit 0
