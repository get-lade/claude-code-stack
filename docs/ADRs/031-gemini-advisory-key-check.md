# ADR-031 — Tier-3 Gemini requirement is an advisory API-key check, not the dead CLI

- Status: Proposed
- Date: 2026-07-03
- Depends on: ADR-030 (advisory vendor-CLI requirements — the shared mechanism)
- Related: ADR-012 (Gemini via CLI, superseded), ADR-027 (Gemini via REST API — the CLI is dead)

## Context

ADR-027 retired the Gemini CLI (`IneligibleTierError` — the CLI no longer
authenticates) and moved the Gemini roles to the REST API
(`scripts/lib/gemini-api.sh`), keyed on `GEMINI_API_KEY` (env) or macOS Keychain
`gemini-api-key`. But `config/tier-manifests/tier-3.json` still hard-required
`command: gemini` and smoke-tested `command -v gemini`, so a fresh Tier-3 install
**aborted on the now-dead CLI**, and verify failed on a box that correctly has no
`gemini` binary.

ADR-030 introduces the shared advisory-requirement mechanism (`"advisory": true`
requirements that warn instead of failing; an `advisory_smoke_tests` array run as
soft checks in `verify.sh`). This ADR is the Gemini-specific application of it.

## Decision

Move the tier-3 Gemini dependency out of hard `requirements[]` / hard
`smoke_tests` into a soft key check that names the real ADR-027 dependency:

- **Dropped the hard `command: gemini` requirement and the `command -v gemini`
  smoke test** — that binary can no longer authenticate.
- **Soft key check** in `advisory_smoke_tests`:
  `[ -n "${GEMINI_API_KEY:-}" ] || security find-generic-password -s
  gemini-api-key -w` — accepts the env var (cloud/CI) or the Keychain item, and
  is null-safe under `verify.sh`'s `set -u` (an unset `GEMINI_API_KEY` must not
  abort the script — exactly the fresh-box case being fixed). `verify.sh` runs
  this at install step 5, so the warning still surfaces during a fresh install.
- **Not a `requirements[]` entry.** ADR-030's advisory-requirement mechanism is
  `command`-only — the `keychain_item` case in `check_tier_requirements` has no
  `advisory` branch, so a `keychain_item` requirement (even marked
  `advisory:true`) hard-fails and aborts a fresh install. Rather than extend
  ADR-030's shared plumbing from this branch, the Gemini key check lives solely
  in `advisory_smoke_tests`. (If a hard-gated install-time Gemini requirement is
  ever wanted, ADR-030 should grow a `keychain_item` advisory branch first.)
- **Codex is untouched here** — ADR-030 owns the codex tier-2/3 advisory change.
  This ADR is Gemini-only.
- Description + `notes.gemini_requirement` rewritten from "local Gemini CLI" to
  the API-not-CLI reality.

## Consequences

### Positive
- Fresh Tier-3 install no longer fails on the dead Gemini CLI; verify passes on a
  box that correctly lacks the binary.
- The requirement names the *actual* dependency (`gemini-api-key`), so the
  advisory warning is actionable instead of "install a dead CLI."

### Negative / dependency
- **This delta is not self-contained.** The `advisory:true` field and
  `advisory_smoke_tests` array are inert (and the Keychain requirement would
  hard-fail) without ADR-030's `tier-installer.sh` / `verify.sh` plumbing. It
  must be **rebased onto `feat/adr-030-codex-api-transport`** before it installs
  correctly. Do not merge or dogfood standalone.

### Neutral
- Verified working on top of the ADR-030 plumbing during development (fresh
  Tier-3 install, key unset, no `--skip-requirements` → exit 0, Gemini advisory
  WARN); that plumbing now lives on the ADR-030 branch.
