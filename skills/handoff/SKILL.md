---
name: handoff
description: Write a handoff doc to .claude/next_prompt.md so the next Claude Code session can resume cleanly. Captures branch state, what shipped this session, what's blocked, exact next steps, and gotchas (env/auth/sandbox). The SessionStart hook reads this file at the start of the next session. Also archives a copy to docs/handoffs/<date>.md for long-term reference and cross-repo work.
---

# /handoff

Run at the end of a working session. Writes `.claude/next_prompt.md` (the "live" handoff for the next session) and `docs/handoffs/<YYYY-MM-DD-HHMM>.md` (the permanent archive).

## Steps

### 1. Ensure directories exist
- `mkdir -p .claude`
- `mkdir -p docs/handoffs`

### 2. Gitignore the live handoff (one-time per project)
- Check `.gitignore` for `.claude/next_prompt.md`. If absent, append it.
- Rationale: the live handoff is session-private; the archive in `docs/handoffs/` is committed.

### 3. Gather state
- `git branch --show-current`
- `git status --short`
- `git log --oneline -10`
- `git diff --stat HEAD~5..HEAD 2>/dev/null`
- `gh pr list --author @me --state open 2>/dev/null`
- `gh pr checks 2>/dev/null` (if PR exists for current branch)

### 4. Compose the handoff content

Use this exact structure:

```markdown
# Next-session handoff

_Written: <YYYY-MM-DD HH:MM PT>_

## Branch & state
- Branch: `<branch-name>` (worktree: `<path-or-N/A>`)
- Uncommitted: <N files, list paths or "clean">
- Behind/ahead of origin: <e.g., "up to date" / "2 ahead, 1 behind">

## What shipped this session
- <commit-sha> — <subject>
- <commit-sha> — <subject>
(top 3–5 commits relevant to today's work; link PR# if applicable)

## What's blocked & why
- <blocker, with the specific obstacle — auth token expired / waiting on review / unclear requirement>
(omit if nothing blocked)

## Exact next steps
1. <concrete action, with file path or command>
2. <...>
3. <...>

## Gotchas
- <env var that needs rotating, e.g., "SUPABASE_ACCESS_TOKEN expires Friday">
- <sandbox limit, e.g., "this branch needs `gh pr create` from your terminal — sandbox can't push">
- <MCP issue, e.g., "Supabase MCP returns 401; rotate via keychain item">
(omit if none)

## Cross-repo references
- <If this work depends on or affects other repos, note them with specific files/PRs>
(omit if standalone)
```

### 5. Write BOTH files
- Write to `.claude/next_prompt.md` (overwrites previous).
- Write to `docs/handoffs/$(date +%Y-%m-%d-%H%M).md` (new file each session).

### 6. Confirm
- Print absolute paths of both files.
- Print first 5 lines of each as sanity check.
- Stop. Do not run further commands.
