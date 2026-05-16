# ADR 004: Multi-provider model strategy with adversarial diversity

**Status:** Accepted
**Date:** 2026-05-15
**Author:** the maintainer + Claude

## Context

The stack defaults to Anthropic models (Claude family). But for adversarial roles (reviewer, red-team, product-critic, architecture-critic), using the same model family as what's being reviewed reproduces blind spots.

## Decision

Multi-provider: Anthropic + OpenAI (Codex, GPT-5) + Google (Gemini 2.5 Pro) + Ollama (local).
Adversarial roles MUST use a different model family than what they review.

## Alternatives considered

- **Anthropic only.** Rejected — adversarial roles lose value if same model family. Same blind spots.
- **Anthropic + one other.** Considered. Rejected because different adversarial roles benefit from different non-Claude families (Codex for code review, Gemini for long-context, GPT-5 for product).
- **Many providers (chosen).** Three external providers (OpenAI, Google, Anthropic) + optional Ollama. Each plays to a specific strength.

## Consequences

- **Positive:** Adversarial review actually catches Claude blind spots. Long-context work (1M tokens) becomes possible via Gemini. Cost optimization possible (Haiku for trivia, Opus where it earns it).
- **Negative:** Three API keys to manage. Three billing relationships. More moving parts in setup.
- **Locked in:** Subagents are tied to specific provider families. Re-routing happens via /model-audit, not casually.

## Routing rules

See `docs/MODEL-STRATEGY.md` and `config/model-routing.json`.

Key invariants enforced by foreman:
- Reviewer's model family ≠ implementer's model family.
- Architecture-critic's model family ≠ architect's model family.
- Product-critic's model family ≠ Claude (the primary).

## References

- ADR-003 (subagent inventory)
- Conversation between the maintainer and Claude on 2026-05-15
