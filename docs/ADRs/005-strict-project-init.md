# ADR 005: Strict mode for foreman — refuse to dispatch without stack-config.json

**Status:** Accepted
**Date:** 2026-05-15
**Author:** the maintainer + Claude

## Context

Without enforcement, users (the maintainer) will start working in a project without running /project-init. Then foreman has to guess at tier and subagent composition. This leads to inconsistent behavior across sessions and across projects.

## Decision

Foreman runs in strict mode by default. If a project lacks `.claude/stack-config.json`, foreman refuses to dispatch and tells the user to run /project-init first.

## Alternatives considered

- **Permissive (always dispatch, use sensible defaults).** Rejected — leads to "wait why is foreman acting weird in this project" debugging. Defaults need to be EXPLICIT not implicit.
- **Soft warning.** Rejected — the maintainer will ignore the warning. He told us so ("strict is the right approach").
- **Strict (chosen).** Forces intentional configuration. Side effect: every project's tier is documented in git, which serves bus-factor.

## Consequences

- **Positive:** Every project has explicit tier. Bus-factor protection. No surprises.
- **Negative:** /project-init friction at start of every new project. Solo developers may find this annoying initially.
- **Locked in:** This is now part of the stack's identity. Permissive mode is an escape hatch (stack_strict_mode=false in ~/.claude/settings.json), not a default.

## Escape hatches

- `~/.claude/settings.json` can set `stack_strict_mode: false` globally.
- User can invoke individual subagents directly, bypassing foreman ("skip foreman").
- /dispatch skill lets user manually compose teams without /project-init.

## References

- Conversation between the maintainer and Claude on 2026-05-15
