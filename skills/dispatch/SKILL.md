---
name: dispatch
description: Manually dispatch a task to a specific subagent team. Override for the foreman's default routing. Use when you want explicit control over which subagents run, or when foreman misroutes. Format: /dispatch <team-name-or-list> for <task>. Available team names match subagent names from config/model-routing.json.
---

# /dispatch

Manual override for foreman routing. Use sparingly — foreman should handle 90% of dispatches automatically.

## Steps

### 1. Parse the dispatch request
User says: `/dispatch architect,implementer,reviewer for refactor the digest formatter`
Parse:
- Team: [architect, implementer, reviewer]
- Task: "refactor the digest formatter"

If team is unparseable, list available subagents and ask.

### 2. Confirm
Print the parsed dispatch and ask confirmation:

> "About to dispatch: architect → implementer → reviewer. Task: 'refactor the digest formatter'. Proceed? [y/N]"

### 3. Invoke
Hand off to foreman with explicit team override. Foreman runs through the team in order.

### 4. Compose and report
Same composition format as foreman's default.

## Anti-patterns

- ❌ Using /dispatch to skip approval gates. (Gates still apply.)
- ❌ Using /dispatch for routine work. (Foreman handles it.)
- ❌ Dispatching subagents that conflict (e.g., implementer without architect for a non-trivial change).
