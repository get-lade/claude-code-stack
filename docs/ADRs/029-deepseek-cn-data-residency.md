# ADR-029 — DeepSeek-CN data-residency gate (routine-only, fail-closed)

- Status: Accepted
- Date: 2026-06-30
- Revises: ADR-026 (DeepSeek third voice)

## Context

ADR-026 wired DeepSeek-v4 as a third adversarial voice on **HIGH-stakes** diffs.
But `api.deepseek.com` is **hosted in China**. The high-stakes tier is exactly
auth/crypto/secret/payment/migration code — so the original wiring sent the most
sensitive code to a China-hosted endpoint. That is backwards for data residency.

## Decision

DeepSeek-CN reviews **routine / non-sensitive diffs ONLY**, and the helper itself
**hard-blocks fail-closed** on anything sensitive — independent of how a caller
invokes it.

- **Rename to flag residency.** Provider `deepseek` → `deepseek-cn`; Keychain item
  `deepseek-api-key` → `deepseek-cn-api-key`; env `DEEPSEEK_API_KEY` →
  `DEEPSEEK_CN_API_KEY`. The `-cn` suffix makes the China class obvious at every
  call site.
- **In-helper data-residency guard (defense-in-depth).**
  `scripts/lib/deepseek-review.sh` refuses to send (returns 8, "BLOCKED —
  data-residency") when ANY of:
  - `STACK_SENSITIVITY=high`,
  - `STACK_DOMAIN_MODE` ∈ {security, schema-migration},
  - the diff's changed paths OR added content match the high-stakes regex
    (auth/login/oauth/token/secret/credential/crypto/encrypt/hmac/private-key/
    vault/kms/mfa/payment/billing/stripe/migration/`.sql`/rls/`.env`/api-key/
    `BEGIN … PRIVATE KEY`).
  This is the real protection: even a mis-wired caller cannot exfiltrate sensitive
  code to China.
- **Caller wiring flipped.** `reviewer` runs it on `RR_STAKES=routine` only.
  `security-auditor` is effectively off (security diffs are high-stakes → the guard
  blocks). `red-team` no longer calls it at all (red-team is always high-stakes).
- **Key-charset hardening folded in** (ADR-026/027 lesson): `dsr_trim` now strips to
  `[A-Za-z0-9._-]`, not just whitespace, so a pasted control byte can't corrupt the
  header.

Config version 1.3.0 → 1.4.0.

## Consequences

### Positive
- The China-hosted model never receives high-stakes or sensitive code — enforced
  in the helper (fail-closed), not merely by convention.
- The residency class is legible everywhere (the `-cn` name).
- Still adds an independent third family on the (large) routine surface.

### Negative
- DeepSeek-CN no longer contributes on the high-stakes diffs where extra eyes are
  most valuable — an accepted trade for data residency.
- The content regex is conservative (biased to block): some non-sensitive diffs
  that merely mention a keyword will be blocked. Acceptable — false-block is safe;
  false-send is not.

### Neutral
- The key value is unchanged (same account); only the Keychain item name + provider
  name change. The old `deepseek-api-key` item can be deleted after `update.sh`.

## Alternatives considered
- **Keep on high-stakes with redaction** — rejected: redacting a diff reliably
  enough to be safe is brittle; blocking is simpler and safe.
- **Disable DeepSeek entirely** — rejected by the maintainer: keep the routine-tier
  coverage with a hard residency guard.
