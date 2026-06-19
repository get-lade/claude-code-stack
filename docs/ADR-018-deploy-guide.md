# ADR-018 Setup Dashboard — build summary & deployment guide

_Shipped 2026-06-19 on `main` (PRs #34, #35). See [ADR-018](ADRs/018-settings-dashboard.md) for the full design + the 12-item security contract._

## What we built

| Capability | Path | Role |
|---|---|---|
| **`/stack-config`** | `skills/stack-config/SKILL.md` | The Setup Dashboard. Read-first front door over **stack** settings (`stack-config.json` + session prefs) **and** native `settings.json`. 4 ops: show-current, recommended-changes, change-one-setting, guided-setup. |
| **`/config` (stub)** | `skills/config/SKILL.md` | `model-invocable:false` forwarder. Cedes `/config` to Claude Code's built-in; points users to `/stack-config`. |
| **`native-settings-edit`** | `skills/native-settings-edit/native_settings_edit.py` + `SKILL.md` | The **only** writer of native `settings.json`. A hardened python3-stdlib executable; `user-invocable:false` (the dashboard calls it). |
| Contract suite | `tests/test-native-settings-edit.sh` | 47 adversarial cases (the security regression net). |

Plus: tier-2 manifest entries + smoke tests, regenerated `capability-registry.json`, and `/config`→`/stack-config` reference fixes across `default-edit`, `default-settings`, `recommend-capabilities`.

## How it works

**Read-first dashboard.** `/stack-config show-current` resolves values across native scopes (`~/.claude` < project < `.local`) and stack scopes, tags every row `[edit]` / `[review]` / `[native]`, and redacts secrets (`providers`, native `env` values, hook commands, MCP `command/args/env`).

**Three write mechanisms (deny-by-default):**
1. Stack `[edit]` → the owning skill (`/tier`, `/sensitivity`, `/session`, …) runs its own confirm.
2. Native `[edit]` → `native-settings-edit`, always `--dry-run` first → user confirms → apply.
3. Direct dashboard writes → none.

**The writer's guarantees (12-item contract, enforced in code not prose):** sets exactly one allowlisted scalar leaf (`/model`, `/outputStyle`, `/statusLine` preset, `/enabledPlugins/<key>`, `/mcpServers/<name>/disabled`); RFC-6901 pointers; per-path value schema; hard-refuses `hooks`/`env`/`permissions`/MCP `command/args/env`; refuses to create keys; atomic write via `mkstemp`+`O_NOFOLLOW`+`flock`; cloud = read-only; user-global scope needs `--confirm-global`; sanitized errors. Worst case from a hijacked prompt: flip a model/style/toggle or print a diff.

**Verification:** 4 cross-model passes (Codex; Gemini CLI tier-blocked). Caught + fixed a `--repo-root` scope bypass and a symlink-follow RCE on the temp/lock files; converged with 2 out-of-threat-model residuals documented in the ADR.

## How to deploy across the rest of your repos

The dashboard ships as **global** skills in `~/.claude` — there is **nothing to install per repo**.

**1. Per machine (makes `/stack-config` live for ALL repos on that box):**
```bash
cd <path-to>/claude-code-stack && git pull origin main
./scripts/update.sh --tier=4      # or your installed tier; ADR-018 caps are tier ≥2
```
This copies the 3 new skills + the executable + the regenerated registry into `~/.claude`. Verify:
```bash
test -x ~/.claude/skills/native-settings-edit/native_settings_edit.py && echo ok
```

**2. Per repo:** no file changes. A project only needs `stack_tier >= 2` in its `.claude/stack-config.json` (set with `/tier 2` or higher, or `/project-init`). Below tier 2 the skills are filtered out (`tier_min: 2`). `/config` (the stub) and `/stack-config` are global, so they work in any tier-≥2 project once step 1 has run.

**3. Cloud (web / iOS):** the `CLAUDE_CODE_REMOTE` SessionStart path already runs `install.sh --tier=2`, so cloud sessions pick up the new skills automatically on next boot. For a brand-new cloud environment, use `/cloud-setup` to print the one-time enable script. Note: the writer refuses all writes in cloud (read-only by design).

**Smoke test after deploy (any repo, tier ≥2):**
- `/stack-config` → pick "show current setup" → confirm native rows render and secrets are redacted.
- `/stack-config` → change-one → Model → confirm it runs `native-settings-edit --dry-run` and shows a diff before writing.
