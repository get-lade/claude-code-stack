# ADR 036: Stack distribution model — operator-run, deferred private flip, CarboNet licensee path

Date: 2026-07-22
Status: accepted
Author: bschonbrun

## Context

The stack repo (`get-lade/claude-code-stack`) is public today. M2 proposed
flipping it private, which requires a `CLAUDE_STACK_REPO_TOKEN` in every
Claude Code cloud environment that bootstraps the stack — and cloud
environments hold env vars individually, set manually in the web UI, with no
org-wide inheritance. There are few lade environments but many CarboNet ones,
so the flip looked like a large per-environment paste job with client-facing
token questions.

Working through it surfaced the actual operating model, which resolves most
of the tension:

1. **lade is the operator.** Clients never run lade locally or in their own
   environments. All Claude Code sessions and cloud environments — including
   the many CarboNet-repo ones — are lade-operated. Clients receive the
   deployed app bundle in their Cloudflare account (and optionally their own
   app's source repo), never lade module code. IP protection is structural,
   not contractual or technical.
2. **Module placement rule.** lade's modules split into: (a) services that
   run on lade's side (engine, provisioner, reconciler — API-shaped, source
   never leaves home) and (b) session tooling that runs in lade-operated
   environments (skills, hooks, packs). The question is only ever "lade
   laptop/cloud vs lade server" — never "client-side vs server-side".
3. **CarboNet is the unique exception**: a right-to-use license. They build
   apps with the stack directly in Claude Code, usually outside lade. They
   legitimately need stack code in their own environments.
4. **Git tokens are session/build-time credentials**, not runtime secrets.
   They live in lade's keychain and lade's cloud env vars — never in a
   tenant's Cloudflare Secrets Store (ADR-035), which holds only what the
   running Worker binds.

## Decision

The repo **stays public for now**. The private flip (M2) is deferred
indefinitely — it is a business paywall decision, not a security one (no
secrets or client content live in the repo; M1 scrubbed tenant specifics,
`.env*` is ignored, ADR-035 keeps values in Cloudflare).

Preparation for the eventual flip is done and parked: a fine-grained
read-only PAT scoped to this repo is minted and stored in Bill's keychain,
`.env.local`, and the lade cloud environment as `CLAUDE_STACK_REPO_TOKEN`.
Flipping later = paste that var into remaining lade-run environments, then
make the repo private. A missed environment degrades gracefully
(cloud-bootstrap exits 0; the session runs stackless).

CarboNet's licensee path is decided in direction and deferred to the
provisioner/reconciler build: deliver core to their org via an
**automatically-synced mirror repo** (recommended; license cutoff = stop
syncing, they keep the frozen copy) and/or **vendoring stack files into each
app repo at provision time** (zero tokens, zero per-environment setup).
Hand-minted per-repo tokens are explicitly rejected as the long-term
mechanism; if token automation is ever needed, it is a GitHub App (which can
mint its own short-lived tokens), not PATs.

## Consequences

### Positive
- No per-environment paste-athon now; no lade credentials in any client hands.
- Onboarding a normal client requires zero client-side setup, by construction.
- CarboNet's new-repo flow can become fully automatic (mirror or vendoring)
  instead of a manual token ritual.
- The flip stays a one-afternoon operation whenever the paywall matters.

### Negative
- While public, anyone can clone the stack — the right-to-use license has no
  technical enforcement yet.
- Deferral means the reconciler/mirror work is now on the critical path for
  both pack delivery (ADR-034 §5) and the CarboNet distribution story.

### Neutral
- `CLAUDE_STACK_REPO_TOKEN` sits unused until the flip; it is read-only and
  single-repo scoped.
- The many CarboNet cloud environments stay configured as they are.

## Alternatives considered

### Flip private now, per-tenant tokens
Mint a second CarboNet-scoped token and paste into every environment.
Rejected for now: large manual UI job across many environments, puts a
lade-issued credential into circulation, and buys nothing today since the
repo holds no secrets.

### Vendor the stack into every client repo
Solves environment-variable sprawl generally, but is unnecessary for normal
clients (lade operates their environments anyway) and premature before the
reconciler exists. Kept as the likely CarboNet mechanism.

### Client-side secrecy engineering (bundling, obfuscation, engine-only code)
Rejected as a general goal: under the operator model clients never see stack
code anyway; anything that truly must stay secret belongs behind the engine
API on lade's server (module placement rule above).

## References
- ADR-034 — tenant pack contract (reconciler PR delivery §5)
- ADR-035 — tenant deploy secrets in Cloudflare Secrets Store
- docs/plans/m3-pack-mechanism.md (M3, shipped #84)
- docs/plans/provisioner-secret-binding.md (secret-binder, shipped #85)
- scripts/cloud-bootstrap.sh (graceful stackless degradation)
