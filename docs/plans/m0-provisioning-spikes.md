# M0 provisioning spikes — Clerk / Neon / Pipedream create-API feasibility

_Written: 2026-07-22 · doc-only feasibility pass (no live smoke yet — see "Live smoke pending" per service)._

Goal: confirm whether `/project-init` auto-provisioning can create each backing
resource **programmatically**. Verdict per service, the exact endpoint, and the gate
that blocks a live smoke.

## Summary

| Service | Programmatic create? | Verdict | Blocker to live smoke |
|---------|----------------------|---------|-----------------------|
| **Neon** (Postgres, default DB) | Yes — `POST /api/v2/projects` | 🟢 GREEN | Just needs a Neon API key |
| **Clerk** (auth) | Only via **Platform API (beta, partner-gated)** — *not* the normal Backend API | 🟡 YELLOW | Partner/reseller access to Platform API |
| **Pipedream** (automation) | Not in REST API; project-create lives in the **Connect API** | 🟡 YELLOW | Confirm Connect API "Create project" + key |

---

## 1. Neon — 🟢 GREEN

- **Endpoint:** `POST https://console.neon.tech/api/v2/projects`
- **Auth:** Bearer API key. Org API keys infer `org_id`; personal keys must pass `org_id` explicitly.
- **Body:** a `project` object; may specify `region` and `pg_version` (14–18).
- **Response (201):** project details **+ a connection URI** (database, role, password) — exactly what the provisioner needs to hand the app a `DATABASE_URL`.
- **Limits:** plan defines max project count; generic API rate limiting applies (no per-endpoint number published).
- **Fit:** clean. One call → project + connection string. This is the model the other two should aspire to.
- **Live smoke pending:** a Neon API key. Then `POST /projects` with a throwaway name, assert 201 + a parseable connection URI, then delete.
- Docs: https://api-docs.neon.tech/reference/createproject

## 2. Clerk — 🟡 YELLOW (the real finding)

- **The normal Clerk Backend API operates *within* one application** (it manages users, orgs, sessions, JWT templates for an existing instance). It **cannot create a new application.**
- Creating a Clerk **application** requires the **Clerk Platform API** — described as a **beta partner/reseller surface** for "programmatically creating and managing Clerk applications, domains, application transfers." That is the correct tool, but:
  - It is **beta** and **access-gated** (partner/reseller), not open to any account.
  - Exact create endpoint + request body (name, plan) + whether the response returns the new app's **publishable + secret keys** could not be confirmed from public docs — the Platform API reference is gated/404 to anonymous fetch.
- There is also a **Clerk CLI** (`clerk api …`) that can reach Platform API endpoints (`clerk api ls` to enumerate) — useful for exploring once access exists.
- **Decision needed:**
  - a) **Pursue Platform API partner access** — cleanest end state (fully auto app-create + key retrieval), but depends on Clerk granting access + confirming the response returns keys.
  - b) **Fallback: manual app creation** in the Clerk dashboard per tenant, provisioner consumes the publishable/secret keys from the tenant's CF Secrets Store (fits ADR-035). Unblocks now; loses full automation of the auth step.
- **Live smoke pending:** Platform API access (for a) — until then, a is un-smokeable. b needs no smoke.
- Docs: https://clerk.com/docs/reference/platform-api · https://clerk.com/docs/cli

## 3. Pipedream — 🟡 YELLOW

- The **REST API does not create projects.** Its resource list is Apps, Components, Events, OAuth, Sources, Subscriptions, Users, Webhooks, Workflows, Workspaces — **no projects**. Workflows are created *inside* an existing project (`proj_…` id taken from the dashboard URL).
- Project creation is exposed by the **Connect API** ("Create project"), a separate surface. This aligns with the handoff's `pd-gateway-mcp` note — provision projects through Connect, not REST.
- **Auth:** Bearer; `org_id` required with User API keys (identifies workspace), not needed with OAuth tokens.
- **Live smoke pending:** confirm the Connect API "Create project" endpoint shape + a Pipedream key, then create a throwaway project and read back its `proj_` id.
- Docs: https://pipedream.com/docs/rest-api/ · Connect API (create project)

---

## What this means for `/project-init` provisioning

- **DB step is safe to build first** (Neon) — proven single-call create → connection URI.
- **Clerk is the sequencing risk.** If Platform API partner access is slow/denied, ship with the **manual-app fallback (2b)** and keep the auto-create path behind a feature flag until access lands. Do not block the whole provisioner on Clerk.
- **Pipedream uses Connect API, not REST** — point the integration at Connect from the start; the REST path is a dead end for project-create.

## Open decisions for the maintainer

1. Clerk: request Platform API partner access now (path a), or ship with manual-app fallback (path b) and revisit? (MCQ-worthy — affects how automated the auth step is at launch.)
2. Whether to run the three live smokes now (needs Neon + Pipedream keys; Clerk blocked on access) or defer until the provisioner skeleton exists.
