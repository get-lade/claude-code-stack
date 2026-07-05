# ADR 033: Post-session model-fit receipt (`model_fit_receipt`)

Date: 2026-07-05
Status: proposed
Author: architect (design only — implementer builds)

## Revision (post cross-family critique)

**This ADR was redesigned after an adversarial architecture-critic pass (Gemini 3.1 Pro, cross-family per ADR-011/ADR-012; verdict REDESIGN).** The original design — a live in-session watcher: a PostToolUse accumulator + Stop-hook drift detector over an N=8 per-turn ring, injecting a mid-session "switch model?" nudge — is **dropped**. The critique surfaced four blockers, each fatal to the live mechanism, not merely tunable:

1. **The `in_tokens ≥ 40000` "reasoning" rule is a fail-open no-op.** Real Claude Code turns routinely pull 40k+ input tokens (`CLAUDE.md` + `MEMORY.md` + a couple of source files + history). Every turn would therefore classify `reasoning` → always Opus → the watcher could *never* suggest a downgrade, while passing every unit test. Absolute per-turn token bands measure **context size, not difficulty**. Dropped entirely.
2. **Per-tool-call rows break the N=8 window.** PostToolUse fires per tool call, so one turn with 6 edits + a bash floods and flushes the ring. "Dominant, high-mass window" reduced to "was the last turn tool-heavy." The whole live-windowing model is invalid. Dropped.
3. **Subagent contamination (previously uncaught blocker).** reviewer / red-team / security-auditor / product-critic run on **non-Anthropic** models (Codex/GPT, Gemini, DeepSeek, local Qwen — see `config/model-routing.json` `subagent_assignments`). Their tool loops fire the same hooks; a nudge would tell the user to run `/model → Sonnet` about a *Qwen* subagent's work. The design must reason **only about the main session's own model** and structurally exclude subagent activity. Addressed explicitly below.
4. **Complexity ≫ ROI.** Two hooks on the hottest path, a per-session state file with lock/prune mechanics, and a 5-class classifier — all to inject an advisory line the model often ignores and the user rarely sees. Layer mismatch: continuous monitoring is for hard bounds (ADR-024 budget caps), not passive advice.

The redesign is the critic's converged counter-proposal: a **post-session "receipt"** — retrospective, non-interrupting, ratio-based (robust to the 40k problem), main-session-only. Status stays `proposed`.

## Context

Model choice for a Claude Code session is a one-time human guess. Someone who runs Opus 4.8 for everything over-pays on mechanical work; someone on Haiku is under-powered on hard work. `/model-audit` checks whether the *model lineup* is fresh against benchmarks/pricing — it never tells a user whether the model they *used this session* fit the work they *actually did*.

We can answer that **retrospectively, once, at the end of a session** from telemetry the stack already writes, with zero live overhead and no interruption. The primitives:

- `~/.claude/logs/subagent-runs.jsonl` — append-only session telemetry, already scoped by `session_start` timestamp + `project` and already **subagent-aware** (rows carry an `agent` field; `/handoff` and `/team-status` already filter it).
- `loop_cost_from_usage` (`skills/loop-engineer/loop_lib.sh`) — token→USD via `config/model-routing.json`, the single audited price table.
- The `Stop` hook event (there is **no `SessionEnd` event** in this stack — confirmed: zero references), plus the `/handoff` and `/goodmorning` end-of-session skills.
- The session-prefs parity contract (ADR-017/ADR-032).

Key structural fact that drives the whole redesign: **`subagent-runs.jsonl` rows describe subagent lifecycle events written by the main session about its subagents** (`event:"dispatch"` / `"complete"` with an `agent` name, plus loop cost rows). There is **no existing per-turn main-session usage row.** So the receipt needs one thin main-session accrual of its own, and subagent exclusion becomes trivial and *structural*: the receipt only ever sums rows it itself tagged as main-session.

## Decision

Ship a **post-session model-fit receipt**: at session end, read this session's own main-session telemetry, compute a **workload ratio** (tool/edit activity vs generation), estimate what the session cost on the current model vs. the ratio-recommended model, and emit **one retrospective line**. No live hooks on the classify/nudge path, no windowing, no drift detector, no mid-session interruption.

### Pref: reduce to `off | on`

The receipt is retrospective; the passive/active distinction (a live prompt vs a passive line) is meaningless for a summary printed after the work is done. Collapse to:

`session_prefs.model_fit_receipt`: `"off" | "on"`, **default `"on"`.**

- `on` (default) — at session end, if the session did enough main-session work to judge, print one receipt line (see Surface). One line, retrospective, ignorable.
- `off` — no receipt, and the main-session accrual hook writes nothing (kill switch + zero-overhead opt-out).

Default `on` because a one-line end-of-session receipt is the entire value and is trivially ignorable; `off` would hide the feature until opt-in, defeating it. (The old `active` mode — a mid-session `AskUserQuestion` — is gone; it was the interrupting behavior the critic rejected.)

Renaming the key (`model_fit_alerts` → `model_fit_receipt`) is correct: the semantics changed from live alerting to a retrospective receipt, and the value set changed. No installs ship the old key yet (this ADR is `proposed`), so there is no migration.

### Where it fires — recommendation

**Two surfaces, one shared computation, no fork:**

1. **Primary: fold into `/handoff` and offer in `/goodmorning`.** `/handoff` already reads `subagent-runs.jsonl` scoped to `session_start` + `project` and already excludes the `workflow` sentinel — it is the natural, already-correct home. The receipt is one more computed line in the handoff's summary (and a one-liner surfaced by `/goodmorning` for the *previous* session).
2. **Fallback: a thin `Stop`-hook receipt that prints at most once per session**, for users who never run `/handoff`. It uses a per-session dedupe flag (`model-fit-receipt.<session_id>.printed`, pruned at SessionStart exactly like `passive_suggest.*.nudged`) so it fires once, prints only, and **never blocks the stop** (`exit 0` always; the sole output is an advisory line, no `{"decision":"block"}`).

**Recommendation: build the shared computation as a small library function and call it from both surfaces.** This is the KISS/DRY choice: one ratio-and-cost calculator, sourced by the `/handoff` skill step and by the Stop-hook fallback. It avoids the coverage gap (skill-only misses users who quit without `/handoff`; hook-only duplicates logic the skill already needs) without duplicating logic.

*Rejected sub-alternative — a dedicated `/model-fit` on-demand skill only (critic's counter-proposal 1):* good, but purely opt-in means most sessions never see it, so it doesn't nudge behavior change. We keep an on-demand entry point for free (the same library is invocable), but the *default* value comes from the automatic-but-retrospective receipt.

### Main-session accrual (the one thin hook)

`hooks/model-fit-turn.sh` — a `Stop` hook (fires when the **main** assistant finishes a response; this is the main session's own turn boundary, *not* a subagent tool loop). It appends **one main-session turn row** to `subagent-runs.jsonl`:

```json
{
  "event": "main_turn",
  "agent": "main",
  "ts": "2026-07-05T14:03:22Z",
  "session_start": "2026-07-05T13:40:11Z",
  "project": "/Users/.../claude-code-stack",
  "model": "claude-opus-4-8",
  "in_tokens": 41200,
  "out_tokens": 610,
  "tool_counts": { "edit": 2, "write": 0, "bash": 1, "read": 4, "agent": 0, "other": 1 }
}
```

- `event:"main_turn"`, `agent:"main"` — the two tags that make subagent exclusion structural (see below).
- `model` — from the Stop payload `.model` (confirmed present via `statusline.sh`).
- `in_tokens`/`out_tokens` — the **main session's** turn usage, from the Stop payload usage fields (same extraction idiom as `loop-cost-accrual.sh`: `.usage.input_tokens // 0` etc.). If the payload has no usage, the row is written with 0s — it still contributes to the *ratio* via `tool_counts`, and cost is simply not attributable for that turn (fail-safe, honest).
- `tool_counts` — computed by reading the transcript (the Stop payload carries `transcript_path`, as `brevity-drift.sh` already uses) and counting `tool_use` blocks by name since the last human prompt. The "since last human prompt" scoping is a **logical** bound (only this turn's tool calls are counted, so cross-turn drift cannot occur), not an **I/O** bound — implementation note: this reads the whole transcript file on every Stop event, same as `brevity-drift.sh`. This is a **count of tool calls in the completed turn**, not per-call rows — so the "6 edits flood the window" problem cannot recur; a turn is one row regardless of tool count.
- **`event:"main_turn"` is a distinct event from ADR-024's `loop_tool_cost` / `loop_iteration` and from `dispatch`/`complete`** — so it never pollutes the financial-accounting stream the critic flagged (blocker 5/6). The cost stream and the fit stream share a file but are disjoint event types; each reader filters its own.

This is **one** hook on the Stop path, doing a full transcript read (logically scoped to the current turn, not I/O-bounded) + one append — not a per-tool-call accrual. Fail-safe: any error → `exit 0`, no row. Gated on `model_fit_receipt != off`.

### How subagent activity is excluded (exactly)

Three structural filters, any one of which is sufficient; together they are belt-and-suspenders:

1. **Event type.** The receipt sums **only `event == "main_turn"` rows.** Subagent activity is `event ∈ {dispatch, complete}` (written by `subagent-log.sh` / `subagent-complete-log.sh`) and loop cost rows are `event ∈ {loop_tool_cost, loop_iteration}`. None are `main_turn`, so none are counted. A cross-family reviewer running on Qwen produces `dispatch`/`complete` rows — invisible to the receipt.
2. **Agent tag.** Every `main_turn` row carries `agent:"main"`; the receipt filters `.agent == "main"`. Subagent rows carry their role name (`reviewer`, `red-team`, …).
3. **Hook context.** `model-fit-turn.sh` is a `Stop` hook. Stop fires at the **main session's** turn boundary. Subagents run *inside* the main session's tool calls (`Task`/`Agent` tool) and do not themselves trigger the main session's Stop event with a subagent model in `.model` — `.model` on the Stop payload is the main session model. (Filters 1–2 make the receipt correct even if a runtime ever fired Stop with a subagent context; the design does not rely on hook context alone.)

So the receipt provably reasons about **the main session's own model and its own turns only**, in an explicitly multi-provider codebase. This is the direct answer to blocker 3.

### Signal = session-level ratio, not absolute token thresholds

The classification is a **single session-level ratio**, computed once over all `main_turn` rows, robust to the 40k-context problem because it never compares an absolute token count to a threshold. Define, summed across the session's `main_turn` rows:

- `edit_calls` = Σ `tool_counts.edit + tool_counts.write + tool_counts.bash` (structural/mechanical work).
- `total_out_tokens` = Σ `out_tokens` (generation volume).
- `total_turns` = count of `main_turn` rows.

The discriminating ratio is **generation-per-edit-action**:

```
gen_per_edit = total_out_tokens / max(edit_calls, 1)
```

Interpretation: a session that does lots of small tool-driven edits with little prose has **low** `gen_per_edit` (mechanical — cheaper model would do). A session that generates lots of tokens with few edit actions has **high** `gen_per_edit` (generation/reasoning-shaped — keep the strong model). This is a *ratio of the session's own two quantities*, so it does not care that every turn pulled 40k of context — input-token size cancels out of the signal entirely. That is the fix for blocker 1.

**Bands (v1, tunable — mark `_v1_tunable` in config):**

| `gen_per_edit` | Session shape | Receipt behavior |
|---|---|---|
| `< 300` and `edit_calls ≥ 10` | **mechanical** | recommend one tier **cheaper** than current (opus→sonnet, sonnet→haiku) |
| `300 – 1200` | **mixed** | no recommendation (print cost summary only, or stay silent — see Surface) |
| `> 1200` | **generation/reasoning-heavy** | recommend **staying** on current if already Opus; if on Haiku/Sonnet, suggest one tier **up** |

Plus two guards so a thin session never triggers advice:

- **Minimum evidence:** require `total_turns ≥ 6` **and** `edit_calls + (total_out_tokens/500) ≥ 12` (a crude "enough happened" mass). Below that → print the cost line only, no recommendation.
- **Never cross below Haiku or above Opus** (clamp to the three real Anthropic tiers).

**Threshold justification (all v1 guesses; the ADR's numbers are the point — tune from real `main_turn` logs):**

- `gen_per_edit < 300`: ~225 output words per edit-action is very little prose around each edit — the session is *doing*, not *explaining*. 300 gives headroom over pure mechanical (which is often <100).
- `edit_calls ≥ 10` gate on "mechanical": a session with only 3 edits isn't a mechanical *workload* even if the ratio is low; require real edit volume before suggesting a downgrade.
- `> 1200`: ~900 words of generation per edit-action means the session's value is in what it *wrote/reasoned*, not what it edited — the case for a strong model. Wide gap (300→1200) so only clearly-shaped sessions get advice; everything ambiguous is `mixed` = no recommendation.
- `total_turns ≥ 6`: fewer than 6 assistant turns is too short to characterize.

The bands are **ratio-based and session-holistic**, so they survive tool-schema drift far better than the old per-turn `edit_lines` bands. On `edit_lines` specifically (critic's should-fix): **we do not use `edit_lines` at all.** `Write` rewriting a whole file and `MultiEdit` format variance made line-counting noise; we count **tool-call events** (`edit`/`write`/`bash` invocations), which are unambiguous in the transcript regardless of how many lines each touched. That removes the noisy signal the critic flagged rather than trying to clean it.

### Fit table (simplified) — in `config/model-routing.json`

The receipt only needs the **tier ladder** and pricing (pricing already exists in the file). Add one small block:

```json
"model_fit": {
  "_doc": "ADR-033 post-session receipt: the Anthropic tier ladder the receipt walks (cheap->strong). Ids MUST exist in providers.anthropic.models. /model-audit keeps this fresh alongside pricing. Ratio bands live in the hook/lib, not here.",
  "_v1_tunable": true,
  "tier_ladder": ["claude-haiku-4-5-20251001", "claude-sonnet-4-6", "claude-opus-4-8"]
}
```

"One tier cheaper/up" = step along `tier_ladder`. Cost estimates for "would have cost ≈$Z on <other model>" reuse `loop_cost_from_usage` with the session's summed `in_tokens`/`out_tokens` (main-turn rows only) priced at the other model's rates. No parallel table; pricing stays single-source.

### Surface (the one line)

Computed by a shared lib function `model_fit_receipt_line` (new, in `loop_lib.sh` or a small `model_fit_lib.sh`), returning a single string or empty:

- **mechanical example:**
  > Model-fit receipt — this session: ~$4.50 on Opus 4.8 across 22 turns, mostly mechanical editing (low prose-per-edit). Sonnet 4.6 would've been ≈$0.95. If sessions like this are common, consider defaulting to Sonnet. (`model_fit_receipt: off` in `/session` to silence.)
- **reasoning example (on Sonnet):**
  > Model-fit receipt — this session: ~$0.80 on Sonnet 4.6, generation/reasoning-heavy. Opus 4.8 (≈$2.10) may be a better fit if quality mattered here.
- **mixed / insufficient evidence:**
  > Model-fit receipt — this session: ~$1.20 on Opus 4.8, mixed workload. No clear cheaper/stronger fit. *(or silent, if `edit_calls`+turns below the minimum-evidence gate)*

Always names: actual model + est. cost, the shape, the alternative + its est. cost, and the off switch. `/handoff` prints it inline; the Stop-hook fallback prints it once via `<system-reminder>` (advisory context) and sets the dedupe flag.

## Config / parity — trimmed ADR-017 file-change checklist

Smaller surface than the live design (one accrual hook, `off|on` pref, no live nudge hook, no per-session fit-state file):

1. `schemas/stack-config-schema.json` — add `model_fit_receipt` to `session_prefs.properties` (enum `["off","on"]`, default `"on"`, description).
2. `schemas/stack-defaults-schema.json` — same in `session_prefs_defaults.properties`.
3. `hooks/session-prefs-init.sh` — add `"model_fit_receipt":"on"` to the `BUILTIN` literal. **(Parity test compares BUILTIN keys ⇔ schema keys — #1 and #3 land together or the test fails.)**
4. `tests/test-session-prefs-parity.sh` — no code change; now asserts 8 keys. Verify green.
5. `config/tier-manifests/tier-2.json` — add `hooks/model-fit-turn.sh` to `files.global` (executable) + smoke tests (`test -x` + a `jq -e` assertion it's registered as a `Stop` hook in `settings.json`). *(Tier 2: depends on the tier-2 `subagent-runs.jsonl` telemetry + price table. The **pref** threads via the tier-0 schema/BUILTIN files above.)*
6. `config/settings.team.template.json` — register `model-fit-turn.sh` in the existing `Stop` array (alongside `loop-stop.sh`). **No PostToolUse entry** (the whole per-tool-call accrual is gone).
7. `templates/stack-config.template.json` — add `"model_fit_receipt": "on"` to `session_prefs`.
8. `templates/stack-defaults.template.json` — add `"model_fit_receipt": "on"` to `session_prefs_defaults`.
9. `skills/session/SKILL.md` — add a "Model-fit receipt" row (off · on) + the JSON shape in Step 3.
10. `config/model-routing.json` — add the simplified `model_fit` (`tier_ladder`) block.
11. `skills/handoff/SKILL.md` — add a step: after the team-utilization block, call `model_fit_receipt_line` and print it in the handoff summary.
12. `skills/goodmorning/SKILL.md` — surface last session's receipt line (best-effort; skip if no `main_turn` rows).
13. `skills/loop-engineer/loop_lib.sh` (or new `model_fit_lib.sh`) — add `model_fit_receipt_line` (the shared ratio + cost calculator; reuses `loop_cost_from_usage`).
14. `config/settings.global.template.json` — **no change** (tier-2 hook, per ADR-024 precedent).
15. `CHANGELOG.md` — Unreleased entry; `stack_version` bump `1.2.0 → 1.3.0`.
16. `skills/model-audit/SKILL.md` — one line: `model_fit.tier_ladder` audited alongside pricing.

**Dropped from the old checklist:** the second hook (`model-fit-accrual.sh` / live nudge), the PostToolUse registration, the per-session `model-fit.<sid>.json` fit-state file and its pruning, the drift/cooldown state. Net: **one** new hook + one lib function + the pref threading.

## Consequences

### Positive
- Kills all four blockers: no absolute token band (ratio cancels context size), no per-call windowing (one row per main turn), structural subagent exclusion (`event:"main_turn"` + `agent:"main"`), and a fraction of the complexity (one Stop hook, no live nudge path).
- Zero live overhead on the hot path — the accrual is one transcript read (logically scoped to the current turn, not I/O-bounded — the same precedent as `brevity-drift.sh`) + one append per main turn; the classify/cost math runs **once** at session end (in `/handoff` or the once-per-session fallback).
- Reuses the already-correct session-scoped, subagent-aware telemetry read that `/handoff` performs, and the single audited price table.
- Retrospective + non-interrupting: the user is never prompted mid-flow.

### Negative
- Ratio bands are still v1 guesses needing a real-log tuning pass (but ratio-shaped signals are far more robust to schema/context drift than the old absolute bands).
- The receipt informs; it doesn't change the model. Behavior change depends on the user acting next session (which is the honest scope of a retrospective).
- One new event type (`main_turn`) added to `subagent-runs.jsonl`; readers must filter by event (existing readers already do — `/handoff` filters `event=="dispatch"`, so `main_turn` is invisible to them by default).

### Neutral
- Dedupe flag is ephemeral per session (SessionStart prune), same idiom as `passive_suggest.*.nudged`.
- Cost figures are estimates (token usage may be absent on some turns → those turns contribute to ratio but not cost).

## Alternatives considered

### A: Live in-session watcher (the original ADR-033)
Rejected by cross-family critique — see the Revision note. Absolute token bands fail open; per-call rows break windowing; subagent contamination; complexity ≫ ROI.

### B: On-demand `/model-fit` skill only (critic counter-proposal 1)
Good hygiene, zero overhead — but purely opt-in means most sessions never see it, so it can't shift the default behavior the feature exists to shift. Kept as a *free* secondary entry point (the same lib is invocable on demand) but not the primary surface.

### C (chosen): Post-session receipt (critic counter-proposal 2), computed once, two surfaces sharing one lib
Automatic-but-retrospective, ratio-based, main-session-only. Best coverage-to-complexity ratio.

## Open questions (log-tuning, none blocking)
1. Do `gen_per_edit` bands (300 / 1200) hold on real `main_turn` logs, or need per-model normalization?
2. Should the receipt also weight subagent *cost* the user paid Anthropic for (Task subagents on Claude models are metered), or strictly the main session? (v1: main session only — the model the user can switch.)
3. Is the once-per-session Stop-hook fallback worth it, or is `/handoff`-only enough? (Ship both; drop the fallback if telemetry shows `/handoff` coverage is high.)

## References
- ADR-011 / ADR-012 (cross-family subagents — the source of blocker 3)
- ADR-017 (session-prefs parity contract)
- ADR-024 (`subagent-runs.jsonl`, `loop_cost_from_usage`; distinct event types)
- ADR-032 (`simple_talk` — parity-threading template)
- `config/model-routing.json` (price + `tier_ladder`); `skills/model-audit/` (freshness complement); `skills/handoff/SKILL.md` (existing session-scoped subagent-aware telemetry read)
- Cross-family critique: session scratchpad `gemini-output.md`

---

## Test plan (rewritten for the receipt)

**Ratio math (unit — `tests/test-model-fit.sh`, `test-loop-engineering.sh` harness):**
- [ ] Mechanical session fixture (20 `main_turn` rows, high `edit_calls`, low `out_tokens`, `gen_per_edit < 300`, `edit_calls ≥ 10`) → recommends one tier cheaper; message names current+alt cost.
- [ ] Reasoning session (`gen_per_edit > 1200`) on Sonnet → suggests Opus; on Opus → "stay".
- [ ] Mixed session (`gen_per_edit` in 300–1200) → no recommendation, cost line only.
- [ ] Boundary fixtures: `gen_per_edit` 299/300, 1200/1201; `edit_calls` 9/10; `total_turns` 5/6 — assert the branch each side lands in.
- [ ] Minimum-evidence gate: 4-turn session → cost line only, no advice.
- [ ] Tier clamp: mechanical session already on Haiku → no "cheaper" suggestion (can't go below Haiku); reasoning session on Opus → no "up".
- [ ] **The 40k-context robustness test (regression for blocker 1):** two fixtures with identical `tool_counts`/`out_tokens` but one with 5k `in_tokens`/turn and one with 60k `in_tokens`/turn → **both classify identically** (proves the ratio ignores context size; the old design would have split them).

**Subagent exclusion (the critical new coverage — blocker 3):**
- [ ] Log with interleaved `main_turn` (agent:"main") + `dispatch`/`complete` rows (agent:"reviewer", model:"qwen…") + `loop_tool_cost` rows → receipt sums **only** the `main_turn` rows; asserts Qwen/Codex/Gemini rows contribute nothing to ratio or cost.
- [ ] A session that is *all* subagent work (reviewer/red-team) and zero `main_turn` rows → receipt prints nothing (below minimum evidence), never says "switch Qwen to Sonnet".
- [ ] `model` in the receipt is the main-session model from `main_turn.model`, never a subagent model.

**Accrual + fail-safe (integration):**
- [ ] `model_fit_receipt=off` → `model-fit-turn.sh` writes no row; `/handoff` + fallback print nothing.
- [ ] Malformed Stop payload / missing usage → row written with 0 tokens (contributes to ratio via tool_counts), or `exit 0` with no row on hard error; never crashes, never blocks stop.
- [ ] Stop-hook fallback **always exits 0** — assert no `{"decision":"block"}` ever emitted.
- [ ] Once-per-session dedupe: fallback prints once; second Stop in the same session → silent (flag present); new session (flag pruned at SessionStart) → prints again.
- [ ] Cost estimate matches `loop_cost_from_usage` for the summed main-turn tokens at both the current and alternate model's rates.

**Parity (must stay green):**
- [ ] `tests/test-session-prefs-parity.sh` passes with `model_fit_receipt` (8 keys, schema ⇔ BUILTIN).
- [ ] `scripts/verify.sh --tier=2 --skip-requirements` passes (new smoke test for the hook + Stop-registration `jq` assertion).
- [ ] `model-routing.json`, both schemas, both templates are valid JSON; every id in `model_fit.tier_ladder` exists in `providers.anthropic.models`.
- [ ] `skills/session/SKILL.md`, `skills/handoff/SKILL.md`, `skills/goodmorning/SKILL.md` reference the receipt.
- [ ] Existing `/handoff` telemetry read still works (its `event=="dispatch"` filter is unaffected by the new `main_turn` rows).
