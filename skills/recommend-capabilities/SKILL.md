---
name: recommend-capabilities
description: Core recommendation engine for stack capabilities. Reads config/capability-registry.json, filters by tier and session settings, and ranks capabilities by relevance to the current thread context. Internal only — never invoked directly by users. Called by /suggest (mode:discovery) and /config (mode:settings).
user-invocable: false
model-invocable: true
recommendable: false
tier_min: 2
tools: Read, Grep
---

# recommend-capabilities

Internal ranking engine. Not user-facing. All three features (`/suggest`, dispatch-nudge, `/config`) delegate to this skill — none fork ranking logic.

## Input contract

The calling skill assembles the following inputs and passes them in-prompt:

```
mode:             "discovery" | "settings"
thread_context:   <recent thread summary — last 3–5 user turns or a paragraph>
last_user_ask:    <latest user message verbatim>
session_settings:
  stack_tier:          <int 0–5>
  orchestration_mode:  <"main-thread" | "hybrid" | "agent-teams" | "dynamic-workflows">
  strict_mode:         <bool>
  domain_mode:         <string | null>
  sensitivity_level:   <"normal" | "sensitive" | "confidential">
  communication_style: <"terse" | "balanced" | "thorough">
max_results:      <int, default 5>
```

**`mode:discovery`** — find capabilities relevant to what the user is doing right now. Used by `/suggest` and `dispatch-nudge.sh`.

**`mode:settings`** — find settings the user might want to change given their context. Used by `/config recommended-changes`. (Full detail for this mode is deferred to the `/config` slice.)

## Output schema

```json
{
  "mode": "discovery",
  "results": [
    {
      "id": "handoff",
      "kind": "skill",
      "reason": "You are ending a working session and need to preserve context.",
      "confidence": "high",
      "invocation": {
        "slash": "/handoff",
        "natural_language": "write a session handoff"
      }
    }
  ],
  "note": "<optional — present when results empty or relevance floor not met>"
}
```

`confidence` is an enum: `high | medium | low`. No floats.

## Ranking rubric (mode:discovery)

Execute these steps in order:

### Step 1 — Load registry

Read `config/capability-registry.json` from the repo root. If absent, return `{"mode":"discovery","results":[],"note":"capability registry not found — run scripts/gen-capability-registry.sh"}`.

### Step 2 — Filter

Keep only entries where:
- `recommendable: true`
- `tier_min <= session_settings.stack_tier`

### Step 3 — Domain / sensitivity gates

- If `domain_mode` is `"financial-code"`: boost `validate-output`, `cost-gate`, `coverage-snapshot`; demote general-purpose skills.
- If `sensitivity_level` is `"confidential"`: exclude any capability whose summary mentions cloud, web, external, or API calls (conservative guard).

### Step 4 — Relevance ranking

Score each remaining capability against (`last_user_ask` + `thread_context`):
- **High** — the capability directly solves the user's stated task.
- **Medium** — the capability is a useful companion to what the user is doing.
- **Low** — the capability is marginally related; include only if filling to `max_results`.

Discard below a relevance floor: any capability with no semantic connection to the thread. When all remaining candidates are below the floor, set `results: []` and set `note` to a brief explanation.

### Step 5 — Staleness guard

Before including a capability in results, verify its source file still exists:
- For `kind: "skill"`: check that `skills/<id>/SKILL.md` exists (use `Read` or `Grep`).
- For `kind: "subagent"`: check that `agents/<id>.md` exists.

If the file is missing, silently drop the entry (it is stale — the registry was not regenerated after a deletion). Do not surface the missing file as an error to the user.

### Step 6 — Cap and return

Return up to `max_results` entries (highest confidence first). Populate `invocation` from the registry entry verbatim.

## What this skill does NOT do

- It does not write files.
- It does not ask the user questions.
- It does not modify settings.
- It does not perform the actions it recommends.
- It does not re-parse skill/agent frontmatter at runtime (registry is the source of truth).

## Ranking rubric (mode:settings)

`mode:settings` is called by `/config recommended-changes`. The engine finds SETTING CHANGES relevant to the user's stated goal and current session context.

### Input additions for mode:settings

The caller MAY pass an optional field:

```
goal: <string | null>   # user's stated goal (e.g. "ship a security audit") — null if absent
```

### Step 1 — Load registry (same as mode:discovery)

Read `config/capability-registry.json`. Absent → return `{"mode":"settings","results":[],"note":"capability registry not found"}`.

### Step 2 — Load current settings

Read `.claude/stack-config.json` (project config) and `~/.claude/session-state/current-prefs.json` (live session prefs). These are the current values the engine compares against proposed changes.

### Step 3 — Filter to setting-skills

Keep only registry entries whose `id` is in the setting-skills allowlist:
`tier`, `sensitivity`, `strict-mode`, `domain-mode`, `cost-cap`, `session`

These are the owning skills for specific mutable settings. EXCLUDED on purpose:
`default-edit` (a generic non-interactive editor — `--setting=X --value=Y` — that
would let a mis-scored result mutate ANY field incl. denylisted ones; the engine
must only ever propose a *specific* setting via its *specific* owning skill),
and `recommend-capabilities` / `config` (never recommend themselves).

### Step 4 — Generate candidate changes

For each setting-skill, generate a SINGLE best candidate change (the most relevant change for the current context). A candidate is:

```json
{
  "setting": "<dot-path, e.g. sensitivity.level>",
  "current_value": "<value from config/prefs>",
  "proposed_value": "<new value>",
  "reason": "<1 sentence — why this change helps the user's context/goal>",
  "confidence": "high|medium|low",
  "owning_skill": "<skill id, e.g. sensitivity>"
}
```

Only generate a candidate if the proposed_value differs from current_value AND the change is semantically relevant to `last_user_ask`, `thread_context`, or `goal`.

### Step 5 — Relevance ranking

Score candidates against (`last_user_ask` + `thread_context` + `goal`):

- **High** — the change directly addresses the user's stated goal or context (e.g., user is working with sensitive data → propose `sensitivity → confidential`).
- **Medium** — the change is a useful companion given the context.
- **Low** — the change is marginally useful; include only if filling to `max_results`.

Discard below the relevance floor (no semantic connection). When all candidates are below the floor, return `results: []` with a `note`.

### Step 6 — Cap and return

Return up to `max_results` entries (highest confidence first).

### Output schema (mode:settings)

```json
{
  "mode": "settings",
  "results": [
    {
      "setting": "sensitivity.level",
      "current_value": "normal",
      "proposed_value": "sensitive",
      "reason": "The thread involves PII handling — sensitive mode adds logging for PII-touched files.",
      "confidence": "high",
      "owning_skill": "sensitivity"
    }
  ],
  "note": "<optional>"
}
```

### What mode:settings does NOT do

- It does not write any files or call any skills.
- It does not propose changes to denylisted settings: `required_approvals`, `cost_protection.per_session_hard_cap_usd`, `providers`, or any secret-bearing field. (The cost-ALERT thresholds `per_session_alert_usd` / `per_day_alert_usd` are allowlisted and MAY be proposed — only the hard CAP is denied.)
- It only ever names a *specific* owning skill (`tier`, `sensitivity`, `strict-mode`, `domain-mode`, `cost-cap`, `session`) — never the generic `default-edit`.
- It does not propose `config` or `recommend-capabilities` themselves.
- It never generates a candidate where `proposed_value === current_value`.

## Notes

- `mode:settings` is called by `/config recommended-changes`. The caller (/config) hands the ranked results to the user via `AskUserQuestion` and routes the chosen change to the owning skill — the engine only ranks and advises.
