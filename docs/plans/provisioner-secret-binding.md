# Provisioner secret-binding — plan

_Captured: 2026-07-22 · status: design, not built · plan only, no implementation_
_Contract: ADR-035 (bind-only Secrets Store) · depends on ADR-034 tenant.json (M3)_

## Problem

At deploy time the provisioner must wire a tenant's Cloudflare Secrets Store secrets
into the Worker/Pages runtime. Secrets are **bind-only** (verified 2026-07-22: the
get-secret API returns `id,name,scopes,status` — no `value` field), so the provisioner
never reads plaintext; it emits wrangler `[[secrets_store_secrets]]` bindings
referencing `store_id` + secret `name`. `tenant.json` carries names only; the
provisioner validates each name against the live store before binding.

## Assumptions

- One CF account + one Secrets Store per tenant (ADR-035 reference table:
  CarboNet `c5cbef…` / `cc2d18…`; lade `0345fe…` / `14145b…`).
- All tenant secret names follow the `<TENANT>_*` prefix convention.
- Deploy runs via Wrangler (locally from /publish, or from a Pipedream code step per
  `docs/plans/2026-07-21-cloudflare-deploy-via-pipedream.md`).
- UNCERTAIN: Pages Functions support for `[[secrets_store_secrets]]` in wrangler
  config (see Open questions #2). Workers support is confirmed.

## 1. Interface / contract

New sourced lib, matching `scripts/lib/tier-installer.sh` style (functions only,
callers own `set -uo pipefail`, jq for JSON, `log()`-style stderr messages):

`scripts/lib/secret-binder.sh`

    # Resolve the tenant's Secrets Store id from the account id.
    # NEVER accept a store id from config — ADR-035 gotcha: account id ≠ store id,
    # and a store id in the accounts/{id} slot returns a misleading 10000 auth
    # error, not a 404. Always resolve live via the list-stores API.
    #   resolve_store_id <account_id>            -> prints store_id | exit 1
    #
    # Preflight-validate that every expected name exists in the store.
    # Resolution name → id is a validation gate only — the wrangler binding
    # references the NAME; the id never enters the TOML.
    #   resolve_secret_names <account_id> <store_id> <name>...   -> exit 0 | exit 1,
    #     stderr lists every missing name (all misses reported, not first-fail)
    #
    # Emit the binding block to stdout (pure function, no API calls):
    #   emit_secret_bindings <store_id> <name>...  -> TOML on stdout
    #
    # Orchestrator (the only entrypoint deploy scripts call):
    #   bind_tenant_secrets <tenant_json_path> <wrangler_toml_path>  -> exit 0 | 1

Inputs (all sourced from M3-parsed `tenant.json` + env, see §4):
- tenant id (for the `<TENANT>_` prefix and error messages)
- CF account id
- secret name list (names only, per ADR-034/035)
- auth token via env `<TENANT>_API_TOKEN` (see §2 bootstrap)

Output — one block per secret, written into the project's wrangler config under a
managed marker region (same idempotent pattern as `append_stack_section` in
`scripts/lib/config-merger.sh`, TOML-comment markers):

    # STACK_SECRETS_MANAGED
    [[secrets_store_secrets]]
    binding = "CARBONET_API_TOKEN"
    store_id = "cc2d18ce6031458697161aa9b6e84a89"
    secret_name = "CARBONET_API_TOKEN"
    # /STACK_SECRETS_MANAGED

`binding` = `secret_name` = the tenant-prefixed name (one name, one identifier,
no aliasing — the Worker reads `env.CARBONET_API_TOKEN`). Bindings are not secret
(store id + names only) so the block is committed and reviewable.

Rejected alternative — ephemeral generated config (`wrangler -c wrangler.generated.toml`)
per deploy: keeps the repo clean but hides the runtime contract from review and
diverges local `wrangler dev` from deploy. Managed-marker block in the committed
config wins; rotation never touches it (binding is by name, ADR-035).

## 2. Name → id resolution flow + the bootstrap problem

Per deploy:

1. `GET /accounts/{account_id}/secrets_store/stores` → find the tenant's store id
   (expect exactly one; >1 stores = hard fail, ask the user).
2. `GET /accounts/{account_id}/secrets_store/stores/{store_id}/secrets` (paginated)
   → set of existing names.
3. Diff against tenant.json's name list. Any missing → exit 1 listing all misses.
   `status: pending` is NOT a failure (secrets show Pending until first bound).
4. Emit bindings, splice into wrangler config, hand off to `wrangler deploy`.

Auth: `Authorization: Bearer` header from env only — never in argv (same hygiene
rationale as cloud-bootstrap.sh's GIT_ASKPASS approach). Account-owned tokens
verify at `/accounts/{id}/tokens/verify`, not `/user/tokens/verify` (ADR-035).
Token needs the explicit `Secrets Store: Read` account permission — default
hosting scopes do not include it.

**Chicken-and-egg:** the API token used to call the list API is itself
`<TENANT>_API_TOKEN`, which lives in the store — and the store is bind-only, so the
provisioner can never fetch its own credential from it. Break: the store copy exists
for the *running Worker*; the *provisioner* holds a separately-saved copy captured at
secret-creation time (ADR-035: creator must save plaintext elsewhere before storing).
Resolution order:

1. env `<TENANT>_API_TOKEN` (cloud / Pipedream code step — Pipedream secret, not the
   Global API Key, per the Pipedream deploy note's blast-radius item)
2. macOS Keychain item, name taken from tenant.json's keychain secret-names map
   (ADR-034 field), via `security find-generic-password -s <name> -w` — same
   pattern as `apply_one_schema` in tier-installer.sh
3. neither → exit 1 with the exact `security add-generic-password` command to run
   (mirror the `[requirement-fail]` message style)

## 3. Deploy-path hook

- **Local:** `/publish` (and `/project-init`'s first deploy) calls
  `bind_tenant_secrets` immediately before `wrangler deploy` / `wrangler pages deploy`.
  secret-binder is a lib sourced by the deploy script, exactly as install.sh sources
  tier-installer.sh.
- **Cloud/engine:** the Pipedream Wrangler step (2026-07-21 plan, step 2) runs the
  same lib before invoking wrangler — one code path, two callers.
- **cloud-bootstrap.sh is NOT a caller.** It is session bootstrap, not deploy; it
  installs the stack into `~/.claude`. What we reuse from it is convention only:
  best-effort logging format, secrets-never-in-argv, retry-with-backoff on network
  calls. Deploys, unlike bootstrap, FAIL HARD — a deploy missing its secret bindings
  must not "continue without the stack."
- Because the managed block is committed, re-provision/redeploy is idempotent:
  re-run replaces the marker region, never appends a duplicate.

## 4. Dependency on M3 (pack mechanism)

Blocked on M3 (`schemas/tenant-pack-schema.json` + `scripts/lib/pack-installer.sh`,
per `.claude/next_prompt.md` step 3). M3 must provide, and the schema must require:

- `tenant.id` — canonical tenant slug → uppercased secret prefix (`carbonet` → `CARBONET_`)
- `deploy.cloudflare.account_id` — 32-hex CF account id (store id deliberately NOT
  a schema field — resolved live, per the ADR-035 gotcha)
- `deploy.cloudflare.secret_names[]` — exact store names, schema-validated against
  `^<TENANT>_[A-Z0-9_]+$`
- `secrets.keychain` map — local keychain item name for the tenant API token (ADR-034
  already scopes this field)
- a stable parse helper (or documented jq paths) so secret-binder reads tenant.json
  through one accessor, not ad-hoc jq scattered across scripts

If M3's field names land differently, secret-binder tracks M3 — this plan defines
the *data* required, M3 owns the *shape*.

## 5. Test plan — machine-checkable done

`tests/test-secret-binder.sh` (same harness style as `tests/test-config-merger.sh`;
mock the API by overriding the curl wrapper function / `CF_API_BASE` to serve fixtures):

- [ ] Fake tenant.json (2 secrets) + mocked list-stores + list-secrets → emitted
      TOML byte-identical to a golden `[[secrets_store_secrets]]` fixture.
- [ ] tenant.json name absent from mocked store → exit 1, stderr names EVERY
      missing secret (not just the first).
- [ ] `pending` status secret → treated as present (binds fine).
- [ ] Mocked `10000 Authentication error` → error message explicitly surfaces the
      account-id-vs-store-id gotcha, not a bare auth failure.
- [ ] Idempotency: `bind_tenant_secrets` twice against the same wrangler.toml →
      exactly one managed block, content unchanged.
- [ ] Pagination: mocked 2-page secret list → names from page 2 resolve.
- [ ] Token resolution order: env beats keychain; neither → exit 1 with the
      add-generic-password instruction.
- [ ] No-plaintext guard: grep of all captured stdout/stderr/TOML for a sentinel
      "secret value" planted in fixtures → zero hits.
- [ ] LIVE smoke (opt-in, `RUN_LIVE_CF_SMOKE=1`, needs `CARBONET_API_TOKEN` in env):
      resolve CarboNet store id from account `c5cbef…`, expect
      `cc2d18ce6031458697161aa9b6e84a89`; list resolves all 4 `CARBONET_*` names;
      read-only — creates/binds nothing.

## 6. Open questions / risks

1. **Bootstrap token source of truth per surface.** Local = keychain, Pipedream =
   Pipedream secret, Claude cloud = environment env var. Three copies of
   `<TENANT>_API_TOKEN` to keep in sync on rotation; no reconciler yet. Accepted
   for M-scale; revisit when the lade SaaS control plane exists.
2. **Wrangler / Pages support (UNVERIFIED).** `[[secrets_store_secrets]]`
   (`binding`/`store_id`/`secret_name`) is confirmed for Workers on current
   wrangler v4; Pages Functions wrangler-config support could not be confirmed
   (Pages config generally requires wrangler ≥3.45 + V2 build system, and new
   binding types land Workers-first). MUST spike before implementation: if Pages
   lacks the binding, the hosting decision moves to **Workers with static assets**
   — flag to the engine plan's open "Pages vs Workers" item rather than deciding
   here. Pin the minimum wrangler version in the requirements check
   (tier-installer `command` requirement pattern) once spiked.
3. **Secrets Store is beta-era.** API shapes (esp. pagination envelope) may drift;
   the curl wrapper isolates the API surface to one function.
4. **Store multiplicity.** Plan assumes one store per account; a second store makes
   "resolve the store" ambiguous. Hard-fail + ask is the chosen behavior.
5. **Lost plaintext.** Store values are unrecoverable; if a provisioner-side token
   copy is lost, the only path is roll-and-restore in all three surfaces. Runbook
   note belongs in the provisioner agent spec, not this lib.
