# Phase 0 verification — findings

**Date:** 2026-06-03
**Build tested:** `claude` 2.1.128 (local macOS, `/usr/local/lib/node_modules/@anthropic-ai/claude-code`)
**Method:** CLI `--help` probes + `strings` on the compiled binary + repo layout inspection.
Cloud-session behavior could **not** be tested from a local terminal (see gate below).

## Verified — PASS

| Spec item (was UNVERIFIED) | Result |
|---|---|
| `claude plugin validate <path>` exists | ✅ `validate [options] <path>` |
| `claude plugin marketplace add/list/remove/update` | ✅ all present (`add <source>` takes URL/path/GitHub repo) |
| `claude plugin enable/disable/install/uninstall/update/tag` | ✅ all present |
| `claude plugin tag` for releases | ✅ `{name}--v{version}` tag, `--push`, `--dry-run`, `-m` |
| `--plugin-dir <path>` for local load | ✅ present (repeatable, accepts dir or `.zip`) |
| settings field `enabledPlugins` | ✅ present in build (37 refs) |
| settings field `extraKnownMarketplaces` | ✅ present (24 refs) |
| `${CLAUDE_PLUGIN_ROOT}` substitution | ✅ present (17 refs) |
| GitHub marketplace **source shape** | ✅ exactly `{ source: "github", repo: "owner/repo", ref?, path? }` — plan's settings block is correct |
| Version pinning across a team | ✅ pin via marketplace source `ref` (git branch/tag); also `claude plugin tag` cuts release tags |
| Source types supported | github, git, url, npm, file, directory, settings |

## Resolved open question — managed settings (decides B3)

**B3 is OUT for the zero-touch cloud goal.** "Managed settings" in this build =
local **`managed-settings.json` / MDM / policy** files
(macOS `/Library/Application Support/ClaudeCode/`, `/Library/Managed Preferences/…plist`,
Windows HKLM/`Program Files/ClaudeCode/managed-settings.json`). That's an
**admin-deployed, per-machine** mechanism — not a cloud-pushed org setting from
the Team plan. It cannot enroll cloud (web/iOS) sessions without touching each
machine. → Stick with **B1** (slim reconciler stamps the repo settings block).

## Component layout — confirms effort estimates

- `skills/` (30) and `agents/` (23) already at repo root = plugin default locations → **no move needed**.
- `hooks/` has 11 `.sh`; **10 of 11 reference `~/.claude` or `$CLAUDE_PROJECT_DIR`** → confirms "hooks are the cost center." Each needs path rebasing to `${CLAUDE_PLUGIN_ROOT}` and a `hooks/hooks.json` entry.
- Hooks that read **machine-global state** (session-state, `~/.claude/logs/*.jsonl`, freshness stamp) are the fiddly ones — `${CLAUDE_PLUGIN_ROOT}` covers plugin-bundled files, **not** per-machine state. Those reads stay absolute by design; flag during Phase 1.
- No `.claude-plugin/` dir yet (Phase 1/2 creates it).

## The one gate I cannot close locally — BLOCKING

**Does the plugin actually load in a live cloud (web/iOS) session, auto-enabled
by a repo-committed `.claude/settings.json` after a one-time workspace-trust,
with no per-user install?**

- Cannot be driven from a local terminal.
- **Chicken-and-egg:** testing cloud auto-enable needs a *published* plugin +
  marketplace to point at — which is Phase 1/2 output. So this sub-item is
  un-testable until a minimal plugin is published.
- Note from build: `--print`/non-TTY **skips** the workspace-trust dialog, so
  any scripted check must use an interactive session to exercise the real trust flow.

## Recommendation

Local Phase 0 items **all pass**; managed-settings question **resolved (B3 out, B1 stands)**.
The remaining cloud-load gate needs a published artifact to test. Two ways forward — decision required (see chat).
