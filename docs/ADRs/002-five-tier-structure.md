# ADR 002: Five-tier installation structure

**Status:** Accepted
**Date:** 2026-05-15
**Author:** the maintainer + Claude

## Context

Different users have different complexity tolerance. A senior engineer running a side project doesn't want 21 subagents. A solo architect running a portfolio of production repos wants the full stack. The stack must serve both.

## Decision

Five tiers (0-5), each fully functional standalone, with cumulative install. Tier 5 (Ollama) is bolt-on, not strictly cumulative.

## Alternatives considered

- **Single tier (everything).** Rejected — would force complexity on users who don't need it. Also makes installation intimidating.
- **Two tiers (basic / full).** Rejected — too coarse. Many users want skills (Tier 1) without subagents (Tier 2).
- **Modular (pick any).** Rejected — too much choice. Most users want "give me the right thing for my situation," not "pick from 30 toggles."
- **Five tiers (chosen).** Each tier has a clear theme. Cumulative install is easy to reason about. Per-project override via stack-config.json provides flexibility.

## Consequences

- **Positive:** Graduated adoption. Each tier is testable. Users see clear next step.
- **Negative:** Tier boundaries become load-bearing in the install code. Moving features between tiers later is breaking.
- **Locked in:** The five names + scopes are now public API (once open-sourced).

## References

- Conversation between the maintainer and Claude on 2026-05-15
- Inspiration: tier-style adoption seen in successful dev tools (e.g., shadcn/ui's progressive composition)
