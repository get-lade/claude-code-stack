# ADR 007: Distribute as git repo first, plugin second

**Status:** Accepted
**Date:** 2026-05-15
**Author:** the maintainer + Claude

## Context

Stack can be distributed as a git repo (clone + install.sh) or as a Claude Code plugin (one-command install). Which first?

## Decision

Phase 1: git repo (`github.com/bschonbrun/claude-code-stack`). Phase 2 (deferred until v1 proven): Claude Code plugin.

## Alternatives considered

- **Plugin only.** Rejected — plugin format is opinionated and may not fit yet. We need flexibility to iterate.
- **Both simultaneously.** Rejected — splits attention. v1 in repo form first; plugin once stable.
- **Git repo first, plugin later (chosen).** Iterate in repo. Once stable, package for plugin.

## Consequences

- **Positive:** Iterate freely without locking into plugin format. Public-ready when we decide to open-source. Phase 2 work captured separately so it doesn't get forgotten.
- **Negative:** Two distribution mechanisms to maintain eventually.
- **Locked in:** Public repo URL (`github.com/bschonbrun/claude-code-stack`) is the canonical reference. Don't rename casually.

## Phase 2 triggers

See PHASE-2-PLUGIN.md for the full list. Summary:
- Tier 4 has 30+ days of runtime data
- All 7 the maintainer repos audited
- No breaking changes for 2 weeks
- Private data scrubbed
- README polished

## References

- PHASE-2-PLUGIN.md
- Conversation between the maintainer and Claude on 2026-05-15
