# ADR 017: Capability recommender — one shared engine, three feature shapes

**Status:** Accepted
**Date:** 2026-06-19
**Author:** the maintainer + Claude (architect) — reviewed by product-critic (Codex), reviewer (Codex), red-team (Gemini)

## Context

The stack ships ~33 skills and ~22 subagents, but discovery is poor: users don't know what exists or which capability fits their current ask. Three features were proposed (explicit `/suggest`, an always-watching nudge hook, a config control panel).

Two hard constraints from the cloud target:
1. **No slash commands in cloud sessions** → every user-facing feature must be invokable by natural language and use the shared engine, not slash-only logic.
2. **No GUI** → the control panel is `AskUserQuestion`-driven only.

There is **no capability registry today**. `claude-automation-recommender` (Tier 0, read-only) recommends *external/new* automations (MCP servers, hypothetical hooks) from hardcoded tables — it does NOT enumerate *this stack's installed* skills/agents. The recommender these features need does not exist and must be built.

Adversarial review (Codex reviewer + Gemini red-team) blocked the first draft on consent, cloud-distribution, namespace-collision, and security-of-mutation grounds. This ADR records the design as revised by the maintainer's four decisions (2026-06-19).

## Decision

**1. One shared core: `recommend-capabilities`, a Claude-only skill** (`skills/recommend-capabilities/SKILL.md`, `user-invocable: false`). Not a shell lib — ranking requires semantic judgment over thread context. The skill defines the input contract, the registry source, the ranking rubric, and the output schema. All three features call it; none forks ranking logic. Marked **non-recommendable** (it and `/config` never appear in their own results).

**2. Capability registry = a committed, generated static index** (`config/capability-registry.json`), built from `skills/*/SKILL.md` and `agents/*.md` frontmatter by `scripts/gen-capability-registry.sh`. **[Decision 4]** The JSON is **committed to the repo** so the manifest file-copy installs it on every path including cloud (`cloud-bootstrap.sh` → `install.sh` copies files but does not run scripts). A **pre-commit/CI freshness check** re-runs the generator and fails if the committed file is stale. The engine reads the JSON; it never re-parses frontmatter at runtime, and it **verifies the recommended capability's file still exists** before returning it (staleness guard).

Each entry: `{id, kind, summary, invocation{slash, natural_language}, tier_min, user_invocable, model_invocable, recommendable}`.

**3. Feature A `/suggest`** — thin user-facing skill (`skills/suggest/SKILL.md`), **slash + natural-language** trigger, thread-scoped, 3–5 ranked results. Gather-delegate-render shell: it assembles inputs and delegates all ranking to `recommend-capabilities` (`mode:discovery`). No forked logic.

**4. Feature B — fold into `dispatch-nudge.sh`; no sibling hook.** Add one session setting, `passive_suggest` (boolean, default `true`), gating only the recommender pointer.
- **[Decision 1] Fail-OPEN:** missing/invalid `passive_suggest` → treated as `true` (preserves current discoverability). **Consent caveat (accepted):** a wiped or cloud-restarted session-state silently re-enables nudging for a user who opted out; mitigated (not eliminated) by the per-session dedupe below and documented in `/session`. Fail-closed was the red-team recommendation; the maintainer chose fail-open for discoverability.
- **[Adopt] `passive_suggest:false` silences ONLY the recommender pointer** — the existing `/foreman`/`/dispatch` routing nudge still fires unconditionally.
- **[Adopt] Gate order:** all cheap in-memory checks (slash skip, word count, trigger words, tier ≥2) run BEFORE any file I/O; `passive_suggest` is read only after they pass.
- **[Adopt] Per-session dedupe:** after the first injection, touch `~/.claude/session-state/passive_suggest.nudged`; the hook exits early if present. Reset at SessionStart. Kills the infinite-nudge loop.
- The hook never ranks — it gates and hands off to the engine.

**5. Feature C — `/config` router, the single front door for settings.** (`skills/config/SKILL.md`, slash + NL.) Four operations, each dispatching to an existing setting-skill or `AskUserQuestion`; it never writes `stack-config.json` directly.
- **[Decision 3] Single front door:** `/config` becomes the entry point; `/default-settings` (view) and `/default-edit` (mutate) get deprecation/forwarding notices pointing to `/config`. One authoritative path.
- Ops: **show-current**, **recommended-changes**, **change-one-setting**, **guided-setup-by-goal**.
- **[Decision 2] op4 ships constrained:** goal→settings is a **hardcoded recipe table in `/config`** (not the engine — engine stays two modes). Guarded by an **allowlist** of mutable settings and a **denylist** (`required_approvals`, cost caps, `providers`/secrets) that op4 may never touch, plus a **mandatory per-change confirm**. The LLM navigates; it does not freely author config mutations.
- **[Adopt] show-current redacts the `providers` block** (supabase ref, keychain item names) and any secret-bearing fields.

## Interface contracts

### Registry — `config/capability-registry.json` (committed)
```json
{
  "generated_at": "<iso8601>",
  "stack_version": "1.1.3",
  "capabilities": [
    {
      "id": "handoff", "kind": "skill",
      "summary": "<first sentence of frontmatter description>",
      "invocation": { "slash": "/handoff", "natural_language": "ask me to write a session handoff" },
      "tier_min": 0, "user_invocable": true, "model_invocable": true, "recommendable": true
    }
  ]
}
```
Generator rules: `kind` from source dir; `summary` = first sentence of `description`; `invocation.slash` = `/<name>` for skills, `null` for subagents; **[Adopt] `tier_min` from a new explicit `tier_min:` frontmatter field, default `0`** if absent; `recommendable:false` for meta-skills (`recommend-capabilities`, `config`); sorted by `id` for stable diffs.

### Engine — `skills/recommend-capabilities/SKILL.md` (Claude-only, tools: Read, Grep)
Input (assembled by caller, passed in-prompt):
```
mode:            "discovery" | "settings"
thread_context:  <recent thread summary>
last_user_ask:   <latest user message verbatim>
session_settings: { stack_tier, orchestration_mode, strict_mode, domain_mode,
                    sensitivity_level, communication_style }   # NOTE: sensitivity_level is the scalar from sensitivity.level
max_results:     <int, default 5>
```
Output:
```json
{ "mode": "discovery",
  "results": [ { "id": "handoff", "kind": "skill", "reason": "<1 sentence>",
                 "confidence": "high|medium|low",
                 "invocation": { "slash": "/handoff", "natural_language": "..." } } ],
  "note": "<optional, e.g. 'no strong match'>" }
```
Ranking: filter `tier_min <= stack_tier`; rank `summary` relevance to `last_user_ask` + `thread_context`; respect `domain_mode`/`sensitivity_level`; exclude `recommendable:false`; cap at `max_results`; empty `results` + `note` below a relevance floor. `confidence` is the enum `high|medium|low` (no float).

### `dispatch-nudge.sh` + `passive_suggest`
- `passive_suggest` (boolean, default true) added to: `current-prefs.json`, `stack-defaults.json` (`session_prefs_defaults`), `stack-config-schema.json` (`session_prefs`), `stack-defaults-schema.json`, and the `/session` menu.
- **[Adopt] Single source of truth:** `session-prefs-init.sh` builds defaults by reading the schema's declared defaults rather than a hardcoded `BUILTIN` string, eliminating the 5-point desync surface. (If schema-read is impractical in pure bash, the BUILTIN is the *one* canonical place and a test asserts schema⇄BUILTIN parity.)
- Both schema `session_prefs(_defaults)` blocks are `additionalProperties:false` — the new key MUST be added there or validation rejects the file.

### `/config` router
| Op | Mutates? | Dispatches to |
|----|----------|---------------|
| show-current | no | reads `stack-config.json` + `current-prefs.json`, **redacts `providers`** |
| recommended-changes | via owning skill | engine `mode:settings` → route chosen change to its skill |
| change-one-setting | via owning skill | `AskUserQuestion` → `/tier`/`/sensitivity`/… (their own safety flow) |
| guided-setup-by-goal | via owning skill | hardcoded recipe table + allowlist/denylist + confirm → route each change |

## Control-panel UX (cloud-compatible, AskUserQuestion-only)
- **Entry (no arg):** one `AskUserQuestion` a/b/c/d for the four ops.
- **show-current:** no questions; print tier, orchestration_mode, strict_mode, domain_mode, sensitivity, cost caps, session prefs (incl. `passive_suggest`), each vs its global default; `providers` redacted.
- **recommended-changes:** engine `mode:settings` → `AskUserQuestion` of ranked changes (pick one or skip) → owning skill runs its confirm/reason flow → re-offer.
- **change-one-setting:** `AskUserQuestion` picks setting → hand off to that skill verbatim.
- **guided-setup-by-goal:** `AskUserQuestion` picks a goal → recipe table maps to an allowlisted change set → per-change confirm → route each through its owning skill sequentially. Denylisted settings never appear.

## Alternatives considered
- **Shared core as a shell lib.** Rejected — relevance ranking over free text is semantic; bash keyword-match forces per-caller re-ranking (the forked-logic failure).
- **New sibling always-watching hook.** Rejected (product-critic + reviewer) — duplicates `dispatch-nudge.sh`'s gate and doubles UserPromptSubmit cost; folding in adds one setting + one branch.
- **Monolithic `/config` that mutates settings directly.** Rejected — re-implements safety flows owned by `/tier`, `/sensitivity`, etc.
- **Free-form LLM goal→config in op4.** Rejected (red-team blocker) — can disable security gates, null cost caps, expose secrets. Constrained to recipes + allowlist/denylist + confirm.
- **Fail-closed `passive_suggest`.** Considered (red-team recommendation); maintainer chose fail-open for discoverability with the consent caveat documented.
- **Registry generated at install (not committed).** Rejected (Decision 4) — `install.sh` copies files, doesn't run scripts; cloud would get no registry. Commit + freshness check instead.
- **Runtime frontmatter parse.** Rejected — slow, non-deterministic, re-globs ~55 files per call.

## Consequences
- **Positive:** one ranking rubric + one registry; cloud-compatible; no new hook; existing setting-skill safety flows reused; `dispatch-nudge.sh` gains a real off switch; `/config` is the single discoverable settings front door.
- **Negative / accepted risk:** fail-open means a wiped state re-enables nudging for opt-out users (mitigated by dedupe + docs); committed registry can drift (mitigated by CI freshness check); `passive_suggest` spans multiple files (mitigated by single-source-of-truth defaults); deprecating `/default-settings`/`/default-edit` touches existing skills.
- **Locked-in public surface:** `config/capability-registry.json` shape, the engine I/O contract, the `passive_suggest` key, the new `tier_min` frontmatter field.

## Implementation plan (next session — NOT done here)
New: `skills/recommend-capabilities/SKILL.md`, `skills/suggest/SKILL.md`, `skills/config/SKILL.md`, `scripts/gen-capability-registry.sh`, `config/capability-registry.json` (committed), CI/pre-commit freshness check.
Modify: `hooks/dispatch-nudge.sh`, `hooks/session-prefs-init.sh` (+ SessionStart dedupe reset), `skills/session/SKILL.md`, `schemas/stack-config-schema.json`, `schemas/stack-defaults-schema.json`, `~/.claude/stack-defaults.json`, `skills/default-settings/SKILL.md` + `skills/default-edit/SKILL.md` (deprecation notices), tier manifests (assign tiers to the 3 new skills), `install.sh` (no script-run needed — registry is committed).
Open sub-task: assign `tier_min` frontmatter to existing skills/agents (bulk; default 0 until done).

## References
- ADR-010 (defaults + shortcut skills) — router reuses these.
- ADR-016 (workflow-roster fence) — precedent for one key, fail-open default, no auto-escalation.
- `.claude/sessions/suggest-hook-controlpanel-critique/` — product-critique.md, foreman-report.md.
