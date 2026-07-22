# M3 plan — tenant-pack mechanism (schema, installer, lint)

**Date:** 2026-07-22
**Normative refs:** ADR-034 (contract), ADR-013 + amendments (override semantics), ADR-035 (secrets = names only)
**Scope:** `schemas/tenant-pack-schema.json`, `scripts/lib/pack-installer.sh`, `install.sh --pack`, deltas-only lint, tests. Plan only — no implementation here.

## Context

Core (`get-lade/claude-code-stack`) is private; each tenant gets a private pack repo
(CarboNet #1 = `carbonet-vibe-coding-standards`). M3 builds the consumption path:
`install.sh --pack=<git-url|path>[@ref]` lands the pack at `~/.claude/packs/<tenant_id>/`
and composes it over the installed core with **pack-wins** semantics. The deltas-only
lint ships with the installer (ADR-013 amendment: lint is load-bearing, not optional).

## Assumptions

- "Project/user wins over pack" refers to the ADR-013 precedence chain
  `built-in < core < global defaults < tenant pack < project`. The **project layer
  (`.claude/stack-config.json`) is resolved at read time**, never merged at install
  time — so the installer only implements `core < pack`. Global `~/.claude` files
  (incl. `stack-defaults.json`) sit *below* the pack in the chain, so pack legitimately
  overwrites them. (UNCERTAIN edge: user hand-edits to global JSON lose to pack — see
  Open questions #2.)
- `/project-init` tenant-awareness (write `tenant_id` into stack-config, assemble
  project CLAUDE.md, vendor `standards/`) is a follow-on task; M3 delivers only the
  schema fields it will consume plus the `stack-config-schema.json` `tenant_id` field.
- Pack payload uses a **convention layout** (see §2), not a tier-manifest-style
  declared files map. Alternative considered below.

## Approaches for the pack-over-core merge (the sharp edge)

**A (recommended) — order-based pack-wins:** core tiers install first (existing
`merge_json`, target/user-wins, unchanged); then the pack applies with a new
`merge_json_pack_wins` where the pack value wins every scalar conflict,
non-interactively, and every overwritten path is logged to a `<target>.pack-overrides`
report. Simple, deterministic, idempotent; matches ADR-034 §2 verbatim.
Tradeoff: a hand-edit a user made directly to a global `~/.claude` JSON file is
overwritten by the pack (visible in the report, recoverable from the step-1 backup).

**B — three-way provenance merge:** treat the core source file as merge base; if
installed value == core value → pack wins (it was a core default); if installed value
differs from core → keep installed (a true user edit). Preserves hand-edits but adds a
third input to every merge, needs the pristine core file path plumbed through, and
invents provenance semantics no ADR specifies. Rejected for M3 (KISS; contract places
global files below the pack anyway). Recorded so tenant #2 doesn't relitigate blind.

## 1. `schemas/tenant-pack-schema.json`

Draft-07, `$id` under the repo `schemas/` path, `additionalProperties: false`
throughout, `description` on every field — same style as `stack-config-schema.json`.
Validates `tenant.json` at the pack root (ADR-034 §3).

| Field | Type | Req | Consumed by |
|---|---|---|---|
| `tenant_id` | string, `^[a-z][a-z0-9-]{1,62}$` | **yes** | install.sh (landing dir `~/.claude/packs/<tenant_id>/`), `/project-init` (writes into stack-config), reconciler |
| `pack_version` | string, `^\d+\.\d+\.\d+$` | **yes** | reconciler PR keying (ADR-034 §5), install stamps |
| `display_name` | string | no | banners, provisioner |
| `github` | object | **yes** | provisioner repo creation |
| `github.org` | string | **yes** | provisioner (`gh` org target) |
| `github.merge_policy` | enum `squash\|merge\|rebase`, default `squash` | no | provisioner branch-protection setup |
| `database` | object | no | `/database-design`, provisioner |
| `database.default` | enum `neon\|supabase`, default `neon` | no | provisioner DB choice |
| `database.supabase_conditions` | string (prose: when Supabase applies instead) | no | `/database-design` decision prompt |
| `clerk` | object | no | provisioner auth, `/clerk-auth` |
| `clerk.strategy` | string | no | `/clerk-auth` |
| `clerk.publishable_key` | string, `^pk_(test\|live)_` | no | provisioner env wiring (publishable — allowed in pack) |
| `clerk.org_id` | string | no | provisioner |
| `deploy` | object | no | provisioner |
| `deploy.default` | enum `["cloudflare"]`, default `cloudflare` | no | provisioner deploy target (single-value enum on purpose — widen when a second target exists) |
| `engine_url` | string, format uri | no | recommend-capabilities engine hooks |
| `design_tokens_path` | string (pack-relative) | no | `/screenshot-diff`, UI skills, `/project-init` vendoring |
| `standards` | object, map name → pack-relative path | no | `/project-init` vendors into repo as committed files (ADR-034 §4) |
| `claude_fragment_path` | string, default `CLAUDE.fragment.md` | no | pack-installer (global CLAUDE.md org region) + `/project-init` (project CLAUDE.md assembly) |
| `gemini_generator` | boolean, default `false` | no | toggles the Gemini-powered generator skill |
| `secrets` | array of string, items `^[A-Z][A-Z0-9_]*$`, uniqueItems | no | provisioner → CF Secrets Store name→id resolution + wrangler bindings (ADR-035 §5). **Names only, never values.** |

Required: `tenant_id`, `pack_version`, `github` (with `github.org`).

Companion change: `stack-config-schema.json` gains optional
`"tenant_id": { "type": "string" }` (written by `/project-init`);
`stack-defaults-schema.json` gains `tenant_pack` (see §3).

### Pack payload convention layout

```
tenant.json               # manifest (validated)
CLAUDE.fragment.md        # → ORG_OVERLAY_MANAGED region
config/**/*.json          # → merged pack-wins into ~/.claude/<same relpath under config/ → ~/.claude/>
skills/**, agents/*.md,
commands/*.md             # → whole-file replace/add under ~/.claude/<same relpath>
standards/*.md            # NOT installed globally — vendored per-repo by /project-init
design/                   # referenced via design_tokens_path
```

Alternative (rejected): tier-manifest-style `files` map inside `tenant.json`. More
flexible, but every pack author must maintain a manifest and the lint can't infer
path correspondence. Convention keeps authoring trivial; revisit only if a pack needs
a non-standard destination.

## 2. `scripts/lib/pack-installer.sh`

Sourced by install.sh (same pattern as `tier-installer.sh`). Entry point:

```
install_pack <pack_dir> <claude_dir> <core_repo_root>
```

**Phase 0 — validate, then apply (fail closed, zero writes on failure):**
1. `tenant.json` exists, parses, required fields present + pattern-valid (jq checks;
   the full JSON-schema is normative documentation + pack-repo CI, no new runtime dep
   — Working Principle 8).
2. `lint_pack_deltas "$pack_dir" "$core_repo_root"` (§4) — violation aborts install.
3. `secrets` sanity: abort if any pack file matches known secret-VALUE shapes
   (`sk_live_`, `sk-ant-`, `AKIA[0-9A-Z]{16}`, PEM headers). Cheap grep; enforces
   ADR-034 "secret values never in a pack" mechanically.

**Phase 1 — compose, type-dispatched (extends the tier-installer lines 37–47 dispatch):**

| Pack file | Action |
|---|---|
| `config/**/*.json` | `merge_json_pack_wins <pack_file> <installed_file>` (new fn in `config-merger.sh`; if target absent → plain copy) |
| `CLAUDE.fragment.md` | `apply_org_overlay_section <fragment> <claude_dir>/CLAUDE.md` |
| everything else `.md` (skills/agents/commands) | `cp` — whole-file replace/add |
| `standards/`, `design/`, `tenant.json` | skipped at install time (consumed by `/project-init` / provisioner from `~/.claude/packs/<tenant_id>/`) |

**`merge_json_pack_wins` — how it inverts `merge_json`:**
- New function beside `merge_json`; `merge_json` itself is NOT modified (core tier
  installs keep target/user-wins).
- Reuses the same jq `deep_merge` shape, but with **operand roles swapped at the
  scalar leaf**: objects deep-merged, arrays concatenated + order-stable deduped
  (same hook-group collapse applies), and on a scalar conflict the **pack (source)
  value is kept** — i.e. the `else $a end` branch resolves to the pack side. Do not
  "just call `merge_json` with swapped args": that would also invert the array/hook
  regroup targeting and the conflict-report semantics. It is a sibling function with
  its own header comment stating the two-conflict-winner rule and citing ADR-013
  amendment #1 / ADR-034 §2.
- Always non-interactive. Every scalar path whose pre-existing value was overwritten
  is written to `<target>.pack-overrides` (path, previous, pack) — the audit trail
  replacing `merge_json`'s prompt.

**`apply_org_overlay_section`:** clone of `append_stack_section` with markers
`<!-- ORG_OVERLAY_MANAGED -->` / `<!-- /ORG_OVERLAY_MANAGED -->` (ADR-013 amendment
#3). Replace-in-place if the region exists, else append at EOF — the core
`CLAUDE_CODE_STACK_MANAGED` region is never touched, both regions coexist and stay
independently re-writable. Marker strings taken as parameters or constants — do not
generalize `append_stack_section` itself beyond parameterizing the marker pair.

**Where packs land:** `~/.claude/packs/<tenant_id>/` is the durable local copy
(with `.git/` retained for future ref updates). Composition always reads from there.

**Idempotency:** re-running `install_pack` converges — marker-region replace is
idempotent, whole-file cp is idempotent, `merge_json_pack_wins` re-applied over its
own output is a no-op. Stamp written on success:
`~/.claude/packs/<tenant_id>/.pack-install.json`
`{tenant_id, pack_version, source, ref, sha, installed_at}`.

**Rollback:** install.sh step 1 (`backup.sh`) already snapshots `~/.claude` before
any mutation; the pack step runs after that backup. Phase-0 failure = zero writes.
Mid-compose failure = restore the step-1 backup (installer prints the exact restore
path on failure). No bespoke undo machinery (YAGNI — uninstall is out of M3 scope).

## 3. `install.sh --pack` integration

1. **Flag parse** (existing `for arg` loop): `--pack=*` → `PACK_SPEC`. Optional; no
   flag = current behavior byte-for-byte. `--pack` requires `--tier` (pack composes
   over an installed core).
2. **Resolve source** (`resolve_pack_source` in pack-installer.sh):
   - Existing directory → local path mode (used by tests/fixtures; no clone).
   - Else git mode. `@ref` split from the **right**, only when the suffix contains no
     `/` and, for scp-style `git@host:org/repo.git@v1`, at least one `@` remains in
     the URL part. Ref must match `^[A-Za-z0-9._-]+$`.
   - Auth: `CLAUDE_STACK_PACK_TOKEN`, falling back to `CLAUDE_STACK_REPO_TOKEN`
     (ADR-034 §1). `GIT_TERMINAL_PROMPT=0`; token passed via
     `http.extraheader`, never interpolated into a logged URL.
3. **Land:** clone (`--depth 1`, `--branch <ref>` when ref given) into `mktemp -d`;
   read + validate `tenant_id` from `tenant.json`; `rsync -a --delete` into
   `~/.claude/packs/<tenant_id>/`. Reading tenant_id BEFORE landing is what makes the
   landing path trustworthy.
4. **New step** between tier install and verify (renumber 5 steps → 6):
   `[3/6] Installing tenant pack…` → `install_pack`.
5. **`stack-defaults.json` update** (jq, after successful compose):
   ```json
   "tenant_pack": {
     "tenant_id": "carbonet",
     "source": "git@github.com:get-lade/carbonet-vibe-coding-standards.git",
     "ref": "v1.2.0",
     "pack_version": "1.2.0",
     "path": "~/.claude/packs/carbonet",
     "installed_at": "2026-07-22T00:00:00Z"
   }
   ```
   Schema addition to `stack-defaults-schema.json`: `tenant_pack` object,
   required `["tenant_id", "path"]`, `additionalProperties: false`.
6. **Install stamp:** `.stack-install.json` gains `tenant_id` + `pack_version`
   (freshness checks in `/goodmorning`, `/project-init` can then detect a stale pack).

## 4. Deltas-only lint

`scripts/lib/pack-lint.sh`, function `lint_pack_deltas <pack_dir> <core_repo_root>`,
plus a thin standalone wrapper `scripts/pack-lint.sh` for pack-repo CI.

- **Core corpus:** `git -C core ls-files`, excluding `docs/`, `tests/`, `.github/`
  (only distributable content counts — skills, agents, hooks, templates, config,
  schemas, scripts).
- **Hash-set comparison** (rename-proof — catches a verbatim core file shipped at any
  path, not just the corresponding one):
  - non-JSON: `shasum -a 256` of file bytes;
  - `.json`: hash of `jq -S .` canonical form (a key-reordered copy is still a
    verbatim copy).
- Every pack file (excluding `tenant.json`, `README.md`, `.git/`, `.pack-install.json`)
  is hashed the same way; any hit in the core set → violation. Output lists each
  offending pack file with the matching core path; exit non-zero.
- Runs blocking inside `install_pack` Phase 0 (contract enforcement is not
  honor-system — ADR-013 amendment), and standalone in the pack repo's CI.
- **Non-goal (documented in the script header):** a pack JSON that is a strict
  *subset* of a core file is a no-op delta but passes v1 lint. Only byte/canonical
  identity is rejected. Revisit if it bites.

## 5. Test plan

New `tests/test-pack-installer.sh` and `tests/test-pack-lint.sh`, matching existing
convention (`set -euo pipefail`, mktemp fixtures, jq assertions, `FAIL:` + `exit 1`).
Fixtures: a mini core (settings.json with scalar `shared: "core"`, a CLAUDE.md with a
core-managed region, one skill file) and a fixture pack (tenant.json,
`config/settings.json` with `shared: "pack"` + one new key, `CLAUDE.fragment.md`, a
replacement skill).

- [ ] **Pack scalar wins over core** — install core file, apply pack:
      `jq -e '.shared == "pack"'`. (The dedicated overlay-wins test ADR-013
      amendment #1 demands — must exist before merge code merges.)
- [ ] Core-only and pre-existing-target-only keys survive the pack merge.
- [ ] Arrays concatenated + deduped; hook groups sharing a matcher collapse to one block.
- [ ] `.pack-overrides` report lists exactly the overwritten scalar paths.
- [ ] **Project wins over pack** — two assertions: (a) `install_pack` writes nothing
      outside `~/.claude` fixture root (no project `.claude/stack-config.json` ever
      touched); (b) read-time chain: with fixture stack-defaults carrying the pack
      value and fixture stack-config carrying a different value, the session-prefs
      resolution used by `test-session-prefs-parity.sh` returns the project value.
- [ ] **Marker region replaced, not appended** — apply fragment twice:
      `grep -c 'ORG_OVERLAY_MANAGED'` unchanged between runs, region content = second
      fragment, `CLAUDE_CODE_STACK_MANAGED` region byte-identical before/after.
- [ ] ***.md whole-file replace** — installed skill == pack skill exactly (no
      concatenation, no core remnants).
- [ ] **Idempotency** — second `install_pack` run: recursive diff of the fixture
      `~/.claude` tree is empty.
- [ ] **Lint catches verbatim core file** — pack shipping a byte-identical core skill
      fails, names the file, exit non-zero; same for a key-reordered copy of a core
      JSON; a genuinely modified file passes.
- [ ] **Secret-value guard** — pack containing `sk_live_…` aborts Phase 0.
- [ ] **Schema/manifest validation** — missing `tenant_id` fails; lowercase secret
      name fails pattern; valid CarboNet-shaped manifest passes.
- [ ] **`--pack` parse unit cases** — local path; `https://…/repo.git`;
      `https://…/repo.git@v1`; `git@host:org/repo.git@v1` (ref `v1`, URL intact);
      bare `git@host:org/repo.git` (no ref).
- [ ] Phase-0 failure leaves `~/.claude` fixture bit-identical (fail-closed).

## 6. Open questions / risks

1. **Two-conflict-winner merge is the sharp edge.** `merge_json_pack_wins` inverts a
   subtle jq merge whose call-by-name pitfalls are already documented in
   `config-merger.sh`. Requirement: implement on **Opus**, land the dedicated
   overlay-wins test in the same PR, and run **cross-family review** (Codex + Gemini
   API) before merge — this class of change is exactly where cross-family review
   caught the ADR-025 fail-open.
2. **Approach A chosen (DECIDED 2026-07-22).** Order-based pack-wins: the pack
   overwrites conflicting global `~/.claude` JSON values, every override logged to
   `<target>.pack-overrides`, recoverable from the step-1 backup. Approach B
   (three-way preserve hand-edits) is rejected for M3. Implement `merge_json_pack_wins`
   accordingly; do not add provenance/base-file plumbing.
3. **"Project wins" is enforced read-time, distributed across hooks/skills.** Any
   consumer that reads `stack-defaults.json` directly without the chain silently
   breaks project-over-pack. Follow-up audit task: grep consumers of stack-defaults
   for chain compliance once the pack ships.
4. **scp-style `@ref` parsing** is the fiddliest parse in §3 — covered by unit cases;
   do not "simplify" the right-split rule.
5. **Lint corpus definition** (git ls-files minus docs/tests/.github) is a judgment
   call; if core later ships distributable docs, the exclusion list must follow.
6. **Out of M3 scope (explicit):** pack uninstall/removal; reconciler PR delivery
   (ADR-034 §5); `/project-init` tenant assembly beyond the schema fields defined
   here; subset-JSON no-op lint.
