# Phase 2: Claude Code Plugin Distribution

**Status: DEFERRED until v1 is proven.**

This document captures the plan for converting the stack from a git-repo install into a Claude Code plugin, distributed through Anthropic's plugin marketplace.

## Why defer

Plugin format is opinionated. Before locking into it, we want:
- 4+ weeks of Tier 4 runtime data (so /agent-performance-review has informed the design)
- All of the maintainer's repos passing audit (so the stack is proven across real-world projects)
- No breaking changes to stack for 2+ weeks (stability)
- Private data scrubbed (so the repo can go public)
- Polished README (so external users can adopt)

## When to start Phase 2

Triggers (all must be true):
- [ ] Tier 4 has been live for 30+ days
- [ ] /agent-performance-review has been run at least once
- [ ] All 7 the maintainer repos audited and at chosen tier
- [ ] No breaking changes to model-routing, subagent definitions, or tier manifests for 2 weeks
- [ ] PRIVACY.md scrub completed
- [ ] README polished for external audience

## Phase 2 work plan

1. **Verify current Claude Code plugin spec.** Check docs.claude.com — the plugin format may have changed since this doc was written.
2. **Convert repo structure to plugin format.** Likely adds a `plugin.json` manifest at root. Subagents and skills probably map cleanly. Hooks may need wrapping.
3. **Plugin metadata.** Name, version, author, description, tier-aware install logic.
4. **Update channels.** Decide on `latest` / `stable` / `nightly` if applicable.
5. **Test installation via `/plugin install`** in a clean Claude Code environment.
6. **Open-source the repo.** Public on GitHub. Apache 2.0 license already in place.
7. **Announcement.** Blog post, social, share with users who'd benefit.
8. **Issue / PR templates** for community contributions (already drafted in `.github/`).

## What might change

- Plugin format may require restructuring `agents/` and `skills/` folders.
- Plugin marketplace may have additional metadata requirements (icons, categories, screenshots).
- Plugin install may handle some things the install script currently does (e.g., hook registration).

## Don't lose the rationale

When converting, preserve:
- Tier structure (users want graduated adoption).
- Routing rule (the philosophical core).
- Adversarial diversity (the model strategy).
- ADRs (the bus-factor protection).
- Self-improvement skills (the differentiator).

If the plugin format makes any of these harder, push back on the format — maintain the philosophy through the conversion.

## Notes for future self

The plugin path is optional. If Anthropic's plugin ecosystem doesn't take off, or if the git-clone path remains best, stay there. Phase 2 is a distribution improvement, not a goal. Don't sacrifice the design to fit the format.

## Reference

Check live before starting Phase 2:
- https://docs.claude.com (current plugin docs)
- Anthropic's plugin marketplace (browse for current submission process)
