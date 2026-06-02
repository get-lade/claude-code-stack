---
name: project-init
description: Initialize a project for use with the Claude Code Stack. Asks which mode to use (quick or review), then either accepts defaults with one confirmation OR walks through every configurable setting group-by-group. Generates .claude/stack-config.json, scaffolds .claude/CLAUDE.md, ensures docs/ directories. Required before foreman will dispatch in strict mode (Tier 2+).
---

# /project-init

Two-mode project initialization. v1.2.

## Steps

### 1. Detect existing state

**1a. Required checks**
- Check for `.claude/stack-config.json`. If present, ask if user wants to update (don't blindly overwrite).
- Check for `CLAUDE.md` at root. If present, note it.
- Check for a git repo: `git rev-parse --is-inside-work-tree`. If it returns
  false / errors (not a repo), ask once: "This isn't a git repo. Initialize
  one here? (yes/no)". If yes, run `git init`. If no, continue — but warn that
  `/handoff`, `/goodmorning`, and foreman features that read git state will be
  limited.
- Read `~/.claude/stack-defaults.json` for the user's personal defaults.
- **Stack freshness.** If `~/.claude/lib/stack-freshness.sh` exists, run
  `bash ~/.claude/lib/stack-freshness.sh` (exit code 10 = behind). If it
  reports the install is behind, surface it and offer to update before
  initializing — a stale local stack means you'd init against old routing /
  schema logic:
  > "Your installed stack is N commit(s) behind origin/<branch>. Update now
  > before initializing this project? [y/N]"
  - If yes: run `./scripts/update.sh --tier=<installed tier>` in the stack
    repo (path is in `~/.claude/.stack-install.json` → `source_repo`), then
    continue. Add `--skip-requirements` if the local box lacks codex/gemini.
  - If no: continue, but note in the final summary that the stack is stale.
  - Skip silently if the helper is absent or reports `current`/unknown.

**1b. Discovery pass (do this BEFORE asking the user anything)**

If the project already exists in any meaningful sense — git history,
deps, partial `.claude/` setup, prior handoffs — read it. Do not arrive
at the user's project blind and ask cold questions.

Read each of the following, silently, and tally what you find:

- `git log --oneline -20` — recent commits (shows velocity and themes)
- `git log --format="%an <%ae>" | sort -u` — contributors (1 person vs team)
- `git status -sb` — current branch + uncommitted state
- `git branch --show-current` — are we on a feature branch mid-work?
- `.claude/next_prompt.md` — prior session handoff, if present
- `docs/handoffs/` — count files, note latest filename + date
- `package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod` / `Gemfile` /
  `requirements.txt` — infer language + framework + key deps
- `README.md` first 50 lines — stated purpose / scope / audience
- `.claude/agents/`, `.claude/skills/`, `.claude/hooks/` — prior partial
  setup (someone may have copy-pasted bits of the stack)
- `supabase/`, `migrations/`, `db/` — schema work in progress
- `app/`, `src/`, `pages/` — UI work in progress
- `.github/workflows/` — CI maturity

**Print a 5-line discovery summary**, in the user's terminal, before
asking any questions. Example:

> Discovery: Vite+React+Supabase+Clerk. 47 commits on `master`, 1 author.
> Existing `CLAUDE.md` with project conventions (3 roles, RLS-bound).
> Prior handoff in `.claude/next_prompt.md` covers Supabase wire-up.
> No prior `stack-config.json`. No `docs/handoffs/` directory yet.
> Suggested: tier 2 + domain-mode `schema-migration`. Accept or override?

**Use the discovery to pre-fill defaults** for the tier and domain-mode
question (step 3). The user can accept the suggestion in one keystroke
or override. Never force the cold question when the answer is sitting in
the repo.

If the discovery surfaces a prior handoff or in-flight work, mention it
explicitly so the user knows nothing was lost.

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
  "stack_version": "1.1.4",
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

**Scaffold the project CLAUDE.md.** If no root `CLAUDE.md` exists, copy
`~/.claude/templates/PROJECT-CLAUDE.md.template` to `./CLAUDE.md` and fill in
the repo name, tier, and one-line purpose from the answers above. Leave the
`<...>` placeholder sections for the user to complete. If a `CLAUDE.md`
already exists, do not overwrite it — note that it should be reconciled with
the template by hand.

**Ensure the docs directory tree.** Create any missing:
- `docs/ADRs/` — copy `~/.claude/templates/ADR.template.md` to
  `docs/ADRs/000-template.md` if absent.
- `docs/runbooks/` — copy `RUNBOOK.template.md` to `docs/runbooks/000-template.md`
  if absent.
- `docs/handoffs/` — the `/handoff` skill archives here.
- `docs/architecture/` — for `data-flow.md` and similar.

**Scaffold ONBOARDING.md.** If `docs/ONBOARDING.md` is absent, copy
`~/.claude/templates/PROJECT-ONBOARDING.md.template` to it.

**Set up cloud-session support (web + iOS).** Cloud sessions run in an
ephemeral container that never sees the user's laptop `~/.claude`, so the
stack's skills/commands aren't discoverable unless they travel with the repo
or are installed at session start. Offer once:
> "Make the stack work in this repo's Claude Code cloud sessions (web/iOS)?
> This commits a SessionStart bootstrap hook + a small portable-core skill
> set into `.claude/`. [Y/n]"

If yes, do all of the following **idempotently — never clobber existing
files; merge or skip and warn instead**:

1. **Bootstrap hook.** If `.claude/hooks/cloud-bootstrap.sh` is absent, copy
   `~/.claude/scripts/cloud-bootstrap.sh` to it and `chmod +x`. If it already
   exists, leave it and note that it was kept.
2. **Wire SessionStart.** Merge the `SessionStart` entry from
   `~/.claude/templates/project-cloud-settings.template.json` into the repo's
   `.claude/settings.json` (the entry runs
   `$CLAUDE_PROJECT_DIR/.claude/hooks/cloud-bootstrap.sh`). If
   `.claude/settings.json` exists, deep-merge — do **not** overwrite it; if an
   equivalent `cloud-bootstrap.sh` SessionStart entry is already present, skip.
   If absent, write the template as the new file.
3. **Portable-core skills.** Read the skill list from
   `~/.claude/config/portable-core-skills.json`. For each, copy
   `~/.claude/skills/<name>/` into `.claude/skills/<name>/` only if the
   destination is absent (skip + note any that already exist). These give the
   repo an offline-safe floor (e.g. `/goodmorning`, `/handoff`) even before the
   bootstrap clone finishes or if the environment's network policy blocks it.
4. **No token needed.** The stack repo is **public**, so the committed
   bootstrap clones anonymously — nothing to configure on the environment, no
   secret. (If the repo is ever made private again, set `CLAUDE_STACK_REPO_TOKEN`
   on the environment; the bootstrap will use it. Never write a token into any
   committed file.) See `docs/CLOUD.md`.

If the user declines, skip this block — they can wire the bootstrap later, or
register the env-level setup script from `docs/CLOUD.md`.

**Update `.gitignore`.** Ensure every entry below is present (append any
that are missing — match on the exact line so re-runs don't duplicate). This
block must cover **all** the runtime scratch paths the stack's skills write
under a project's `./.claude/`, otherwise that scratch shows up as untracked
noise in `git status` (one stacked project accumulated ~1,300 untracked lines
from this gap):
```
# Claude Code Stack — runtime scratch, never commit
.DS_Store
.claude/scratch/
.claude/worktrees/
.claude/plans/
.claude/sessions/
.claude/design-targets/
.claude/cost-projections/
.claude/coverage-snapshots/
.claude/reviews/
.claude/validations/
.claude/next_prompt.md
```
What writes each path (keep this list in sync if a skill adds a new scratch
location): `scratch/` ad-hoc, `worktrees/` worktree dispatch, `plans/`
`/plan`, `sessions/` the foreman/architect→implementer→validator flow (the
architect-handoff packet lives at `.claude/sessions/<id>/architect-handoff.md`,
so `sessions/` already covers it), `design-targets/` `/design-match`,
`cost-projections/` `/cost-gate`, `coverage-snapshots/` `/coverage-snapshot`,
`reviews/` `/review-handoff`, `validations/` `/validate-output`,
`next_prompt.md` `/handoff`.

**Do NOT ignore** the shared, tracked files: `.claude/stack-config.json`,
root `CLAUDE.md`, and `docs/handoffs/` — those are committed on purpose. (The
stack's own hooks also write to `~/.claude/logs/`, `~/.claude/state/`, and
`~/.claude/projects/`, but those live in `$HOME`, not the project, so they
don't need a project-level ignore.)

> Follow-up (not blocking): the scratch paths above could be consolidated
> under a single `.claude/scratch/` subtree so this becomes one ignore line.
> That's a cross-skill refactor (each skill would change its write path); fix
> the ignore block now, track the consolidation separately.

**Offer session preferences.** Once, before suggesting the commit:
> "Set communication / working preferences now (style, effort, verbosity)? [y/N]"
- If yes: run the `/session` skill. Its "save as **project** default" writes the
  choices into this project's `stack-config.json` `session_prefs`.
- If no: continue — defaults apply, and `/session` can be run anytime.

**Suggest the commit.** Do not commit automatically. Print the suggested
command for the user to run:
```
git add .claude/stack-config.json CLAUDE.md docs/ .gitignore
# if cloud-session support was set up, also stage:
git add .claude/settings.json .claude/hooks/cloud-bootstrap.sh .claude/skills/
git commit -m "chore: stack init at tier <N>"
```

The committed `.claude/skills/` portable-core set and `cloud-bootstrap.sh`
are **shared, tracked files** (like `stack-config.json`) — the `.gitignore`
block above ignores only runtime scratch, so these are not affected.

After this, foreman is unlocked for the project (strict mode satisfied).
