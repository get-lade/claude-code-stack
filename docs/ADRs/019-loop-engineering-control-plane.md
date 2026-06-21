# ADR 019: Loop-Engineering Control Plane

**Status:** Accepted
**Date:** 2026-06-20
**Author:** the maintainer + Claude (Opus 4.8)

## Context

The stack accumulated loop primitives — `ralph-loop`, `worktree-fanout`, `review-handoff`, `foreman`/`agent-teams`, plus platform `/goal`, `/loop`, `/schedule` — with no unifying model, no shared bounds, and no routing. A user cannot reach for "the right loop," and an autonomous loop has no enforced budget/iteration cap. The documented failure this leaves open is the 1.7M-token runaway (ADR-008). Boris Cherny (Head of Claude Code) frames the destination as "loop engineering" — *"my job is to write loops"*: small programs that discover work, prompt Claude, read output, decide done, re-prompt. We want loop engineering as a first-class, governed capability deployed to every repo, scaled to tier, and safe by default for users who don't understand the internals.

The core question is *where the loop layer lives*: inside foreman, as a subagent, or above foreman.

## Decision

Build a **loop-engineering control plane that sits ABOVE foreman** — `loop-eng(foreman(dispatch))`. Looping is control-plane (decide whether to iterate again); foreman stays one-shot work-plane (run one iteration). **The control plane — not foreman — owns the budget/iteration/recursion caps**, because a control-plane→foreman→subagent chain is the 10×-cost shape and the caps must sit above the recursion layer.

Mechanism: a `/loop-engineer` front-door skill (pre-flight validates a loop spec, clamps to the policy ceiling), a fail-closed **Stop-hook** (`hooks/loop-stop.sh`) that blocks the session from stopping until the goal's machine-checkable criterion passes or a bound trips, an **irreversible-deny** PreToolUse hook scoped to active loops, `session-state/loop-state.json` as the shared runtime contract, and a `loop_policy` block in stack-config. Autonomy is a tier+ultracode-scaled **ceiling** with a safe `checkpoint` default everywhere (risk dial); thinking effort is a tier-scaled **default** on the live `fast/balanced/max` enum (cost dial). foreman gains a loop-shape detection step that routes by task shape and logs `pattern selected: X`.

Phase 1 (the build, shipped as PR #37) is the governed runner. **Phase 2 is now shipped** (PR #42): Supabase `loop_runs` telemetry (Tier 3+, `schemas/004-loop-runs.sql`), the live mid-flight cost monitor (`hooks/loop-cost-monitor.sh`) that closes the within-iteration runaway gap, the **ultracode signal** (`loop_ultracode_active` + `loop_effective_ceiling` + `/ultracode`), hard recursion-depth enforcement, and the no-progress hash now folding untracked-file byte-contents. The sibling design-before-code gate landed as **ADR-021** (`hooks/design-gate.sh`). Full design: `docs/superpowers/specs/2026-06-20-loop-engineering-design.md`; Phase-2 plan: `docs/superpowers/plans/2026-06-21-loop-engineering-phase2.md`.

## Alternatives considered

- **A — Loop logic inside foreman:** Rejected because foreman is one-shot and stateless across dispatches (its only loop is a hardcoded 2-round reviewer cap); embedding loop control duplicates orchestration and pushes the caps *below* the recursion layer that needs bounding.
- **B — Loop as a subagent:** Rejected as a category error — a subagent runs *within* a loop and cannot control the session's outer Stop behavior; the loop boundary is the harness (Stop-hook), not the work-plane.
- **C (chosen) — Control plane above foreman:** A thin governance + routing layer that wraps foreman, enforced by the Stop-hook/session-state substrate, configured by `loop_policy`. Keeps foreman simple and reusable as the per-iteration engine; the caps live where the cost multiplies.

## Consequences

- **Positive:** Bounded autonomy on unknown-size work (audits, migrations, eval loops) without babysitting; one taxonomy over ~6 patterns the stack already ships; verification-first termination (Cherny's #1 quality lever); caps owned where runaway cost originates; safe-by-default for naive users, opt-up for power users / high tiers / ultracode.
- **Negative:** New always-on Stop-hook in every session (must be fail-closed and cheap); a `loop_policy` schema migration (`additionalProperties:false`); foreman gains a routing step; more moving parts to maintain.
- **Locked in:** The Stop-hook/`session-state`/`permissionDecision: deny` substrate is the shared **governance-hooks base** that **ADR-021** (the design-before-code gate) also consumes. The control plane — not foreman — is the home for loop caps.
- **Phase-2 status (PR #42):** the cost circuit-breaker is no longer advisory-only — `hooks/loop-cost-monitor.sh` halts a within-iteration runaway live; `max_recursion_depth` is now a **hard bound** in `loop_check_bounds`; the no-progress hash includes untracked-file byte-contents. `irreversible-deny` remains **best-effort defense-in-depth, not a security boundary** — that limit is inherent to a pattern-matching Bash hook; the real boundary stays the autonomy ceiling + human checkpoint + Claude Code's own permission system.

## References
- Spec: `docs/superpowers/specs/2026-06-20-loop-engineering-design.md`
- Plan: `docs/superpowers/plans/2026-06-20-loop-engineering-phase1.md`
- Phase-1 build: PR #37 (`docs/loop-engineering-spec`)
- ADR-008 (orchestration modes + the 1.7M-token runaway this guards)
- ADR-011 / ADR-012 (Codex / Gemini adversarial critics used to harden this)
- ADR-015 (cloud critic fallback), ADR-016 (workflow roster fence), ADR-018 (settings dashboard / `model_effort` enum)
- Sibling: ADR-020 (superpowers design-before-code gate — pending)
- Research: Boris Cherny "loop engineering" (latent.space/p/claude-code, primary)
