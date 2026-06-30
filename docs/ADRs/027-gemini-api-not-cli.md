# ADR-027 — Gemini via REST API (the CLI is dead)

- Status: Accepted
- Date: 2026-06-30
- Revises: ADR-012 (Gemini CLI for the Google family)
- Related: ADR-015 (cloud cross-family via API keys), ADR-026 (DeepSeek third voice)

## Context

ADR-012 reached the non-Claude Gemini family through the locally-installed,
authenticated Gemini CLI (`gemini -p`), which also read the repo itself for
whole-repo context. As of 2026-06-30 the CLI is dead for this account:

```
IneligibleTierError: This client is no longer supported for Gemini Code Assist
for individuals. To continue using Gemini, please migrate to the Antigravity
suite of products. (tierId: free-tier, reasonCode: UNSUPPORTED_CLIENT)
```

The three Gemini roles — architecture-critic, red-team, historian — were
therefore broken. The /model-audit (2026-06-30) had separately recommended
pinning `gemini-3.1-pro` to stop CLI auto-downgrade to 3.5 Flash; that
recommendation is now subsumed — there is no CLI to pin.

## Decision

Reach the Gemini family through the **REST API**, pinned to
**`gemini-3.1-pro-preview`**.

- **Helper:** `scripts/lib/gemini-api.sh` (`gmn_call <prompt>`, optional context
  on stdin). POSTs to
  `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro-preview:generateContent`
  with header `x-goog-api-key`; returns `.candidates[0].content.parts[0].text`.
- **Key:** macOS Keychain item `gemini-api-key`, `GEMINI_API_KEY` env fallback
  (cloud/CI). All whitespace stripped from the resolved key (the ADR-026 401
  lesson). Never logged; `set +x` guards xtrace leakage.
- **Context shift (load-bearing):** the API has NO filesystem access — the CLI
  used to read the repo itself. The orchestrating agent now ASSEMBLES context
  (diff, files, archived docs) and pipes it into `gmn_call`. The three agent
  files are rewired accordingly; the helper caps input size.
- **No CLI fallback.** The dead CLI rung is removed from the ADR-012 ladder. If
  the API key is absent, the role STOPs and tells the user — it does NOT fall back
  to a Claude-only pass (cross-family diversity is the point of these roles).
- **Cross-family invariant (ADR-011) preserved:** Gemini is non-Claude; the
  helper pins a Google-only endpoint + model id.

Config: the `gemini` provider block flips from CLI to API (base URL, model,
Keychain ref). Version 1.2.0 → 1.3.0.

## Consequences

### Positive
- The three Gemini roles work again, on a current model (3.1 Pro > 2.5 Pro on
  reasoning + long context), with no silent downgrade.
- Consistent with the cloud-adversarial / API-key direction (ADR-015) and the
  DeepSeek helper pattern (ADR-026).

### Negative
- Gemini API spend is billed to the API key and is NOT metered into `cost_log`
  (same as Codex/DeepSeek).
- The agent now bears context assembly the CLI did for free — curation matters
  (the helper caps input; whole-repo dumps will be truncated). For very large
  critiques this is a real limitation vs the old CLI's repo-walking.
- `gemini-3.1-pro-preview` is a PREVIEW id — revisit at the next /model-audit.

### Neutral
- ADR-012's intent (cross-family Gemini perspective) is unchanged; only the
  transport changes.

## Alternatives considered

- **Migrate to the Antigravity suite** (the error's suggestion) — larger change,
  unclear automation surface; the REST API is the minimal restore.
- **Drop Gemini, reassign roles to DeepSeek/Codex** — rejected by the maintainer:
  keep a distinct third family rather than narrow to two.
- **Pin `-m gemini-3.1-pro` on the CLI** (the original audit fix) — impossible;
  the CLI no longer authenticates at all.
