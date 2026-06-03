---
name: cost-gate
description: Run before any bulk LLM job (>100 rows or any LLM-per-row script). Samples 10 rows, measures actual tokens, projects total cost, writes projection to .claude/cost-projections/, and stops for explicit approval. Use when about to kick off scripts matching enrich|backfill|bulk-*|rescue or anything calling an LLM in a loop. Targets the cost-runaway friction pattern (May 2026 — $123 unexpected charges before halted).
---

# /cost-gate

Sample, measure, project, stop. Do not run the full job until the user types "proceed".

## Steps

### 1. Identify the job
- Ask which script will run, total row count, and the LLM model.
- Find the limit flag — read argv parsing for `--limit`, `--max`, `--n`, `--batch-size`.
- If no limit flag exists, say so and stop. (Don't proceed without sample capability.)

### 2. Run a 10-row sample
- Run with limit set to 10.
- Capture per call: input tokens, output tokens, wall time, API errors.
- If the script doesn't log token usage: wrap the LLM call with a temporary logger that prints `{input_tokens, output_tokens, model}`. Revert before exiting.

### 3. Compute per-call cost
- Use current pricing for the model.
- **Confirm pricing live via web_search if uncertain.** Apr 2026 friction was a 3.4× underforecast.
- Starting reference (verified 2026-05-15 — confirm before use):
  - Claude Opus 4.7: ~$5/M in, ~$25/M out
  - Claude Sonnet 4.6: ~$3/M in, ~$15/M out
  - Claude Haiku 4.5: ~$1/M in, ~$5/M out
  - GPT-5.5: ~$2.50/M in, ~$15/M out
  - Gemini 2.5 Pro: ~$1.25/M in, ~$10/M out
- avg_per_call = mean of the 10 samples (use median if max > 2× median; flag the variance).

### 4. Project total
- projected_cost = avg_per_call × total_rows
- projected_time = avg_wall_time × total_rows (adjust for script parallelism)
- Flag if any sample call returned errors — extrapolate failure rate.

### 5. Write the projection

```bash
mkdir -p .claude/cost-projections
```

Write to `.claude/cost-projections/<YYYY-MM-DD>-<script-basename>.md`:

```markdown
# Cost projection: <script>

_Run: <timestamp>_

## Summary
- Model: <name>
- Sample size: 10
- Per-call avg: <X> tokens in, <Y> tokens out → $<Z>
- Total rows: <N>
- **Projected total cost: $<total>**
- Projected wall time: <duration>
- Sample error rate: <pct>

## Variance flags
- <e.g., "max sample 2.8× median — likely scanned PDFs; actual cost could 3× projected">

## Sample data
| Call # | In tokens | Out tokens | $ cost | Wall (s) |
|---|---|---|---|---|
| 1 | ... | ... | ... | ... |
...

## Approval needed
Type "proceed" to run the full job. Or:
- "downgrade to Haiku" — re-sample with cheaper model
- "abort" — don't run
- "adjust" — tell me what to change
```

### 6. Gitignore the directory (one-time per repo)
- Check `.gitignore` for `.claude/cost-projections/`. If absent, append it.

### 7. Stop and wait
Print 3-4 line summary to chat. End with:
> "Type 'proceed' to run the full job, or tell me what to change."

Do NOT run the full script. Do NOT background it. Wait for the explicit word.

### 8. After approval: log to cost_log (Tier 2+ only)
If Supabase cost_log table exists (Tier 2+), the FULL run writes to it as it goes — not just the projection.
