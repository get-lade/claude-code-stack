# Philosophy

## Why this stack exists

Anthropic's Claude Code is excellent out of the box. But out-of-the-box, it has friction patterns that show up consistently in real usage — patterns documented by Anthropic's own Insights tooling:
- Shipping before validating
- Chasing wrong hypotheses before pausing to plan
- Producing correct-looking but actually-wrong code
- Repeating mistakes across sessions because there's no continuity
- Conflating "the AI did something" with "the AI did the right thing"

The fix is not a better model. The fix is **process scaffolding**: forcing the AI through plan → implement → validate → review → document loops that mirror how a senior engineering org operates.

This stack provides that scaffolding.

## What this stack optimizes for

In priority order:

1. **Bus-factor protection.** If the primary user disappeared tomorrow, a successor should be able to read the docs and pick up where they left off. Every architectural decision has an ADR. Every deployed function has a runbook. Every session's outcome is captured in a handoff.

2. **Enterprise-grade output for a solo architect.** The premise is that one technical person + 21 specialized AI subagents + good process can produce code quality matching a small senior engineering team. Not because AI replaces engineers, but because process discipline + specialized roles + adversarial review catches what a single AI misses.

3. **Self-improvement.** The stack monitors its own performance and proposes its own changes. Monthly model audits. Per-subagent performance reviews. The stack's improvement is automated; only the approval is human.

4. **Tiered adoption.** Most users don't need 21 subagents. The stack is structured so a user can adopt only what they need at their complexity level — but the structure exists for them to grow into.

5. **Distribution as a learning artifact.** The stack ships as an installable system not because everyone needs the full stack, but because the patterns inside it (routing rule, model strategy, subagent design) are reusable. Even users who reject this specific configuration benefit from reading the ADRs.

## What this stack does NOT optimize for

- **Speed of initial setup.** Tier 0 is 5 minutes. Tier 5 is hours. That's deliberate.
- **Single-developer comfort.** This stack is opinionated. If you want freeform, use stock Claude Code.
- **Universal applicability.** Some patterns (financial-code mode, schema-migration mode) reflect the author's domain. Skip what doesn't apply.
- **Bleeding-edge feature use.** We adopt new Claude Code features after they're stable, not at announcement.

## Three load-bearing principles

### Principle 1: Routing rule (hook → skill → CLAUDE.md → cut)

For any friction pattern:
1. Can a shell command detect or prevent it deterministically? → Hook.
2. Is it a repeatable multi-step workflow you'd otherwise re-explain? → Skill.
3. Is it a fact you'd otherwise re-explain that the AI can't read from code? → CLAUDE.md line.
4. Anything else → cut it.

Hooks and CLAUDE.md should not duplicate each other. If `tsc` runs as a hook, delete "always run tsc" from CLAUDE.md.

### Principle 2: Liu's test (minimal context)

For any line in any markdown file we ship to the user's context window:
> *"Would removing this cause Claude to make a mistake it couldn't recover from?"*

If no, cut it. Context dilution is real. Tokens spent on noise are tokens not spent on signal.

### Principle 3: Adversarial diversity

Roles that review other roles' work MUST use a different model family. Reviewer is GPT-5.5 (OpenAI) not Claude. Red-team is Gemini (Google) not Claude. Product-critic is GPT-5.5 not Claude. Otherwise you're getting the same blind spots twice.

Execution roles don't need diversity. Implementer can be Sonnet. Documenter can be Sonnet. They need reliability, not perspective.

### Principle 4: Review your own output before declaring done (v1.1 addition)

Multi-artifact deliverables, handoffs, specs, design docs, and any work that will be read by future readers (humans or AI) require an explicit review pass before being declared complete.

The review pass checks:
- **Cross-artifact consistency** — references resolve, terminology is consistent, structure is parallel where it should be
- **Hardcoded values** that should be parameterized — user-specific paths, project refs, API keys
- **Assumptions that should be verified** — model IDs, API specifics, doc URLs, vendor capabilities
- **Gaps** the original draft missed
- **Liu's test** applied to any new markdown content

Never trust your first draft of authoritative documentation. The pattern is: **draft → review → revise → ship.**

This principle is enforced by:
- `/review-handoff` skill (Tier 1) — walks any multi-artifact deliverable through structured review
- Documenter subagent (Tier 2) owns the review pass for documentation work
- Foreman skill mandates review-pass gate before signaling completion on doc deliverables

This principle was added in v1.1 after v1.0 itself was shipped without a review pass and contained multiple architectural errors. The stack now codifies the lesson. See ADR-009.

## Tradeoffs we accepted

- **Multi-provider complexity** in exchange for adversarial diversity. Yes, three API keys is more than one. The blind-spot reduction is worth it for adversarial work.
- **Strict mode friction** in exchange for accidental-dispatch prevention. Yes, you have to run `/project-init` before foreman works. The "I accidentally let the AI loose on prod" mistake is worth preventing.
- **Tier complexity** in exchange for graduated adoption. Yes, 5 tiers is more than 1. The user who only needs Tier 0 isn't burdened by Tier 4 infrastructure.
- **Documentation overhead** in exchange for bus-factor. Yes, ADRs and runbooks take time. The "primary author quits and nobody knows why anything works" scenario is worth preventing.

## Tradeoffs we rejected

- **A single mega-CLAUDE.md.** Babich's "10 sections" approach is sensible for many users; it's wrong for this stack. Context dilution is the bigger risk.
- **Fewer subagents.** Tempting. But every consolidation we considered created an ambiguous role with overlapping responsibilities, which is itself a friction source.
- **Anthropic-only.** Simpler. But adversarial diversity matters more than simplicity for the roles that need it.
- **Auto-apply model audit results.** Tempting at scale. Too dangerous when models change behavior in subtle ways. Human approval is the right gate.
