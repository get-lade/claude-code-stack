---
name: ultracode
description: Session-scoped risk dial that raises the loop autonomy ceiling one level above the tier default (capped at bounded-autonomous) and is read by the ADR-021 design-before-code gate. /ultracode on enables it for this session, /ultracode off disables, /ultracode (no arg) or status shows current state. Not persisted in stack-config — it is a per-session opt-in, set here or via the CLAUDE_ULTRACODE env var.
tier_min: 2
user-invocable: true
model-invocable: false
recommendable: true
tools: Bash, Read
---

# /ultracode

A **session-scoped risk dial** (ADR-019 §4). When on, the loop-engineering
control plane raises the autonomy ceiling **one level above the tier default**
(checkpoint → bounded-checkpoint → bounded-autonomous, capped at
bounded-autonomous), and the ADR-021 design-before-code gate becomes active.
Ultracode is **additive**, not a synonym for Tier 4 — it lifts whatever the
tier ceiling already is.

It is deliberately **not** persisted in `stack-config.json`: it is a per-session
opt-in so an elevated ceiling never silently outlives the session that asked for
it. Two signals are honored (either turns it on):

- env `CLAUDE_ULTRACODE` ∈ `1|true|on|yes`, or
- session-state flag `~/.claude/session-state/ultracode-state.json` → `{"active":true}`.

## Usage

```
/ultracode          # status
/ultracode status   # status
/ultracode on       # raise ceiling +1 for this session
/ultracode off      # back to the tier default ceiling
```

## Steps

1. **Resolve state dir.** `STATE_DIR="${LOOP_STATE_DIR:-$HOME/.claude/session-state}"`;
   `FILE="$STATE_DIR/ultracode-state.json"`.

2. **status / no-arg:** source the lib and report:
   ```bash
   source ~/.claude/skills/loop-engineer/loop_lib.sh
   if loop_ultracode_active; then echo "ultracode: ON"; else echo "ultracode: off"; fi
   ```
   Also note which signal is active (env vs state file) so a surprising state is
   explainable.

3. **on:**
   ```bash
   mkdir -p "$STATE_DIR"
   printf '{"active":true,"set_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$FILE"
   ```
   Then print the effective ceiling for the current tier:
   `loop_effective_ceiling <tier_ceiling> true`.

4. **off:**
   ```bash
   printf '{"active":false}\n' > "$FILE"
   ```
   (If `CLAUDE_ULTRACODE` is set in the env, warn that the env var still forces
   it on for this shell — unset it to fully disable.)

## What this does NOT do

- Does NOT change `stack-config.json` or any tier setting.
- Does NOT raise the ceiling above `bounded-autonomous` (hard cap).
- Does NOT survive the session unless the env var is set externally.
