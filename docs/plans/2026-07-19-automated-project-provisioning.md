# Automated project provisioning for Claude Code apps (CarboNet)

**Date:** 2026-07-19
**Status:** Updated 2026-07-19 — owner decision: the provisioning engine is a **standalone
service**, NOT part of claude-code-stack. The stack stays a config layer and grows only thin
client skills (`/project-init` provisioning step, `/publish`, `/project-teardown`) that call
the engine's API. The engine itself — architecture, publish button, GlideOS migration, Laid
convergence — is planned in
`Architect-for-Claude-Code/docs/plans/2026-07-19-provisioning-engine-standalone.md`.
Sections below stand as the vendor-feasibility research and the stack-integration spec;
read "Worker" as the standalone engine.
**Problem:** Every new CarboNet project scaffolded with the stack still requires manual setup
of the GitHub repo, Clerk application + org, Supabase project, and Netlify site — all done by
one person, by hand. Goal: `/project-init` (or a sibling skill) provisions all of it
automatically so users can create Claude Code apps end-to-end without an operator.

**Relationship to Laid:** this is the same provisioning orchestrator Laid needs (see
`Architect-for-Claude-Code/docs/plans/2026-07-19-laid-company-infrastructure-migration.md` §3),
scoped down to internal CarboNet use. Build it once, shape it as the shared core; CarboNet is
customer #1.

---

## 1. What's automatable (per vendor)

| Resource | API support | Notes |
|---|---|---|
| GitHub repo | ✅ Full | Org-owned **GitHub App** creates repo **from a template repo** that has the stack scaffolding (`.claude/`, docs/, CI) pre-baked — replaces the copy-paste half of project-init too |
| Supabase project | ✅ Full | Management API `POST /v1/projects` with an org access token; returns keys + connection string |
| Neon project | ✅ Full | Neon API; same provisioner shape as Laid ADR-028 (`DataStoreProvisioner` port) |
| Cloudflare (Workers/Pages) | ✅ Full | API creates the project + binds the GitHub repo for CI deploys; per-project env vars/secrets via API |
| Netlify site | ✅ Full | API creates site + links repo — works, but new projects should target Cloudflare (below) |
| Clerk application | ⚠️ **Verify** | User/org/instance-settings management is fully API'd, but *creating a new Clerk application* has historically been dashboard-only. **This is the one spike item.** Mitigations in §4. |

## 2. Architecture — two options

### Option A: stack-native scripts (runs on the user's machine)
A `provision` skill + `scripts/provision/` that call vendor APIs directly, with org tokens
pulled from Keychain/1Password on the developer's box.

- ✅ No new infrastructure; shippable in days.
- ❌ Every user who can provision holds **org-level tokens** (GitHub App key or org PAT,
  Supabase org token, Clerk secret, Cloudflare account token) on a personal machine. That
  recreates, per user, exactly the personal-equipment problem the Laid migration is
  eliminating. Token rotation and revocation become per-laptop chores.

### Option B (recommended): a CarboNet **provisioning Worker**
A small Cloudflare Worker owned by the CarboNet account holds the org tokens as Worker
secrets and exposes one authenticated endpoint:

```
POST /provision   { projectName, db: "supabase" | "neon", deploy: "cloudflare", options… }
→ { repoUrl, dbRef + keys, clerkKeys, deployUrl, state }
```

- Users authenticate to the Worker via **Cloudflare Access** (CarboNet Google/IdP identity) —
  no vendor tokens ever leave the Worker.
- Idempotent state machine per project (`repo → db → auth → deploy`), with compensating
  teardown (`DELETE /provision/:project`) so abandoned experiments don't leave orphaned
  Supabase projects billing forever.
- Audit log of who provisioned what, when — free SOC 2 evidence later.
- It **is** the embryo of the Laid orchestrator: same ports (`RepoProvisioner`,
  `DataStoreProvisioner`, `AuthProvisioner`, `Publisher`), different tenant policy. Extract as
  a shared package when Laid's control plane lands.

The stack side stays thin either way: a skill collects the answers, calls the backend
(script or Worker), and writes the results into the project. **Define the skill contract
now; Option B is the backend.** Only fall back to Option A if the Worker is somehow blocked.

## 3. User flow

1. User runs `/project-init` in an empty directory (or the skill offers provisioning when it
   detects no repo during the existing discovery pass).
2. New step after tier/domain questions: *"Provision infrastructure? (repo / db / auth /
   deploy)"* — collects app name, DB choice (defaulted by the rule in §5), deploy target
   (default Cloudflare).
3. Skill calls the provisioning Worker; streams state transitions to the terminal.
4. On success the skill:
   - clones the freshly created repo (from the stack template) into place,
   - writes refs into `.claude/stack-config.json` (new `infra` block: repo, dbProvider,
     dbRef, clerkAppId, deployTarget, provisionedAt),
   - writes local `.env` for dev; per-project secrets go to GitHub repo secrets + the deploy
     target's env via the Worker — never committed,
   - fills the CLAUDE.md "Operational facts" section (infra access, deploy command) that is
     currently left as placeholders in every project,
   - prints the ONBOARDING summary with URLs.
5. `/project-teardown` (new, small) calls the Worker's delete path with a confirmation gate.

## 4. The Clerk question (spike, ~1 day)

Verify whether Clerk now exposes application creation via API. Outcomes:

- **Yes** → Worker creates the app, enables organizations, creates the CarboNet org, returns
  publishable/secret keys. Done.
- **No** → two workable fallbacks:
  1. **Pool pattern:** pre-create N Clerk applications in the dashboard (10 min/quarter);
     the Worker assigns one from the pool per project and configures it fully via the
     existing Backend API (org creation, instance settings, redirect URLs are all API'd).
  2. **One shared Clerk application** for all internal CarboNet apps, with a Clerk
     **Organization per project** and per-app allowed-origins added via API. Fewer moving
     parts; acceptable for internal tools, wrong for anything external-facing.

Pool pattern is the better default if app creation isn't API'd — keeps per-app isolation.

## 5. Supabase vs Neon inside CarboNet

No reason to force one. Since **Clerk owns auth**, Supabase's differentiators here are
storage, realtime, and edge functions (which the stack's `/deploy-edge` skill already
targets). Proposed decision rule, encoded as the skill's default:

- App needs **storage / realtime / edge functions** → Supabase project.
- App is **plain Postgres + API/UI** → Neon (scale-to-zero for idle internal tools, CoW
  branches for preview envs, cheaper fleet economics).

Both live behind the same `DataStoreProvisioner` port, so the choice is a flag, not an
architecture.

## 6. Prerequisites (mostly org hygiene, mirrors the Laid Phase 1 list)

- CarboNet-owned org accounts: GitHub org (+ GitHub App + template repo), Supabase org,
  Neon org, Clerk, Cloudflare account. Tokens minted org-level, stored **only** as Worker
  secrets.
- A stack **template repo** in the CarboNet GitHub org containing the current tier
  scaffolding — this also simplifies `/project-init` for the non-provisioned path.
- Cloudflare Access policy: which CarboNet users may hit `/provision`.

## 7. Sequencing

| Step | What | Effort |
|---|---|---|
| 1 | Clerk API spike (§4) + create org accounts + template repo | ~2–3 days |
| 2 | Worker v1: repo + Supabase + Cloudflare deploy, idempotent + teardown | ~1 wk |
| 3 | Stack skill: provisioning step in `/project-init`, `infra` block in stack-config schema, `/project-teardown` | ~2–3 days |
| 4 | Add Neon provider + Clerk (API or pool) | ~2–3 days |
| 5 | Later: extract shared orchestrator core for Laid | when Laid control plane lands |

## 8. Decisions needing an owner call

1. **Option B (provisioning Worker) over stack-local scripts** — recommended.
2. **Default deploy target for new CarboNet apps: Cloudflare** (Netlify remains supported for
   existing sites) — recommended; also feeds the Laid Workers-for-Platforms spike with real usage.
3. **Clerk fallback if app-creation isn't API'd:** pool pattern vs shared-app-per-org.
4. **Where the Worker code lives:** new small repo in the CarboNet org (recommended) vs a
   package inside claude-code-stack (stack stays a config layer — leans no).
