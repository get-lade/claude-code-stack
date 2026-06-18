# ADR 008: Three-mode orchestration with Agent Teams as experimental opt-in

**Status:** Accepted
**Date:** 2026-05-15 (v1.1)
**Author:** the maintainer + Claude

## Context

v1.0 of the stack designed foreman as a subagent that dispatches other subagents. During v1.1 review pass, Anthropic's docs were checked and found to explicitly state: *"subagents cannot spawn other subagents"* (docs.claude.com/en/sub-agents, verified 2026-05-15). The Plan subagent's purpose explicitly notes this prevents "infinite nesting."

So foreman-as-subagent wouldn't work as v1.0 specified.

At the same time, Anthropic shipped Agent Teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) in v2.1.32 (Feb 2026, with Opus 4.6). This IS a real multi-session orchestration feature — lead + teammates with peer-to-peer messaging. It's experimental but well-aligned with where Anthropic is investing.

the maintainer's instruction: *"I don't think we should shy away from that experimental feature though for Agent Teams. It will mature. We can put guard rails around it and clarity when to truly trust it solo vs. using the more trusted approach as a backup or check for it. It's one of the bigger elements that Anthropic is clearly growing into — true orchestration. Let's not miss out on that."*

## Decision

Three orchestration modes, user-selectable per project via `stack-config.json` `orchestration_mode` field:

1. **`main-thread`** (default, trusted) — Main Claude Code thread reads `/foreman` skill and invokes subagents sequentially as leaves. Subagents return results; main thread orchestrates handoffs.

2. **`agent-teams`** (experimental, opt-in) — Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. Lead session (`foreman-team-lead` subagent) + teammates with peer-to-peer messaging. Used when subagents benefit from talking to each other mid-task.

3. **`hybrid`** — Main-thread for critical path; Agent Teams spawned for parallel exploration.

Foreman is a **skill** (`skills/foreman/SKILL.md`) — the routing source of truth, read by either the main thread or the team-lead subagent depending on mode.

## Alternatives considered

- **Keep foreman as subagent.** Rejected — Anthropic's docs explicitly say subagents can't dispatch other subagents. v1.0 design was wrong.
- **Main-thread only.** Rejected — misses Anthropic's investment in Agent Teams. the maintainer explicitly pushed back on this.
- **Agent Teams only.** Rejected — experimental status (known broken session resumption, occasional stuck teammates) makes it inappropriate for high-stakes work without alternative.
- **Three modes (chosen).** Lets user pick trust level per project. Defaults to trusted (main-thread). Agent Teams available when user opts in. Hybrid for advanced.

## Guardrails

- Default mode: `main-thread`. Agent Teams never auto-enabled.
- `/agent-teams` shortcut skill makes flipping easy: `/agent-teams [on | off | hybrid | status]`.
- Soft-warn (with override) when enabling Agent Teams in `domain_mode: financial-code` or `schema-migration` or `sensitivity: confidential`. User must explicitly accept.
- All Agent Teams runs log to `subagent_runs` with `orchestration_mode` field. `/agent-performance-review` compares outcomes across modes.

## Consequences

- **Positive:** Aligned with Anthropic's product direction. Trusted default for production work. Experimental capability available when wanted. Pattern detection over time tells us which mode wins for which task class.
- **Negative:** More complexity in foreman skill (must handle three modes). Two foreman artifacts to maintain (skill + team-lead subagent).
- **Locked in:** `orchestration_mode` field in stack-config.json is now a public part of the stack.

## Addendum (v1.2, 2026-05-30): fourth mode + parallel-mode safety

Opus 4.8 (released 2026-05-28) shipped **Dynamic Workflows** in research
preview — a workflow runtime that fans out up to 16 concurrent / 1,000 total
subagents. Public feedback on both experimental features at this point is
mixed: Agent Teams is well-liked for parallel review/adversarial debugging
but dogged by coordination bugs (stuck tasks, duplicate spawns, same-file
overwrites) and ~7× token cost; Dynamic Workflows' dominant risk is uncapped
spend (a runaway loop reportedly burned ~1.7M tokens with no built-in cap or
refund) and subagents that auto-approve file edits regardless of session mode.

Two changes, consistent with the original "guard rails around it" instruction:

1. **`dynamic-workflows`** added as a fourth `orchestration_mode`. Scoped to
   **read-only fan-out** (audits, research sweeps, bug hunts), gated behind
   `/cost-gate` on every launch (treated as `pre-bulk-job`), never headless on
   a writable tree, with the `CLAUDE_CODE_DISABLE_WORKFLOWS=1` kill-switch
   documented. Not for write-heavy work.
2. **Parallel-mode safety rule** added to `/foreman` and `foreman-team-lead`:
   under `agent-teams`/`hybrid`, only read-only roles parallelize; writers
   stay sequential; parallel batches partition by file ownership so no two
   agents edit the same file. `hybrid` is now the recommended mode over pure
   `agent-teams` for any task that writes code.

Recommendation captured here for posterity: **start using Agent Teams now for
human-supervised parallel review/audit** (its proven sweet spot), keep
implementation on the main-thread, and treat Dynamic Workflows as
**pilot-only** for scoped, metered, read-only fan-out until it matures.

## References

- docs.claude.com/en/sub-agents (subagent constraint)
- docs.claude.com/en/agent-teams (Agent Teams docs)
- code.claude.com/docs/en/workflows (Dynamic Workflows docs)
- v1.1 corrections changelog
- Conversation between the maintainer and Claude on 2026-05-15 (post-review)
- Conversation between the maintainer and Claude on 2026-05-30 (Opus 4.8 review)

## Addendum (v1.2, 2026-06-18): roster convention across parallel modes

The agentType convention is now uniform across `agent-teams`, `hybrid`, and `dynamic-workflows`: any agent() call that does review/audit/security/architecture work passes agentType: <roster-name> so the named role and its non-Claude pass (reviewer/security-auditor → Codex, red-team/architecture-critic → Gemini) run. Write-heavy Workflow runs that name no roster agentType are fenced by hooks/workflow-roster-check.sh; the warn-vs-block decision and the workflow_roster config key are recorded in ADR-016.
