# ADR-028 — OpenAI API key: Keychain backup for the Codex family

- Status: Accepted
- Date: 2026-06-30
- Related: ADR-011 (Codex for the OpenAI family), ADR-015 (cloud cross-family via API keys), ADR-027 (Gemini CLI death)

## Context

The Codex roles (reviewer, security-auditor, product-critic) reach the
OpenAI/GPT-5.5 family via the local Codex CLI (`~/.codex/auth.json`), with
`OPENAI_API_KEY` (env) as the cloud direct-API rung (ADR-015). On 2026-06-30 the
Gemini CLI died outright (IneligibleTierError, ADR-027) — a vendor CLI vanished
with no warning. The Codex CLI is the same class of single-point dependency.

## Decision

Add a macOS **Keychain item `openai-api-key`** as a resilient LOCAL backup for the
OpenAI family, read by a small resolver.

- **Helper:** `scripts/lib/openai-key.sh` — `oai_key` (env `OPENAI_API_KEY` first,
  else Keychain `openai-api-key`, whitespace-stripped), `oai_available`, and
  `oai_export` (exports `OPENAI_API_KEY` from the Keychain ONLY when unset).
- **Cloud env always wins.** `oai_export` is a no-op if `OPENAI_API_KEY` is
  already set, so the cloud mechanism (ADR-015) is unchanged.
- **Wiring:** `cross-family-preflight.sh` calls `oai_export` before its key check,
  so a local box with the Keychain item gets a `READY` verdict even if the Codex
  CLI auth is gone. The three Codex agents `source openai-key.sh && oai_export` in
  their own shell before the preflight / direct-API rung (the preflight runs in a
  separate process, so each agent fills its own env).
- **Never logged; xtrace-guarded** (`set +x`) — the ADR-026/027 secret-hygiene rules.
- **Config:** the `codex` provider block records `api_key_keychain_backup:
  openai-api-key`. Version 1.2.0 → 1.3.0.

This is a BACKUP, not a new primary path: the Codex CLI remains the default; the
key only fills the gap when the CLI can't authenticate.

## Consequences

### Positive
- The OpenAI family survives a Codex CLI auth loss (the Gemini lesson, applied
  preemptively) — adversarial review degrades to the direct API instead of dying.
- Symmetric with DeepSeek (ADR-026) and Gemini (ADR-027): all non-Claude families
  now resolve a key from Keychain-or-env via a small `*_key`/`*_export` helper.

### Negative
- A direct OpenAI API call (the backup rung) IS billed to the key and metered by
  OpenAI, unlike the Codex CLI account — `cost_log` still won't see it.
- One more secret in the Keychain to rotate.

### Neutral
- **Anthropic deliberately NOT given the same backup.** The main loop *is* Claude;
  if Anthropic auth fails the whole agent is down and a backup key can't save a
  running session. The existing `anthropic-api-key` config slot covers metered
  sub-calls if ever needed.

## Alternatives considered
- **Store the key but don't wire it** — rejected: a key nothing reads adds no
  resilience.
- **Make the Keychain key the primary** — rejected: the Codex CLI account is the
  intended billing path; the key is a backup, not a replacement.
