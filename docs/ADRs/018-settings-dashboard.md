# ADR 018: Claude Code Setup Dashboard — scope correction of ADR-017 Feature C

**Status:** Accepted (plan approved 2026-06-19; build deferred to a fresh session — implementation MUST satisfy every item in §"native-settings-edit security contract" before the native writer ships)
**Date:** 2026-06-19
**Author:** the maintainer + Claude (architect) — reviewed by product-critic (Codex) + red-team (Gemini)

## Context

ADR-017 Feature C shipped `/config` as the front door for **stack** settings (`stack-config.json` + session prefs), routing every mutation through an owning setting-skill. It does not read or write Claude Code's own native `settings.json`. The original ask was broader: one place to see/change the **whole** Claude Code setup. Two problems forced a re-plan:

1. **Namespace collision** — Claude Code has a built-in interactive `/config`; ours shadows it.
2. **Scope gap + scope risk** — the settings users actually hunt for (`model`, output style, MCP/plugin toggles) live in native `settings.json`, which also holds `hooks` (arbitrary shell), `permissions` (the trust boundary), and `env` (secrets). Naively "make `/config` edit everything" turns a preferences panel into a control plane over execution and trust.

product-critic (Codex) reframed the win as **"understand your setup + make only safe changes,"** not omnimutation. red-team (Gemini) reviewed the resulting design and **blocked the build** on 3 critical RCE vectors in the native writer's contract, supplying 10 required hardening changes — all incorporated below.

**Repo grounding:** there is **no `update-config` skill** in this repo (the closest, `default-edit`, writes *stack* config, never native `settings.json`). Writing native `settings.json` is a **brand-new capability** introduced here via one narrow writer. Tier install is manifest-driven; the rename touches the manifest, the capability registry, and the deprecation chain.

## Decision

Rebuild Feature C as the **Setup Dashboard** (`/stack-config`): read-first across stack + native settings, with a small, hard-enforced safe-write surface.

### D1 — Rename `/config` → `/stack-config`
- `skills/config/` → `skills/stack-config/` (`name: stack-config`, label "Settings Dashboard").
- `skills/config/SKILL.md` becomes a **forwarding stub**: prints "`/config` = Claude Code's built-in; the stack dashboard is `/stack-config`" then delegates to `/stack-config show-current`. **Stub is `model-invocable: false`** (red-team M3 — prevents a subagent invoking it to reach a write path).
- `/config` reserved for Claude Code's built-in (surfaced as a link-only row).

### D2 — Three hard-classified row states (the security spine)
Every known setting is exactly one of:
- **Editable** — strictly the curated write-allowlist (Contract A).
- **Review-only** — read/summarize/redact, **never written** (env names, permissions summary, hooks inventory, MCP command/args/env).
- **Open native** — print the exact built-in command (`/permissions`, `/model`, `/agents`, `/hooks`, `/config`).
Tags `[edit]` / `[review]` / `[native]` shown on every row.

### D3 — Curated write-allowlist (deny-by-default; NOT a generic editor)
Beyond stack settings + session prefs, the only writable native settings: `model`, `outputStyle`, `statusLine` (preset selection only), `enabledPlugins["<k>"]` toggle (existing key only), `mcpServers["<name>"].disabled` (enable/disable only). Everything else native is Review-only or Open-native.

### D4 — Write routing (three deterministic mechanisms)
1. **Stack settings** → owning stack-skill (unchanged from ADR-017).
2. **Native (allowlisted)** → the new **`native-settings-edit`** skill — the ONLY component that writes `settings.json`.
3. **Direct dashboard writes** → none. The dashboard is a pure reader/orchestrator.

### D5 — Scope-resolved read model
Show effective value + source across native scopes (user < project < local) and stack scopes (built-in < global defaults < project < session). Contract B.

### D6 — Cloud = read-only
In cloud: `show-current` only; **all write paths disabled** — and the disable is enforced inside `native-settings-edit`, not just the UI (red-team H4).

### D7 — Risky changes = diff-only, never applied
`hooks`, `env` values, `permissions` rules, raw MCP command strings: the dashboard prints a copy-pasteable diff or the native command and stops. Enforced as a hard tool behavior (red-team M1), not model discretion.

## native-settings-edit security contract (MANDATORY — red-team C1–C3, H2–H4, M1–M4, L1–L3)

`native-settings-edit` is the only writer of `settings.json`. It MUST implement all of:

1. **Set-at-path, never deep-merge (C1).** Set exactly ONE scalar leaf. If `--value` is an object/array for a path expecting a scalar → **hard-refuse**. No merging of a value blob (which could smuggle `command`/`env`/`disabled` siblings).
2. **RFC 6901 JSON Pointer paths, not `split('.')` (C2, H3).** Parse/validate paths as JSON Pointers. Canonicalize first: resolve `..`, normalize Unicode, reject non-ASCII segment chars. A plugin key literally containing `.command` cannot collide with the `command` denylist segment because pointer tokens are explicit.
3. **Per-path value schema (C3, L1).** `enabledPlugins[k]` → boolean only; `mcpServers[x].disabled` → boolean only; `model` → string ∈ shipped preset list; `outputStyle` → string ∈ installed styles (else diff-only); `statusLine` → string ∈ **audited shipped preset constant**. String `"false"` for a boolean field → refuse.
4. **statusLine preset constant audited (C3).** Presets ship as a code constant; none may contain `type:"command"` pointing at a user-writable path. The value is matched literally against this list; an object value is refused outright.
5. **Hard-refuse denied segments regardless of context (M1, D7).** Any path whose pointer contains `hooks`, `env`, `permissions`, or a `*.command`/`*.args`/`*.env` leaf → refuse, even if a caller (or the model) requests it. Review-only paths are unreachable by the writer.
6. **`--dry-run` is a real flag (M1).** Diff-only mode prints and exits; it is not model-enforced prose.
7. **Atomic write + lock (H2, L2, L3).** Read-modify-write under an advisory `flock`; write to `settings.json.tmp` then `rename()`. Preserve `$schema` and ALL untargeted siblings byte-for-byte where possible.
8. **Cloud gate inside the tool (H4).** Refuse all writes in cloud; detection must be multi-factor / non-spoofable, not a single env var, and checked inside `native-settings-edit` (not only the dashboard).
9. **Default scope = `project`; user scope requires `--confirm-global` (M2).** Writing `~/.claude/settings.json` (affects every project) requires the explicit flag; the dashboard confirmation shows the scope prominently. (This OVERRIDES the architect's earlier user-default recommendation, per red-team.)
10. **Sanitized errors (M4).** Catch all read/parse errors; never echo raw file content (the `env` block) into messages or logs.
11. **Refuse to CREATE `enabledPlugins`/`mcpServers` keys** — only flip an existing one.
12. **The dashboard never executes a model-generated command blob (H1).** It decomposes the operation into a human-readable confirmation ("This will DISABLE plugin X. Confirm?"). The model proposes; the UI gates; the tool validates.

## Interface contracts

### Contract A — Curated write-allowlist
**Stack (mechanism = owning skill; file = stack-config.json):** `stack_tier`→tier · `orchestration_mode`→agent-teams · `strict_mode`→strict-mode · `domain_mode`→domain-mode · `sensitivity.level`→sensitivity · `cost_protection.per_session_alert_usd`/`per_day_alert_usd`→cost-cap · `session_prefs.{communication_style,model_effort,explanation_verbosity,orchestration_mode,cost_alert_sensitivity,passive_suggest}`→session.

**Native (mechanism = native-settings-edit; default scope = project):**
| Pointer | Type / constraint |
|---|---|
| `/model` | string ∈ shipped preset list (never free-typed) |
| `/outputStyle` | string ∈ installed styles; else diff-only |
| `/statusLine` | string ∈ audited preset constant; object value refused |
| `/enabledPlugins/<key>` | boolean; existing key only |
| `/mcpServers/<name>/disabled` | boolean; never touches command/args/env |

### Contract B — Scope resolution
Native: `~/.claude/settings.json` (user) < `<project>/.claude/settings.json` (project) < `<project>/.claude/settings.local.json` (local). Deep-merge per key; object keys (permissions/hooks/enabledPlugins/mcpServers) shown as the per-scope union with a source label; scalars: highest scope wins. Best-effort: a missing/unparseable scope file is skipped with a note. Stack precedence unchanged from ADR-010/017.

### Contract C — Review-only / denylist registry
hooks → inventory (matcher + path, counts; commands truncated) · change = diff-only or `/hooks`. env → names only, values `[redacted]`. permissions → effective summary + **shallow** display-only conflict flag · change = `/permissions`. mcpServers command/args/env → inventory only. providers/secrets + stack `required_approvals`/`per_session_hard_cap_usd` → redacted/read-only.

### Contract D — Ops + forwarding stub
`/stack-config` keeps ADR-017's 4 ops, native-aware: **show-current** (scope-resolved read, Contract C redaction, row-state tags) · **recommended-changes** (engine `mode:settings` → only Contract-A candidates) · **change-one-setting** (→ owning skill or native-settings-edit) · **guided-setup-by-goal** (recipes reference only Contract-A paths; non-allowlisted targets become diff-only steps). Stub: `model-invocable:false`, prints the notice, delegates to show-current.

## Resolved open decisions
1. New `native-settings-edit` skill = the only native writer (not `default-edit`). ✓
2. Default native scope = **project** + `--confirm-global` for user scope (red-team M2 overrode the user-default rec). ✓
3. `statusLine` = preset-only, value validated against an audited constant. ✓
4. permissions conflict flag = shallow, display-only. ✓

## Alternatives considered
- **Full-mutate (edit hooks/env/permissions).** Rejected — editing the security boundary from an LLM-navigated surface; the 3 critical RCE vectors live here.
- **Keep `/config` name.** Rejected — collides with the built-in.
- **Read-only everything.** Rejected — the safe subset (model/output style/plugin+MCP toggle/statusLine preset) is low-risk, high-value with the dedicated allowlisted writer.
- **Reuse `default-edit` for native writes.** Rejected — a generic editor on a security surface.

## Consequences
- **Positive:** one front door for the whole settings surface; collision resolved; first-ever safe native edits behind a single audited writer; honest cloud degradation.
- **Security posture:** writable surface is a closed enumeration enforced in two places (dashboard routing + writer self-validation); hooks/env/permissions/raw-MCP are structurally unreachable from any write path; worst case from a compromised prompt is flipping model/outputStyle/a toggle/a statusLine preset, or printing a diff. Contingent on ALL 12 contract items shipping — partial implementation reopens the RCE vectors.
- **Negative / accepted risk:** a new writer on a sensitive file (mitigated by set-at-path + allowlist self-check + atomic write); preset lists need maintenance as Claude Code evolves (invalid values fall through to diff-only).

### Build verification (2026-06-19) + accepted residuals
Implemented and verified across four cross-model passes (Gemini CLI was account-tier-blocked; the red-team ran via **Codex** with the maintainer's sign-off — cross-model, not Claude-only). Passes: red-team (Codex, 66 probes — no bypass) → reviewer (Codex) → security-auditor (Codex) ×2 + an Opus belt-and-suspenders pass. Three findings were fixed and regression-tested (`tests/test-native-settings-edit.sh`, 47 cases):
1. `--scope project --repo-root <home>` resolved to `~/.claude/settings.json` and skipped `--confirm-global` → fixed with `_is_user_global()` (symlink- and case-insensitive-FS-robust).
2. `settings.json.tmp` written via `open("w")` followed a planted symlink → RCE copying project `hooks` into the user-global file → fixed with `tempfile.mkstemp` (unpredictable name + `O_EXCL`).
3. `settings.json.lock` `open("w")` truncated through a symlink → fixed with `os.open(..., O_NOFOLLOW)` + no-truncate, plus a TOCTOU re-check of the user-global guard under the flock.

**Accepted residuals (out of the documented threat model = *hostile repo contents*, NOT a same-UID concurrent attacker):**
- **MEDIUM — residual TOCTOU.** A same-UID process could race-swap `<repo>/.claude` → `~/.claude` in the sub-ms window between the in-lock guard re-check and `mkstemp`/`os.replace`. An attacker with that capability can already write `~/.claude/settings.json` directly. A full fix needs `O_DIRECTORY`/`openat` fd-chaining (C/`ctypes`, not stdlib) — declined per KISS/YAGNI; tracked here.
- **LOW — orphan lock.** If `<repo>/.claude` is itself a symlink to `~/.claude`, the lock `os.open` (final-component `O_NOFOLLOW` only) can create `~/.claude/settings.json.lock` before the in-lock guard refuses the data write. No data is written; worst case is a spurious "suspicious lock file" refusal on a later write.

## Migration from the shipped `/config` (implementer steps — no code here)
1. `git mv skills/config skills/stack-config`; `name: stack-config`; extend ops + add native sections.
2. Recreate `skills/config/SKILL.md` as the `model-invocable:false` forwarding stub.
3. New `skills/native-settings-edit/SKILL.md` implementing the full security contract above.
4. `config/tier-manifests/tier-2.json`: repoint the skill entry to `skills/stack-config/SKILL.md`; add entries + smoke tests for the stub and `native-settings-edit`.
5. Regenerate `config/capability-registry.json` (`config`→`stack-config`, slash `/stack-config`; stub + native-settings-edit `recommendable:false`); run `--check`.
6. `docs/ADRs/017-...md`: add a header note "Feature C superseded by ADR-018."
7. `skills/default-settings` + `skills/default-edit`: forwarding notices `/config`→`/stack-config`.
8. Repo-wide `grep '/config\b'`: reclassify each hit (stack sense → rename; native sense → leave).
9. No `install.sh` change (manifest-driven); registry stays committed.

## References
- ADR-017 (Feature C superseded), ADR-010 (scope precedence), ADR-014 (cloud distribution), ADR-016 (deny-by-default precedent).
- `.claude/sessions/.../` product-critique + red-team reports (this session).
