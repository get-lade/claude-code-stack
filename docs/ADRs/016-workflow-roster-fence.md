# ADR 016: Workflow-roster fence — warn by default, opt-in block

**Status:** Accepted
**Date:** 2026-06-18 (v1.2)
**Author:** the maintainer + Claude

## Context

The Workflow tool (Opus 4.8 dynamic-workflows) spawns generic `agent()` workers that do NOT carry the stack's named-roster cross-model wiring (reviewer/security-auditor → Codex, red-team/architecture-critic → Gemini). A write-heavy Workflow that skips `agentType` silently ships code with no cross-family adversarial review — exactly the case ADR-008's dynamic-workflows guardrail calls out as "read-only only." Worse, the gap was invisible: Workflow runs were never logged, so team-utilization reporting showed roster roles "benched" when work had in fact shipped without them.

PR #30 added a non-blocking PreToolUse(Workflow) warn hook + foreman guardrail #6, but only on one install path. This ADR records the design that makes the fence comprehensive (every install path + every reporting consumer) and adds an opt-in enforcement level.

## Decision

1. **Default = warn, not block.** A write-heavy Workflow naming no roster agentType emits a non-blocking system-reminder. Workflow stays fully usable for legitimate read-only fan-out.
2. **Optional block via a dedicated config key only:** `workflow_roster` in stack-config.json — `"warn"` (default) | `"block"` | `"off"`. The hook reads this key; absent/invalid → `"warn"`.
   - `block`: write-heavy + no-roster → `permissionDecision:"deny"`.
   - `off`: no warn/deny, but the run is still logged.
3. **No auto-escalation.** Block is NOT triggered by strict_mode or sensitivity. Mandatory cross-model review on writes is an explicit per-repo choice, set via this one key.
4. **Best-effort log.** Every Workflow PreToolUse (in any mode, Tier 2+) attempts to append a `workflow_dispatch` row recording `roster_agents` (the roster roles the workflow actually used), `write_heavy`, `mode`, `decision`, and `script_source`; dropped silently if the log dir is unwritable (matches the rest of the log infra — no locking).

## Alternatives considered

- **Block by default.** Rejected — breaks legitimate read-only fan-out and the research-preview workflow runtime's main use; too blunt for a default.
- **Escalate to block automatically under strict_mode / sensitivity:confidential.** Rejected — couples an orthogonal concern to existing flags, surprising and hard to reason about. A dedicated, explicit key is clearer (maintainer decision, 2026-06-18).
- **Boolean log field only (`uses_roster`).** Rejected for reporting — a bool can't credit *which* roster roles a workflow used, so benched math stayed wrong. Record the name list (`roster_agents`); keep `uses_roster` for backward-compat.

## Consequences

- **Positive:** Workflow runs are visible; benched reporting is accurate; cross-model review can be made mandatory per-repo without forcing it globally.
- **Negative:** One more config key; the hook now parses agentType names (regex must track the roster). Reporting consumers must handle old rows lacking `roster_agents` (`// []`).
- **Locked in:** `workflow_roster` and the `workflow_dispatch` row shape (with `roster_agents`/`mode`/`decision`) are now public stack surface.

## References

- ADR-008 (orchestration modes; dynamic-workflows guardrail) + its v1.2 addendum
- PR #30 (initial warn hook + foreman guardrail #6)
- hooks/workflow-roster-check.sh, schemas/stack-config-schema.json
- config/settings.team.template.json — tier-2-only settings fragment that wires the team-hook matchers (PreToolUse Workflow/Agent, PostToolUse Agent, dispatch-nudge); merged into ~/.claude/settings.json at tier ≥2 so tier-0/1 installs don't reference hooks that ship only at tier 2
- Maintainer decision, 2026-06-18 (warn default; dedicated key; no auto-escalation)
