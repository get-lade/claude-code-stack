# Loop-Engineering Control Plane — Phase 3 Implementation Plan

> **STATUS: PROPOSED.** Phases 1 (ADR-019/020, PR #37) and 2 (PR #42) are shipped.
> Phase 3 is "observability + smarter control + authoring path." Precursor ADR:
> **ADR-022** (loop-engineering Phase 3) — authored in Task 0.

> **For agentic workers:** TDD task-by-task. Steps use checkbox (`- [ ]`) syntax.
> Each task = test → fail → implement → pass → commit. Bash + `jq` + the existing
> `tests/test-*.sh` harness; JSON Schema Draft-7; Supabase SQL matching `schemas/`.

**Goal:** turn the Phase-2 telemetry into a feedback loop, tighten the live cost
halt with a real token signal, make the design-gate per-feature, add the effort
dial + dashboard wiring, vendor the superpowers authoring half, and finish the
durable-corrections guardrail (spec §6.7). Net: loops that *learn* from their own
run history and a design-gate that is precise rather than coarse.

**Scope (the six items from the roadmap):**
- (T1) **Telemetry → feedback loop**: `/loop-review` + cap-calibration from `loop_runs`.
- (T2) **Real token-cost signal**: live monitor reads actual per-tool/per-subagent token cost.
- (T3) **Per-path design-gate marker**: replace ADR-021's session-wide approval.
- (T4) **5-point effort enum**: widen `fast/balanced/max`, wire ADR-018 dashboard + readers.
- (T5) **Vendor `using-superpowers` + brainstorming (text core)**: the authoring path the gate enforces.
- (T6) **Durable corrections**: loop mistakes append to CLAUDE.md / memory, wired to `/handoff`.

**Non-goals:** ToT/GoT/Self-Consistency patterns (spec §4, out of scope); vendoring
the brainstorming visual-companion Node server (text core only); changing the
Phase-1/2 enforcement contracts (Stop-hook, deny shape) — Phase 3 builds *on* them.

---

## Task 0 — ADR-022 (Phase 3 decisions)

**Files:** new `docs/ADRs/022-loop-engineering-phase3.md`.

Record the cross-cutting decisions that the tasks below assume:
- Telemetry is the **source of truth for cap calibration** — caps become
  data-informed defaults, never silently auto-applied (human approves a bump).
- The live cost signal is **best-effort**: when a real token count is
  unavailable (no usage in the hook payload), fall back to the Phase-2 logged-row
  sum — never crash, never block on missing data.
- The design-gate marker moves from **session-scoped** → **path-scoped**;
  session-wide remains as a fallback for back-compat.
- Effort enum widening is **additive** — old `fast/balanced/max` values keep
  working (mapped onto the new 5-point scale).

- [ ] Write ADR-022 with Context / Decision / Consequences / Alternatives.
- [ ] Commit.

---

## Task 1 — telemetry feedback loop (`/loop-review` + calibration)

**Files:** new `skills/loop-review/SKILL.md`; new lib fns in
`skills/loop-engineer/loop_lib.sh` (`loop_stats`, `loop_calibrate`); new
`schemas/004-loop-runs.sql` view (extend); test.

`loop_stats` reads the local `loop-runs.jsonl` (and Supabase view when present)
and computes per-pattern: run count, met %, budget_exceeded %, iter-cap %,
p50/p95 iterations, avg cost. `loop_calibrate` proposes a `loop_policy` bump
(e.g. `max_iterations := ceil(p95 * 1.2)`) but **only prints** it — applying is a
human step via `/stack-config`. `/loop-review` renders the table + the proposal.

- [ ] Tests: `loop_stats` aggregates a seeded JSONL correctly (counts, p95);
      `loop_calibrate` proposes a value strictly ≥ observed p95 and never auto-writes
      stack-config; empty history → graceful "no data".
- [ ] Implement lib fns + `/loop-review` skill + tier-2 manifest entry + smoke test.
- [ ] Pass + commit.

## Task 2 — real token-cost signal for the live monitor

**Files:** modify `hooks/loop-cost-monitor.sh`; modify
`hooks/subagent-complete-log.sh` (ensure per-call cost lands in the log with a
`ts` + `loop_id`); new `loop_lib.sh` helper `loop_cost_from_usage`; test.

The Phase-2 monitor sums logged rows. Phase 3: when the PreToolUse/PostToolUse
payload carries token usage (input/output/cache), convert it to USD via the
model price table and accrue it immediately — closing the lag between a costly
call and the next logged row. Fall back to the logged-row sum when usage is
absent. Fail-open unchanged.

- [ ] Tests: payload with usage → cost computed from tokens (matches price table);
      payload without usage → falls back to logged sum; unknown model → fallback,
      no crash; over-budget still denies + marks `budget_exceeded`.
- [ ] Implement helper + monitor wiring + reuse the existing price table (locate
      via `config/` — reuse, do not duplicate).
- [ ] Pass + commit.

## Task 3 — per-path design-gate marker

**Files:** modify `hooks/design-gate.sh`; modify `skills/plan/SKILL.md` (write a
path-scoped marker); modify `skills/loop-engineer/SKILL.md` (same); test.

Today the marker is one session-wide `design-approved.json` (`{active:true}`).
Phase 3: the marker carries an `approved_paths` array (globs). The gate allows a
source edit when the target matches an approved glob; the bare `{active:true}`
still allows everything (back-compat). `/plan` writes the glob(s) for the feature
it just planned.

- [ ] Tests: marker with `approved_paths:["skills/foo/**"]` → edit to
      `skills/foo/bar.sh` allowed, edit to `skills/other/x.sh` still denied;
      legacy `{active:true}` → all source allowed (back-compat); ultracode-off →
      allow always (unchanged).
- [ ] Implement gate match logic + `/plan` + `/loop-engineer` marker writers.
- [ ] Pass + commit.

## Task 4 — 5-point effort enum + ADR-018 dashboard wiring

**Files:** modify `schemas/stack-config-schema.json` (effort enum); modify the
effort reader(s) + `/stack-config` (ADR-018) dashboard; migration note for the
old 3-value form; test.

Widen `fast | balanced | max` → `minimal | fast | balanced | thorough | max`
(names TBD in ADR-022). Old values map onto the new scale
(`fast→fast`, `balanced→balanced`, `max→max`); readers accept both. Surface the
new dial in the `/stack-config` dashboard.

- [ ] Tests: schema validates all 5 new values + the 3 legacy values; reader maps
      legacy → new; dashboard lists the 5 options; default unchanged per tier table.
- [ ] Implement schema + reader mapping + dashboard option + back-compat.
- [ ] Pass + commit.

## Task 5 — vendor `using-superpowers` + brainstorming (text core)

**Files:** new `skills/using-superpowers/SKILL.md` (+ supporting refs); new
`skills/brainstorming/SKILL.md` (text core only — **drop** the visual-companion
Node server); tier-manifest entries; capability-registry regen; test.

This is the **authoring path** the ADR-021 gate enforces: the user runs
brainstorming → `/plan` → approved marker → code. Vendor at Tier 0/1 so it is
present everywhere the gate can fire. Cloud-compatible (no Node server, no
`[P]`/`[N]` hard deps).

- [ ] Tests: both SKILL.md present with valid frontmatter; no reference to the
      dropped Node server; capability-registry fresh; install copies them.
- [ ] Implement skills + manifest + `gen-capability-registry.sh` + smoke tests.
- [ ] Pass + commit.

## Task 6 — durable corrections wired to `/handoff`

**Files:** new `loop_lib.sh` fn `loop_record_correction`; modify
`hooks/loop-stop.sh` (capture a correction note on `no_progress`/`escalated`
exits); modify `skills/handoff/SKILL.md` (surface accumulated corrections); test.

Spec §6.7: loop mistakes should compound into fixes. When a loop exits
`no_progress` or `escalated`, append a structured note (loop_id, status, last
goal, hint) to `session-state/loop-corrections.jsonl`; `/handoff` folds unresolved
corrections into the next-session doc so the lesson carries forward.

- [ ] Tests: `loop_record_correction` appends a well-formed row; Stop-hook writes
      one on `no_progress` exit and none on `met`; `/handoff` reads them.
- [ ] Implement fn + Stop-hook wiring + handoff surfacing.
- [ ] Pass + commit.

---

## Final verification

- [ ] `bash tests/test-loop-engineering.sh` → FAIL=0 (plus any new `test-loop-review.sh`).
- [ ] JSON validity across touched `hooks.json`, schema, manifests, settings template.
- [ ] `bash scripts/gen-capability-registry.sh --check` → fresh (new skills).
- [ ] Dry-run installs tier-1/2/3 → "All checks passed."
- [ ] Full repo `tests/test-*.sh` suite green.
- [ ] Docs: ADR-022 accepted; spec §11 gains a Phase-3 SHIPPED line; ADR-019
      "Phase 2 status" note extended.

## Open questions (resolve in ADR-022)

1. Effort enum names (5-point) and the exact legacy→new mapping.
2. Calibration formula + whether `/loop-review` may *offer* to write via
   `/stack-config` (with confirm) or print-only.
3. Token price table location — confirm the single source of truth to reuse
   (cost-log / model-routing) rather than duplicating.
4. Path-marker glob syntax (shell glob vs. gitignore-style) + how `/plan` infers
   the feature's path set.
