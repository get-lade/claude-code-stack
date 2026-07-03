# ADR-032 — `simple_talk`: a plainness modifier orthogonal to length

- Status: Accepted
- Date: 2026-07-03
- Related: ADR-017 (session-prefs single source of truth), ADR-022 (session prefs), the `brevity-drift.sh` / `brevity-reinforce.sh` brevity system

## Context

The stack already controls response **length** through `communication_style`
(terse / balanced / thorough → `brevity-drift.sh` word/sentence budgets). But
length is not the only axis a user cares about. The maintainer kept manually
appending "explain simply" to nearly every prompt even with `communication_style`
at its tightest — because "short" and "plain" are **different axes**. A reply can
be short but jargon-dense, or plain but long. Brevity tooling only covered short.

Nothing in the stack expressed "use plain words / no jargon / caveman phrasing."

## Decision

Add `simple_talk`, an opt-in **plainness modifier** on the `session_prefs`
axis, separate from `communication_style` (length) and `explanation_verbosity`.

- **Field:** `simple_talk: "off" | "plain" | "caveman"`, default `"off"`.
  - `off` — no change (other users see zero new behavior).
  - `plain` — plain everyday words, no jargon, glossed terms.
  - `caveman` — terse caveman phrasing (drop filler, fragments OK) on top of plain.
- **Enforcement:** new `hooks/simple-talk.sh` (UserPromptSubmit). Reads
  `simple_talk` from the live session-state file and injects a per-turn directive
  when `plain`/`caveman`; silent (`exit 0`) when `off`/absent. Every-turn, not
  SessionStart-once, for the same reason as `brevity-drift.sh`: the directive
  decays as context grows and must be re-asserted.
- **Plumbing (the ADR-017 parity contract):** added to
  `schemas/stack-config-schema.json` `session_prefs`, `stack-defaults-schema.json`
  `session_prefs_defaults`, and the `BUILTIN` baseline in `session-prefs-init.sh`
  (the parity test enforces schema ⇔ BUILTIN). Registered in the tier-0 manifest
  (file + smoke test) and `config/settings.global.template.json` (UserPromptSubmit).
  `/session` gains a "Simple talk" menu row. Templates ship `off`.
- **Orthogonal, not a replacement:** `simple_talk` composes with any
  `communication_style`. `caveman` + `thorough` is a legal (if unusual) combo —
  long but plain — which is the whole point of a separate axis.

## Consequences

### Positive
- Plainness is now a first-class, opt-in, per-project/per-session dial.
- Default `off` = no behavior change for existing installs; safe to ship.
- Fail-safe hook: any error → no injection, never blocks a turn.

### Negative / notes
- The directive is **advisory** (injected context), not a hard constraint — the
  model can still drift, same as the brevity system. Belt-and-suspenders with
  `communication_style`.
- A user who wants plainness as a **durable** default must persist it via
  `/session` → global/project; a bare `~/.claude/stack-defaults.json` edit is
  overwritten by `update.sh` (templated file), the same gotcha as any default.
- The maintainer's own machine keeps a standalone personal
  `~/.claude/hooks/explain-simply.sh` (predates this feature, survives update);
  it can be retired in favor of `simple_talk: "caveman"` once the default-persistence
  gotcha above is acceptable.
