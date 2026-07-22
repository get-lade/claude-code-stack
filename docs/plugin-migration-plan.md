# Plugin migration — scoping plan

**Status:** Draft for review (not yet approved to build)
**Date:** 2026-06-03
**Supersedes consideration:** ADR-007 (plugins deferred) — this revisits it.

## Goal

Distribute the stack to a team with **zero per-user action** and have it work in
**Claude Code cloud sessions** (web + iOS). Today that's done by (a) the
`~/.claude` install and (b) the org reconciler committing Path-B bootstrap files
into tagged repos. A plugin could do the same with less machinery — and is the
"native" answer.

## Key finding (the crux)

Org-level **Skills** (Team plan → Organization settings → Skills) are
**claude.ai-chat only — they do NOT reach Claude Code**. So that route is out.

But Claude Code **plugins** do work in cloud, and can be auto-enabled per repo
with **no per-user install** via repo-committed `.claude/settings.json`:

```jsonc
// .claude/settings.json (committed to a repo)
{
  "extraKnownMarketplaces": {
    "claude-code-stack": { "source": { "source": "github", "repo": "bschonbrun/claude-code-stack" } }
  },
  "enabledPlugins": { "claude-code-stack@claude-code-stack": true }
}
```

On first session the user is prompted once to **trust the workspace**; after
that the plugin's skills/agents/hooks load automatically — in cloud too.
This is strictly simpler than copying files per repo.

> ⚠️ Several specifics below (CLI flags, `userConfig`, seed dirs, managed
> settings on the **Team** tier vs Enterprise) come from a docs sweep and are
> **marked UNVERIFIED**. Confirm against a live `claude` build before building.

## Architectural choices to decide

### A. One plugin vs many (tiering)
The stack today is tiered (0–5). Plugins are **all-or-nothing**; there is no
native tiering. Options:
- **A1 (recommended): one plugin = the whole stack.** Tiers were a local-install
  concern; for team/cloud, "everything on" is simpler and matches how skills are
  already gated at runtime by `stack-config.json`. Drop tiers from the plugin.
- **A2: split into `stack-core`, `stack-tier2`, … plugins** wired via the
  `dependencies` field. More faithful to tiers, much more upkeep. Not worth it v1.

### B. Does the plugin replace the reconciler?
- **B1 (recommended): plugin + slim reconciler.** Keep the reconciler, but its
  payload shrinks from "copy hooks + skills + config" to "write the 3-line
  `.claude/settings.json` block above" into each tagged repo. One small file,
  same topic-gating, same PR flow. Far less to keep in sync.
- **B2: drop the reconciler, document the snippet.** Teams paste the settings
  block into repos themselves. Simplest to maintain; loses auto-enrollment.
- **B3: managed settings (org-wide, no repo edits at all).** Cleanest *if*
  available on the Team plan — **UNVERIFIED**; may be Enterprise-only. If
  available, it beats both. Verify first.

### C. Distribution repo
- **C1 (recommended): reuse this public repo** as the marketplace. Add
  `.claude-plugin/marketplace.json` + `.claude-plugin/plugin.json`; point
  component paths at the existing `skills/`, `agents/`, `hooks/`. No second repo.
- C2: separate `bschonbrun/claude-plugins` repo. Cleaner separation, more repos.

## Component mapping (this repo → plugin)

| Stack today | Plugin location | Effort |
|---|---|---|
| `skills/<name>/SKILL.md` (~30) | `skills/` at plugin root — **already there** | none (path is default) |
| `agents/<name>.md` (~13) | `agents/` at plugin root — **already there** | none |
| hooks wired in `settings.global.template.json` + `hooks/*.sh` | `hooks/hooks.json` referencing `${CLAUDE_PLUGIN_ROOT}/hooks/*.sh` | **real work** — rewrite hook paths, port SessionStart/UserPromptSubmit/PostToolUse entries |
| `config/*.json`, `schemas/`, `templates/` | plugin-relative paths | low |
| tiered `install.sh` | n/a (all-or-nothing) | drop for plugin path |
| `lib/*.sh` referenced by hooks | bundle under plugin root, fix paths | medium |

The big lift is **hooks**: today they assume `~/.claude/...` absolute paths and
`$CLAUDE_PROJECT_DIR`. In a plugin they must use `${CLAUDE_PLUGIN_ROOT}` and be
declared in `hooks/hooks.json`. Every hook script that sources `lib/` needs its
path rebased.

## Phased plan

**Phase 0 — verify (blocking).** Confirm on a live `claude`:
- plugin loads in a **cloud** session;
- repo `.claude/settings.json` `enabledPlugins` auto-enables after trust, no
  per-user install;
- whether **Team-plan managed settings** exist (decides B3);
- `claude plugin validate` / CLI field names actually present.

**Phase 1 — author the plugin (no behavior change).**
- Add `.claude-plugin/plugin.json` (`name: claude-code-stack`, version, paths).
- Author `hooks/hooks.json`; rebase hook + `lib` paths to `${CLAUDE_PLUGIN_ROOT}`.
- `claude plugin validate .`; load locally via `--plugin-dir` and smoke-test a
  hook + a skill + an agent.

**Phase 2 — marketplace.**
- Add `.claude-plugin/marketplace.json` (one entry → this plugin, source = this
  repo). Decide explicit `version` (manual bumps) vs omit (commit-SHA auto-update).
- Document `/plugin marketplace add bschonbrun/claude-code-stack` + install.

**Phase 3 — team enablement.**
- B1: change the reconciler payload to write the `.claude/settings.json` block
  instead of copying files; keep the version stamp + topic gating.
- Or B3 if managed settings are available on Team.

**Phase 4 — migrate + deprecate.**
- Roll the settings-block PRs to the 6 enrolled org repos; verify cloud loads
  the plugin; then retire the file-copy bootstrap (keep `cloud-bootstrap.sh` as a
  fallback for repos that can't use plugins).
- New ADR recording the plugin decision; update `docs/CLOUD.md`.

## Risks / open questions

- **Hooks are the cost center.** If many hooks rely on absolute `~/.claude`
  paths or on the tiered install, porting is fiddly; budget most of the work here.
- **Trust prompt UX** in cloud — one-time per workspace, but confirm it's not a
  per-session nag.
- **Tiering loss** — acceptable if `stack-config.json` runtime gating covers it;
  confirm no skill *requires* a tier-install side effect.
- **Version pinning across a team** — UNVERIFIED; may not be per-plugin.
- **Two systems during migration** — plugin + existing bootstrap coexist until
  Phase 4; make sure they don't double-wire hooks.

## Recommendation

Pursue **A1 + B1 + C1**: one `claude-code-stack` plugin, this repo as its own
marketplace, reconciler slimmed to stamp the enable-block into tagged repos.
**Do Phase 0 first** — the build only makes sense if cloud auto-enable behaves as
documented.
