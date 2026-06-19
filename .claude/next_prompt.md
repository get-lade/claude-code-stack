# Next-session handoff

_Written: 2026-06-19 (ADR-017 implementation session)_

## Resume prompt
> "Push chore/tier-4-bump + PR; then build ADR-018 (Setup Dashboard: rename /config→/stack-config + native-settings-edit)."

## TOP PRIORITY NEXT SESSION — build ADR-018 (Setup Dashboard)
ADR-017 Feature C (`/config`) was a scope miss: the user wanted a control panel over ALL Claude Code settings, not just the stack's 13. Re-planned as **[ADR-018](docs/ADRs/018-settings-dashboard.md)** (Accepted) — build deferred to next session. Cross-model: product-critic (Codex) + red-team (Gemini, BLOCKED the first design on 3 native-write RCE vectors → 10 fixes folded into a 12-item security contract).
- **Rename** `/config` → `/stack-config` (cede `/config` to Claude Code's built-in); old path becomes a `model-invocable:false` forwarding stub.
- **New skill `native-settings-edit`** = the ONLY writer of native `settings.json`. MUST implement all 12 contract items (set-at-path not merge; RFC-6901 pointers; per-path value schema; audited statusLine preset constant; `--dry-run`; atomic write + flock; cloud-gate inside the tool; default scope=project + `--confirm-global`; hard-refuse hooks/env/permissions; sanitized errors). **Do not ship a partial implementation — partial = the RCE vectors reopen.**
- Dashboard = read-first, 3 row states ([edit]/[review]/[native]); safe-write allowlist only (model, outputStyle, statusLine preset, plugin/MCP enable-disable); hooks/env/permissions read-only or diff-only; cloud read-only.
- Follow ADR-018 §Migration (9 ordered steps): git mv, stub, new writer, manifest repoint + new entries + smoke tests, registry regen + `--check`, ADR-017 supersede note (done), update /default-settings + /default-edit forwarding, repo-wide `grep '/config\b'` reclassify.
- After build: validator + cross-model reviewer (Codex) + a fresh red-team (Gemini) pass on the native writer, then scribe + review-handoff.

## Branch & state — ADR-017 COMPLETE
- Branch: `chore/tier-4-bump` — **8 commits ahead of `main`, not yet pushed** (sandbox cannot push `main` or open PRs).
  1. `22ea21c` chore: bump dogfood project to Tier 4
  2. `fc03e36` docs(adr): accept ADR-017
  3. `d0aaf3b` feat: slice 1 — registry + engine + /suggest
  4. `53e313a` feat: slice B — passive_suggest folded into dispatch-nudge
  5. `24c8cb8` feat: slice C — /config router + engine mode:settings
  6. `32beffa` feat: install wiring — manifest + registry copy + CI freshness
  7–8. docs(handoff) updates
- Working tree clean except untracked local artifacts under `.claude/sessions/` + `.claude/reviews/` (gitignored — keep local).
- **First action next session:** push `chore/tier-4-bump` and open a PR to `main` (this is the human/desktop step; sandbox can't).

## What shipped this session
- **Tier 2→4** on the dogfood repo (`.claude/stack-config.json`) + global `default_tier=4` (`~/.claude/stack-defaults.json`).
- **ADR-017 accepted** (`docs/ADRs/017-capability-recommender.md`) — full cross-model plan: product-critic + reviewer (Codex) ∥ red-team (Gemini), review-handoff APPROVE.
- **Slice 1**: `scripts/gen-capability-registry.sh` (python3 stdlib, `--check` freshness gate), committed `config/capability-registry.json` (57 caps), `skills/recommend-capabilities/` engine, `skills/suggest/`. Codex review fixes folded in.
- **Slice B**: `passive_suggest` folded into `hooks/dispatch-nudge.sh` (session-scoped dedupe, fail-open, cloud project-layer fallback, jq `//`-false-collapse avoided) + `hooks/session-prefs-init.sh`, both schemas, `templates/stack-defaults.template.json`, `/session` menu, new `tests/test-session-prefs-parity.sh`. All 9 test files pass.
- **Slice C**: `skills/config/` router (4 ops, hardcoded goal recipes, allowlist/denylist, secret redaction, routes all mutations through owning skills) + engine `mode:settings` spec + `/default-settings`/`/default-edit` deprecation notices. Codex review closed the mutation-abuse bypasses (denylist self-enforced at the /config boundary; engine no longer routes via generic `default-edit`; recipe arg + redaction fixed). 58-cap registry, `--check` green, all tests pass.

## Exact next steps (implementation COMPLETE — these are human/verify steps)
1. **Push `chore/tier-4-bump` + open a PR to `main`** (sandbox can't). Verify both CI jobs go green: `lint-skills` (now includes the registry freshness check) and `test-install` (tier 0–4 matrix incl. the new tier-2 manifest entries).
2. **Run `scripts/update.sh`** on each machine to install the 3 new skills + registry into `~/.claude` (this dogfood session edited repo files only; the global skills aren't live until update.sh runs).
3. Smoke-test live: invoke `/suggest` on a real task; toggle `passive_suggest` off via `/session` and confirm the nudge pointer disappears; run `/config` show-current and confirm the providers block is redacted.
4. Optional: a cross-model reviewer pass on the wiring commit (manifest/CI/path change — low risk, already validated: manifest well-formed, all from-paths exist, registry `--check` green, 9/9 tests pass).

## Known out-of-scope (pre-existing, not ADR-017)
- `/default-edit` remains a direct unrestricted config editor (its purpose). `/config` no longer routes to it; deprecation notice steers users to `/config`. Locking down direct `/default-edit` use is a separate hardening effort.
- Several setting-skills (`/strict-mode`, `/sensitivity`, `/domain-mode`, `/cost-cap`, `/agent-teams`) apply on selection without a second confirm — `/config`'s own selection step is the consent gate for op2/op4; op3 is explicit user intent. Adding universal pre-write confirms to those skills is a separate change.

## Deferred minor items (from slice-1 reviewer, capture during slice C / wiring)
- `gen-capability-registry.sh` parser is python3 stdlib (dev-time dep; registry is committed so no install-time dep).
- `/suggest` "thread-scoped" de-dup of repeated suggestions is unspecified (only the hook dedupes).
- Trigger disambiguation between `claude-automation-recommender` (external scope) and `recommend-capabilities` (installed-stack scope) — not yet spelled out in frontmatter.
- `dispatch-nudge.sh` TOCTOU (check-then-touch) within one session — worst case a rare double-nudge; left as-is.
- `tests/test-session-prefs-parity.sh` grep of the BUILTIN line is column-0/quote-fragile (nit).

## Gotchas
- **Sandbox cannot push `main` or open PRs** — feature-branch push + PR is the human step.
- **Cross-model egress is OPEN**: `codex` AND `gemini` on PATH, both keys set. Use the real roster cross-model passes (Codex for reviewer/security-auditor/product-critic; Gemini for red-team/architecture-critic). Do NOT silently substitute Claude-only.
- Registry has a `generated_at` timestamp → never freshness-check via `git diff`; use `gen-capability-registry.sh --check` (strips the timestamp).
- This is the stack **source** repo (dogfoods Tier 4). Skills/hooks/agents are global (`~/.claude`), reached via `scripts/update.sh` per machine — but this work changes only repo files.
- `passive_suggest` opt-out is fail-OPEN by maintainer decision (a wiped session-state re-enables nudging); consent caveat documented in ADR-017 + `/session`.

## Team this session
- Used: product-critic, architect, reviewer (Codex ×3), red-team (Gemini), validator (×2), implementer (×2). All cross-model passes ran (egress confirmed open).
- Benched: data-engineer, integration-specialist, incident-commander, designer, documenter, ops, historian, librarian, estimator, accessibility-auditor, performance-engineer, security-auditor, tester (no durable test suite written beyond the parity test — consider `tester` for slice C).
