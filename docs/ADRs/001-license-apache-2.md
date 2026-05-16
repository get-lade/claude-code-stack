# ADR 001: License under Apache 2.0

**Status:** Accepted
**Date:** 2026-05-15
**Author:** the project maintainer + Claude (Opus 4.7)

## Context

The stack will eventually be open-sourced (Phase 2 plan). License choice affects who can use it, how, and whether commercial adoption is possible.

## Decision

Apache 2.0.

## Alternatives considered

- **MIT.** Simpler, permissive. Rejected because Apache 2.0 adds explicit patent grant — important for a project that codifies process patterns that might be patentable in some jurisdictions.
- **MPL 2.0.** Weak copyleft. Rejected because we want commercial users to integrate without source-disclosure obligations.
- **GPL v3.** Strong copyleft. Rejected because it would deter commercial adoption.
- **Apache 2.0 (chosen).** Permissive + explicit patent grant + widely understood + commercially friendly.

## Consequences

- **Positive:** Maximum reach. Commercial users can adopt freely. Patent grant protects contributors.
- **Negative:** No "must contribute back" enforcement. Improvements may stay private.
- **Locked in:** Can't switch to a stricter license later without contributor consent.

## References

- https://www.apache.org/licenses/LICENSE-2.0
- choosealicense.com
