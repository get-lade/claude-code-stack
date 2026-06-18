---
name: goodmorning
description: Boot a Claude Code session with full context. Reads .claude/next_prompt.md handoff, runs git log/status/diff, reloads CLAUDE.md + stack-config.json, checks open PRs + CI, surfaces pending data/migration work, and prints a brief summary with a suggested first move. Run from inside the project you're starting on. Doesn't start work — produces a summary and waits.
---

# /goodmorning

Run these steps in order. The deliverable is a brief summary at the end — do not start work after this skill, just print the summary and wait.

## Steps

### 0. Wrapper-folder detection (do this FIRST — before any other check)

Desktop workspaces commonly open at `~/foo/` where the real git repo + `.claude/` live one level deeper at `~/foo/foo/`. If you skip this step you will report "no git repo / no handoff" when both actually exist.

- Run `pwd`, then `git rev-parse --show-toplevel 2>/dev/null`.
- If that command returns a path: you're inside a git repo, continue to Step 1.
- If it returns empty (cwd is NOT a git repo): scan immediate subdirs for one containing `.claude/stack-config.json` OR `.claude/next_prompt.md` OR a `.git` entry. If exactly **one** subdir matches, `cd` into it and continue from there. Note `(wrapper detected — switched to <subdir>)` in the Flight line of the final summary.
- If 0 or 2+ subdirs match, stay in cwd and proceed; the summary will reflect the missing repo honestly.

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

### 6b. Team benched check (skip if log missing)

- Log: `~/.claude/logs/subagent-runs.jsonl`. If absent, `Team:` line in summary becomes `Team: no log yet`.
- Window: last 14 days, scoped to current project.
- Roster: `ls ~/.claude/agents/*.md 2>/dev/null` + `ls .claude/agents/*.md 2>/dev/null`. Strip path + `.md` for names.
- Active set:
  ```
  CUTOFF=$(date -u -v-14d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)
  PROJECT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  # dispatch rows: agent names from direct dispatches (exclude agent:"workflow" sentinel)
  # workflow_dispatch rows: union in roster_agents[] names so rostered workflows credit their roles
  jq -r --arg c "$CUTOFF" --arg p "$PROJECT" '
    select(.ts >= $c) | select(.project == $p) |
    if ((.event // "dispatch") == "dispatch") and .agent != "workflow" then .agent
    elif .event == "workflow_dispatch" then (.roster_agents // [])[]
    else empty end
  ' ~/.claude/logs/subagent-runs.jsonl | sort -u
  ```
- Benched = roster minus active. Drop obvious-meta names (`historian`, `librarian`, `incident-commander`, `scribe`) — those don't fire routinely.
- **Unrostered write-heavy workflows**: count rows where `event=="workflow_dispatch"` and `write_heavy==true` and `(.roster_agents // []) == []` and `(.uses_roster != true)`. If count > 0, append to the `Watch:` line: `<N> write-heavy workflow(s) with no roster role`.

### 6c. Stack freshness check (skip silently if helper missing)

Is the locally-installed stack (`~/.claude`) behind the source repo? This is a
**nudge only** — never run `update.sh` from here (this skill prints and waits).

- If `~/.claude/lib/stack-freshness.sh` exists, run:
  ```
  bash ~/.claude/lib/stack-freshness.sh --oneline
  ```
- The helper is best-effort (handles missing stamp / offline / no repo) and
  prints a compact token. Map it to the `Stack:` line:
  - `current` → omit the line (don't clutter the summary).
  - `N behind — run update.sh` → `Stack: N behind — run update.sh`.
  - anything else (`unstamped`, `repo-not-found`, …) → omit the line.
- If the helper file is absent (Tier 0 not installed / older install), skip silently.

### 6d. Session preferences (offer once — the one permitted prompt)

Exception to this skill's no-questions rule: a single boot-time offer to set
communication/working preferences.

- Read `~/.claude/session-state/current-prefs.json`. If absent or `source` is
  `"config"` (i.e. not yet customized this session), ask **once**:
  > "Set session preferences (style, effort, verbosity)? [y/N]"
  - If yes: run the `/session` skill, then continue to the summary.
  - If no / no answer: continue.
- If `source` is already `"session"`, skip silently (don't re-offer).
- Skip silently if the state file's directory can't be read.

### 6e. Automation recommender (offer once per repo)

A second permitted boot-time prompt — but only for a repo that's never been
offered, and only when it looks like a real project.

- Gate: skip silently if `.claude/.automation-offered` exists (already offered
  on this machine), OR if no project signal is present (none of
  `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `pom.xml` at root).
- Otherwise ask **once**:
  > "Scan this repo and recommend Claude Code automations (hooks, subagents, MCP servers)? [y/N]"
  - If yes: run the `claude-automation-recommender` skill, then continue.
  - If no / no answer: continue.
- Either way, `mkdir -p .claude && touch .claude/.automation-offered` so it
  never re-prompts here. Skip the touch silently if `.claude/` can't be written.

### 7. Print summary

Emit summary **inside a single ``` fenced code block** (no language tag). Caveman tone — drop articles, fragments OK, short. ≤7 lines. Use these exact labels:

```
Left off: <one line from handoff next-steps, or last commit subject>
Flight: <branch>, <N> dirty, <PR# + CI if any>
Tier: <n + mode, or "uninit — run /project-init">
Watch: <flags / pending SQL / stale TODOs>
Team: <benched roles last 14d, comma list — or "all in play", or "no log yet">
Stack: <N behind — run update.sh — omit line entirely if current/unknown>
Style: <communication_style·model_effort from current-prefs.json — "/session to change"; omit if no state file>
Next: <one concrete action>
```

Skip any line that's empty. No prose outside the fence.

### 8. Stop and wait
Do not start coding, planning, or asking follow-up questions (other than the single step 6d preferences offer). The summary is the deliverable. Wait for the next user prompt.
