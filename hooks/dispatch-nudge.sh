#!/usr/bin/env bash
# UserPromptSubmit hook: nudge user toward /foreman or /dispatch when their
# prompt looks like multi-step engineering work but they didn't route it.
# Soft, infrequent: only fires when ALL of:
#   1) project has .claude/stack-config.json with stack_tier >= 2
#   2) prompt contains trigger words (build / add / implement / fix / refactor / migrate)
#   3) prompt does NOT already start with / (skill invocation)
#   4) prompt is not trivial-short (< 12 words)
# Output is injected as system-reminder context.

set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"
PROMPT="$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

# Skip if prompt is a slash command.
[[ "$PROMPT" =~ ^/ ]] && exit 0

# Skip short prompts.
WORD_COUNT=$(echo "$PROMPT" | wc -w | tr -d ' ')
[[ "$WORD_COUNT" -lt 12 ]] && exit 0

# Skip if no trigger words.
LOWER="$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')"
if ! echo "$LOWER" | grep -qE '\b(build|add|implement|fix|refactor|migrate|deploy|create.*feature|new feature)\b'; then
  exit 0
fi

# Only nudge in stack-initialized Tier 2+ projects.
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
[[ -z "$CONFIG" ]] && exit 0

TIER="$(jq -r '.stack_tier // 0' "$CONFIG" 2>/dev/null)"
[[ "$TIER" -lt 2 ]] && exit 0

# Inject reminder. The hook's stdout is appended to the model's context.
cat <<EOF
<system-reminder>
Dispatch nudge: this prompt looks like multi-step engineering work in a Tier $TIER project. Consider routing it via /foreman or /dispatch so the right subagents handle it (architect → implementer → validator → reviewer). If you've already decided this is single-edit / trivial work, ignore this and proceed directly.
</system-reminder>
EOF

exit 0
