# ADR 024: /loop-review deterministic rendering + PostToolUse real-cost accrual

Date: 2026-06-21
Status: accepted
Author: bschonbrun

## Context

ADR-023 (Phase 3) left three "open questions (none required)": richer
`/loop-review` rendering, real per-tool token usage, and per-feature (vs per-path)
design-gate markers. Picking these up, two findings reshaped the scope:

1. **Per-feature design-gate markers are already covered.** `design-gate.sh`
   matches `approved_paths` globs (ADR-023 §T3) — a feature is scoped by globbing
   its files. A separate "feature name" concept duplicates that. **Dropped (YAGNI).**

2. **The "real token-cost signal" branch is operationally dead.** ADR-023 §2 put
   usage→USD conversion in `loop-cost-monitor.sh`, which is a **PreToolUse** hook.
   Token usage only exists *after* a call, so `tool_response.usage` is never
   present at PreToolUse runtime — the branch is exercised only by a synthetic
   test payload. Real per-tool cost has therefore never been recorded, and
   `loop_live_cost` (the monitor's enforcement source) is ~always 0.

`/loop-review` rendering is genuinely missing: the skill instructs the model to
"render a compact table" with no deterministic formatter.

## Decision

1. **`/loop-review` gets a deterministic formatter.** Add `loop_stats_table` to
   `loop_lib.sh` — it renders the existing `loop_stats` JSON as an aligned text
   table (pattern · runs · met% · budget% · iter_cap% · p50 · p95 · avg $).
   `/loop-review` calls it instead of `loop_stats | jq .`. Empty history prints
   nothing; the skill emits the "no history" message. Fail-safe.

2. **Real per-tool cost accrues in a PostToolUse hook, not the monitor.** New
   `hooks/loop-cost-accrual.sh` (PostToolUse `Agent|Workflow`): during an active
   loop, convert `tool_response.usage` → USD via the single price table
   (`loop_cost_from_usage`) and append a `{event:"loop_tool_cost", loop_id,
   cost_usd, ts}` row to `subagent-runs.jsonl`. `loop_live_cost` already sums any
   loop-tagged row, so the PreToolUse monitor now enforces the budget against
   **real** spend — caught on the *next* call. The monitor is registered on
   `Bash|Agent|Workflow` so a Workflow-only loop is still enforced.

3. **The Stop hook is a true hard cap.** `loop-stop.sh` folds the
   `loop_live_cost` total into `cost_so_far_usd` (via `max`, never additive — so
   loop_tool_cost rows are not double-counted) *before* the budget bound check.
   So when the goal is still unmet, a loop that has overrun via per-tool spend
   trips `budget_exceeded` at the next Stop, not just at the next tool call.

4. **Remove the dead usage branch from `loop-cost-monitor.sh`.** One
   responsibility each: PostToolUse accrues, PreToolUse enforces via
   `loop_live_cost`. This supersedes ADR-023 §2's placement.

5. **Telemetry reflects real spend.** `loop_runs_record` records
   `max(cost_so_far_usd, loop_live_cost(loop_id, started_at))` so `/loop-review`
   `avg $` is honest about per-tool cost, not just the between-iteration snapshot.

## Consequences

- Per-call preemption is impossible by construction (usage postdates the call);
  the budget is enforced one call late, with the Stop hook as the hard cap. This
  is honest, not a regression — the prior code never enforced real per-call cost
  at all.
- New PostToolUse hook is registered in the Tier-2 team template + manifest and
  `hooks/hooks.json`. No global-template change (loop hooks are Tier 2+).
- `approved_paths` remains the design-gate's scoping mechanism; no marker schema
  change.

## Status of ADR-023 open questions

- Richer `/loop-review` rendering → **done** (Decision 1).
- Real per-tool token usage → **done, reframed** to PostToolUse (Decisions 2–4).
- Per-feature design-gate markers → **dropped** (already covered by `approved_paths`).
