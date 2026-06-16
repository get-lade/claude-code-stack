# ADR 012: Route Gemini-family work through the local Gemini CLI

**Status:** Accepted
**Amended by:** ADR-015 — in cloud, "Gemini CLI unavailable → STOP" now applies only when **both** the `gemini` CLI and `GEMINI_API_KEY` are absent; otherwise the agent reaches Gemini via the env key (ad-hoc install or direct API).
**Date:** 2026-05-16
**Author:** the maintainer + Claude (during Session 5 — Tier 3 install)

## Context

The artifacts assign `architecture-critic` (Tier 3), `red-team` (Tier 2), and `historian` (Tier 4) to `model: google/gemini-2.5-pro`, and the Tier 3 manifest requires a Keychain item `google-ai-api-key`. Gemini was chosen for two reasons: a non-Claude model family (adversarial diversity) and a large context window (read a whole repo at once).

Same two problems as the OpenAI case (ADR-011):

1. **Claude Code cannot run a subagent on a non-Claude model.** "architecture-critic runs on Gemini" was never literally possible as a native subagent.
2. **No Google API key and no Gemini tooling existed** on the machine — only a stale `~/.gemini/` directory from Google's Antigravity IDE.

the maintainer chose (2026-05-16) to add Google rather than drop it — keeping genuine three-way diversity (Claude + OpenAI-via-Codex + Gemini). Claude Opus 4.7 already has a 1M context window, so "read the whole repo" did not strictly require Gemini; the deciding factor was preserving a third independent model family for adversarial roles.

## Decision

The stack reaches the Gemini family through the **local Gemini CLI** (Google's official `gemini` CLI, installed via Homebrew), not a direct Google AI Studio API key.

- `architecture-critic` and `red-team` are subagents that run on a Claude model (`claude-sonnet-4-6`) and **orchestrate the Gemini CLI** via `bash` — `gemini -p "<prompt>"` (non-interactive; `--skip-trust` to avoid the workspace-trust prompt), run from the repo root for whole-repo context. They capture and relay Gemini's output; they do not substitute Claude judgment for it. If the Gemini CLI is unavailable they STOP rather than fall back to a Claude-only pass.
- `historian` (Tier 4) follows the same pattern when Tier 4 installs.
- `model-routing.json` replaces the API-key `google` provider block with a `gemini` provider (CLI invocation, `~/.gemini/` auth, no Keychain item).
- The Tier 3 manifest requires `command: gemini` instead of `keychain_item: google-ai-api-key`.

The Gemini CLI is authenticated via the maintainer's Google account login (auth stored in `~/.gemini/`), exactly parallel to how Codex stores auth in `~/.codex/`.

## Alternatives considered

### A: Drop Gemini; route those roles to Codex + Opus
architecture-critic / red-team → Codex; historian → Claude Opus. No new tooling. Rejected by the maintainer — it collapses to a two-family setup and loses Gemini's larger context for whole-repo reads.

### B (chosen): Add Google via the Gemini CLI
Preserves genuine three-way model diversity. Uses Google's official CLI (installed, authenticated). Parallel to the Codex pattern (ADR-011).

### Direct Google AI Studio API key
Considered as the auth method. The Gemini CLI's Google-account login is simpler (no key to store or rotate) and is what was used. An API key remains a valid alternative if account-based quota is ever insufficient.

## Consequences

### Positive
- Genuine three-family adversarial diversity (Claude / OpenAI-via-Codex / Gemini).
- Uses Google's official, maintained CLI; no stack-maintained API-call code.
- No new credential to manage (Google-account login, like Codex).

### Negative
- Deviates from the artifacts' `google-ai-api-key` assumption — `model-routing.json`, three subagent definitions, and the Tier 3 manifest are adapted.
- Gemini calls are billed via the Gemini CLI account and are **not** metered into `cost_log` — Tier 4 cost reporting will not see architecture-critic / red-team / historian spend (same gap as Codex, ADR-011).
- These roles depend on the `gemini` CLI being present and authed; if not, they halt by design.

### Neutral / locked-in
- `architecture-critic`, `red-team`, `historian` are now Gemini-CLI-orchestrating subagents.

## References

- ADR-011 (the parallel Codex decision — same reasoning, OpenAI family)
- ADR-004 (multi-provider strategy — this realizes the "third family" goal)
- ADR-008 (the prior artifact-vs-Claude-Code-reality correction)
- `agents/architecture-critic.md`, `agents/red-team.md`
- `config/model-routing.json` (`gemini` provider)
- `config/tier-manifests/tier-3.json`
- Conversation between the maintainer and Claude, 2026-05-16. Gemini CLI v0.42.0 verified working.
