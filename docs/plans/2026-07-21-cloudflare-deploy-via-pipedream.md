# Cloudflare deploy via Pipedream + Wrangler (M5 provisioning note)

_Captured: 2026-07-21 · status: design note, not yet built_

## Context

Cloudflare is one of the provisioned hosting targets (ADR-034). Provisioning runs
through **Pipedream** — already lade's workflow engine (`lade.workflows`), so
Cloudflare connects there as a standard connected account.

Pipedream's Cloudflare actions cover the account **plumbing** but not the site
**deploy**:

- ✅ Pipedream (`cloudflare_api_key-*`): create zone, DNS records, KV namespace,
  SSL/certs, cache purge.
- ❌ No "deploy Pages/Workers site" action — the actual publish needs **Wrangler**
  or the direct Cloudflare deploy API.

## Decision

Keep everything inside the Pipedream engine: the deploy step is **Wrangler invoked
from a Pipedream workflow**, not a separate CI system.

Flow (per tenant provision):

1. Pipedream workflow creates the zone + DNS + KV via existing `cloudflare_api_key-*`
   actions.
2. Same workflow runs a **Wrangler deploy** (Pages or Workers) in a code/exec step,
   authed with a **scoped deploy token** (not the Global API Key).
3. Post-deploy: DNS/SSL finalization via the existing Cloudflare actions.

## Open items

- **Pages vs Workers vs Workers-with-static-assets** — hosting product lives in the
  provisioning **engine** plan (`Architect-for-Claude-Code` repo), not the stack.
  Decides the exact Wrangler command.
- **Blast radius** — Pipedream's Cloudflare connection uses the **Global API Key**
  (full account access). Fine for the lade-infra account; for a **tenant** account
  (e.g. CarboNet) prefer a scoped token for the deploy step to wall off the tenant.

## Account model (agreed 2026-07-21)

Account-per-tenant: separate Cloudflare account for lade-infra vs CarboNet tenant —
isolated billing, blast radius, and token scope. Both need **Workers Paid ($5/mo)**
(provisioning creates KV + Workers), one Free-plan zone each.
