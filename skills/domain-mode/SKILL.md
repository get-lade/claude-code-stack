---
name: domain-mode
description: Shortcut to set the project's domain mode. Domain modes enable extra safety rules (financial-code forces validator+red-team+security-auditor; schema-migration forces dry-run; deploy forces ops pre+post). /domain-mode <name> sets it. /domain-mode none clears it (safety-relevant). /domain-mode (no arg) shows current. Domain modes are enforced by foreman skill on every dispatch.
---

# /domain-mode

Set the project's domain mode. Domain modes activate extra safety rules in foreman.

## Usage

```
/domain-mode                          # status
/domain-mode status                   # status with history
/domain-mode financial-code           # set
/domain-mode schema-migration         # set
/domain-mode deploy                   # set
/domain-mode ui-design                # set
/domain-mode data-operation           # set
/domain-mode none                     # clear (safety-relevant if was set)
```

## Steps

### 1. No arg / status
- Read `.claude/stack-config.json` `domain_mode` field
- Print:
  - Current mode (or "none")
  - When last changed
  - What's enforced under this mode (read from `~/.claude/config/domain-modes.json`)
  - Global default value

### 2. Set to one of: financial-code | schema-migration | deploy | ui-design | data-operation

Step 2a: Verify the mode exists in `~/.claude/config/domain-modes.json`. If not, refuse with "Unknown domain mode. Available: <list>."

Step 2b: If domain_mode was previously set to something else AND old mode was financial-code/schema-migration (escape from stricter mode): treat as safety-relevant (full safety flow per /strict-mode off pattern).

Step 2c: If setting to financial-code or schema-migration: also check `orchestration_mode`. If set to agent-teams, soft-warn:
> Note: orchestration_mode is currently agent-teams (experimental). Agent Teams is not recommended for <financial-code|schema-migration> work without deliberate acceptance.
> Continue? [y/N]

Step 2d: Apply
- Update `.claude/stack-config.json` `domain_mode: "<value>"`
- Append to change_history
- Print "Domain mode set to <X>. Foreman will now enforce: <list of rules from domain-modes.json>"

### 3. none (safety-relevant if previously set)

Full safety flow per /strict-mode off pattern. Reason capture + global default offer.

Then:
- Update `.claude/stack-config.json` `domain_mode: null`
- Print "Domain mode cleared. Foreman will use default routing without domain-specific safety rules."

## Validation

- Must be called inside a project directory
- Mode value must exist in domain-modes.json
- Escape from financial-code or schema-migration triggers safety flow
