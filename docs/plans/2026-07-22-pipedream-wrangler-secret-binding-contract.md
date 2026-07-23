# Pipedream Wrangler step — secret-binding contract (for the engine repo)

_Captured: 2026-07-22 · status: contract, not built · target repo: `Architect-for-Claude-Code` (engine)_
_Depends on: ADR-035 (bind-only Secrets Store), ADR-036 (distribution model),
`docs/plans/2026-07-21-cloudflare-deploy-via-pipedream.md`, `scripts/lib/secret-binder.sh`_

## Purpose

This is a contract doc, not an implementation. The Wrangler deploy step
described in `docs/plans/2026-07-21-cloudflare-deploy-via-pipedream.md`
("same workflow runs a Wrangler deploy … authed with a scoped deploy token")
lives in the **engine** repo, not here. This doc specifies exactly what that
step must do so provisioning-time deploys get the same secret-binding
guarantee as the local `/publish` path (`scripts/publish.sh`, this repo,
next-step #2). The engine implements it; this doc is the spec + review
checklist.

`scripts/publish.sh` is the reference implementation for the *shape* of the
call sequence. The Pipedream step is a different runtime (a Pipedream
code/exec step, not a laptop bash session) and must NOT literally invoke
`publish.sh` — see "Where the lib comes from" below.

## 1. The exact call, in order

Inside the Pipedream Wrangler code/exec step:

```
bind_tenant_secrets <tenant_json_path> <wrangler_toml_path>   # must succeed
wrangler deploy                                                # only if bind succeeded
```

`bind_tenant_secrets` is the single entrypoint in `scripts/lib/secret-binder.sh`
(this repo, ADR-035) — see that file, function starting at line 212. Do not
reimplement store-id resolution, secret-name preflight, or TOML splicing in
the engine; source or shell out to the lib itself (see §4).

## 2. Arg resolution — where the two paths come from

- **`tenant_json_path`** — a tenant.json-shaped file (schema:
  `schemas/tenant-pack-schema.json`, this repo) written to disk for the
  duration of the step. On a laptop this is the M3-landed
  `~/.claude/packs/<tenant_id>/tenant.json`; the engine has no such local
  landing directory. The engine must materialize the equivalent from its own
  tenant record (DB row / pack repo checkout it already holds for this
  provision) into a temp file before calling `bind_tenant_secrets`, matching
  the schema's required shape: `.tenant_id`, `.deploy.cloudflare.account_id`,
  `.deploy.cloudflare.api_token_keychain_item` (irrelevant in this surface —
  see §3), `.secrets[]`.
- **`wrangler_toml_path`** — the repo-root `wrangler.toml` of the tenant app
  repo checkout the same Pipedream workflow already has present for the
  deploy step (per the 2026-07-21 plan: zone/DNS/KV creation → Wrangler
  deploy, same workflow). `bind_tenant_secrets` creates the file if it's
  absent and splices/replaces only the `# STACK_SECRETS_MANAGED` region — it
  does not touch the rest of the file.

Neither path is ever free-typed or inferred from a workflow-step input string
the way a human could fat-finger — both are derived from the tenant record
and the checked-out repo the workflow already owns for this run.

## 3. Token source on this surface

`resolve_tenant_token` in `secret-binder.sh` checks env `<TENANT>_API_TOKEN`
first, then macOS Keychain. **Keychain does not exist on a Pipedream
execution surface** — the engine step must export `<TENANT>_API_TOKEN`
(uppercased tenant id + `_API_TOKEN`, ADR-035 §3 naming convention) from a
Pipedream secret before sourcing the lib, and must NOT use the account's
Global API Key (blast-radius note in the 2026-07-21 plan — use a scoped
token with the explicit `Secrets Store: Read` account permission, ADR-035).

## 4. Where the lib comes from (ADR-036 module placement)

`scripts/lib/secret-binder.sh` is stack **session tooling**
(ADR-036 §"Module placement rule" — category (b)), not an engine service.
The engine's Pipedream exec step is lade-operated infrastructure, so it is
allowed to hold a copy of the lib — but the lib must reach it the same way
the rest of the stack reaches lade-operated surfaces: a pinned checkout or
vendored copy of `claude-code-stack` at a known ref, fetched into the
Pipedream step's execution environment (or vendored into the engine's deploy
container image at build time). **It must never be copied into, or shipped
as part of, a client/tenant app repo** — clients receive only the deployed
app bundle (ADR-036 §1), never stack lib code.

## 5. Same-process rule — the load-bearing constraint

`bind_tenant_secrets` and `wrangler deploy` **must execute in the same shell
process / same Pipedream step**, with the step configured to fail on a
non-zero exit (no "continue on error"). This is the whole point of the
contract: a bind failure must hard-abort the deploy, not just log a warning
that a later, independently-scheduled step ignores.

Concretely, in the Pipedream code step:

```bash
set -euo pipefail
source /path/to/vendored/secret-binder.sh
bind_tenant_secrets "$TENANT_JSON" "$WRANGLER_TOML"   # set -e aborts here on failure
wrangler deploy
```

Do **not** split this into two Pipedream steps ("bind" then "deploy"). Two
steps means Pipedream's per-step continue-on-error UI toggle (or a future
workflow edit that flips it) can silently let the deploy step run after a
failed bind step — the exact failure mode ADR-035/the local `/publish` path
were built to prevent. One step, one process, `set -e`, mirrors
`scripts/publish.sh`'s design (this repo) exactly.

## 6. Review checklist for the engine PR that implements this

- [ ] `bind_tenant_secrets` and `wrangler deploy` are in the same Pipedream
      step / same process — verified by reading the step config, not just
      the code (a "continue on error" toggle can defeat correct code).
- [ ] The step token source is a scoped deploy token with `Secrets Store:
      Read`, not the account's Global API Key.
- [ ] `tenant_json_path` is materialized from the engine's own tenant record,
      never accepts a workflow-input string as a path or tenant id.
- [ ] `secret-binder.sh` is vendored/pinned into the engine's execution
      surface — not present in any client-visible repo or bundle.
- [ ] A missing-secret test (mirror `tests/test-publish-ordering.sh`'s case
      2 in this repo) proves the deploy step never runs when the bind fails.
- [ ] `unset <TENANT>_API_TOKEN` (and `CF_API_TOKEN`, the in-process variable
      `resolve_tenant_token` sets) immediately after `bind_tenant_secrets`
      returns and BEFORE `wrangler deploy` runs. `wrangler deploy` can shell
      out to a tenant-controlled build command (e.g. a `build` script in the
      deployed repo); if the CF token is still exported when that subprocess
      runs, tenant-controlled code can read it out of its own environment.
      The bind step needs the token; the deploy step does not.
- [ ] The `<TENANT>_API_TOKEN` value itself is operator/lade-held — sourced
      from a Pipedream secret the engine's own team configured, never
      derived from a tenant record, a pack file, or any workflow input. A
      tenant can influence *which* secrets get bound (by name, via
      tenant.json) but must never be able to influence *which credential*
      the binder authenticates with to do the binding.
