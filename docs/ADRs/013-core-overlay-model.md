# ADR 013: Core/overlay model for organization-specific customization

**Status:** Accepted (amended 2026-05-30 — see "Amendments" below)
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

The overlay slots in as a named layer between core and project. Note there are in fact **two distinct mechanisms** the overlay touches, not one (this is corrected in the Amendments section — the original text wrongly called them "the same layering"):

- **Read-time defaults resolution** — how the running stack resolves a setting's value: `built-in < global session_prefs_defaults < project`. The overlay adds a layer here.
- **Install-time file composition** — how files land in `~/.claude` (`scripts/lib/tier-installer.sh` + `config-merger.sh`). This is where override resolution actually runs, and its current semantics do **not** match the precedence above (see Amendments).

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

## Amendments (review, 2026-05-30)

Accepted on review against the core's actual structure (`scripts/lib/config-merger.sh`, `scripts/lib/tier-installer.sh`, tier manifests, and the read-time defaults chain). The model and the deltas-only contract are sound and the rejected alternatives are correctly rejected. Three corrections, and one decision the original deferred.

### 1. Precedence inversion in the install-time merge (must-fix before the mechanism ships)

The original Consequences say the merge mechanism is "extend `scripts/lib/config-merger.sh`." That is not a safe drop-in. `merge_json` resolves a scalar conflict by **keeping the target (the value already on disk)** and applying the stack's incoming value only on explicit user approval — i.e. *target/user wins*. Installs apply tiers cumulatively, so if the overlay is applied as a later step, the overlay is the *source* and an already-installed core value is the *target* — meaning **the overlay would lose to core**, the exact opposite of this ADR's `core < overlay` precedence.

Therefore the override resolver cannot reuse `merge_json`'s default semantics for overlay-over-core. It needs an explicit application order where, on conflict: `core < overlay`, and then `overlay < project/user`. Concretely that is two different conflict-winners depending on which pair is merging — not one global rule. Whoever builds this owns reconciling that, not just "calling the existing merger."

### 2. Two mechanisms, not one (corrected inline above)

The overlay touches both read-time defaults resolution and install-time file composition; they are separate systems with separate semantics. The Decision text has been corrected.

### 3. CLAUDE.md single managed-marker limitation (must-fix for composition point 2)

`append_stack_section` supports exactly one `<!-- CLAUDE_CODE_STACK_MANAGED -->` … `<!-- /…_MANAGED -->` block per file. Composition point 2 (repo-init injecting the org's CLAUDE.md template) would collide with the core's own managed section — only one survives. The repo-init injection needs a **distinct overlay marker** (e.g. `<!-- ORG_OVERLAY_MANAGED -->`) so core-managed and org-managed sections coexist and both stay idempotently re-writable.

### Override semantics — decided now, not deferred

The original defers both the mechanism *and* its spec until org #2. Deferring the **implementation** is right (YAGNI — only CarboNet exists and is applied directly). Deferring the **spec** is not: CarboNet's overlay is being authored against this contract *today*, so the override semantic must be pinned now or overlay authors build against an undefined target. Pinning it is one paragraph; discovering a mismatch at org #2 is a rewrite of an org's overlay.

**Override resolution semantic (mirrors the existing per-type dispatch at `tier-installer.sh` lines 37–47):**

| Overlay file type | Resolution against the core file it overrides |
|---|---|
| `*.json` config | **Deep-merge**, overlay wins on scalar conflict (then project/user wins over overlay) |
| `CLAUDE.md` / templates with managed markers | **Marker-region replace** under the org overlay marker (see #3) |
| Everything else (skills, agents, prompts, standards `*.md`) | **Whole-file replace** — these are documents; deep-merging prose is meaningless |

This is exactly the type-based branching the installer already does; the overlay resolver should extend that dispatch rather than invent a new model.

### Lint check is now load-bearing, not optional

The "no core file copied verbatim" lint the original lists as a later nicety is the *only* enforcement of the deltas-only contract that keeps `git pull` upstream conflict-free. Without it the contract is honor-system and will erode. It should ship with the mechanism (org #2), not after.
