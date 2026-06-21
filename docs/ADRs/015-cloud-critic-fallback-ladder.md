# ADR 015: External-model critics fall back to env-key/API in cloud instead of STOPping

**Status:** Accepted (amends ADR-011 and ADR-012)
**Amended by:** ADR-022 — rung 3's literal STOP is replaced, for the *structurally-gated* case (key present but `api.openai.com` denied by the network policy / sandbox classifier, which an in-session `settings.local.json` edit cannot fix), by a preflight probe + a labeled Claude-only deviation + a structured decision handback. STOP survives only as the blocking recommendation for novel crypto/auth.
**Date:** 2026-06-16
**Author:** the maintainer + Claude (Opus 4.8)

## Context

ADR-011 (Codex) and ADR-012 (Gemini) route the adversarial-review gate through
a **non-Claude model family** reached via a local CLI: `reviewer`,
`security-auditor`, `product-critic` → `codex`; `red-team`,
`architecture-critic`, `historian` → `gemini`. Both ADRs ended the same way:
*if the CLI is unavailable, STOP — do not fall back to a Claude-only pass,
because adversarial diversity is the whole point.*

That rule was written for the **Mac Desktop** surface, where the CLIs are
installed and authenticated. It silently assumed "CLI present" and "capability
present" were the same thing.

In a **cloud** session they are not. The container starts with an empty
toolchain — the `codex` / `gemini` binaries are not preinstalled — but the
OpenAI / Gemini **API keys are available as environment variables** (the
intended way to pass secrets to a cloud session). The critic agents shelled out
to the missing CLIs, hit "command not found," and — following ADR-011/012
literally — **declared the entire critic gate unavailable and STOPped.** They
never checked `printenv OPENAI_API_KEY` / `GEMINI_API_KEY`, never installed the
CLI ad-hoc, and never called the API directly. The adversarial-review gate
stalled for hours, with the capability sitting right there in the environment.

The error was conflating the **binary** with the **model**. ADR-011/012 require
the *model family*, not a specific executable. A missing CLI with the key
present is a fully capable session.

## Decision

Replace the "CLI missing → STOP" rule in all six CLI-backed critic agents with a
**fallback ladder**. Stop only at the bottom rung:

1. **CLI on PATH** (`command -v codex` / `command -v gemini`) → use it (the
   ADR-011/012 default path, unchanged).
2. **Else if the key is in the environment** (`printenv OPENAI_API_KEY` /
   `printenv GEMINI_API_KEY`) → reach the same model family another way. Both of
   these satisfy ADR-011/012 — the agent picks at runtime based on what's
   available:
   - `npm i -g @openai/codex` / `@google/gemini-cli` ad-hoc, then use the CLI as
     normal; **or**
   - call the OpenAI / Gemini API directly over HTTP with the env key.
3. **Only if BOTH the CLI and the key are absent** → STOP and tell the user.
   The original anti-fallback rule still holds here: never substitute a
   Claude-only pass and call the gate complete.

Supporting changes:

- **Cloud bootstrap** (`scripts/cloud-bootstrap.sh`): when a key is present in
  the environment, best-effort `npm i -g` the matching CLI at session start so
  rung 1 is satisfied natively. A failed install never blocks the session — the
  agent ladder is the backstop.
- **Foreman / main-thread** (`skills/foreman/SKILL.md`): before relaying any
  "capability unavailable" in a cloud session, verify with `printenv` + PATH and
  confirm the agent walked its ladder. "CLI missing" ≠ "capability missing."
- **Docs** (`docs/CLOUD.md`): the critic API keys belong in the cloud
  environment's **variables** — that is the intended mechanism, not something to
  avoid. `printenv` is the detection path.

## Alternatives considered

- **A: Keep STOP, require each repo to commit an `install-ai-critics.sh` hook.**
  Rejected: pushes per-repo setup onto every project, is easy to forget (and was
  forgotten — that is how the stall happened), and still STOPs the moment a repo
  lacks the hook even though the key is present. Capability detection belongs in
  the agents and the shared bootstrap, not in N copies of a repo hook.
- **B: Force one fallback mechanism (HTTP API only, or ad-hoc install only).**
  Rejected: the raw-API path requires baking model IDs and request/response
  shapes into six prompt files (brittle, drifts as APIs change); the install
  path requires npm + network egress at agent runtime (not always available).
  Each fails in conditions the other survives. Documenting both and letting the
  agent pick at runtime is the most robust.
- **C (chosen): CLI → env-key (ad-hoc install *or* direct API, agent's choice)
  → STOP only if both absent**, plus a best-effort bootstrap install and a
  foreman verification rule.

## Consequences

- **Positive:** the critic gate runs in cloud whenever the keys are set, with no
  per-repo hook. The non-Claude-family requirement of ADR-011/012 is preserved
  on every rung. Local Desktop behavior is unchanged (rung 1 always hits).
- **Negative:** the agent prompts are longer, and rung 2 can incur an ad-hoc
  install or a hand-built API call whose request shape the agent must get right.
  Bootstrap install adds a few seconds to cold cloud boots when keys are set.
- **Locked in:** API keys for the external-model critics are expected to live in
  the cloud environment's variables. The "STOP, never fall back" absolute from
  ADR-011/012 now applies only at rung 3 (both binary and key absent).

## References

- ADR-011 (Codex for the OpenAI/GPT-5.5 family) — amended here.
- ADR-012 (Gemini via the local CLI) — amended here.
- `docs/CLOUD.md` — "External-model critics (Codex / Gemini) in cloud."
- Agents: `reviewer`, `security-auditor`, `product-critic`, `red-team`,
  `architecture-critic`, `historian`.
