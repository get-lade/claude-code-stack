#!/usr/bin/env bash
# UserPromptSubmit hook: auto-enablement for loop-engineering (ADR-022 / Phase 3).
# When a prompt looks like iterate-until-verified work AND the user has not yet
# been onboarded to governed loops, inject a one-time reminder telling the
# assistant to offer the onboarding choices (governed loop? autonomy? ultracode?
# design-first?) via AskUserQuestion. Non-loop prompts are never touched.
#
# Fires only when ALL of:
#   1) prompt is NOT a slash command and not trivially short
#   2) prompt matches the loop-shape taxonomy (foreman's, reused here)
#   3) project is stack-initialized at Tier >= 2 (loop-eng lives at Tier 2+)
#   4) the user is not already loop-onboarded (marker absent)
#   5) once per session (dedupe), so it never nags every turn
# Output is injected as system-reminder context. Fail-open: any error -> silent.
set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"
PROMPT="$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

# 1) skip slash commands + short prompts.
[[ "$PROMPT" =~ ^/ ]] && exit 0
WORD_COUNT=$(echo "$PROMPT" | wc -w | tr -d ' ')
[[ "$WORD_COUNT" -lt 6 ]] && exit 0

# 2) loop-shape classifier (mirrors foreman's loop-shape table). Conservative:
#    require an explicit iterate/until/recurring signal — one-shot edits, Q&A,
#    and "explain/read" never match.
LOWER="$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')"
LOOP_RE='\b(until (it|the|all|tests|they|done)|iterate|keep (going|running|trying)|babysit|repeatedly|run .* until|loop until|every (hour|day|commit|run)|recurring|watch the pr|eval.*(threshold|until)|until .* (pass|passes|green|done)|don.?t stop|keep .* until)\b'
echo "$LOWER" | grep -qE "$LOOP_RE" || exit 0
# Negative guard: pure read/explain requests are not loops even if they say "until".
echo "$LOWER" | grep -qE '^\s*(explain|what|why|how does|show me|describe|summari)' && exit 0

# 3) Tier 2+ stack project only.
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
[[ -z "$CONFIG" ]] && exit 0
TIER="$(jq -r '.stack_tier // 0' "$CONFIG" 2>/dev/null)"
[[ "$TIER" =~ ^[0-9]+$ ]] || TIER=0
[[ "$TIER" -lt 2 ]] && exit 0

STATE_DIR="${LOOP_STATE_DIR:-$HOME/.claude/session-state}"

# 4) already onboarded -> silent.
[[ -f "$STATE_DIR/loop-onboarded.json" ]] && exit 0

# 5) once-per-session dedupe (scoped to session id; skip dedupe if absent).
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -c 'A-Za-z0-9._-' '_')"
if [[ -n "$SESSION_ID" ]]; then
  FLAG="$STATE_DIR/loop-onboard-nudged.$SESSION_ID"
  [[ -f "$FLAG" ]] && exit 0
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  touch "$FLAG" 2>/dev/null || true
fi

cat <<'EOF'
<system-reminder>
Loop-shape detected: this request looks like iterate-until-verified work, and the user is not yet loop-onboarded. Before doing the work, offer the one-time governed-loop setup via AskUserQuestion (novice-friendly, recommend the safe default):
  1) Run as a governed loop (iterate until a check passes)?  — yes (recommended) / one-shot
  2) Autonomy — checkpoint (recommended) / bounded-checkpoint / bounded-autonomous (clamp to the tier ceiling)
  3) Raise autonomy for this session (ultracode)? — off (recommended) / on
  4) Design-first (brainstorming → /plan) before code? — on (recommended) / off
After they answer: persist via /session (writes session_prefs + loop_policy.default_autonomy), then write ~/.claude/session-state/loop-onboarded.json so this never re-asks. If they decline, honor it and proceed one-shot. If the work clearly isn't loop-shaped after all, ignore this and proceed.
</system-reminder>
EOF
exit 0
