---
name: default-settings
description: Read-only view of stack configuration. Shows global defaults (~/.claude/stack-defaults.json), current project's stack-config.json, and where each setting comes from (global default, project override, env var). Flags divergence between global default and current project. Useful for "wait, what mode am I in?" moments.
---

# /default-settings

Show me what's configured and where it came from.

## Steps

### 1. Load both files
- `~/.claude/stack-defaults.json` (global defaults)
- `<project>/.claude/stack-config.json` (project config, if any)

### 2. Display in groups
For each setting group (Tier/scope, Orchestration, Subagents, Cost, Project):
- Show global default
- Show current project value (if exists)
- Show "source" of effective value (global | project | env-var)
- Flag divergence with ⚠️

### 3. Print summary
```
Stack defaults (global):
  Orchestration mode: main-thread
  Strict mode: on
  Default tier: 2
  ...

Current project (./my-project):
  Orchestration mode: agent-teams  ⚠️ diverges from global
  Strict mode: on
  Tier: 4
  ...

Effective config (what's actually used):
  ...
```

### 4. Suggest related skills
- "/default-edit global" to change defaults
- "/default-edit project" to change current project
- "/agent-teams [on|off|hybrid|status]" shortcut for orchestration mode
