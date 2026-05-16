# ADR 003: Twenty-one subagents (full stack dev team analog)

**Status:** Accepted
**Date:** 2026-05-15
**Author:** the maintainer + Claude

## Context

Multi-agent setups range from "1 agent does everything" to "100s of micro-agents." The stack needs a middle ground that's expressive without being unmanageable.

## Decision

21 subagents (12 core + 6 specialist bench + 3 meta), with foreman orchestrating. Each has a single responsibility; overlapping roles are split rather than merged.

## Alternatives considered

- **Single agent.** Rejected — this IS stock Claude Code; doesn't solve the friction.
- **5-8 agents.** Considered. Rejected because user (the maintainer) explicitly wanted "a full stack dev team analog" and consolidation creates ambiguous roles.
- **30+ agents.** Rejected — too many to orchestrate. Foreman would need to be more sophisticated than is reasonable.
- **21 agents (chosen).** Matches the dev-team analog. Adversarial diversity for review roles. Each role has a clear single responsibility. Foreman can be deterministic about routing.

## Consequences

- **Positive:** Clear separation of concerns. Adversarial diversity catches blind spots. Aligns with the maintainer's "I'm the architect" framing.
- **Negative:** Cost overhead (more agents = more invocations). Orchestration complexity (foreman has more to decide).
- **Locked in:** This count is now part of the stack's identity. Adding 22nd or trimming to 20 should be ADR-tracked.

## Subagent inventory

Core (12): architect, implementer, validator, reviewer, tester, documenter, scribe, ops, product-critic, designer, red-team, security-auditor

Specialist bench (6): performance-engineer, data-engineer, integration-specialist, incident-commander, architecture-critic, accessibility-auditor

Meta (3): historian, librarian, estimator

Plus: foreman (orchestrator), local-ops (Tier 5 variant) — bringing total agent files to 23 if counting these, but the core/specialist/meta naming convention says 21.

## References

- Conversation between the maintainer and Claude on 2026-05-15
