# ADR 035: Tenant deploy secrets live in Cloudflare Secrets Store

**Status:** Accepted
**Date:** 2026-07-22
**Author:** the maintainer + Claude
**Relates to:** ADR-034 (tenant pack contract — "secret values never live in a pack")

## Context

ADR-034 fixed the tenant-pack contract but deliberately left secret *values* out of it:
packs carry only secret *names*. That left an open question the provisioning engine
(`/project-init` → GitHub + Neon/Supabase + Clerk + Cloudflare) must answer: **where do
per-tenant deployment secrets actually live**, such that the provisioner can read them at
deploy time and each tenant stays isolated.

The stack's stated direction is to **migrate all infrastructure to Cloudflare** (hosting via
Pages/Workers, R2 for storage). Options weighed:

1. **Per-tenant private repo** — secrets in each pack repo's `.env.local` / GitHub secrets.
   Simple, isolated, but scatters secrets across N repos and couples secret storage to git.
2. **Third-party vault** (Doppler / 1Password) — strong CLI+API, built for this, but adds a
   vendor outside the Cloudflare consolidation and another bill/integration to own.
3. **Cloudflare Secrets Store** — account-scoped encrypted secret store, native binding to
   Workers/Pages runtime, readable via the same CF API token family the provisioner already
   holds. Consistent with the all-in-on-Cloudflare plan.

## Decision

1. **Cloudflare Secrets Store is the home for tenant deploy secrets.** One CF account per
   tenant (CarboNet, lade, …); each account's Secrets Store holds that tenant's secrets,
   account-scoped and encrypted at rest. No tenant secrets in pack repos, in
   `claude-code-stack`, or in a third-party vault.
2. **`claude-code-stack` (the private lade core repo) holds only lade's own keys** — never a
   client's. Client keys live exclusively in that client's CF account.
3. **Naming convention: every secret name is prefixed with the tenant/company name.**
   `CARBONET_API_TOKEN`, `CARBONET_ACCESS_KEY_ID`, `CARBONET_SECRET_ACCESS_KEY`,
   `CARBONET_S3_API_ENDPOINT`; lade uses `LADE_*`. Rationale: as many tenants' secrets flow
   through one provisioner read scope (or a merged `.env`), bare names like `API_TOKEN`
   collide; the prefix keeps them unambiguous at scale.
4. **Scope = Workers. Secrets are bind-only, never read back.** Secrets Store's only consumer
   is the Workers runtime (which backs Pages Functions). **Verified 2026-07-22** against the
   live CF API: `GET .../secrets_store/stores/{store}/secrets/{id}` returns metadata only
   (`id`, `name`, `scopes`, `status`) — **there is no `value` field**. Plaintext cannot be
   read out. The provisioner therefore **binds** named secrets into the Worker/Pages deploy
   (wrangler `[[secrets_store_secrets]]`, referencing `store_id` + secret `name`); the running
   Worker reads them as `env.<NAME>`. No deploy step, script, or model ever reads plaintext.
5. **Pack manifest still carries names only.** `tenant.json` (ADR-034) references the CF
   secret *names* it expects; the provisioner resolves each name → secret `id` via the list
   API and writes the wrangler binding at deploy time. Values never enter a pack, a commit,
   Claude's context, or a deploy log.
6. **R2 keys are optional per tenant.** `ACCESS_KEY_ID` / `SECRET_ACCESS_KEY` /
   `S3_API_ENDPOINT` are stored only for tenants whose app uses R2 object storage. Tenants
   with no file storage store only `*_API_TOKEN`.

## Consequences

- Secret storage is consistent with the Cloudflare migration — one system, one API token
  family, native runtime binding.
- Isolation is per CF account: a leaked or rotated tenant token blasts only that tenant.
- **Provisioner work (follow-up):** at deploy, resolve each `tenant.json` secret name → id
  via the list API, then emit the wrangler `[[secrets_store_secrets]]` bindings for the
  Worker/Pages project. The `tenant.json` name list is the contract. Rotation = update the
  value in the store; the binding (by name) is unchanged, so no code or pack change.
- **Provisioner token needs the `Secrets Store` account permission** (Read to list/resolve;
  Write if it creates secrets). The default hosting token scopes (Pages/Workers/DNS) do
  **not** include it — add explicitly. Account-owned tokens verify at
  `/accounts/{id}/tokens/verify`, not `/user/tokens/verify`.
- **Values are unrecoverable once stored.** The store masks them and the API won't return
  them — so whoever creates a secret must save the plaintext elsewhere (or plan to roll it)
  *before* it goes in. Losing the only copy = roll a new one.
- **Isolation** is per CF account: a leaked or rotated tenant token blasts only that tenant.
- **Trade-off accepted:** Cloudflare Secrets Store is newer than Doppler/1Password and
  account-scoped rather than org-federated. Acceptable given the all-in-on-Cloudflare plan;
  revisit if a cross-account federated view becomes necessary.
- Secrets show **Pending** until first bound to a Worker, then **Active** — expected.

## Reference — live account facts (2026-07-22)

| Tenant   | CF account id                      | Secrets Store id                     |
|----------|------------------------------------|--------------------------------------|
| CarboNet | `c0000000000000000000000000000001` | `c0000000000000000000000000000002` (`default_secrets_store`) |
| lade     | `1ade0000000000000000000000000001` | `1ade0000000000000000000000000002`   |

Each tenant store holds `<TENANT>_API_TOKEN`, `<TENANT>_ACCESS_KEY_ID`,
`<TENANT>_SECRET_ACCESS_KEY`, `<TENANT>_S3_API_ENDPOINT`, all Workers-scoped, Active.

**Watch out — account id ≠ store id.** They are distinct 32-hex strings. The token
summary screen shows the token's account id ("Entire `<id>` account"); the Secrets Store
page shows the store id. Pointing an API call at the store id in the `accounts/{id}` slot
returns a misleading `10000 Authentication error` (not a 404), even with a valid,
correctly-scoped token. Resolve the store id per account via the list-stores API rather
than assuming it.
