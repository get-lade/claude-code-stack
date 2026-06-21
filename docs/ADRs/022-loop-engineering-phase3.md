# ADR 022: Loop-Engineering Phase 3 — observability, smarter control, authoring path

Date: 2026-06-21
Status: accepted
Author: bschonbrun

## Context

Phases 1 (ADR-019, PR #37) and 2 (PR #42) shipped the governed loop control
plane: pre-flight validation, a fail-closed Stop-hook, irreversible-deny, a live
mid-flight cost monitor, `loop_policy`, the ultracode signal, and the ADR-021
design-before-code gate. Telemetry (`loop_runs`) now records every finished loop,
but nothing *consumes* it; the live cost monitor sums logged rows (lagging a
costly call by one row); the design-gate's approval is coarse (one session-wide
flag); the effort dial is a 3-value enum; the authoring half the gate enforces
(brainstorming → `/plan`) is not vendored; and durable corrections (spec §6.7)
are unwired. Phase 3 closes these. Plan:
`docs/superpowers/plans/2026-06-21-loop-engineering-phase3.md`.

## Decision

1. **Telemetry is the source of truth for cap calibration — advisory, never
   silent.** `/loop-review` computes per-pattern stats from `loop-runs.jsonl`
   (+ Supabase view when present) and *proposes* `loop_policy` bumps
   (`max_iterations := ceil(p95 × 1.2)`), but applying is a human step via
   `/stack-config`. No loop ever auto-rewrites its own caps.

2. **The live cost signal is best-effort, fail-open.** When tool-use token usage
   is present in the hook payload, convert it to USD via the **single price table
   in `config/model-routing.json`** (`pricing_per_million_input/output`) and
   accrue immediately. When usage is absent or the model is unknown, fall back to
   the Phase-2 logged-row sum. Never crash, never block on missing data.

3. **The design-gate marker becomes path-scoped, with session-wide back-compat.**
   `design-approved.json` gains `approved_paths` (glob array); the gate allows a
   source edit when the target matches an approved glob. A bare `{"active":true}`
   still allows all source (legacy). `/plan` and `/loop-engineer` write the glob
   set for the feature they just planned.

4. **Effort enum widening is additive.** `fast | balanced | max` →
   `minimal | fast | balanced | thorough | max`. Legacy values keep validating and
   map onto the new scale (`fast→fast`, `balanced→balanced`, `max→max`); readers
   accept both. Per-tier defaults are unchanged in meaning.

5. **Vendor the authoring path at Tier 0/1.** `using-superpowers` + brainstorming
   (text core only — the visual-companion Node server is dropped) ship wherever
   the gate can fire, cloud-compatible, no `[P]`/`[N]` hard deps.

6. **Durable corrections compound into the handoff.** On a `no_progress` or
   `escalated` loop exit, append a structured note to
   `session-state/loop-corrections.jsonl`; `/handoff` folds unresolved
   corrections into the next-session doc.

7. **Auto-enablement is classify → ask once → persist.** A `UserPromptSubmit`
   hook reuses foreman's loop-shape taxonomy; on a loop-shaped request with no
   onboarding marker it surfaces one novice-framed prompt (governed loop?
   autonomy? ultracode? design-first?), writes a marker, and the same question
   group is added to `/session` and `/project-init` so the answers become
   defaults. Non-loop requests are never interrupted (silent when unsure).

## Consequences

- **Positive:** loops learn from their own history; cost halts tighten; the gate
  stops over-blocking; novices get one plain-language prompt instead of needing
  to know the machinery exists.
- **Negative / residual:** calibration is only as good as accumulated data
  (cold-start = no proposal); the token signal depends on the harness surfacing
  usage to hooks (fallback covers the gap); path-glob matching is shell-glob, not
  a full ignore-syntax engine.
- **Unchanged contracts:** the Stop-hook decision shape, the `permissionDecision:
  deny` shape, and fail-closed/fail-open postures from Phases 1–2 are preserved.

## Alternatives considered

- **Auto-apply calibrated caps:** rejected — silently mutating a safety bound is
  the opposite of the control plane's purpose. Propose-and-confirm only.
- **A second price table for the monitor:** rejected (DRY) — reuse
  `model-routing.json`, the existing audited source.
- **Replace the session-wide marker outright:** rejected — keep it as a
  back-compat fallback so existing flows don't break.

## References
- Spec: `docs/superpowers/specs/2026-06-20-loop-engineering-design.md`
- Plan: `docs/superpowers/plans/2026-06-21-loop-engineering-phase3.md`
- ADR-019 (control plane), ADR-021 (design gate), ADR-018 (settings dashboard)
