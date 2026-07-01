# Changelog

All notable changes to the Claude Code Stack are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning is [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **Karpathy ten-rule set — six loop-era rules added to the global standards**: `config/claude.md.global.template` gains an always-active **Loop & Self-Check Discipline** section (rules 5–10) on top of the four originals — Verification (reproduce-with-test before fixing), Goal-driven (machine-verifiable "done" before code), Debugging (full trace, reproduce, one variable at a time), Dependencies (stdlib first; every package is permanent code), Communication (useful uncertainty over vague reassurance), and Named failure modes (stop on Kitchen Sink / Wrong Abstraction / Optimistic Path / Runaway Refactor). `skills/loop-engineer/SKILL.md` step 6 references rules 5–10 as the per-iteration self-check gate, since a governed loop has no human reviewing each step. Landed in #64; source is the circulating ten-rule CLAUDE.md (provenance unconfirmed). `stack_version` bumped 1.1.3 → 1.1.4 so existing installs surface the freshness nudge.
- **Comprehensive workflow-roster fence (v1.2)**: `hooks/workflow-roster-check.sh` now extracts roster agent names from `agentType` declarations (both quote forms, `:` and `=`), best-effort appends a `workflow_dispatch` row with `roster_agents`/`mode`/`decision`/`script_source` on every Tier 2+ Workflow invocation (including off/quiet paths; dropped silently if log dir unwritable), and supports an opt-in `workflow_roster:"block"` mode via `stack-config.json` (default: `"warn"`; `"off"` disables warn/deny but still logs). Install coverage added: hook registered in the tier-2 manifest and the tier-2-only settings fragment `config/settings.team.template.json` (PreToolUse Workflow matcher), merged into `settings.json` at tier ≥2. Reporting in `/team-status`, `/goodmorning` Step 6b, and `/handoff` updated to exclude the `agent:"workflow"` sentinel from dispatch counts, credit roster names from `workflow_dispatch` rows toward the in-play set (via `(.roster_agents // [])`), and surface an unrostered-write-heavy-workflow count. `workflow_roster` key added to `schemas/stack-config-schema.json`. Design in ADR-016; ADR-008 addendum records the uniform agentType convention across all parallel modes. New `tests/test-workflow-roster-check.sh` covers all decision-table branches.
- **Reconciler auto-initializes repos (`stack-config.json`)**: the org reconciler
  now also writes a default `.claude/stack-config.json` into each enrolled repo
  (tier from the admin `config.yml`), so tagged repos are initialized for foreman
  without a manual `/project-init`. Existing `stack-config.json` files are never
  overwritten — repos someone already init'd keep their settings. Generated from
  `templates/stack-config.template.json` (tier/created/last_modified/purpose
  filled in). Covered by an offline assertion in `tests/test-reconcile.sh`.
- **Org-wide cloud distribution (`/team-init` + reconciler Action)**: roll the
  cloud bootstrap out across an entire GitHub org/team automatically, so every
  existing **and** new repo gets it without per-repo work. Ships a per-org admin
  repo template (`templates/team-admin/`) with a GitHub Action reconciler
  (`scripts/reconcile.sh`) that runs hourly + on manual dispatch, enumerates
  repos tagged with a GitHub topic (default `claude-stack`), and opens **one PR
  per repo** that's missing or has a stale bootstrap (tracked by a
  `.claude/.stack-bootstrap-version` stamp). No hosting — pure Actions. New
  `/team-init` skill scaffolds the admin repo and captures org/topic/tier.
  Safe-by-default: a `config.yml` `enabled: false` gate and dry-run default mean
  nothing is written until an admin flips it and adds the `STACK_RECONCILE_TOKEN`
  PAT. Deep-merges (never overwrites) an existing `.claude/settings.json`.
  Installed via the Tier 0 manifest (+ smoke tests); offline unit test
  `tests/test-reconcile.sh` (stubbed `gh`/`git`). Design in
  `docs/ADRs/014-org-wide-cloud-distribution.md`. Not yet run against a live
  org — dry-run + security review recommended before enabling writes.
- **`/cloud-setup` skill**: prints the one-time setup-script one-liner + the
  click-by-click steps to enable the stack in a Claude Code cloud environment
  (web + iOS). Cloud environments are configured individually in the web UI and
  can't be set from a repo, so this makes the unavoidable manual paste a single
  copy. Public repo → no token. Installed via the Tier 0 manifest (+ smoke
  test); `docs/CLOUD.md` Path A now points at it.
- **Cloud session support (web + iOS)**: the stack's personal/global
  skills/commands (`/goodmorning`, `/handoff`, …) now work in Claude Code
  *cloud* sessions, not just the Mac Desktop app. Cloud containers never sync a
  user's laptop `~/.claude`, so new `scripts/cloud-bootstrap.sh` clones this
  **public** repo anonymously (no token, no environment secret) and runs the
  idempotent `install.sh --tier=2 --skip-requirements` into the container's
  `~/.claude`. The script is best-effort (blocked network → warn + exit 0, never
  breaks the session) and guarded by a per-boot marker so it runs at most once.
  Two distribution paths: (B, recommended) `/project-init` commits a copy into a
  repo's `.claude/hooks/`, wires the `SessionStart` hook, and copies a
  portable-core skill set (`config/portable-core-skills.json`) so the repo
  self-bootstraps with **zero** environment config; or (A) register it as a
  per-environment **setup script** (covers every repo using that environment).
  If the repo is ever made private again, set `CLAUDE_STACK_REPO_TOKEN` on the
  environment and the bootstrap uses it via `GIT_ASKPASS` (never in argv or
  `.git/config`). Installed to `~/.claude/scripts/` via the Tier 0 manifest
  (+ smoke tests). New `docs/CLOUD.md` documents both paths, the network-policy
  caveat, `/goodmorning` verification, and why a plugin (deferred per ADR-007)
  wouldn't replace this bootstrap. New `tests/test-cloud-bootstrap.sh` covers
  the offline decision paths.
- **Session preferences picker (`/session`)**: a per-session, multiple-choice
  way to set communication style (terse/balanced/thorough), model effort,
  explanation verbosity, orchestration mode, and cost-alert sensitivity — so
  different users get their own defaults without hand-editing config. New
  `/session` skill (Tier 1) drives an `AskUserQuestion` menu, writes the live
  choice to `~/.claude/session-state/current-prefs.json` (+ `last-prefs.json`
  to remember last), and offers opt-in persistence to global
  (`stack-defaults.session_prefs_defaults`) or project
  (`stack-config.session_prefs`). New `hooks/session-prefs-init.sh`
  (`SessionStart`, Tier 0) resolves precedence built-in < global < project into
  the session-state file so defaults apply without running `/session`; per-session
  choices are ephemeral. `brevity-drift.sh` reads `communication_style` as the
  highest-precedence budget (above the per-project block below): terse ≈ 70/4,
  balanced ≈ 120/6, thorough ≈ 320/16. `session_prefs` / `session_prefs_defaults`
  added to both schemas + templates. Offered (not forced) atop `/goodmorning`
  (the one permitted boot prompt, plus a `Style:` summary line) and `/project-init`.
- **Per-project brevity thresholds**: `hooks/brevity-drift.sh` now reads an
  optional `brevity` block from the nearest `.claude/stack-config.json` (via
  the shared `lib/find-stack-config.sh` finder, same as `dispatch-nudge.sh`):
  `enabled` (false opts a project out of drift correction entirely),
  `word_budget`, and `sentence_budget`. Absent, null, or non-numeric values
  fall back to the built-in defaults (enabled, 120 words / 6 sentences), so a
  malformed config can only fall back, never misbehave. Added the `brevity`
  object to `stack-config-schema.json` (with `additionalProperties: false`)
  and a default block to `templates/stack-config.template.json`. This
  establishes the config contract for a future `/project-init` step that asks
  for these values. (Note: avoided jq's `//` operator for the `enabled` check —
  `// true` falls through on both null and false, which would silently re-enable
  an explicitly disabled project.)

### Fixed
- **Tier-0/1 installs no longer wire team hooks that don't exist yet.** The
  global settings template (`config/settings.global.template.json`, applied at
  tier 0) referenced four hook scripts — `subagent-log.sh` (PreToolUse Agent),
  `workflow-roster-check.sh` (PreToolUse Workflow), `subagent-complete-log.sh`
  (PostToolUse Agent), and `dispatch-nudge.sh` (UserPromptSubmit) — that the
  installer only copies at tier 2. A fresh tier-0/1 install got a `settings.json`
  pointing at missing scripts, so every matching tool call tried to exec a
  non-existent file (non-fatal but untidy; flagged in a 2026-06-18 review). Those
  matchers now live in a tier-2-only fragment (`config/settings.team.template.json`)
  that the installer deep-merges into `settings.json` at tier ≥2; the tier-0 base
  carries only the Bash matcher. Behavior at tier 2 is unchanged (merge is
  idempotent). `tests/test-install.sh` now asserts no `settings.json` hook
  command points at a missing script for every tier; `tests/test-workflow-roster-check.sh`
  C-merge covers the base/fragment split and re-merge idempotency.
- **`/project-init` `.gitignore` block now covers all runtime scratch**
  (`stack_version` → `1.1.4`). The block previously only ignored
  `.claude/scratch/`, `.claude/worktrees/`, and `.claude/cost-projections/`,
  but stack skills also write `.claude/plans/` (`/plan`), `.claude/sessions/`
  (foreman/architect→implementer→validator flow, incl. the nested
  `architect-handoff.md`), `.claude/design-targets/` (`/design-match`),
  `.claude/coverage-snapshots/` (`/coverage-snapshot`), `.claude/reviews/`
  (`/review-handoff`), `.claude/validations/` (`/validate-output`), and
  `.claude/next_prompt.md` (`/handoff`) — none of which were ignored. Stacked
  projects accumulated this scratch as untracked noise in `git status` (one
  project showed ~1,300 untracked lines). Expanded the inline block in
  `skills/project-init/SKILL.md` step 6 to the full superset and documented
  which skill owns each path. Shared/tracked files (`.claude/stack-config.json`,
  `CLAUDE.md`, `docs/handoffs/`) are explicitly kept tracked; host-level
  `~/.claude/{logs,state,projects}/` are out of scope (they live in `$HOME`,
  not the project). Existing projects pick up the wider block on the next
  `/project-init` re-run. Follow-up noted in-skill: consolidating the scratch
  paths under a single `.claude/scratch/` subtree (one ignore line) is a
  cross-skill refactor tracked separately.

### Added
- **Adaptive brevity enforcement (`brevity-drift.sh`)**: new
  `UserPromptSubmit` hook that keeps the response-style rules from decaying
  mid-session. `brevity-reinforce.sh` injects the full rules once at
  `SessionStart`, but that dilutes as context grows and the model drifts back
  to verbose prose. This hook measures the assistant's most recent response on
  every turn and injects a one-shot correction **only** when it exceeded
  budget (default: >120 words or >6 sentences) — silent when already terse, so
  it never becomes noise the model tunes out. Fail-safe: any transcript-parse
  problem yields no output and a clean exit, so the hook can never block a
  turn. Wired into the global settings template's `UserPromptSubmit` ahead of
  `dispatch-nudge.sh`; installed at tier 0.
- **Local stack-freshness checks**: `install.sh` now writes an install stamp
  to `~/.claude/.stack-install.json` (source SHA, branch, repo path, tier,
  timestamp). New shared helper `lib/stack-freshness.sh` (installed at Tier 0)
  reads the stamp, fetches the source repo, and reports how many commits the
  installed stack is behind `origin/<branch>` — best-effort and non-fatal
  (missing stamp / offline / no repo all resolve to a benign status; exit 10
  signals "behind"). Wired into two skills:
  - `/goodmorning` gains a `Stack: N behind — run update.sh` line in the daily
    summary fence (nudge only; omitted when current — never auto-updates,
    respecting the print-and-wait contract).
  - `/project-init` gains an interactive check in step 1a that offers to run
    `update.sh` before initializing when the local install is stale.
  Addresses the gap where local `~/.claude` silently drifts behind `main`
  (web sessions self-install fresh, but local installs are manual).
- **Parallel-mode safety + `dynamic-workflows` orchestration mode**: two
  hardening changes to `/foreman` for the Opus 4.8 experimental
  orchestration features.
  1. *File-ownership / no-overlap rule* — new "Parallel-mode safety"
     subsection in the `/foreman` dispatch protocol (mirrored in the
     `foreman-team-lead` agent). Under `agent-teams`/`hybrid`, only
     read-only roles (reviewer, red-team, security/accessibility-auditor,
     read-only validator) parallelize; writers (implementer, data-engineer)
     stay sequential, and parallel batches must partition by file ownership
     so no two agents edit the same file. `hybrid` reframed as the
     recommended mode: main-thread critical write path + parallel
     review/audit only.
  2. *`dynamic-workflows` mode* — added to the `orchestration_mode` enum in
     `stack-config-schema.json` and to `/foreman` step 2, with a
     "Dynamic-workflows guardrails" subsection: read-only by default,
     mandatory `/cost-gate` before every workflow launch (treated as a
     `pre-bulk-job`), no headless writes, `CLAUDE_CODE_DISABLE_WORKFLOWS=1`
     kill-switch documented, and domain-mode overrides required for
     financial-code / schema-migration / confidential work.
- **Team-status Phase 1.5 — outcome logging**: new `subagent-complete-log.sh`
  PostToolUse Agent hook pairs with the existing PreToolUse dispatch log.
  Each completion row carries `event:"complete"`, success bool, and
  `wall_seconds` (computed against the most recent matching dispatch).
  Pre-existing dispatch rows now carry `event:"dispatch"` explicitly.
  Together these unlock real per-agent metrics in
  `/agent-performance-review`, which has also been pointed at the JSONL log
  (was referencing a non-existent `subagent_runs` table).
- **Token-expiry monitor**: new manifest at
  `~/.claude/state/token-expiry.json` plus
  `scripts/check-token-expiry.sh` (modes: check / --quiet / add). A
  SessionStart hook calls `--quiet` so a fresh session prints a warning
  banner only when a tracked token is within 30 days of expiry, silent
  otherwise. Catches the failure mode where a Supabase PAT silently expires.
- **Dispatch-nudge**: new `dispatch-nudge.sh` UserPromptSubmit hook
  injects a soft system-reminder when a prompt looks like multi-step
  engineering work (build / add / implement / fix / refactor / migrate)
  in a Tier 2+ project but no `/foreman` or `/dispatch` was used. Skips
  slash commands, short prompts (<12 words), and uninitialized projects.
  Targets the habit of routing non-trivial work through the team.
- **Statusline mode chip** (Claude Code CLI only): new `statusline.sh`
  StatusLine hook reads `.claude/stack-config.json` and emits a single-line
  chip — e.g. `🟢 agent-teams · T3 · strict · schema-migration · 🔒sensitive`
  or `⚪ uninit`. Wired in the global settings template. Does not render in
  the Claude Desktop app; the SessionStart banner is the Desktop analogue.
- **SessionStart banner now shows orchestration_mode**. Old format:
  `✅ Stack active — Tier 3 · schema-migration · strict · sensitivity:normal`;
  new format prefixes with mode: `... — main-thread · Tier 3 · ...`.
  Default reads `main-thread`; flips to `agent-teams` or `hybrid` if
  `/agent-teams on|hybrid` was used.
- **Shared runtime lib**: new `lib/find-stack-config.sh` does the
  walk-up + wrapper-fallback resolution to the nearest
  `.claude/stack-config.json`. Used by `statusline.sh` and `dispatch-nudge.sh`;
  available for future hooks that need the same lookup.
- **Team-status instrumentation (Phase 1)**: every subagent dispatch is now
  logged to `~/.claude/logs/subagent-runs.jsonl` via a PreToolUse hook
  matched on the `Agent` tool. Each row carries timestamp, session_start,
  project (git root or cwd), agent, description, and model. Powers a new
  `/team-status` skill (roster + utilization + benched roles over a
  configurable window, with `--global`, `--window`, `--session`, and
  `--replan` modes) and new mini-sections in `/goodmorning` (Team line in
  the summary fence listing benched roles over 14d) and `/handoff`
  (`## Team this session` section with counts and rule-based misses for
  domain-mode-required agents that weren't dispatched). SessionStart hook
  also stamps `~/.claude/state/session-start.txt` so /handoff can compute
  session-scoped counts.
- Global CLAUDE.md now includes a "Session start protocol" directive
  telling the assistant to echo the SessionStart hook banner verbatim
  in its first response. Without this, the ✅/⚠️ banner reached the model
  as system context but was never visible to the user in the Claude Code
  Desktop app — hooks are a context-injection mechanism, not a UI surface.
  Lands in `~/.claude/CLAUDE.md` on next install via the existing
  CLAUDE_CODE_STACK_MANAGED section.
- SessionStart hook now shows a ✅ banner with current settings when a
  repo is initialized — tier, domain mode, strict-mode flag, sensitivity
  level — plus shortcut commands to change any of them (`/tier`,
  `/domain-mode`, `/strict-mode`, `/sensitivity`, `/cost-cap`) and a
  reminder that `/project-init` can be re-run safely. Surfaces the
  per-setting edit skills that were previously hidden.
- SessionStart hook now warns when opening an un-initialized git repo
  (no `.claude/stack-config.json`). Soft, non-blocking — points to
  `/project-init`. Auto-detects the stack source repo itself by structural
  markers (`agents/`, `skills/`, `scripts/install.sh`) so the warn doesn't
  fire on the stack or forks of it. Stays silent in non-git dirs.
- The bottom "── Claude Code Stack ──" multi-line marketing banner is now
  a single-line key-commands footer
  (`/goodmorning · /handoff · /project-init · /budget-guard · /operating`).
  Less noise per session, same discoverability.
- `project-init` discovery pass — before asking the user any questions,
  reads git log, branch state, prior handoffs (`.claude/next_prompt.md`,
  `docs/handoffs/`), package manifests (`package.json`, `pyproject.toml`,
  etc.), README, and any partial `.claude/` setup. Prints a 5-line
  discovery summary and pre-fills tier + domain-mode suggestions based
  on what's actually in the repo. Catches the "ran init on a mature
  in-flight project, got asked cold questions about a stack it could
  have inferred" failure mode.
- `handoff` auto-stages the `docs/handoffs/<timestamp>.md` archive when
  in a git repo, and prints an explicit commit hint. Surfaces the
  archive-vs-live split: archive is sharable with collaborators, live
  `.claude/next_prompt.md` is local-only by design.
- `verify.sh --repo=PATH` — verifies a single repo is correctly onboarded
  onto the stack: `stack-config.json` exists and is valid JSON, `stack_tier`
  is 0–5, `stack_version` is set, and `domain_mode` (if any) is a real mode
  from `config/domain-modes.json`. Soft-warns on missing §11 audit artifacts
  (ADRs, runbooks, ONBOARDING). Complements `--tier=N`, which only checks
  the global install — gives the §11 audit a one-command per-repo health
  check it previously lacked.
- CI now runs the full `tests/` suite in a `unit-tests` job
  (`test-install.yml`). Previously only the per-tier install/verify matrix
  ran — the merger, conflict, and tier-isolation tests were never exercised
  in CI. `test-merger-interactive.sh` (expect-driven) added alongside.

### Changed
- `config-merger.sh` — `merge_json` no longer silently overwrites a user's
  scalar value with the stack's on a conflict. The user's value is kept by
  default; the stack value is applied only on approval — prompted when a
  terminal is present, otherwise (or with `STACK_MERGE_NONINTERACTIVE` set)
  the user value is kept and a `<target>.merge-conflicts` report is written.
  Objects still deep-merge and arrays still concatenate. Makes
  `install.sh --mode=merge` honor its documented "preserves user
  customizations" contract.

### Fixed
- **`brevity-reinforce.sh` was never installed**: the `SessionStart`
  brevity-reinforcement hook was wired into
  `config/settings.global.template.json` but missing from every tier
  manifest's `files.global`, so `install.sh` never copied it to
  `~/.claude/hooks/`. The configured `SessionStart` command pointed at a file
  that did not exist, so the brevity baseline never fired at all — the main
  reason the response style "never happened without constant reminders."
  Registered it (and the new `brevity-drift.sh`) in the tier-0 manifest with
  matching smoke tests. (Same class of bug as the `subagent-log.sh` /
  `statusline.sh` miss below.)
- Tier manifests now correctly register `subagent-log.sh` and
  `statusline.sh`, which the team-status Phase 1 commit (a9406eb) had
  installed into the working copy but never added to `tier-2.json` /
  `tier-0.json` / `settings.global.template.json`. Fresh installs were
  therefore missing the team-utilization features. Backfilled in
  `07e0a93`.
- `scripts/update.sh` was referenced by `docs/MULTI-MACHINE.md` and the repo
  structure docs but never existed. Written: pulls latest, then re-runs
  `install.sh` in merge mode; refuses to run on a dirty working tree.
- `model-routing.json` routed `local-ops` to `ollama/qwen-2.5-coder-7b` — not
  a valid ollama tag, and a model `tier-installer.sh` never pulls. Corrected
  to `ollama/qwen2.5-coder:32b`, the code model the installer actually pulls
  and `HARDWARE.md` recommends.
- `config-merger.sh` `append_stack_section` declared `end_marker` only inside
  the replace branch; the append branch read it unset, aborting any
  `install.sh --mode=merge` of `CLAUDE.md` under `set -u` (the documented
  default + `update.sh` path). Declaration hoisted so both branches see it.
  Surfaced by wiring the test suite into CI.

## [1.1.3] — 2026-05-17

### Added
- `--skip-requirements` flag on `install.sh` — downgrades missing-command /
  missing-Keychain checks to warnings. Lets CI test install mechanics for
  every tier without the external tools (`codex`, `gemini`) the tiers expect.
- Project templates (`PROJECT-CLAUDE`, `PROJECT-ONBOARDING`, `PROJECT-README`)
  now install to `~/.claude/templates/` at Tier 0, so `/project-init` (Tier 1)
  can actually find them.

### Changed
- `stack_version` bumped to `1.1.3` in `stack-config` / `stack-defaults`
  templates and the `project-init` skill.
- `project-init` skill: completed the previously dangling step 6 (CLAUDE.md
  scaffold, docs/ tree, `.gitignore`, suggested commit); step 1 now runs
  `git init` after a single confirmation when the directory is not a repo.
- Tier-0 manifest installs all doc templates; Tier-2 manifest no longer
  redundantly re-installs the ADR/RUNBOOK templates (Tier 2 extends Tier 0).

### Fixed
- CI `test-install.yml` was failing on Tiers 2–4 (`requirement-fail: codex`).
  The workflow now installs with `--skip-requirements`.
- Removed dead `docs/MODEL-STRATEGY.md` link from README — pointed at
  `config/model-routing.json` + ADR-004 instead.
- Deleted duplicate `config/claude.md.repo.template` (byte-identical to
  `templates/PROJECT-CLAUDE.md.template`, which is now canonical).
- `config-merger.sh` `deep_merge` was broken for nested data: jq function
  args are call-by-name filters, so the recursion re-evaluated them against
  the reduce accumulator (`{}[0]` → "cannot index object with number").
  Never surfaced before because a first install `cp`s settings.json; only
  a merge-mode re-install onto an existing file hits the path. Args are now
  bound to `$`-variables. Found re-installing the stack post-1.1.3.
- foreman skill read the wrong stack-config field name (`approval_gates`);
  the schema, template, and all project configs use `required_approvals`.
  Renamed foreman's read to `required_approvals` so tier approval gates are
  actually applied. Also rewrote step 6 so foreman reads
  `domain-modes.json[domain_mode].approval_gates` and applies the domain
  review checkpoints — previously they never fired.

## [1.1.2] — 2026-05-17

### Added
- `/operating` skill — on-demand guide for running Claude Code with the stack.
- `docs/OPERATING.md` — the operating guide (source of truth for `/operating`).
- Session-start stack blurb in `session-start-handoff.sh`: what the stack is,
  the key commands, and a pointer to `/operating`.
- `remoteControlAtStartup: true` default in the Tier-0 global settings template.

### Changed
- Tier-0 manifest installs and smoke-tests the `/operating` skill.

### Notes
- Remote Control auto-enable via `remoteControlAtStartup` is currently buggy
  upstream (anthropics/claude-code#54527, OPEN — the setting does not
  auto-enable on new sessions). The reliable mechanism today is the shell
  alias `claude --remote-control`; the template setting is the correct config
  and becomes a no-op-but-correct default once #54527 lands. The earlier
  `--remote-control` CLI flag request (#39347) and the config-reset bug
  (#29929) are both CLOSED.

## [1.1.1] — 2026-05-16

### Changed
- Corrected model IDs: `llama3.2:8b` → `llama3.1:8b` (Llama 3.2 has no 8B);
  Haiku IDs given dated form; provider prefixes made consistent across
  agent definitions and `model-routing.json`.
- Tier-2 manifest rewritten to the working install format.
- Schemas `002`/`003` (`subagent_runs`, `model_audits`) placed in the
  Supabase `stack` schema for consistency with `cost_log`.

### Added
- Repo-completion pass: ops docs, runbooks, project templates, test suite,
  `.github/` CI workflows, uninstall + audit-repos scripts.
- ADR-011 (OpenAI-family review via the local Codex CLI) and ADR-012
  (Gemini-family review via the local Gemini CLI).
- `docs/AUDIT-PASS.md` — the retroactive per-repo audit plan.

### Notes
- The stack was rolled out to every repo in the rollout (Tiers 1–5), one PR per
  repo. Each repo gained `.claude/stack-config.json`, retroactive ADRs,
  runbooks, `docs/ONBOARDING.md`, and a cross-repo data-flow doc. That
  rollout is tracked in each repo's `docs/handoffs/`, not here.

## [1.0.0] — 2026-05-15

### Added
- Initial stack release: Tiers 0-5
- 21 subagent definitions
- 15 skills
- 6 hooks
- Multi-provider model routing (Anthropic, OpenAI, Google, Ollama)
- Self-improvement skills (model-audit, agent-performance-review)
- Per-project tier selection via /project-init
- Strict mode foreman orchestration
- Apache 2.0 license
- 8 initial ADRs

### Notes
- Tier 4 self-improvement requires 30 days of subagent_runs data to be meaningful
- Phase 2 (Claude Code Plugin distribution) deferred until v1 proven across the maintainer's production repos
