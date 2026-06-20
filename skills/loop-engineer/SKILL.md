---
name: loop-engineer
description: Set up a governed autonomous loop. Use when the user wants an agent to iterate toward a verifiable goal until done (run-until-tests-pass, babysit-PRs, eval-until-threshold, long refactor) rather than a one-shot task. Validates a loop spec, applies the stack-config loop_policy ceiling, and writes loop-state so the Stop-hook enforces caps. Refuses unbounded loops.
tier_min: 2
user-invocable: true
model-invocable: true
recommendable: true
tools: Bash, Read
---

# /loop-engineer

Set up a **bounded, governed loop**. You are the front door; the `Stop` hook
(`loop-stop.sh`) does the enforcing. Your job: build a valid loop spec, clamp it
to the project's `loop_policy` ceiling, and write `loop-state.json`. **Refuse to
start an unbounded or unverifiable autonomous loop.**

## Steps

1. **Read the policy.** From `.claude/stack-config.json`, read `loop_policy`
   (ceiling, caps, `require_external_termination`). If absent, use the schema
   defaults (safe floor).

2. **Establish the goal + verification.** Ask the user (or infer) the goal and a
   **machine-checkable success criterion** — a shell command that exits 0 when
   done (e.g. `npm test && npm run lint`, an eval threshold script). This is the
   #1 lever; a loop without it is only as good as its iteration cap.

3. **Pick autonomy, clamp to ceiling.** Never exceed `autonomy_ceiling`. Default
   to `checkpoint` unless the user opts up and the tier/ultracode ceiling allows.

4. **Validate.** Build the spec JSON (see contract) and run:
   `bash skills/loop-engineer/loop_lib.sh` is sourced; call
   `loop_validate_spec "$SPEC"`. If it returns 2, **STOP** and tell the user what
   is missing (a bound, or — for `bounded-autonomous` — a success criterion).

5. **Write loop-state and announce the pattern.** On valid spec, source the lib
   and `loop_write_state "$SPEC_WITH_ACTIVE_TRUE"`. Print
   `pattern selected: <pattern> (<why>)` so a misroute is visible.
   Loop-state is **per session** (ADR-020): it is keyed by `CLAUDE_CODE_SESSION_ID`,
   so a loop you arm here never blocks another session's stops.

6. **Hand to the loop.** Begin the work. The Stop-hook will block stops until the
   criterion passes or a bound trips. To stop early, the user runs
   `/loop-engineer clear` (sets `active=false`).

## Spec contract

See `docs/superpowers/specs/2026-06-20-loop-engineering-design.md` §3 for the
`loop-state.json` shape. Required to start: `bounds` (>=1) and — for
`bounded-autonomous` with `require_external_termination` — `success_criterion.command`.

## Clearing a loop

`/loop-engineer clear` → source the lib, write `{"active":false,"status":"cleared"}`.

## What you do NOT do

- Do NOT write loop-state without passing `loop_validate_spec`.
- Do NOT raise autonomy above `autonomy_ceiling`.
- Do NOT run irreversible actions inside the loop (the deny hook blocks them).
