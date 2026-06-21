# Loop-Engineering Control Plane — Phase 2 + ADR-021 Implementation Plan

> **STATUS: COMPLETE (PR #42).** All tasks T1–T7 shipped; 118 loop tests + full
> repo suite green; tier-2 (98/0) and tier-3 (105/0) installs pass. The checkbox
> steps below are the as-built record.

> **For agentic workers:** TDD task-by-task. Steps use checkbox (`- [ ]`) syntax. Each task = test → fail → implement → pass → commit.

**Goal:** Close every stated Phase-1 residual and ship Phase-2 of the loop-engineering control plane (spec `docs/superpowers/specs/2026-06-20-loop-engineering-design.md` §11), plus the sibling **ADR-021** superpowers design-before-code gate (spec §10, renumbered from ADR-020 which became per-session-loop-state).

**Scope (from spec §9/§11 residuals + §38 Phase-2 row + open question 1):**
- Phase-1 residual (a) irreversible-deny wrapper-stripping — **already shipped** via ADR-007 (`hooks/irreversible-deny.sh`). No work.
- (T1) Phase-2 (d): no-progress hash must include **untracked-file byte-contents**, not just names.
- (T2) Phase-2 (c): **recursion-depth enforcement** — `max_recursion_depth` becomes a hard bound (was advisory).
- (T3) Open Q1: the **ultracode signal** — config flag + detection + ceiling-lift (+1 level, cap `bounded-autonomous`). Needed by ADR-019 ceiling-lift and ADR-021 gate.
- (T4) Phase-2 (b): **live mid-flight cost monitor** — PreToolUse halt when in-iteration cost crosses `per_run_budget_usd` (closes the within-iteration runaway gap).
- (T5) Phase-2: **Supabase `loop_runs`** telemetry (Tier 3+) — schema + graceful no-op writer + install apply.
- (T6) **ADR-021**: superpowers design-before-code gate — `Edit|Write` deny-until-spec PreToolUse hook, tier+ultracode gated, reuses the §3 governance-hooks base. ADR doc + hook + registration.
- (T7) Docs: ADR-019 + spec status updates marking Phase-2 shipped; ADR for ultracode folded into ADR-019 update.

**Tech stack:** bash + `jq` (lib/hooks), JSON Schema Draft-7, Supabase SQL (matches `schemas/001-cost-log.sql`), existing `tests/test-*.sh` harness.

**Non-goals (explicit, per spec §11/§158):** 5-point effort-enum widening (keep `fast/balanced/max`); vendoring `[P]` pattern targets (graceful-degrade stays).

---

## Task 1 — no-progress hash includes untracked-file contents

**Files:** modify `skills/loop-engineer/loop_lib.sh`; test `tests/test-loop-engineering.sh`.

`loop_state_hash` currently hashes `HEAD + diff HEAD + status --porcelain`. Porcelain lists untracked **names** only. Add the byte-contents of untracked, non-ignored files so a loop editing an untracked file is seen as progress.

- [ ] Test: create git repo, add untracked file `u`, hash; change `u`'s contents (still untracked); hash must differ.
- [ ] Implement: append `git ls-files --others --exclude-standard -z | xargs -0 cat` (size-bounded, fail-safe) into the hash stream.
- [ ] Pass + commit.

## Task 2 — recursion-depth becomes a hard bound

**Files:** modify `loop_lib.sh` (`loop_check_bounds`); test.

State carries `recursion_depth` (caller-incremented on fan-out); bound is `bounds.max_recursion_depth`. `loop_check_bounds` returns `max_recursion_depth` when `recursion_depth >= max_recursion_depth`.

- [ ] Tests: depth over cap → `max_recursion_depth`; depth within → `ok`; missing fields → `ok` (back-compat).
- [ ] Implement: integer-validate then check, placed before the iteration check.
- [ ] Pass + commit.

## Task 3 — ultracode signal + ceiling-lift

**Files:** new `skills/loop-engineer/loop_lib.sh` fns; new `skills/ultracode/SKILL.md`; modify `schemas/stack-config-schema.json`; test.

- Detection: `loop_ultracode_active` → true iff env `CLAUDE_ULTRACODE` ∈ {1,true,on} OR session-state `ultracode-state.json` `{"active":true}`. Fail-safe false.
- Ceiling math: `loop_effective_ceiling <tier_ceiling> <ultracode_bool>` → raise one level (`checkpoint`→`bounded-checkpoint`→`bounded-autonomous`), cap `bounded-autonomous`.
- `/ultracode on|off|status` skill writes/reads the session-state flag (reuses governance session-state contract).
- Schema: no stack-config change required (ultracode is session-scoped, not persisted policy) — document in skill.

- [ ] Tests: detection from env + state; ceiling-lift each level + cap; off = identity.
- [ ] Implement lib + skill.
- [ ] Pass + commit.

## Task 4 — live mid-flight cost monitor

**Files:** new `hooks/loop-cost-monitor.sh` (PreToolUse Bash); register in `config/settings.team.template.json` + `hooks/hooks.json`; manifest tier-2; test.

During an active loop, on each PreToolUse it sums cost rows in `subagent-runs.jsonl` since `started_at` for this `loop_id`, adds `cost_so_far_usd`, and if `>= per_run_budget_usd` emits `permissionDecision:deny` with an over-budget reason and marks state `status=budget_exceeded`. Outside a loop / no budget → silent. Fail-open (never crash the tool). Reuses the irreversible-deny structure.

- [ ] Tests: over-budget → deny + status set; under-budget → allow; no active loop → allow.
- [ ] Implement hook + lib helper `loop_live_cost <loop_id> <started_at>`.
- [ ] Register + manifest + pass + commit.

## Task 5 — Supabase `loop_runs` telemetry (Tier 3+)

**Files:** new `schemas/004-loop-runs.sql`; lib `loop_runs_record`; call from Stop-hook on terminal status; install apply; test.

`loop_runs` columns: id, created_at, loop_id, pattern, autonomy, goal, status, iterations, cost_usd, started_at, ended_at, project_slug, session_id. `loop_runs_record` POSTs via PostgREST if `SUPABASE_URL`+`SUPABASE_SERVICE_KEY` set; **no-op otherwise** (matches cost-log). Stop-hook calls it once when it marks a terminal status.

- [ ] Tests: SQL is valid (psql-less: `grep` columns + balanced parens check already used by 001 test if any); `loop_runs_record` no-ops without creds (rc 0, no crash); builds correct JSON payload.
- [ ] Implement SQL + lib + Stop-hook wiring + install apply line.
- [ ] Pass + commit.

## Task 6 — ADR-021 superpowers design-before-code gate

**Files:** new `docs/ADRs/021-superpowers-design-gate.md`; new `hooks/design-gate.sh` (PreToolUse `Edit|Write`); register; manifest; test.

Gate: when ultracode-on AND tier ≥ configured floor AND the target is source (not docs/tests/config), deny `Edit|Write` unless a spec/plan exists for the work (a `docs/superpowers/specs/*` or `docs/superpowers/plans/*` file, or an ADR). Reconcile with `/plan`: the gate **wraps** `/plan` (gate is the enforcement, `/plan` is the authoring path) — see ADR-021 decision. Reuses §3 governance base (session-state read, deny pattern, registration). Conservative default: **off** unless ultracode-on (so it never blocks normal work).

- [ ] Tests: ultracode-off → allow always; ultracode-on + no spec + source file → deny; ultracode-on + spec present → allow; docs/test target → allow.
- [ ] Implement ADR + hook + registration + manifest.
- [ ] Pass + commit.

## Task 7 — docs: mark Phase 2 shipped

**Files:** modify `docs/ADRs/019-loop-engineering-control-plane.md` (Phase-2 status + ultracode decision); modify spec status line; add Phase-2 entry to any roadmap.

- [ ] Update ADR-019 status table rows (loop_runs, live monitor, ultracode, recursion enforcement → shipped).
- [ ] Update spec §9/§11 residual notes (d)(c) → resolved; (b) → live monitor shipped.
- [ ] Commit.

## Final verification

- [ ] `bash tests/test-loop-engineering.sh` → FAIL=0.
- [ ] JSON validity: `for f in hooks/hooks.json schemas/stack-config-schema.json config/tier-manifests/tier-2.json config/settings.team.template.json; do jq empty "$f" || echo BAD:$f; done`.
- [ ] `for f in schemas/*.sql; do :; done` syntax sanity (balanced parens / `create table`).
- [ ] Dry-run install: `HOME=$(mktemp -d) bash scripts/install.sh --tier=2 --skip-requirements` ends "All checks passed."
- [ ] Full repo suite: run every `tests/test-*.sh`, all green.
