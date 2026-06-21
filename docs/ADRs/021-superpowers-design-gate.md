# ADR 021: Superpowers design-before-code gate

Date: 2026-06-21
Status: accepted
Author: bschonbrun

## Context

The loop-engineering design spec (`docs/superpowers/specs/2026-06-20-loop-engineering-design.md`)
names a sibling to ADR-019: a **design-before-code gate** that reuses the §3
governance-hooks base (session-state read/write, the PreToolUse
`permissionDecision: deny` pattern, hook registration in
`config/settings.*.template.json`). The spec originally called this ADR-020, but
ADR-020 was taken by per-session loop-state; this gate is therefore **ADR-021**.

The friction it targets: the recurring "wrong-approach-first" failure
(documented across the stack — see `/plan`). An agent dives into editing source
before any design exists, and the rework cost is paid later. The stack already
has `/plan` (author-time discipline) and superpowers-style planning, but nothing
**enforces** that a design exists before code is touched. Enforcement matters
most exactly when autonomy is highest — i.e. when `ultracode` is on and the loop
autonomy ceiling has been raised (ADR-019 §4).

## Decision

Ship a PreToolUse `Edit|Write` hook — `hooks/design-gate.sh` — that **denies
edits to source files when ultracode is on and no approved design exists**.

1. **Ultracode-gated, off by default.** The gate is active **only when
   `loop_ultracode_active` returns true** (env `CLAUDE_ULTRACODE` or the
   `/ultracode` session-state flag). With ultracode off — the default — it is
   completely silent and never blocks normal work. This is the conservative
   choice: the gate rides the same risk dial that raised the autonomy ceiling,
   so the discipline scales with the autonomy.

2. **Source-only.** It denies only **code** targets
   (`.sh .bash .py .ts .tsx .js .jsx .go .rs .rb .java .c .h .cpp .php .sql`).
   It always allows docs, markdown, config (`.json .yml .yaml .txt`), and
   anything under `docs/` or `tests/` — you must be free to write the spec, the
   plan, and the tests that satisfy the gate.

3. **Approved-design marker.** The gate allows the edit when an approval marker
   exists at `~/.claude/session-state/design-approved.json` with
   `{"active": true}`. This is the reconciliation with `/plan` (spec open
   question 2): the gate **wraps** `/plan` rather than replacing it. `/plan`
   writes the marker when the user approves a plan; `/loop-engineer` writes it
   when a validated loop spec is armed. The gate is the *enforcement*; `/plan`
   remains the *authoring path*.

4. **Reuses the §3 governance base.** Same session-state read contract, same
   `permissionDecision: deny` shape, same registration mechanism as
   `irreversible-deny.sh` and `loop-cost-monitor.sh`. Fail-OPEN: any error
   allows the edit (a gate failure must never brick editing).

## Consequences

- **Positive:** when an operator opts into high autonomy (`/ultracode on`), code
  edits are blocked until a design is approved — the wrong-approach-first cost is
  paid up front, by construction, exactly when it matters most.
- **Positive:** zero impact on default workflows. Ultracode-off sessions never
  see the gate.
- **Negative / residual:** the marker is coarse (one session-wide approval, not
  per-feature). A long ultracode session that pivots to unrelated work keeps the
  old approval. Acceptable for v1; a per-path marker is a future refinement.
- **Negative / residual:** like `irreversible-deny`, this is defense-in-depth,
  not a security boundary — an agent can still write a `.md` then `mv` it, or
  disable ultracode. The goal is to make accidental code-first work unlikely
  under high autonomy, not to defeat a determined bypass.

## Reconciliation with `/plan`

`/plan` and `/loop-engineer` each write `design-approved.json` on approval; the
gate reads it. `/ultracode off` does not clear the marker (the marker is about
design state, not autonomy), but turning ultracode off disables the gate anyway.
A future `/plan` revision may scope the marker to a path or feature id.
