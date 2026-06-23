# ADR 025: Tier adversarial review by stakes (review router)

**Status:** Accepted
**Date:** 2026-06-23
**Author:** the maintainer + Claude (Opus 4.8)
**Relates to:** ADR-011 (Codex for the OpenAI family — the cross-family rule this preserves), ADR-012 (Gemini roles — explicitly out of scope here), ADR-022 (cross-family preflight — runs before this router on the Codex tiers)

## Context

The three adversarial-review subagents — `reviewer`, `product-critic`,
`security-auditor` — all routed through the local Codex CLI on **one fixed
tier**: `gpt-5.5` at `model_reasoning_effort=high`, over a **whole-repo cold
read** (`codex exec review`).

Measured from `~/.claude/logs/subagent-runs.jsonl` over ~1 month:

- reviewer 155 + security-auditor 35 + product-critic 20 = **210 review runs**
- ~200M tokens / ~$200 → **~$0.95 and ~950K tokens per run**

That per-run token count is whole-repo context, not the diff. And paying
frontier-tier-at-high-effort on *every* diff — most of which are routine —
is the cost driver. The OpenAI adversarial-review bill (~$200/mo) equalled the
month's entire Claude bill.

Two structural wastes:

1. **No stakes tiering.** A docs/test/refactor diff got the same gpt-5.5@high
   pass as a novel auth/crypto change.
2. **No scope discipline.** Reviews read the whole repo instead of the diff —
   the single biggest token multiplier, and it dilutes review focus.

## Decision

Introduce a deterministic **review router** (`scripts/lib/review-router.sh`),
sourced by all three adversarial agents, that classifies each review's stakes
and selects a tier:

| Stakes | When | Engine / model | Effort |
|--------|------|----------------|--------|
| **high** | diff touches auth/crypto/payment/migration/RLS/secret paths, or `STACK_DOMAIN_MODE` ∈ {security, schema-migration}, or `STACK_SENSITIVITY=high` | Codex / `gpt-5.5` | high |
| **routine** | everything else | local `qwen2.5-coder:32b` first → escalate Codex / `gpt-5.4` @ medium | n/a → medium |

Plus three invariants:

- **Scope fix:** every tier reviews the **diff** (`base..head`), never the whole
  repo. Applies even to high-stakes reviews.
- **Cross-family (ADR-011) holds on both tiers.** Local Qwen (Alibaba) and
  gpt-5.x (OpenAI) are each a different model family than the Claude
  implementer. The router MUST NOT route review to a Claude model — enforced by
  a test.
- **Route logging.** Every routed review appends an `event:"review_route"` row
  to `subagent-runs.jsonl`, so the high/routine split is verifiable against the
  ~27% high / ~73% routine estimate before any further tuning.

**Config-driven models (Tier-5 forward-compat).** Tier model IDs are resolved
`env var > config/model-routing.json .review_tiers > built-in default` — never
hardcoded in the script. When the high-RAM/GPU box arrives, Tier-5 repoints the
routine/escalation (and possibly high) models to a larger local model by editing
the `review_tiers` block — no script change. A strong enough local model can
absorb the high tier too, driving OpenAI review spend toward $0.

**Escalation is prose-judgment, not a second classifier (for now).** A routine
review runs local Qwen first; the orchestrating Claude escalates to gpt-5.4 only
on low-confidence / non-trivial output. A dynamic LLM triage layer (the "hybrid
escalator") is deferred until the route log shows whether the cheap tier
actually misses findings.

## Consequences

**Projected:** ~$200/mo → ~$60/mo. Model tiering captures ~$75–85; the scope fix
captures ~$80–100 and sharpens every review. Both estimated off run-counts
(Codex tokens are not metered into `cost_log`), so the route log exists to
confirm the split empirically.

**Unchanged:** the security-auditor Opus second pass on novel crypto/auth/payment
runs regardless of tier — tiering only changes Pass 1's engine. ADR-022 preflight
still gates the Codex tiers (high, routine-escalation); a routine review may
proceed on local Qwen even when the OpenAI path is BLOCKED.

**Out of scope:** Gemini roles (architecture-critic, red-team, historian) bill on
a separate CLI account; their cost is pending the console number and the scope
fix barely applies (they intentionally want whole-repo context). Tracked
separately.

**Risk:** a mis-tuned high-stakes regex could send risky code to the cheap tier.
Mitigated by a conservative regex (false-high only costs money), the unchanged
Opus second pass on novel crypto/auth, and the explicit override knobs
(`REVIEW_TIER_FORCE`, `STACK_DOMAIN_MODE`, `STACK_SENSITIVITY`).
