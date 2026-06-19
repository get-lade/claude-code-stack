---
name: config
description: Single front door for all stack settings. Four operations — show current config, get AI-ranked setting recommendations, change one setting interactively, or run a guided setup toward a named goal. Invoked as /config or via natural language ("change my settings", "what should I configure", "set up this repo for X", "configure the stack"). Routes all mutations through the owning setting-skill — never writes stack-config.json directly.
user-invocable: true
model-invocable: true
recommendable: false
tier_min: 2
tools: Read
---

# /config

Single front door for all stack settings. All mutations route through the owning setting-skill (which runs its own confirm/reason flow).

## Security constraints (mandatory)

**Allowlist** — the only settings op3 (change-one-setting) and op4 (guided-setup) may surface or touch:

| Setting dot-path | Owning skill |
|---|---|
| `stack_tier` | `tier` |
| `orchestration_mode` | `agent-teams` |
| `strict_mode` | `strict-mode` |
| `domain_mode` | `domain-mode` |
| `sensitivity.level` | `sensitivity` |
| `session_prefs.communication_style` | `session` |
| `session_prefs.model_effort` | `session` |
| `session_prefs.explanation_verbosity` | `session` |
| `session_prefs.orchestration_mode` | `session` |
| `session_prefs.cost_alert_sensitivity` | `session` |
| `session_prefs.passive_suggest` | `session` |
| `cost_protection.per_session_alert_usd` | `cost-cap` |
| `cost_protection.per_day_alert_usd` | `cost-cap` |

**Denylist** — these MUST NEVER be touched by op3 or op4, must not appear in any recipe, and must never be surfaced as a recommended change:

- `required_approvals` (any value)
- `cost_protection.per_session_hard_cap_usd`
- `providers` (entire block)
- Any field containing secret, key, token, password, keychain, supabase_ref, or similar secret-bearing names

**Enforcement — `/config` self-enforces; it does NOT assume the owning skills enforce these:**

- Before routing ANY automated change (op2 recommended-changes, op4 guided-setup), `/config` checks the target `setting` against the denylist AND rejects any change whose owning skill is `default-edit` (a generic editor that could reach denylisted fields). If either matches, refuse and do not route — print "that setting can't be changed through /config."
- The explicit user confirm for op2/op4 is the **`/config` selection step** (the `AskUserQuestion` where the user picks which change(s) to apply). `/config` owns that gate and does not assume the owning skill re-confirms before writing — several setting-skills apply on selection without a second prompt.
- op3 (change-one-setting) is **explicit user intent**: it hands full control to the owning skill, which owns its own surface (equivalent to the user invoking that skill directly). The denylist applies to the automated paths (op2/op4), not to a user deliberately driving a setting-skill via op3.

## Entry — no arg

When invoked with no argument, present one `AskUserQuestion`:

> What do you want to do with your stack settings?
>
> a) Show current config — view all settings vs defaults (no changes)
> b) Recommended changes — AI-ranked suggestions based on your current context and goal
> c) Change one setting — pick from a menu and hand off to that skill
> d) Guided setup by goal — describe your goal, get a matched change set

Then execute the chosen operation below.

When invoked with a natural-language description (e.g., "configure for security work"), infer the most likely operation and proceed — defaulting to op4 (guided-setup) for goal-like phrases or op1 (show-current) for "show me what's configured" phrases. When ambiguous, ask the menu above.

## Op 1 — show-current

**No mutation. No questions beyond entry.**

### Step 1 — Load files

- Read `.claude/stack-config.json` (project config). If absent, note "no project config — run /project-init".
- Read `~/.claude/session-state/current-prefs.json` (live session prefs). If absent, treat all session prefs as defaults.
- Global defaults are the built-in values noted inline below.

### Step 2 — Print

Print in this exact groups order. For each setting, show: current value | global default | source (built-in / project / session-override).

**Project settings:**

```
Tier:              <stack_tier>   (default: 2)   [source]
Orchestration:     <orchestration_mode>   (default: main-thread)   [source]
Strict mode:       <strict_mode>   (default: true)   [source]
Domain mode:       <domain_mode or "none">   (default: none)   [source]
Sensitivity:       <sensitivity.level>   (default: normal)   [source]
Cost alert/session: $<per_session_alert_usd or "none">   (default: none)
Cost alert/day:    $<per_day_alert_usd or "none">   (default: none)
Hard cap/session:  <"set" if per_session_hard_cap_usd else "not set">   (denylisted here — change via /cost-cap directly)
```

**Session prefs (current-prefs.json or built-in defaults):**

```
Communication:     <communication_style>   (default: balanced)
Model effort:      <model_effort>   (default: balanced)
Verbosity:         <explanation_verbosity>   (default: normal)
Cost alerts:       <cost_alert_sensitivity>   (default: normal)
Passive suggest:   <passive_suggest>   (default: true)
```

**REDACT** (never print):
- The entire `providers` block
- Any field whose name contains: secret, key, token, password, keychain, supabase_ref
- The `notes` subfield of `sensitivity` (may contain path info)
- `model_overrides` and `skill_overrides` (internal implementation detail)

If a redacted field is present, print one line: `[providers / secrets block: redacted]`

### Step 3 — Done

Do not offer to change anything. Print one line: "Run /config again to change a setting."

## Op 2 — recommended-changes

### Step 1 — Collect optional goal

Ask via `AskUserQuestion` (one optional question):

> What's your current goal? (e.g. "ship a security audit", "cut costs", "work with sensitive data") — or press Enter / type "skip" to base recommendations on thread context only.

Capture the user's response as `goal` (null if skipped).

### Step 2 — Call recommend-capabilities (mode:settings)

Assemble the input:

```
mode:            "settings"
thread_context:  <summary of the last 3–5 user turns>
last_user_ask:   <the user's most recent message verbatim>
goal:            <goal from step 1, or null>
session_settings:
  stack_tier:          <from stack-config.json>
  orchestration_mode:  <effective value>
  strict_mode:         <effective value>
  domain_mode:         <effective value or null>
  sensitivity_level:   <sensitivity.level>
  communication_style: <from current-prefs.json or default "balanced">
max_results:     5
```

Invoke `recommend-capabilities`. It returns ranked setting-change candidates.

### Step 3 — Present results

If results are empty, print the engine's `note` and return to entry.

Otherwise present one `AskUserQuestion` with the ranked candidates:

> Recommended changes (pick one to apply, or skip):
>
> a) <setting>: <current_value> → <proposed_value> — <reason> [confidence: <high|medium|low>]
> b) <next candidate>…
> …
> (skip) — no change, return to menu

### Step 4 — Route the chosen change

**Guard first (mandatory):** if the chosen change's `setting` matches the denylist, or its `owning_skill` is `default-edit`, REFUSE — print "that setting can't be changed through /config" and return to step 3. The engine should never propose these, but `/config` enforces it regardless of what the engine returned.

On a valid pick: invoke the **owning_skill** for that change (e.g., `/sensitivity sensitive`). The user's selection here is the consent gate. `/config` does not mutate directly.

After the owning skill completes (or if the user skipped): re-offer the results list from step 3 (so the user can apply a second change). Continue until the user picks "skip" or the list is exhausted.

## Op 3 — change-one-setting

### Step 1 — Pick setting

Present one `AskUserQuestion` with the allowlisted settings only (denylist never appears):

> Which setting do you want to change?
>
> a) Stack tier (/tier)
> b) Orchestration mode (/agent-teams)
> c) Strict mode (/strict-mode)
> d) Domain mode (/domain-mode)
> e) Sensitivity level (/sensitivity)
> f) Session preferences (/session)
> g) Cost caps & alerts (/cost-cap)

### Step 2 — Route verbatim

Hand off to the chosen skill. Reproduce the user's context as-is. Do not add confirm steps, do not pre-validate, do not filter the skill's own prompts. The owning skill runs its complete flow. This is deliberate: op3 is the user explicitly choosing to drive a setting-skill (incl. its full surface, e.g. `/cost-cap`'s hard-cap subcommand) — equivalent to invoking it directly. The denylist guards the AUTOMATED paths (op2/op4), not explicit op3 use.

### Step 3 — Done

After the skill returns, print: "Done. Run /config again to change another setting or view current config."

## Op 4 — guided-setup-by-goal

### Step 1 — Pick goal

Present one `AskUserQuestion`:

> What are you setting this repo up for?
>
> a) Ship fast / low ceremony — streamline for a solo dev or prototype; remove friction
> b) High-assurance security/finance — add domain guardrails for code touching money or auth
> c) Sensitive/regulated data — lock down routing and PII logging for HIPAA/PCI/GDPR work
> d) Cost-controlled experimentation — conservative caps; prevent surprise runaway spending

### Step 2 — Map goal to recipe

Use this HARDCODED table (the LLM must not author alternative recipes):

**Goal a — ship fast / low ceremony**
```
strict_mode:              false         (via /strict-mode off)
orchestration_mode:       main-thread   (via /agent-teams off)
session_prefs.passive_suggest: false   (via /session)
```

**Goal b — high-assurance security/finance**
```
domain_mode:              financial-code  (via /domain-mode financial-code)
strict_mode:              true            (via /strict-mode on)
session_prefs.model_effort: max          (via /session)
```

**Goal c — sensitive/regulated data**
```
sensitivity.level:        sensitive       (via /sensitivity sensitive)
strict_mode:              true            (via /strict-mode on)
session_prefs.passive_suggest: false     (via /session)
```

**Goal d — cost-controlled experimentation**
```
cost_protection.per_session_alert_usd: 2.00   (via /cost-cap session 2.00)
cost_protection.per_day_alert_usd:     10.00  (via /cost-cap day 10.00)
session_prefs.model_effort: fast              (via /session)
```

**Verify no recipe change touches the denylist.** If a future edit ever adds a denylist setting to a recipe, refuse and escalate — do not apply.

### Step 3 — Present the change set

Read current values from `.claude/stack-config.json` and `~/.claude/session-state/current-prefs.json`. For each recipe entry, note current vs proposed.

Skip any entry where `proposed_value === current_value` (already set correctly — note it to the user).

Present one `AskUserQuestion` summarizing the remaining changes:

> For goal "<goal label>", these changes are recommended:
>
> a) <setting>: <current> → <proposed>   (via /<owning-skill>)
> b) <setting>: <current> → <proposed>   (via /<owning-skill>)
> …
> Apply all? Or pick individual changes:
> z) Skip — no changes

### Step 4 — Route changes sequentially

For each confirmed change (all or individually per user pick): invoke the owning skill in sequence. Each skill runs its own confirm/reason flow.

After all changes: print a summary of what was applied and what was skipped.

## What /config NEVER does

- Writes `.claude/stack-config.json` directly.
- Writes `~/.claude/stack-defaults.json` directly.
- Prints any value from the `providers` block or secret-bearing fields.
- Proposes or applies changes to denylisted settings.
- Bypasses or short-circuits a setting-skill's own confirm/reason flow.
- Generates free-form config mutations not in the hardcoded recipe table (op4).
