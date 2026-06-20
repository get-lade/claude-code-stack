# ADR 020: Per-session loop-state

Date: 2026-06-20
Status: accepted
Author: bschonbrun

## Context

ADR-019 shipped the loop-engineering control plane (Phase 1, PR #37). Loop state
lives in a single machine-global file: `~/.claude/session-state/loop-state.json`
(`LOOP_STATE_FILE` in `skills/loop-engineer/loop_lib.sh`). The `Stop` hook
(`hooks/loop-stop.sh`) reads that one file on every stop, regardless of which
Claude Code session is stopping.

Dogfooding on 2026-06-20 exposed the flaw. With two live sessions on the same
machine (an authoring session and a fresh test rig), **both** sessions hit the
Stop hook against the **same** loop-state and **both** incremented the **same**
iteration counter. Observed symptoms:

- A loop armed in the fresh session blocked stops in the authoring session,
  which had armed nothing — the authoring session got trapped.
- The iteration counter appeared to "double-increment" (block read `iter 2/N`
  after a single deliberate stop). This was misdiagnosed at first as an
  off-by-one in the hook; the real cause is two sessions advancing one shared
  counter.
- Test 2 (bounds-trip) could not be read cleanly because the cap tripped on the
  *combined* stop attempts of both sessions, not one loop's iterations.

Forces: loops are inherently session-bound work (the agent iterating is the
session), but the state that governs them is global. The bound guarantees
ADR-019 advertises (max_iterations, no-progress, timeout) are only coherent if
exactly one session drives one counter.

## Decision

Scope loop-state per session. The loop-state record is keyed by the Claude Code
`session_id`, and each component reads/writes only its own session's state:

- **`loop_lib.sh`** — derive `LOOP_STATE_FILE` from a session id:
  `~/.claude/session-state/loop-state.<session_id>.json`. Session id resolves
  from an explicit env var (`CLAUDE_SESSION_ID`) with the existing
  `LOOP_STATE_FILE` override still honored for tests. If no session id is
  resolvable, fall back to the legacy single-file path (preserves current
  behavior rather than silently splitting state).
- **`loop-stop.sh`** — read `session_id` from the hook's stdin payload (`$INPUT`
  already carries it alongside `stop_hook_active`) and load only that session's
  state file. A session with no per-session loop-state stops freely.
- **`/loop-engineer` skill** — stamp the loop-state with the session id it is
  running in at setup time, so the loop is owned by the session that created it.

One session, one loop-state, one counter. A loop armed in session A is invisible
to session B's Stop hook.

## Consequences

### Positive
- Eliminates the cross-session trap: an authoring session is never blocked by a
  loop another session armed.
- Bound guarantees (iterations, no-progress, cost) become coherent again — one
  counter advanced by one session.
- Multiple governed loops can run concurrently across sessions without
  interference.

### Negative
- Adds a session-id dependency to three components. If `session_id` is
  unavailable in any path (older Claude Code, headless/cron, missing env), the
  legacy-single-file fallback re-opens the collision for that edge case — must
  be documented, not silent.
- Stale per-session state files accumulate in `session-state/` as sessions end;
  needs a reaper (or TTL/`active=false` skip) so they don't pile up.

### Neutral
- Intentional cross-session "babysit" loops (one loop, many sessions) are no
  longer possible by default. Not a current use case; revisit via the hybrid
  alternative if it becomes one.
- `tests/test-loop-engineering.sh` keeps using `LOOP_STATE_FILE` override, so the
  suite is unaffected by the session-id keying.

## Alternatives considered

### Single-active-loop + owner guard
Keep one machine-global loop-state, but record an `owner_session_id`; only the
owning session's Stop hook enforces, others ignore it. Rejected: keeps a single
global counter (still fragile if the owner check is ever wrong), and only one
loop can exist machine-wide — strictly less capable than per-session for no real
simplicity gain once session id is already threaded through.

### Hybrid (per-session default + opt-in global)
Per-session by default, with an explicit machine-global mode for deliberate
cross-session babysit loops. Rejected for now as speculative (YAGNI): no current
use case needs a shared loop, and the dual mode doubles the state-resolution
surface area. The per-session decision here does not preclude adding this later.

## References
- [ADR 019: loop-engineering control plane](019-loop-engineering-control-plane.md)
- Design spec: `docs/superpowers/specs/2026-06-20-loop-engineering-design.md`
- Dogfood findings: `.claude/scratch/dogfood-findings.md`
- Phase-1 build: PR #37 (commit `d491aaa`)
- Superpowers design-before-code gate moves to ADR-021 (was reserved as 020).
