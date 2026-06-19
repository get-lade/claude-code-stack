# Next-session handoff

_Written: 2026-06-19 (ADR-017 implementation session)_

## Resume prompt
> "Continue ADR-017 — build slice C (/config router), then wire slices into install."

## Branch & state
- Branch: `chore/tier-4-bump` — **4 commits ahead of `main`, not yet pushed** (sandbox cannot push `main` or open PRs).
  1. `22ea21c` chore: bump dogfood project to Tier 4
  2. `fc03e36` docs(adr): accept ADR-017
  3. `d0aaf3b` feat: slice 1 — registry + engine + /suggest
  4. `53e313a` feat: slice B — passive_suggest folded into dispatch-nudge
- Working tree clean except untracked local artifacts under `.claude/sessions/` + `.claude/reviews/` (gitignored — keep local).
- **First action next session:** push `chore/tier-4-bump` and open a PR to `main` (this is the human/desktop step; sandbox can't).

## What shipped this session
- **Tier 2→4** on the dogfood repo (`.claude/stack-config.json`) + global `default_tier=4` (`~/.claude/stack-defaults.json`).
- **ADR-017 accepted** (`docs/ADRs/017-capability-recommender.md`) — full cross-model plan: product-critic + reviewer (Codex) ∥ red-team (Gemini), review-handoff APPROVE.
- **Slice 1**: `scripts/gen-capability-registry.sh` (python3 stdlib, `--check` freshness gate), committed `config/capability-registry.json` (57 caps), `skills/recommend-capabilities/` engine, `skills/suggest/`. Codex review fixes folded in.
- **Slice B**: `passive_suggest` folded into `hooks/dispatch-nudge.sh` (session-scoped dedupe, fail-open, cloud project-layer fallback, jq `//`-false-collapse avoided) + `hooks/session-prefs-init.sh`, both schemas, `templates/stack-defaults.template.json`, `/session` menu, new `tests/test-session-prefs-parity.sh`. All 9 test files pass.

## Exact next steps
1. **Push branch + open PR** (human step). Verify CI.
2. **Slice C — `/config` router** (`skills/config/SKILL.md`), per ADR-017 Feature C:
   - 4 ops: show-current (redact `providers`), recommended-changes (engine `mode:settings`), change-one-setting (route to owning skill), guided-setup-by-goal.
   - op4 constrained: hardcoded goal→recipe table + allowlist + **denylist** (`required_approvals`, cost caps, `providers`/secrets) + mandatory per-change confirm.
   - Single front door: add deprecation/forwarding notices to `/default-settings` + `/default-edit`.
   - Engine `mode:settings` needs its full spec written (currently stubbed in `skills/recommend-capabilities/SKILL.md`).
   - Mark `config` non-recommendable (generator already excludes it; add `recommendable: false` frontmatter to be explicit) and regenerate the registry.
3. **Install wiring** (so /suggest + /config actually ship): add the 3 new skills to a tier manifest (`config/tier-manifests/tier-2.json`, tier_min 2); add the committed registry to the manifest file-copy; add a CI/pre-commit **freshness hook** running `scripts/gen-capability-registry.sh --check`.
4. Regenerate registry after adding `/config`; run `--check`; run full test suite; cross-model reviewer pass on slice C; then scribe + review-handoff.

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
