---
name: project-init
description: Initialize a project for use with the Claude Code Stack. Asks which mode to use (quick or review), then either accepts defaults with one confirmation OR walks through every configurable setting group-by-group. Generates .claude/stack-config.json, scaffolds .claude/CLAUDE.md, ensures docs/ directories. Required before foreman will dispatch in strict mode (Tier 2+).
---

# /project-init

Two-mode project initialization. v1.1.

## Steps

### 1. Detect existing state
- Check for `.claude/stack-config.json`. If present, ask if user wants to update (don't blindly overwrite).
- Check for `CLAUDE.md` at root. If present, note it.
- Check for `.git/`. If absent, ask if user wants to `git init`.
- Read `~/.claude/stack-defaults.json` for the user's personal defaults.

### 2. Ask which mode
Print:
> Two modes:
> - **quick** — accept all defaults from your stack-defaults.json with one confirmation
> - **review** — walk through every configurable setting group-by-group
> 
> Which? (quick/review)

Wait for answer. Default to asking; do not assume.

### 3a. Quick mode
- Show all defaults pulled from `~/.claude/stack-defaults.json`.
- Ask: "Accept all? (yes/edit-individual/cancel)"
- If yes: write stack-config.json with these values; jump to step 5.
- If edit-individual: name which settings to change; quick-edit those; write.
- If cancel: stop.

### 3b. Review mode

Walk through groups in order. For each setting: show default, ask user.

**Group 1: Tier and scope**
- Tier (0-5)
- Domain mode (none | financial-code | schema-migration | deploy | ui-design | data-operation)
- Sensitivity level (normal | sensitive | confidential)

**Group 2: Orchestration**
- Orchestration mode (main-thread | agent-teams | hybrid)
- Strict mode (on | off)
- Approval gates (configurable list)

**Group 3: Subagent activation**
- Active subagents (list, defaults from tier)
- Model overrides (per-subagent, optional)

**Group 4: Cost protection**
- Per-session cost alert threshold (default: $5)
- Per-day cost alert threshold (default: $50)
- Hard cost cap per session (default: none)

**Group 5: Project-specific**
- Purpose (one sentence)
- Repo family (related repos, if any)
- Known sensitive data paths (for local-ops routing)

### 4. Safety-relevant changes (both modes)

If user is changing safety-relevant flags from stack-shipped defaults (strict-mode off, domain-mode escape, sensitivity downgrade), prompt for a one-line reason. Append to stack-config.json `change_history`.

Then ask: "Should this also become your default for new projects?"
- [a] Yes, change global default
- [b] No, just this project
- [c] Show me my recent overrides for this setting

### 5. Write stack-config.json

```json
{
  "stack_version": "1.1.0",
  "stack_tier": <chosen>,
  "purpose": "<one-line>",
  "created": "<YYYY-MM-DD>",
  "last_modified": "<YYYY-MM-DD>",
  "orchestration_mode": "<main-thread | agent-teams | hybrid>",
  "strict_mode": <true|false>,
  "domain_mode": "<value or null>",
  "sensitivity": { "level": "<normal|sensitive|confidential>", "notes": "" },
  "active_subagents": [...],
  "required_approvals": [...],
  "model_overrides": {},
  "skill_overrides": {},
  "cost_protection": {
    "per_session_alert_usd": 5.00,
    "per_day_alert_usd": 50.00,
    "per_session_hard_cap_usd": null
  },
  "change_history": []
}
```

**`change_history` entry shape (v1.1):** Each entry is an object appended when settings are changed (especially safety-relevant ones). Shape:

```json
{
  "date": "<ISO-8601 timestamp>",
  "setting": "<dot-path: e.g. 'strict_mode', 'sensitivity.level', 'cost_protection.per_session_hard_cap_usd'>",
  "old_value": <previous value, any JSON type>,
  "new_value": <new value, any JSON type>,
  "reason": "<one-line reason from user, or 'init' for /project-init creation>",
  "scope": "<'project' or 'global'>",
  "also_updated_global": <true|false — whether user chose to update ~/.claude/stack-defaults.json too>,
  "invoked_via": "<'/project-init' | '/default-edit project' | '/default-edit global' | '/agent-teams' | '/strict-mode' | '/domain-mode' | '/sensitivity' | '/cost-cap' | '/tier'>"
}
```

Example entry after `/strict-mode off` with reason "quick prototype, not worth the project-init overhead":

```json
{
  "date": "2026-05-16T14:32:11Z",
  "setting": "strict_mode",
  "old_value": true,
  "new_value": false,
  "reason": "quick prototype, not worth the project-init overhead",
  "scope": "project",
  "also_updated_global": false,
  "invoked_via": "/strict-mode"
}
```

The librarian subagent (Tier 4) reads change_history across projects to spot patterns ("user overrides this 60% of the time — maybe the default is wrong"). The "show me my recent overrides" option in safety-change flows queries this same data.

### 6. Scaffold CLAUDE.md, ensure directories, update .gitignore, suggest commit
(Same as v1.0; see prior section of this artifact.)
