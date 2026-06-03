---
name: sensitivity
description: Shortcut to set the project's data sensitivity level. Three levels — normal (default), sensitive (PII present — extra logging), confidential (regulated data — local-ops routing required, cloud subagents restricted). /sensitivity <level> sets it. Downgrading is safety-relevant. /sensitivity (no arg) shows current and what it restricts.
---

# /sensitivity

Set the project's data sensitivity level.

## Usage

```
/sensitivity                  # status
/sensitivity status           # status with history
/sensitivity normal           # default — no restrictions
/sensitivity sensitive        # PII may be present (safety-relevant if upgrading from normal? no — only downgrades trigger safety)
/sensitivity confidential     # regulated/restricted (local-ops routing required)
```

## Steps

### 1. No arg / status
- Read `.claude/stack-config.json` `sensitivity.level` field
- Print:
  - Current level
  - When last changed
  - What's restricted at this level:
    - normal: no restrictions
    - sensitive: subagent_runs logs PII-touched files; bulk-job-reminder fires more aggressively
    - confidential: local-ops subagent required for data-touching tasks; cloud subagents restricted from reading these files
  - Global default value

### 2. Set to normal (downgrade — safety-relevant)

If current level is sensitive or confidential, this is a DOWNGRADE. Full safety flow per /strict-mode off pattern:

Step 2a: Prompt
> Safety check: you're downgrading sensitivity from <current> to NORMAL.
> This will:
> - Stop logging PII-touched files (if was sensitive or higher)
> - Allow cloud subagents to access previously restricted files (if was confidential)
>
> Reason for this change? (one line)

Step 2b: Reason capture + global default offer (same pattern)

Step 2c: Apply

### 3. Set to sensitive or confidential (upgrade — no safety flow)

- Update `.claude/stack-config.json` `sensitivity.level: "<value>"`
- Append to change_history (no reason needed for upgrades)
- If confidential: print "Confidential mode set. Local-ops subagent is now required for data-touching tasks. Cloud subagents (Anthropic/OpenAI/Google) restricted from reading files in: <list paths from sensitivity.notes>."
- Also prompt: "Add any specific paths to mark as confidential? (paths comma-separated, or empty)" — populates `sensitivity.notes`.

## Validation

- Must be called inside a project directory
- Setting to confidential requires Tier 5 (local-ops) to be installed; warn if not
- Confidential mode + orchestration_mode=agent-teams = warn (Agent Teams is experimental for sensitive work)
