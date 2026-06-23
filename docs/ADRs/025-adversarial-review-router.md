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
- **Fail-safe toward `high`.** On ANY ambiguity or error — an invalid
  `REVIEW_TIER_FORCE`, an unresolvable git ref, a failed `git diff` — the router
  defaults to **high**, never routine. Downgrading happens only on a positive
  "this diff is routine" signal (clean diff, no high-stakes paths). For the
  engine that gates everything, silence is never routine. (Added after the
  ADR-025 cross-family review found the original logic failed *open* toward
  routine on every error/override path.)
- **Cross-family (ADR-011) enforced at resolution, not just documented.**
  `rr_resolve` REFUSES any model id naming a Claude family
  (`claude|anthropic|opus|sonnet|haiku|fable`) from env or config and falls back
  to the built-in non-Claude default — so a stray override cannot quietly defeat
  the rule. Covered by tests for env- and config-supplied Claude ids.
- **Route logging is observability-only.** Every routed review appends an
  `event:"review_route"` row to `subagent-runs.jsonl`. This lets us confirm the
  high/routine *split* fired as estimated (~27/73); it does NOT certify each
  decision was correct (a mis-classified routine logs as a normal routine). It
  is telemetry to read, not a control loop.

**Config-driven models (Tier-5 forward-compat).** Tier model IDs are resolved
`env var > config/model-routing.json .review_tiers > built-in default` — never
hardcoded in the script. When the high-RAM/GPU box arrives, Tier-5 repoints the
routine/escalation (and possibly high) models to a larger local model by editing
the `review_tiers` block — no script change. A strong enough local model can
absorb the high tier too, driving OpenAI review spend toward $0.

**Escalation is best-effort, NOT a guarantee — the real backstop is the Opus
second pass.** A routine review runs local Qwen first; the orchestrating Claude
*may* escalate to gpt-5.4 on shallow / low-confidence output. This is a
convenience, not a safety mechanism: it is subjective and unaudited, so we do not
rely on it to catch what Qwen misses. For security-relevant code the genuine
safety net is the **unchanged security-auditor Opus second pass on novel
crypto/auth/payment**, which runs regardless of tier. A deterministic triage
layer (the "hybrid escalator") is deferred until the route log shows whether the
cheap tier actually misses findings; the fail-safe `high` default + the Opus
second pass cover the interim. (Reframed after the ADR-025 review flagged that
the original "escalate on judgment" framing over-claimed a safety property the
mechanism does not provide.)

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

**Risk:** the high-stakes classifier is path-regex-based, so it can be defeated
two ways. (1) *Missing terms* — addressed in review by broadening the regex
(jwt/hmac/kms/cert/tls/ssh/vault/seed/private-key + key/cert file extensions) and
biasing it toward false-high; a canary test asserts representative crypto/auth
paths classify `high`. (2) *Refactor drift* — renaming a high-stakes directory to
a name the regex no longer matches silently demotes it (Gemini's point; the false
case the "false-high only costs money" framing does NOT cover). Residual
mitigation: the fail-safe `high` default on any error, the unchanged Opus second
pass on novel crypto/auth, the override knobs (`REVIEW_TIER_FORCE`,
`STACK_DOMAIN_MODE`, `STACK_SENSITIVITY`), and a documented expectation to review
`RR_HIGH_STAKES_RE` during any repo-wide path refactor. A semantic classifier
(structured-signal tool or forced-function-call LLM triage) is the longer-term
fix if drift bites — deferred per "escalation" above.
