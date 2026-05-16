# ADR 010: Defaults system with shortcut skills for every important setting

**Status:** Accepted
**Date:** 2026-05-15 (v1.1)
**Author:** the maintainer + Claude

## Context

v1.0 had `stack-config.json` per project but no global defaults file and no easy way to view or change settings post-init. the maintainer: *"Maybe / default-settings and / default-edit?? ... no downside in having all of the defaults or settings enabled with shortcuts."*

## Decision

Three-layer configuration system + shortcut skills for every important setting.

**Three-layer config:**
1. **Stack-shipped defaults** — in install scripts, conservative
2. **User global defaults** — `~/.claude/stack-defaults.json`, set during install, edited via `/default-edit global`
3. **Project config** — `<project>/.claude/stack-config.json`, set during `/project-init`, edited via `/default-edit project`

**Skills:**
- `/project-init` (upgraded, Tier 1) — two modes (quick / review); walks user through settings; safety-relevant changes prompt for reason + offer to update global default.
- `/default-settings` (new, Tier 1) — read-only view of effective config; flags divergence between global and project.
- `/default-edit` (new, Tier 1) — interactive editor; safety prompts; can update global or project.
- **Shortcut skills** for common flags: `/agent-teams`, `/strict-mode`, `/domain-mode`, `/sensitivity`, `/cost-cap`, `/tier`. Each shortcut: no-arg shows status, with-arg flips with safety prompts.

**Safety-relevant change pattern:** for strict-mode → off, domain-mode escape, sensitivity downgrade:
1. Prompt for one-line reason (logged to stack-config.json `change_history`)
2. Ask "should this also become your default for new projects?" with three options: yes (update global) / no (just this project) / show recent overrides (pattern detection trigger)

## Alternatives considered

- **Only `/default-edit`, no shortcuts.** Rejected — the maintainer: "no downside in having all of the defaults or settings enabled with shortcuts."
- **Only shortcuts, no editor.** Rejected — some settings (model overrides, approval gates) are complex enough to deserve a full editor.
- **Shortcuts + editor + project-init walkthrough (chosen).** Three access paths for three different needs: full editor, focused flip, walkthrough on init.

## Consequences

- **Positive:** Every important setting is user-visible and user-controllable from day one. Pattern detection via "show recent overrides" creates feedback loop into librarian. Two-mode `/project-init` respects both deliberate-first-project and quick-routine-project use cases.
- **Negative:** Many skills to maintain. Each shortcut needs parallel safety-prompt logic.
- **Locked in:** Shortcut naming pattern (`/<setting-name>` with no-arg showing status). Adding a new important setting now requires both `/default-edit` schema update AND a shortcut skill.

## References

- v1.1 corrections changelog
- Conversation between the maintainer and Claude on 2026-05-15 (defaults design)
- Skills: `/project-init`, `/default-settings`, `/default-edit`, `/agent-teams`, `/strict-mode`, `/domain-mode`, `/sensitivity`, `/cost-cap`, `/tier`
