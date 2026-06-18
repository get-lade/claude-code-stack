#!/usr/bin/env bash
# PreToolUse hook (matcher: Workflow): warn — never block — when a Workflow run
# bypasses the named subagent roster.
#
# Why this exists: the Workflow tool spawns generic worktree-parallel agents that
# do NOT carry the roster's cross-model wiring (reviewer/security-auditor → Codex,
# red-team/architecture-critic → Gemini). foreman's `dynamic-workflows` mode is
# documented read-only + /cost-gate-first + "not for write-heavy work", but
# nothing enforced it. A write-heavy Workflow that skips `agentType` silently
# loses the cross-family adversarial review the stack is built around.
#
# This hook fires only in stack-initialized Tier 2+ projects, and only when the
# script looks write-heavy AND names no roster agentType. It also appends a row
# to the subagent log so Workflow runs stop being invisible `unknown`s.
#
# Decision (per maintainer, 2026-06-18): WARN + convention, not block. Workflow
# stays fully usable for legit read-only fan-out; the model just gets a nudge to
# route writes through the roster or keep them on main-thread.

set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"

# Workflow script lives in tool_input.script (inline) / scriptPath / name.
SCRIPT="$(echo "$INPUT" | jq -r '.tool_input.script // .tool_input.scriptPath // .tool_input.name // empty' 2>/dev/null)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

# Only fence stack-initialized Tier 2+ projects.
CONFIG="$(bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/lib/find-stack-config.sh" "$CWD" 2>/dev/null)"
[[ -z "$CONFIG" ]] && exit 0
TIER="$(jq -r '.stack_tier // 0' "$CONFIG" 2>/dev/null)"
[[ "$TIER" -lt 2 ]] && exit 0

ROSTER='architect|implementer|validator|reviewer|security-auditor|red-team|tester|data-engineer|designer|architecture-critic|product-critic|performance-engineer|documenter|integration-specialist|accessibility-auditor'

# Does any agent() call route to a named roster member via agentType?
HAS_ROSTER=0
if echo "$SCRIPT" | grep -qE "agentType['\"[:space:]]*[:=].*($ROSTER)"; then
  HAS_ROSTER=1
fi

# Does the workflow write to the tree (worktree isolation, or build/edit verbs)?
WRITE_HEAVY=0
if echo "$SCRIPT" | grep -qiE "isolation['\"[:space:]]*[:=]['\"[:space:]]*worktree|\b(implement|refactor|scaffold|migrat|build the|edit |write the|apply the fix|create .*file)\b"; then
  WRITE_HEAVY=1
fi

# Log the run so Workflow dispatches are visible (mirrors subagent-log.sh schema).
LOG_DIR="$HOME/.claude/logs"; mkdir -p "$LOG_DIR"
PROJECT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if command -v jq &>/dev/null; then
  jq -nc --arg ts "$TS" --arg project "$PROJECT" \
    --argjson roster "$HAS_ROSTER" --argjson write "$WRITE_HEAVY" \
    '{event:"workflow_dispatch", ts:$ts, project:$project, agent:"workflow", uses_roster:($roster==1), write_heavy:($write==1)}' \
    >> "$LOG_DIR/subagent-runs.jsonl" 2>/dev/null || true
fi

# Quiet path: read-only fan-out (sanctioned), or already routing to the roster.
if [[ "$HAS_ROSTER" -eq 1 || "$WRITE_HEAVY" -eq 0 ]]; then
  exit 0
fi

# Warn path: write-heavy Workflow that names no roster agentType. Non-blocking.
REASON="Write-heavy Workflow run names no roster agentType — cross-model review (Codex/Gemini) will be skipped, and this is the case foreman's dynamic-workflows guardrail flags (read-only only). Either keep file-writing work on the main-thread critical path via /foreman (architect → implementer → validator → reviewer), or pass agentType: <roster-name> to your agent() calls so the named roles (and their Codex/Gemini wiring) run. Proceeding either way."

jq -nc --arg r "$REASON" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow", permissionDecisionReason:"stack workflow-roster-check", additionalContext:("<system-reminder>"+$r+"</system-reminder>")}}' \
  2>/dev/null || true

exit 0
