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

## Notes

- `mode:settings` is used by `/config recommended-changes` (later slice). At that point the engine reads `session_settings` and the registry's `kind: "skill"` entries that correspond to settings-changing skills (`/tier`, `/sensitivity`, `/domain-mode`, `/strict-mode`, `/session`, `/cost-cap`), then ranks which setting change is most relevant to the user's stated goals.
