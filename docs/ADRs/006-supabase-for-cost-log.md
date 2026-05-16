# ADR 006: Use Supabase for cost_log and subagent_runs

**Status:** Accepted
**Date:** 2026-05-15
**Author:** the maintainer + Claude

## Context

Tier 2+ needs persistent storage for cost tracking and (Tier 4) performance review. Where does this live?

## Decision

Supabase project `<your-supabase-ref>` (the maintainer's existing shared project). New tables: cost_log, subagent_runs, model_audits.

## Alternatives considered

- **SQLite locally.** Rejected — the maintainer works across multiple machines (laptop, maybe Pro upgrade). Multi-machine state needs central store.
- **CSV files.** Rejected — same multi-machine problem. Plus harder to query for /agent-performance-review.
- **New Supabase project just for stack.** Rejected — adds management overhead. the maintainer's existing project is already configured, has auth working, has migrations infrastructure.
- **Existing Supabase project (chosen).** Reuses what works.

## Consequences

- **Positive:** Multi-machine ready. Easy to query for perf reviews. Existing auth/keychain setup works. RLS available.
- **Negative:** Stack-level state lives in the maintainer's user project. If the project is migrated, stack data goes with it.
- **Locked in:** Schemas are now part of the stack. Migrations to the stack schemas need version management.

## Privacy

cost_log and subagent_runs do NOT log code contents, secrets, or sensitive data. Only metadata (task summaries, token counts, costs, outcomes). See PRIVACY.md.

## References

- Schemas: schemas/001-cost-log.sql, 002-subagent-runs.sql, 003-model-audits.sql
- Conversation between the maintainer and Claude on 2026-05-15
