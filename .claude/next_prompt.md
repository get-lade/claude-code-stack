# Next-session handoff

_Written: 2026-06-18 09:59 PT_

## Branch & state
- Branch: `main` (worktree: N/A)
- Uncommitted: clean (this handoff lands via a `chore/handoff-*` PR)
- Behind/ahead of origin: up to date with `origin/main`

## What shipped this session
- `dde799f` — Merge PR #30 `feat/workflow-roster-fence` → main
- `7b9deb5` — fix(install): move team-hook matchers to a tier-2-only settings fragment (the comprehensive workflow-roster fence)
- `e052740` — chore: stack init at tier 2 (this source repo is now Tier-2 stack-initialized; dogfoods the roster + workflow-roster hook)
- PR [#30](https://github.com/bschonbrun/claude-code-stack/pull/30): **MERGED**, all CI green (lint, test 0–4, unit-tests)

### What the fence now does (all merged)
- `hooks/workflow-roster-check.sh`: extracts roster names from `agentType` (both quote forms + double-quoted JSON keys), best-effort logs a `workflow_dispatch` row with `roster_agents`/`mode`/`decision`/`script_source` on every Tier 2+ Workflow call; resolves `scriptPath` content; numeric-tier guard.
- Opt-in `workflow_roster: warn|block|off` (default `warn`) in `stack-config.json` (schema updated). `block` denies write-heavy + no-roster runs; `off` still logs.
- Install coverage: tier-2-only `config/settings.team.template.json` (PreToolUse Workflow/Agent + dispatch-nudge) merged at tier ≥2; tier-0 base carries only Bash → no dangling-hook refs at tier 0/1.
- Reporting (`/team-status`, `/goodmorning` 6b, `/handoff`): exclude the `agent:"workflow"` sentinel, credit `roster_agents` toward in-play, flag unrostered write-heavy workflows; `(.event // "dispatch")` + `(.uses_roster != true)` backward-compat guards.
- Docs: ADR-016 (warn-vs-block, chosen warn), ADR-008 v1.2 addendum (agentType convention across all parallel modes), CHANGELOG, README/tests-README.

## What's blocked & why
- Nothing blocked.

## Exact next steps
1. **Other machines:** `git pull && scripts/update.sh --tier=<their tier>`, then restart Claude Code — picks up the updated `workflow-roster-check.sh` hook + reporting skills. (This machine already ran `update.sh --tier=2` this session.)
2. **Cloud:** picks up automatically at next session start (cloud-bootstrap); just restart.
3. **(Optional) Verify the fence live** in a Tier 2+ stack-initialized repo: dispatch a write-heavy Workflow with no `agentType` → expect a non-blocking warn system-reminder; add `agentType: 'reviewer'` → quiet. Confirm a `workflow_dispatch` row lands in `~/.claude/logs/subagent-runs.jsonl`.
4. **(Optional) Enforcement:** set `workflow_roster: "block"` in any high-sensitivity repo's `.claude/stack-config.json` to hard-deny unrostered write-heavy workflows.

## Gotchas
- Hooks/skills/agents are **global** (`~/.claude/`), not per-repo. One `update.sh` per machine covers all repos/threads; a **Claude Code restart** is required (they cache at boot).
- The fence only **fires** in repos whose `.claude/stack-config.json` has `stack_tier ≥ 2`. Uninitialized repos need `/project-init` at Tier 2+.
- Sandbox can push branches + open PRs but **cannot push directly to `main`** — this handoff lands via a `chore/handoff-*` PR, not a direct push.
- `.claude/next_prompt.md` was previously gitignored in this repo (old behavior); the current `/handoff` skill tracks it, so the ignore line was removed this session.

## Cross-repo references
- This is the stack **source** repo; the change reaches every machine/repo via the `~/.claude` install path (`scripts/update.sh`) — see Next steps 1–2. No per-repo code install.

## Team this session
- Used: implementer ×2, architect ×1, validator ×1, reviewer ×1 (Codex, cross-model).
- Note: the subagent-log session window reset at the mid-session Claude Code restart (`session-start.txt` = 2026-06-18T16:58Z), so the jq utilization counts read 0; the above is recorded from session memory.
- Highlight: the Codex reviewer caught **2 real backward-compat bugs** (event-less log rows dropped; old `uses_roster:true` rows miscounted) that the same-family architect→implementer→validator chain missed — both fixed and verified before merge.
