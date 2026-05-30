# ADR 013: Core/overlay model for organization-specific customization

**Status:** Proposed
**Date:** 2026-05-30
**Author:** the maintainer + Claude

## Context

The stack is built to be **generic and publicly shareable** — agents, skills, hooks, tiers, and templates that serve any team. But real use also needs **organization-specific** material: brand colors, auth/org IDs, infra rules, domain standards, project templates. Today that company material has no defined home, so it either pollutes the generic core or lives in a disconnected repo (e.g. the Antigravity-era `carbonet-vibe-coding-standards`).

Three requirements pull in tension:

1. **Evolve the core for everyone.** The maintainer keeps improving the generic stack and shares it publicly; all consumers pull those improvements.
2. **Layer private, company-specific deltas** on top of that core without forking it.
3. **Reuse across multiple organizations** over time — company #2, #3 each get their own private layer over the same public core.

A full private fork of the stack satisfies (2) but breaks (1) and (3): every core improvement becomes a merge, and private company data can leak into a fork meant to track a public upstream.

## Decision

Adopt a **core + overlay** model with a strict contract.

- **Core** = this repo (`claude-code-stack`), public, organization-agnostic. The single upstream everyone tracks.
- **Overlay** = a private, per-organization repo (e.g. `CarboNet-Nano/carbonet-standards`) containing only that org's deltas: standards docs, company `CLAUDE.md` template, any skill/agent additions or overrides, company config.

**The contract that keeps it conflict-free:**
> An overlay never *copies or edits* a core file. It only **adds new files** or **declares overrides** (a file the merge layer applies on top of the corresponding core file). The core therefore stays upgradeable forever — `git pull` upstream never conflicts with company deltas.

**Two composition points:**

1. **Install / update time** → merged into `~/.claude`. Layer precedence, lowest to highest:
   `built-in defaults  <  core  <  global defaults  <  organization overlay  <  project (.claude/stack-config.json)`.
   Core upgrade = pull upstream; the overlay and project layers are untouched.

2. **Repo-init time** (`/project-init`) → the overlay supplies the organization's `CLAUDE.md` template and standards, which are injected into every newly initialized repo automatically. New project inherits core behavior + company standards in one step.

This is the same layering the stack already uses for defaults (`built-in < global session_prefs_defaults < project`); the overlay slots in as a named layer between core and project.

## Alternatives considered

### A: Full private fork of the stack
Self-contained, but every public-core improvement is a manual merge, and the fork mixes private data with a tree meant to track public upstream. Rejected — fails "evolve for everyone" and "reuse across orgs."

### B: Bake company material into the core, gate by config
One repo, company files guarded by flags. Rejected — private brand/auth/infra data cannot live in a public repo, and it doesn't scale to multiple orgs.

### C (chosen): Core + private overlay, deltas-only contract
Core stays public and generic; each org keeps a private overlay of pure deltas; both compose at install and repo-init. Satisfies all three requirements.

## Consequences

### Positive
- Core evolves once, benefits every consumer; public sharing stays clean.
- Company data is fully private and isolated in its own repo.
- Multi-org reuse is free — each org is another overlay over the same core.
- Core upgrades never conflict with company customization (deltas-only rule).

### Negative / to define later
- A **merge mechanism** must implement override resolution at install time (extend `scripts/lib/config-merger.sh`). Deferred until a second org actually exists (YAGNI) — short term, only CarboNet's overlay is built and applied directly.
- Override semantics need a precise spec (whole-file replace vs. deep-merge for JSON/templates) before the mechanism ships.
- Overlay authors must honor the deltas-only rule; a lint check should later enforce "no core file copied verbatim."

## Short-term path (CarboNet)
1. Keep this repo as the generic public core.
2. Stand up private `CarboNet-Nano/carbonet-standards` with the 6 migrated `STANDARDS/*.md`.
3. Apply it directly for now; formalize the install-time merge mechanism when org #2 appears.
