---
name: goodmorning
description: Boot a Claude Code session with full context. Reads .claude/next_prompt.md handoff, runs git log/status/diff, reloads CLAUDE.md + stack-config.json, checks open PRs + CI, surfaces pending data/migration work, and prints a brief summary with a suggested first move. Run from inside the project you're starting on. Doesn't start work — produces a summary and waits.
---

# /goodmorning

Run these steps in order. The deliverable is a brief summary at the end — do not start work after this skill, just print the summary and wait.

## Steps

### 1. Confirm cwd & branch sanity
- `pwd` — confirm which project.
- `git branch --show-current`
- `git status --short`
- `git fetch --quiet origin 2>/dev/null && git status -sb`
- **Flag** if: on `main`/`master`, branch is behind origin, unexpected uncommitted changes.

### 2. Load handoff
- Read `.claude/next_prompt.md` if it exists.
- If present: quote the **Exact next steps** section verbatim in "Where you left off."
- If absent: say "No handoff from previous session."

### 3. Recent activity
- `git log --oneline -10`
- `git diff --stat HEAD~5..HEAD 2>/dev/null || git diff --stat HEAD~3..HEAD 2>/dev/null || git diff --stat`

### 4. Reload project context
- Read `CLAUDE.md` at project root if present.
- Read `.claude/stack-config.json` if present — note the active tier and any overrides.
- Read `~/.claude/projects/<project-slug>/memory/MEMORY.md` if present.

### 5. Open PRs & CI
- `gh pr list --author @me --state open 2>/dev/null`
- If PR exists for current branch: `gh pr checks 2>/dev/null`
- Skip silently if `gh` isn't installed.

### 6. Pending data work
- `git status --porcelain | grep -E '\.sql$|migrations/'`
- `git log --since='7 days ago' --name-only --pretty=format: 2>/dev/null | sort -u | xargs grep -l 'TODO\|FIXME' 2>/dev/null | head -10`

### 7. Print summary

Print exactly this structure (≤10 lines, terse):

```
**Where you left off:** <one line from handoff "next steps", or last commit subject>
**In flight:** <branch>, <N> uncommitted files, <PR# + CI status if any>
**Stack tier:** <from stack-config.json, or "not initialized — run /project-init">
**Watch-outs:** <branch sanity flags + pending SQL + stale TODOs, or "none">
**Suggested first move:** <one concrete action — usually top item from handoff next steps>
```

Skip a section if empty.

### 8. Stop and wait
Do not start coding, planning, or asking follow-up questions. The summary is the deliverable. Wait for the next user prompt.
