# ADR 009: Review pass as standard methodology for multi-artifact deliverables

**Status:** Accepted
**Date:** 2026-05-15 (v1.1)
**Author:** the maintainer + Claude

## Context

v1.0 of the stack was produced in one direction without an explicit review pass — Claude wrote 7,800 lines of authoritative specification and declared "done" without verifying against current docs, without cross-checking artifacts for consistency, and without catching hardcoded user-specific values.

When the maintainer prompted for a review, multiple real issues surfaced:
- Foreman architecturally couldn't work as specified
- Model identifiers were speculative
- Pricing in cost-router was wrong by 3x in places
- A hardcoded user path was in a "shareable" template
- No skill or subagent existed for "review this deliverable before declaring done"

The stack had code review (reviewer + red-team + security-auditor) and architecture review (architecture-critic) and product review (product-critic) — but no documentation review.

the maintainer's instruction: *"Make sure a review pass is part of our standard methodology and team structure."*

## Decision

Review pass is a mandatory step for any multi-artifact deliverable, codified via:

1. **Fourth philosophy principle** in `docs/PHILOSOPHY.md`: *"Review your own output before declaring done. Multi-artifact deliverables, handoffs, specs, design docs, and any work that will be read by future readers (humans or AI) require an explicit review pass before being declared complete."*

2. **`/review-handoff` skill** (Tier 1) — walks any multi-artifact deliverable through structured review: cross-artifact consistency, hardcoded values, live-verification needs, gaps relative to requirements, Liu's test on new markdown.

3. **Documenter subagent's responsibilities extended** (Tier 2) — owns the review pass for documentation deliverables.

4. **Foreman skill mandates review-pass gate** for documentation task types — won't signal completion without it.

## Alternatives considered

- **No formal methodology, rely on user to ask.** Rejected — this is what failed in v1.0.
- **A new "doc-reviewer" subagent.** Rejected — overlaps too much with reviewer. Skill + documenter responsibility is cleaner.
- **Make every subagent self-review.** Rejected — undermines adversarial diversity. Authors of work shouldn't be its only reviewers.
- **Review skill + documenter owns it + foreman enforces (chosen).** Three layers: tool, owner, gate.

## Consequences

- **Positive:** Catches what v1.0 missed. Codified, so future deliverables follow the pattern. Bus-factor protection (review reports are committed). Demonstrates the stack's self-correcting capability.
- **Negative:** Adds time to documentation work. Marginally more friction for doc-only changes.
- **Locked in:** Multi-artifact deliverables now have a quality bar. Removing the gate would be a deliberate decision, not an oversight.

## How v1.1 itself was produced as proof of the methodology

1. v1.0 shipped without review (the mistake we're correcting)
2. User asked: "did you review the artifacts and outputs and check them both against this thread as well as best practices?"
3. Claude did the review pass: web-searched Claude Code docs, found 5 critical issues
4. User: "I don't want to accept any issues or risks"
5. Claude proposed corrections, web-searched to verify (Agent Teams, model IDs, pricing)
6. User added enhancements (per-setting shortcuts, defaults system, /default-edit pattern)
7. v1.1 written: corrections doc first (this ADR + the changelog), then surgical edits to artifacts

This is the pattern: draft → review → revise → ship. Codified.

## References

- v1.1 corrections changelog (`00b-CORRECTIONS-v1.1.md`)
- Conversation between the maintainer and Claude on 2026-05-15 (review pass)
- `skills/review-handoff/SKILL.md`
- PHILOSOPHY.md Principle 4
