# ADR-026 — DeepSeek-v4 as a third adversarial voice

- Status: Accepted
- Date: 2026-06-30
- Extends: ADR-011 (Codex for the OpenAI family), ADR-025 (adversarial-review router)
- Supersedes: none

## Context

Adversarial review (ADR-011) is delegated to a NON-Claude model family so it
carries different blind spots than the Claude implementer. Today two families
cover it: Codex (OpenAI/GPT-5.5) on high-stakes diffs, local Qwen (Alibaba) on
routine. The maintainer now has DeepSeek-v4 API keys and wants DeepSeek used for
adversarial testing.

Two independent reviewers still share failure modes; a third independent family
catches what both miss — most valuable exactly on the diffs that matter (auth,
crypto, payment, migration, RLS, secrets).

## Decision

Add **DeepSeek-v4** (`deepseek-v4-pro`) as a **third, independent, ADVISORY
adversarial voice on HIGH-stakes diffs only**.

- **Additive, not a replacement.** The Codex pass remains the mandated
  cross-family gate. DeepSeek runs alongside it and its findings are relayed as a
  distinct voice. It NEVER auto-blocks and NEVER substitutes for Codex.
- **High-stakes only.** Routine diffs stay on the existing local-Qwen→Codex path
  — no third call, no added routine cost.
- **Orchestration:** `scripts/lib/deepseek-review.sh` (`dsr_run <agent> [base]
  [head]`). DeepSeek's API is OpenAI-compatible (base `https://api.deepseek.com`,
  `/chat/completions`, model `deepseek-v4-pro`; verified 2026-06-30). The helper
  builds the diff, posts the standard adversarial-review prompt, prints findings.
- **Key handling:** macOS Keychain item `deepseek-api-key` (matches the
  `anthropic-api-key` pattern), with `DEEPSEEK_API_KEY` env fallback for
  cloud/CI. The key is never logged or echoed.
- **Degradation:** missing key / unreachable API / git failure → the voice prints
  "UNAVAILABLE" and exits non-zero. This does NOT fail the review — Codex is still
  the gate. (Same advisory posture as a flaky optional check, not a hard stop.)
- **Cross-family invariant (ADR-011) preserved:** DeepSeek is non-Claude. The
  helper pins a DeepSeek-only base URL + model id; it must never be pointed at a
  Claude model.

Config: `config/model-routing.json` gains a `deepseek` provider block and a
`review_tiers.high.third_voice` entry (`advisory:true, blocks:false`). Version
bumped 1.1.1 → 1.2.0. Wired into `reviewer`, `security-auditor`, and `red-team`.

## Consequences

### Positive
- A third independent family on high-stakes diffs — strictly more coverage where
  it matters; DeepSeek-v4-pro is a strong reasoning/agentic model at low cost
  (~$0.44/$0.87 per Mtok in/out).
- Zero added cost on routine reviews (high-stakes only).
- Fail-soft: never strands a PR if the DeepSeek path is down.

### Negative
- One extra cloud call + wall-time per high-stakes review.
- DeepSeek spend, like Codex/Gemini, is billed to its own API account and is NOT
  metered into `cost_log` — Tier-4 cost reporting does not see it.
- A third voice can add noise / conflicting findings; the orchestrating agent
  relays all three and the human decides (no auto-merge).

### Neutral
- `deepseek-chat`/`deepseek-reasoner` model ids retire 2026-07-24; we pin the v4
  ids. Revisit at the next /model-audit.

## Alternatives considered

- **Replace routine-tier Qwen with DeepSeek** — rejected: the maintainer chose a
  3rd independent voice on high stakes (more coverage) over a cheaper routine
  reviewer.
- **Replace Gemini roles with DeepSeek** — rejected: would drop a family rather
  than add one.
- **Make DeepSeek blocking** — rejected for now: an advisory third voice avoids a
  new merge-gate dependency on a freshly-added provider; revisit once it has a
  track record.
