---
name: session
description: Set your communication and working preferences for this session via a multiple-choice menu. Picks communication style (terse/balanced/thorough), model effort, explanation verbosity, orchestration mode, and cost-alert sensitivity, then writes them to the session-state file that the brevity hook and the assistant read. Optionally saves the choices as your global or project default. Offered (not forced) at the top of /goodmorning and /project-init; run directly anytime with /session.
---

# /session

Set per-session preferences. Session-scoped by default; persistence is opt-in.

## Steps

### 1. Load current + last choices (for menu defaults)

- Live session value: `~/.claude/session-state/current-prefs.json` (if present).
- Last explicit pick: `~/.claude/session-state/last-prefs.json` (if present) —
  use this to **pre-select** the menu (the "remember last" behavior).
- Fall back to built-ins: style `balanced`, effort `balanced`, verbosity
  `normal`, cost-alert `normal`, orchestration from project `stack-config.json`.

### 2. Ask (multiple-choice menu)

Use the `AskUserQuestion` tool. One question per preference; put the current/last
value first (marked "(current)"). Keep it to these six:

| Pref | Options |
|---|---|
| **Communication style** | terse · balanced · thorough |
| **Model effort** | fast · balanced · max |
| **Explanation verbosity** | minimal · normal · teaching |
| **Orchestration mode** | main-thread · hybrid · agent-teams · dynamic-workflows |
| **Cost-alert sensitivity** | relaxed · normal · strict |
| **Passive capability suggestions** | on (default) · off — controls whether the dispatch nudge appends a pointer to the recommend-capabilities engine; the routing nudge itself always shows |

Style → brevity budget (what the user is really choosing): terse ≈ 70 words /
4 sentences, balanced ≈ 120 / 6, thorough ≈ 320 / 16. Mention this inline.

### 3. Write the session value

Write the merged object to **both**:
- `~/.claude/session-state/current-prefs.json` (active for this session)
- `~/.claude/session-state/last-prefs.json` (so next session can pre-select)

Shape (stamp `source:"session"` and an ISO `set_at`):
```json
{
  "communication_style": "...",
  "model_effort": "...",
  "explanation_verbosity": "...",
  "orchestration_mode": "...",
  "cost_alert_sensitivity": "...",
  "passive_suggest": true,
  "source": "session",
  "set_at": "<iso8601>"
}
```
Write `passive_suggest` as a JSON boolean from the menu choice: **on → `true`,
off → `false`** (unquoted — the hook compares the literal `false`; a quoted
`"off"`/`"on"` string would silently leave nudging enabled).
`mkdir -p ~/.claude/session-state` first. This takes effect immediately:
`brevity-drift.sh` reads `communication_style` on the next turn, and you (the
assistant) honor effort/verbosity/orchestration directly for the session.

### 4. Offer to persist (opt-in)

Ask once via `AskUserQuestion`: "Save these as a default?"
- **No, this session only** (default) — done.
- **Global default** — write the fields to `~/.claude/stack-defaults.json`
  under `session_prefs_defaults` (reuse `/default-edit global` conventions;
  append a `change_history` entry, `invoked_via: "/session"`).
- **Project default** — write to the nearest `.claude/stack-config.json` under
  `session_prefs` (append a `change_history` entry). Skip if no stack-config
  exists; suggest `/project-init` instead.

### 5. Confirm

Print a 2-line confirmation of the active prefs and where they were saved
(session only / global / project). Do not start other work.

### 6. Offer the automation recommender (once per repo)

After confirming prefs, offer a one-time repo scan — but only when it's useful:

- Gate: skip silently if `.claude/.automation-offered` exists, OR if no project
  signal (`package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod` /
  `pom.xml` at root).
- Otherwise ask **once** via `AskUserQuestion`:
  > "Scan this repo and recommend Claude Code automations (hooks, subagents, MCP servers)?"
  - If yes: run the `claude-automation-recommender` skill (read-only).
  - If no: continue.
- Either way, `mkdir -p .claude && touch .claude/.automation-offered` so it
  isn't re-offered here or in `/goodmorning`. Skip the touch if `.claude/`
  can't be written.

## Notes

- Precedence at session start (handled by `hooks/session-prefs-init.sh`):
  built-in < global `session_prefs_defaults` < project `session_prefs`. `/session`
  overrides all of them for the live session.
- Per-session choices are ephemeral: a new session resets to the configured
  defaults unless you saved them in step 4.
- **For everything beyond session prefs, use `/stack-config`** — the Setup
  Dashboard. `/session` only covers the per-session communication/effort/verbosity
  prefs; `/stack-config show-current` shows the whole setup (tier, modes, caps,
  native model/output-style/plugins), scope-resolved, and safely changes the
  common ones. Mention this once at the end of the `/session` flow so users
  discover the dashboard. (Tier ≥2; absent below tier 2.)
