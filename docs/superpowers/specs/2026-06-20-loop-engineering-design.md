# Design Spec — Loop-Engineering Control Plane

**Status:** Proposed (precursor to ADR-019; sibling ADR-020 for the superpowers gate)
**Version:** v2 (folds adversarial review `w1kckn9h3` — grounding + quality fixes)
**Intent:** **Flagship capability** — a deliberate stack investment, not a measured-need utility. Cost-justification does not gate it; instrumentation runs *alongside*, not first.
**Date:** 2026-06-20
**Author:** the maintainer + Claude (Opus 4.8)
**Brainstormed from:** context maps `wwcuppan1` / `wvs3clz24`, research `wepos5wi1` (Boris Cherny + agentic-loop literature), review `w1kckn9h3`.

---

## 1. Context / Problem

The stack has loop *primitives* scattered and ungoverned. There is no unifying model, no shared bounds, and no routing — a user can't reach for "the right loop," and an autonomous loop has no enforced budget/iteration/recursion cap. The 1.7M-token runaway (ADR-008) is the documented failure this leaves open.

Boris Cherny (Head of Claude Code) frames the end-state as **"loop engineering"**: *"my job is to write loops"* — programs that discover work, prompt Claude, read output, decide done, re-prompt. This spec makes loop engineering a **first-class, governed capability** deployed to every repo.

## 2. Decision (the spine)

1. **Control plane ABOVE foreman.** `loop-eng(foreman(dispatch))`. Looping is control-plane; foreman is work-plane (one-shot, stateless across dispatches). **The control plane — not foreman — owns budget/iteration/recursion caps** (a control-plane→foreman→subagent chain is the 10×-cost shape).
2. **Enforcement = two hooks + state + config:** a **pre-flight gate** (start-time validation, in the skill / a PreToolUse hook), a **Stop-hook** (mid-flight + exit-time only — Stop hooks *cannot* refuse to start), `session-state/loop-state.json`, and a `loop_policy` block in stack-config.
3. **Pattern-pluggable, routed by task-shape — foreman owns routing.** foreman infers the pattern and writes it to `loop-state.json`; `/loop-engineer` reads the pattern and writes goal + policy ceiling. Routing emits a **visible `pattern selected: X (why)`** line; unknown shape → fall back to ReAct.
4. **Autonomy = tier+ultracode-scaled ceiling, safe default.** Default = conservative `checkpoint` floor everywhere; **tier raises the ceiling, not the default**; **ultracode-on lifts the ceiling one level above the tier default (capped at `bounded-autonomous`)** — additive, not a synonym for Tier 4. Risk dial.
5. **Thinking effort = tier-scaled DEFAULT**, mapped to the **live `fast/balanced/max` enum** (cost dial; the deliberate exception to tier-independent defaults).
6. **Verification gating, scoped honestly.** `require_external_termination` is **required only for unattended (`bounded-autonomous`) loops** and recommended for `checkpoint` loops — not a blanket default. (Blanket-required blocks refactors/docs that have no machine-check, and users respond by disabling the hook = governance theater.)

## 3. Architecture

| Layer | Owns | Mechanism | Status |
|---|---|---|---|
| `/loop-engineer` skill | front door: write goal + ceiling; **pre-flight validate** (termination + ≥1 bound) before first dispatch; read foreman's pattern | new skill (vendored) | new |
| `loop_policy` (stack-config) | tier-scaled ceilings + safe defaults | JSON block (§5) | new |
| **pre-flight gate** | refuse to *start* a loop missing termination/bound | skill check + optional `hooks/loop-preflight.sh` (PreToolUse) | new |
| **Stop-hook** | per-stop: met? bounds ok? progress? → block / release / escalate | `hooks/loop-stop.sh` (Stop), committed in `.claude/settings.json` | new |
| **irreversible-deny** | block deploy/push/merge/bulk-write/`rm -rf` mid-loop | `hooks/irreversible-deny.sh` (PreToolUse), red-team-tuned | new |
| `session-state/loop-state.json` | runtime: iteration, cost-so-far, pattern, status | session-state file | new |
| foreman (loop-aware) | infer task-shape→pattern; write pattern + emit success criterion + bound | edit `foreman/SKILL.md` | edit |
| **[Phase 2]** `loop_runs` (Tier 3+) · live cost monitor · telemetry · ultracode signal | observability + mid-flight halt | Supabase + hook | new |

**Touched artifacts (deliverables):** `schemas/stack-config-schema.json` (add `loop_policy`; top-level is `additionalProperties:false`, so the schema MUST be amended or the block is rejected), `templates/stack-config.template.json`, `/stack-config` + `/project-init` writers, the 3 new hooks, `foreman/SKILL.md`, the new skill, `config/settings.team.template.json` (register hooks).

**Shared governance-hooks base (owned by ADR-019; ADR-020 consumes):** the common substrate is (a) the `session-state/` read/write contract, (b) the PreToolUse `permissionDecision: deny` pattern, and (c) hook registration in `config/settings.*.template.json`. ADR-019 defines it; ADR-020's `Edit|Write` design-gate reuses it.

**Flow:** goal → skill pre-flight validates + writes `loop-state` + reads `loop_policy` ceiling → foreman infers pattern, writes it, dispatches per round (state to files; commit only if opted-in) → **Stop-hook gates each stop** (termination met? bounds remaining? progress?) → continue / release / escalate.

**Rejected:** *inside foreman* (duplicates orchestration; caps sit below the recursion layer); *as a subagent* (can't control the outer Stop).

## 4. Loop Pattern Catalog

Provenance tags: **[S]** vendored stack skill · **[P]** plugin · **[N]** native/platform. The control plane **must degrade gracefully** when a [P]/[N] target is unavailable (esp. cloud) — never hard-depend.

| Pattern | Termination | Strict-mode | When | Maps to |
|---|---|---|---|---|
| ReAct | final answer / iter cap | iter-cap only* | default multi-step | implicit (every subagent) |
| Reflexion | external success / max trials | ✓ external | retry-heavy debug w/ signal | review-handoff **[S]** |
| Self-Refine | critic "good enough" / ~4 | iter-cap only* | polish one artifact | polish **[P]** |
| Generator–Critic | independent critic / ~3–5 | ✓ external | quality w/ blind spots | review-handoff **[S]**, critique **[P]** |
| Plan-and-Execute | steps done / replan tol | ✓ external | known-structure multi-step | plan **[S]**, foreman **[S]** |
| Ralph (Wiggum) | external check / iter cap | ✓ external | long unattended refactor | ralph-loop **[P]**, /loop **[N]**, worktree-fanout **[P]** |
| Eval-driven | eval target + regression + human | ✓ external | improve skill/agent/prompt | eval-bump **[S]**, worktree-fanout **[P]** |
| Subagent fan-out | all verified / orchestrator budget | ✓ external | parallel, context-isolated | foreman/agent-teams/dispatch **[S]** |
| Stop-hook self-loop | `stop_hook_active` / `{"continue":false}` | ✓ external | deterministic in-session | this spec |
| /goal evaluator | NL condition judged | iter-cap only* | ad-hoc session gating | /goal **[N]** |
| Scheduled Routines | schedule tick / trigger | ✓ external | recurring, survives laptop-off | /schedule **[N]** |
| ToT/GoT/Self-Consistency | evaluator / N-vote | — | pure reasoning | **out of scope** |

\* *Self-assessment patterns: when `require_external_termination=true` the Stop-hook downgrades them to **iteration-cap-only** (won't accept the agent's "done").*

Routing (foreman): long refactor→Ralph · skill improvement→Eval-driven · review gate→Generator-Critic · recurring→Scheduled · ad-hoc completion→/goal · else→ReAct. **Tiebreak:** most-specific shape wins; ties → ReAct + log. Every route logs `pattern selected: X (why)`.

## 5. `loop_policy` schema (stack-config)

```jsonc
"loop_policy": {
  "enabled": true,
  "default_autonomy": "checkpoint",       // safe floor (risk dial)
  "autonomy_ceiling": "checkpoint",        // raised by tier; ultracode = +1 level, cap bounded-autonomous
  "max_iterations": 25,                    // hard cap, caller-owned
  "max_recursion_depth": 5,                // control-plane-owned fan-out/recursion cap
  "per_run_budget_usd": 5,                 // pre-flight + between-iteration (Phase 1); live halt (Phase 2)
  "timeout_minutes": 180,
  "no_progress_exit": true,                // identical state-hash for 2 consecutive iters → stop
  "require_external_termination": "auto",  // auto = required iff autonomy==bounded-autonomous
  "commit_per_iteration": false,           // opt-in; when on, squash/tag (avoid 25 bare commits)
  "irreversible_actions_break_loop": true
}
```

**Autonomy levels (observable):**

| Level | Unattended actions | Halts for human |
|---|---|---|
| `checkpoint` | read-only + tests it wrote | every write, every external call |
| `bounded-checkpoint` | reads + writes within declared scope | irreversible actions, scope exits |
| `bounded-autonomous` | reads + writes + reversible commands | only irreversible (deploy/push/merge/money) |

**Tier scaling (ceilings + effort default):**

| Tier | autonomy_ceiling | model_effort default |
|---|---|---|
| 0–1 | checkpoint | fast |
| 2 | checkpoint | balanced |
| 3 | bounded-checkpoint | balanced |
| 4 | bounded-autonomous | max |
| 5 | bounded-autonomous (offline) | max |

`ultracode-on` → raise `autonomy_ceiling` one level above the tier row (cap `bounded-autonomous`). Effort stays a tier default (cost dial). *(Effort uses the live `fast/balanced/max` enum; a 5-point widening is a possible future deliverable touching the ADR-018 dashboard + readers — out of scope here.)*

## 6. Guardrails (mandatory core)

Pre-flight gate + Stop-hook enforce:

1. **External termination** — tests/eval/CI/sentinel via `coverage-snapshot`/`validate-output` **[S]**. Required for `bounded-autonomous`; downgraded to iter-cap for self-assessment patterns under strict.
2. **Hard iteration cap** — `max_iterations` (SDKs don't enforce this).
3. **Cost circuit-breaker** — **Phase 1 catches *between-iteration* only**: pre-flight `/cost-gate` **[S]** + per-iteration accrual of estimated cost (from `subagent-runs.jsonl`) into `loop-state.json`; halts before the *next* iteration. **It does NOT stop a single within-iteration runaway** — that's the Phase-2 live monitor. Residual risk stated explicitly. (`budget-guard` lives at `~/.claude/tools`, global, not guaranteed in cloud — `/cost-gate` is the in-stack path.)
4. **No-progress detector** — identical state-hash (git+fs) for 2 consecutive iters → exit.
5. **Human checkpoint before irreversible** — `hooks/irreversible-deny.sh` denies `git push`, `git merge`, `deploy-edge`, bulk SQL, money movement, `rm -rf`; acceptance test: *push denied, status allowed*. Red-team tunes the list.
6. **State in files+git** — durability via `loop-state.json` always; `commit_per_iteration` opt-in (squash/tag).
7. **Durable corrections** — loop mistakes append to CLAUDE.md / memory (compounding fixes), wired to `/handoff` **[S]**.
8. **Recursion cap** — `max_recursion_depth` (default 5).

## 7. Stop-hook contract (load-bearing new artifact)

- **stdin:** receives `stop_hook_active` (true once the hook has already blocked once) — the hook MUST release when `stop_hook_active` is true to avoid infinite re-block.
- **reads:** `session-state/loop-state.json` (pattern, iteration, cost, bounds, termination spec).
- **outputs:** `{"continue": false}` to release (goal met / bound tripped); `{"decision":"block","reason":"<criterion + remaining budget>"}` to keep working; escalate by releasing + writing a `/handoff` when a bound trips with goal unmet.
- **writes:** increments iteration + cost in `loop-state.json` (atomic write: temp + rename).
- **failure mode: fail-CLOSED** — malformed/missing state → release (stop), never loop blindly. (Safety > liveness.)

## 8. foreman loop-shape detection

- New step in foreman's boot sequence (after task classification): map the existing task-type → loop pattern (refactor/migration→Ralph; meta/eval→Eval-driven; audit/review→Generator-Critic; else→ReAct).
- **Tiebreak:** most-specific shape; ties → ReAct.
- **Emits** to `loop-state.json`: `{ pattern, success_criterion, bound }` where `success_criterion` is a shell-checkable command or eval ref, `bound` mirrors `loop_policy`. The Stop-hook consumes this exact shape.

## 9. Caveats (corrected — config requirements, not capability walls)

- **Classifier — layered, not absent.** Anthropic's Auto-Mode classifier internals are product-internal (not obtainable) and not required. We layer: Auto Mode (where enabled) + the red-team-tuned `irreversible-deny` list + tier/sensitivity bounding. The ADR states tier-scaling *compensates for* lacking an ML classifier; it does not claim "permissive is safe."
- **Cloud — not local-only.** Loop skills are vendored and hooks committed in `.claude/settings.json`; both bootstrap into cloud via `cloud-bootstrap.sh` → `install.sh` (same path as `/goodmorning`, `/handoff` — `docs/CLOUD.md`). Narrow real constraints: a `/schedule` Routine env must run the bootstrap; external critic keys set in the cloud env (ADR-015); `[P]`/`[N]` pattern targets may be absent → degrade. The `cloud-no-plugins` limit does not apply to the vendored control plane.

## 10. Sibling — ADR-020 (superpowers gate, separate spec)

Reuses the §3 governance-hooks base. Summary: vendor `using-superpowers` (Tier 0/1) + brainstorming's text core (drop the visual-companion Node server); a PreToolUse `Edit|Write` `deny`-until-spec-exists gate, tier + ultracode gated; reconcile with `/plan` **[S]** (replace / wrap / mode — decide in ADR-020).

## 11. Phasing (flagship — instrument alongside, not first)

- **Phase 1:** `/loop-engineer` + pre-flight gate + Stop-hook + `irreversible-deny` + `loop_policy` (schema-migrated) + foreman routing + guardrails 1–8 + **per-run loop cost logging to `subagent-runs.jsonl` (instrument alongside)**. Vendored; cloud-compatible.
- **Phase 2:** Supabase `loop_runs` (Tier 3+) + **live mid-flight cost monitor** (closes the within-iteration gap) + telemetry + the ultracode signal + (optional) effort-enum widening.

## 12. Open questions

1. **Ultracode signal** — absent from the stack (grep: zero). Define a config flag + detection (needed by ADR-019 ceiling-lift and ADR-020 gate).
2. **`/plan` vs brainstorming** reconciliation (ADR-020).
3. **Effort enum** — keep `fast/balanced/max`, or widen to 5-point (touches ADR-018 dashboard)? Defaulting to keep.
4. **Pattern provenance** — which `[P]` targets (ralph-loop, worktree-fanout) to *vendor* vs leave as graceful-degrade dependencies.

## 13. Testing plan

- Pre-flight gate refuses a loop missing termination/bound (before any dispatch).
- Stop-hook: releases on met; blocks on unmet-with-budget; releases on `stop_hook_active`; fail-closed on malformed state.
- Each bound halts (iteration, budget between-iter, timeout, no-progress, recursion depth).
- `irreversible-deny`: push/merge/deploy denied; status/read allowed.
- Cloud parity: vendored skill + committed hooks resolve in a fresh cloud session (`docs/CLOUD.md` verify steps).
- Durable-correction capture writes to CLAUDE.md/memory.
- Schema: `loop_policy` validates against amended `stack-config-schema.json`.

## 14. References

- Maps `wwcuppan1`/`wvs3clz24`; research `wepos5wi1`; review `w1kckn9h3`.
- Cherny: latent.space/p/claude-code (primary); theneuron.ai; howborisusesclaudecode.com (community, quotes traceable; some origins LOW-CONFIDENCE).
- Stack: ADR-008, ADR-011/012, ADR-015, ADR-016, ADR-018, `docs/CLOUD.md`, `schemas/stack-config-schema.json`, memories `defaults-tier-independent` + `cloud-no-plugins`.
- Literature: ReAct, Reflexion, Self-Refine, Plan-and-Execute, Ralph; AutoGPT/BabyAGI no-progress failures; LangGraph `recursion_limit`.
