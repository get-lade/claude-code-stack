# ADR 034: Tenant pack contract — private core, repo-per-tenant packs

**Status:** Accepted
**Date:** 2026-07-21
**Author:** the maintainer + Claude
**Extends / partially supersedes:** ADR-013 (core/overlay model)

## Context

ADR-013 assumed the core stays **public** and organization overlays layer on top. Owner
decision (2026-07-21): the stack is now **private lade IP** (transferred to the
`get-lade` org), deployed as lade's dev-stack module to multiple tenants, with CarboNet
as customer #1. ADR-013's mechanics survive; its "public core" premise does not. The
overlay also needs a machine-readable identity so provisioning (`/project-init` →
GitHub + Neon/Supabase + Clerk + Cloudflare) can be tenant-aware.

## Decision

1. **Core is private.** `get-lade/claude-code-stack`, distributed to tenants via
   token-authenticated install (near-term `CLAUDE_STACK_REPO_TOKEN`; later a lade-hosted
   release endpoint). Anonymous clone paths are removed.
2. **Overlay is renamed "tenant pack", one private repo per tenant** (CarboNet pack #1 =
   the former `carbonet-vibe-coding-standards`). ADR-013's deltas-only contract and
   amended override semantics apply verbatim:
   - JSON config: deep-merge, **pack wins over core** on scalar conflict; project/user
     wins over pack (two conflict-winners, per ADR-013 amendment #1 — do not reuse
     `merge_json` target-wins defaults for pack-over-core).
   - `CLAUDE.md`: marker-region replace under `<!-- ORG_OVERLAY_MANAGED -->`, distinct
     from `<!-- CLAUDE_CODE_STACK_MANAGED -->` (amendment #3).
   - Skills / agents / standards `*.md`: whole-file replace.
   - The deltas-only lint ("no core file shipped verbatim") ships **with the pack
     installer now** — tenant #2 is the product plan, not a hypothetical.
3. **`tenant.json` manifest** at pack root, validated by `schemas/tenant-pack-schema.json`.
   It carries publishable identity + defaults only (GitHub org + merge policy, DB default
   `neon` + Supabase conditions, Clerk strategy + publishable key + org id, deploy default
   `cloudflare`, engine URL, design tokens path, standards map, CLAUDE fragment path,
   Gemini generator toggle, keychain secret *names*). **Secret values never live in a
   pack.**
4. **Consumption:** `install.sh --pack=<git-url|path>[@ref]` lands the pack at
   `~/.claude/packs/<tenant_id>/` and composes via `scripts/lib/pack-installer.sh`
   (extends the tier-installer type dispatch, pack-wins semantics).
   `~/.claude/stack-defaults.json` gains a `tenant_pack` reference. `/project-init`
   writes the tenant id into `stack-config.json`, assembles project `CLAUDE.md`
   (core section + pack fragment + project body), and **vendors the pack's
   `standards/` into the repo as committed files** — replacing the CarboNet-era
   symlink + 6h LaunchAgent sync pipeline, which is retired.
5. **Distribution to tenant repos** is the org reconciler (team-admin) delivering pack
   updates as PRs, keyed on pack version.

## Alternatives considered

- **Keep core public + private premium layer:** rejected — owner wants the stack itself
  as private product IP; split-brain licensing for one codebase.
- **Packs as directories inside the core repo (`tenants/<org>/`):** rejected — every
  tenant sees every other tenant's rules; tenant can't own/edit its pack repo.
- **Packs as control-plane DB rows:** right for the lade SaaS era; premature while
  delivery is git+installer. The `tenant.json` schema is the migration path.

## Consequences

- ADR-013's "public core" sections are superseded; its contract/amendments remain the
  normative override spec and are incorporated here by reference.
- Cloud bootstrap and org reconciler must carry a read-only token before the repo goes
  private (sequencing: token first, visibility flip second).
- `docs/handoffs/` and tenant-specific plans are internal-only and excluded from every
  distribution artifact.
- Multi-org reuse becomes the product mechanism: onboarding tenant #N = author pack repo
  + issue token + `install.sh --pack`.
