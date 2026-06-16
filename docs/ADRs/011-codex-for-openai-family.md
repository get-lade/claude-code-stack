# ADR 011: Route OpenAI / GPT-5.5-family work through the local Codex CLI

**Status:** Accepted
**Amended by:** ADR-015 — in cloud, "Codex CLI unavailable → STOP" now applies only when **both** the `codex` CLI and `OPENAI_API_KEY` are absent; otherwise the agent reaches GPT-5.5 via the env key (ad-hoc install or direct API).
**Date:** 2026-05-16
**Author:** the maintainer + Claude (during Session 4 — Tier 2 install)

## Context

The v1.0/v1.1 artifacts define three adversarial-review subagents — `reviewer`, `product-critic`, `security-auditor` — with `model: openai/gpt-5.5-2026-04-23`, and the Tier 2 manifest requires a Keychain item `openai-api-key`.

Two problems surfaced when installing Tier 2:

1. **Claude Code cannot run a subagent on a non-Claude model.** A subagent's `model:` field accepts Claude models / aliases only. So "reviewer runs on GPT-5.5" was never literally possible as a native Claude Code subagent — the cross-family review always needed a real bridge (a direct API call, or a separate CLI). This is the same class of gap that v1.1 caught with foreman-as-subagent (ADR-008).
2. **No `openai-api-key` exists in the maintainer's Keychain.** But the Codex CLI (`codex` v0.128.0) *is* installed and authenticated (`~/.codex/auth.json`), and Codex is OpenAI's GPT-5.5-family coding agent. The OpenAI-family capability already exists on the machine.

## Decision

The stack reaches the OpenAI / GPT-5.5 family through the **local Codex CLI**, not a direct OpenAI API key.

- `reviewer`, `product-critic`, `security-auditor` are defined as subagents that run on a Claude model (`claude-sonnet-4-6`) and **orchestrate Codex** via `bash` — `codex exec` (general) and `codex exec review` (code review). They capture and relay Codex's output; they do not substitute Claude judgment for Codex's verdict. If Codex is unavailable they STOP rather than fall back to a Claude-only pass (a Claude-only pass would reproduce the implementer's blind spots and defeat adversarial diversity).
- `model-routing.json` replaces the `openai` provider block with a `codex` provider (CLI invocation, `~/.codex/auth.json` auth, no Keychain item).
- The Tier 2 manifest requires `command: codex` instead of `keychain_item: openai-api-key`.

## Alternatives considered

### A: Add a separate OpenAI API key to Keychain
Create a new key at platform.openai.com, store as `openai-api-key`. Rejected: it adds a second OpenAI credential and billing surface, and — critically — does **not** make the subagent definitions work as written (a subagent still can't run natively on GPT-5.5). The actual invocation would still go through Codex or a script. The key alone solves nothing the Codex path doesn't.

### B (chosen): Use the existing Codex CLI
Already installed, authenticated, and is itself the GPT-5.5-family agent. One OpenAI billing surface. The adversarial-diversity intent — review by a non-Claude model family — is fully served.

## Consequences

### Positive
- Uses what is already installed and working; no new credential.
- Honestly reflects how Claude Code actually works (no pretend OpenAI-model subagents).
- Single OpenAI billing surface (the Codex account).

### Negative
- Deviates from the artifacts' `openai-api-key` assumption — the Tier 2 manifest and three subagent definitions are adapted (done in Session 4).
- Codex calls are billed via the Codex account and are **not** metered into the stack's `cost_log` table — Tier 4 cost reporting will not see adversarial-review spend.
- Adversarial roles depend on the `codex` CLI being present and authed; if it is not, those roles halt by design.

### Neutral / locked-in
- `reviewer`/`product-critic`/`security-auditor` are now Codex-orchestrating subagents. Reverting to a direct OpenAI API would require re-adapting them.

## Open / related

- `red-team`, `architecture-critic`, `historian` use `google/gemini-2.5-pro` and have the **same** "Claude Code can't run non-Claude subagents" issue. No Google key is configured. This is unresolved and deferred to Session 5 (Tier 3) for a parallel decision.

## References

- ADR-008 (three-mode orchestration — the prior instance of an artifact-vs-Claude-Code-reality correction)
- `agents/reviewer.md`, `agents/product-critic.md`, `agents/security-auditor.md`
- `config/model-routing.json` (`codex` provider)
- `config/tier-manifests/tier-2.json`
- Conversation between the maintainer and Claude, 2026-05-16
