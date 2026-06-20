# Loop-Engineering Control Plane — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Phase-1 governed loop control plane — a `/loop-engineer` front door, a shared bash lib, a fail-closed Stop-hook, an irreversible-action deny hook, a `loop_policy` config block, and foreman loop-shape routing — so a bounded autonomous loop can run with enforced caps.

**Architecture:** A control plane *above* foreman. The `/loop-engineer` skill validates a loop spec and writes `~/.claude/session-state/loop-state.json`. A `Stop` hook reads that state on every stop attempt and either blocks (keep iterating) or releases (goal met / bound tripped), fail-closed. A `PreToolUse` deny hook blocks irreversible Bash during an active loop. foreman gains a loop-shape detection step that writes the chosen pattern into loop-state. All bash logic is shared via `loop_lib.sh` (DRY).

**Tech Stack:** bash + `jq` (hooks/lib), JSON Schema Draft-7 (`stack-config-schema.json`), the stack's tier-manifest copy/install system, the existing bash test harness style (`tests/test-*.sh`).

**Spec:** `docs/superpowers/specs/2026-06-20-loop-engineering-design.md` (v2). This plan implements **Phase 1 only** — §11. Phase 2 (Supabase `loop_runs`, live mid-flight cost monitor, ultracode signal) and ADR-020 (superpowers gate) are separate plans.

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `skills/loop-engineer/loop_lib.sh` | Shared bash: read/write loop-state (atomic), state-hash, spec validation, bound checks, cost accrual | Create |
| `skills/loop-engineer/SKILL.md` | Front door: validate spec → write loop-state; refuse if invalid | Create |
| `hooks/loop-stop.sh` | Stop hook: per-stop gate (met? bounds? progress?), fail-closed | Create |
| `hooks/irreversible-deny.sh` | PreToolUse Bash: deny push/merge/deploy/rm-rf/money during an active loop | Create |
| `schemas/stack-config-schema.json` | Add `loop_policy` object (schema is `additionalProperties:false` → required) | Modify |
| `templates/stack-config.template.json` | Ship `loop_policy` defaults | Modify |
| `hooks/hooks.json` | Register `Stop` + `PreToolUse[Bash]` hooks | Modify |
| `config/tier-manifests/tier-2.json` | Copy skill + lib + hooks; smoke tests | Modify |
| `skills/foreman/SKILL.md` | New "Detect loop-shape" boot step + routing table | Modify |
| `tests/test-loop-engineering.sh` | Regression suite for lib + hooks | Create |

**`loop-state.json` contract (the shared interface every component reads/writes):**

```json
{
  "active": true,
  "loop_id": "babysit-prs",
  "pattern": "ralph",
  "goal": "all tests pass and lint is clean",
  "success_criterion": { "type": "shell", "command": "npm test && npm run lint" },
  "autonomy": "bounded-autonomous",
  "require_external_termination": true,
  "bounds": { "max_iterations": 25, "max_recursion_depth": 5, "per_run_budget_usd": 5, "timeout_minutes": 180 },
  "iteration": 0,
  "cost_so_far_usd": 0,
  "no_progress_count": 0,
  "last_state_hash": "",
  "started_at": "2026-06-20T18:00:00Z",
  "status": "active"
}
```

`status` ∈ `active | met | max_iterations | budget_exceeded | timeout | no_progress | escalated`.

---

## Task 1: `loop_lib.sh` — read/write loop-state (atomic)

**Files:**
- Create: `skills/loop-engineer/loop_lib.sh`
- Test: `tests/test-loop-engineering.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-loop-engineering.sh`:

```bash
#!/usr/bin/env bash
# Regression suite for the loop-engineering Phase-1 control plane.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/skills/loop-engineer/loop_lib.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
[[ -f "$LIB" ]] || { echo "FAIL: loop_lib.sh not found at $LIB"; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Isolate state dir per run
export HOME="$(mktemp -d)"
# shellcheck disable=SC1090
source "$LIB"

# read on empty -> {}
[[ "$(loop_read_state)" == "{}" ]] && ok "read empty -> {}" || bad "read empty"

# write then read roundtrip
loop_write_state '{"active":true,"iteration":2}'
got="$(loop_read_state | jq -r '.iteration')"
[[ "$got" == "2" ]] && ok "write/read roundtrip" || bad "roundtrip got=$got"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-loop-engineering.sh`
Expected: FAIL with "loop_lib.sh not found".

- [ ] **Step 3: Write minimal implementation**

Create `skills/loop-engineer/loop_lib.sh`:

```bash
#!/usr/bin/env bash
# Shared library for the loop-engineering control plane.
# Sourced by the /loop-engineer skill helper and the loop hooks.
# All functions are fail-safe: errors never crash the caller.
set -uo pipefail

LOOP_STATE_DIR="${LOOP_STATE_DIR:-$HOME/.claude/session-state}"
LOOP_STATE_FILE="$LOOP_STATE_DIR/loop-state.json"

loop_read_state() {
  if [[ -f "$LOOP_STATE_FILE" ]]; then
    jq -c '.' "$LOOP_STATE_FILE" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

loop_write_state() {
  local json="$1" tmp
  mkdir -p "$LOOP_STATE_DIR" 2>/dev/null || return 1
  tmp="$LOOP_STATE_FILE.tmp.$$"
  printf '%s\n' "$json" | jq -c '.' >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$LOOP_STATE_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-loop-engineering.sh`
Expected: PASS (2 ok, FAIL=0).

- [ ] **Step 5: Commit**

```bash
git add skills/loop-engineer/loop_lib.sh tests/test-loop-engineering.sh
git commit -m "feat(loop-eng): loop_lib state read/write (atomic)"
```

---

## Task 2: `loop_lib.sh` — state hash + spec validation + bound checks

**Files:**
- Modify: `skills/loop-engineer/loop_lib.sh`
- Test: `tests/test-loop-engineering.sh`

- [ ] **Step 1: Write the failing tests** (append before the final `echo "---"` line)

```bash
# state hash is stable for unchanged tree, differs after a change
cd "$(mktemp -d)"; git init -q; echo a > f; git add f; git commit -qm init
h1="$(loop_state_hash "$PWD")"; echo b >> f; h2="$(loop_state_hash "$PWD")"
[[ -n "$h1" && "$h1" != "$h2" ]] && ok "state_hash changes on edit" || bad "state_hash h1=$h1 h2=$h2"

# validate: missing success_criterion for bounded-autonomous -> rc 2
loop_validate_spec '{"autonomy":"bounded-autonomous","require_external_termination":true,"bounds":{"max_iterations":5}}'
[[ $? -eq 2 ]] && ok "validate refuses missing criterion" || bad "validate should refuse"

# validate: complete spec -> rc 0
loop_validate_spec '{"autonomy":"checkpoint","success_criterion":{"type":"shell","command":"true"},"bounds":{"max_iterations":5}}'
[[ $? -eq 0 ]] && ok "validate accepts complete spec" || bad "validate should accept"

# check_bounds: iteration over cap -> max_iterations
r="$(loop_check_bounds '{"iteration":5,"bounds":{"max_iterations":5},"cost_so_far_usd":0,"no_progress_count":0,"started_at":"2999-01-01T00:00:00Z"}')"
[[ "$r" == "max_iterations" ]] && ok "bounds trip on iterations" || bad "bounds got=$r"

# check_bounds: budget over cap -> budget_exceeded
r="$(loop_check_bounds '{"iteration":1,"bounds":{"max_iterations":5,"per_run_budget_usd":1},"cost_so_far_usd":2,"no_progress_count":0,"started_at":"2999-01-01T00:00:00Z"}')"
[[ "$r" == "budget_exceeded" ]] && ok "bounds trip on budget" || bad "bounds got=$r"

# check_bounds: all within -> ok
r="$(loop_check_bounds '{"iteration":1,"bounds":{"max_iterations":5,"per_run_budget_usd":5},"cost_so_far_usd":1,"no_progress_count":0,"started_at":"2999-01-01T00:00:00Z"}')"
[[ "$r" == "ok" ]] && ok "bounds ok within caps" || bad "bounds got=$r"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-loop-engineering.sh`
Expected: FAIL ("loop_state_hash: command not found" or similar).

- [ ] **Step 3: Implement** (append to `skills/loop-engineer/loop_lib.sh`)

```bash
# Hash of the working state: git HEAD + porcelain status + untracked.
# Used by the no-progress detector. Stable when nothing changed.
loop_state_hash() {
  local cwd="${1:-$PWD}"
  { git -C "$cwd" rev-parse HEAD 2>/dev/null
    git -C "$cwd" status --porcelain 2>/dev/null
  } | shasum 2>/dev/null | awk '{print $1}'
}

# Validate a loop spec. rc 0 = ok, rc 2 = refuse.
# Rule: must have >=1 bound. If autonomy==bounded-autonomous AND
# require_external_termination, a success_criterion.command is mandatory.
loop_validate_spec() {
  local json="$1"
  echo "$json" | jq -e '.bounds.max_iterations or .bounds.per_run_budget_usd or .bounds.timeout_minutes' >/dev/null 2>&1 || return 2
  local auto ext cmd
  auto="$(echo "$json" | jq -r '.autonomy // "checkpoint"' 2>/dev/null)"
  ext="$(echo "$json" | jq -r '.require_external_termination // false' 2>/dev/null)"
  cmd="$(echo "$json" | jq -r '.success_criterion.command // empty' 2>/dev/null)"
  if [[ "$auto" == "bounded-autonomous" && "$ext" == "true" && -z "$cmd" ]]; then
    return 2
  fi
  return 0
}

# Return the first tripped bound, or "ok". Pure function of the state JSON.
loop_check_bounds() {
  local json="$1" iter cap cost budget npc started now elapsed timeout
  iter="$(echo "$json"  | jq -r '.iteration // 0')"
  cap="$(echo "$json"   | jq -r '.bounds.max_iterations // 1000000')"
  cost="$(echo "$json"  | jq -r '.cost_so_far_usd // 0')"
  budget="$(echo "$json"| jq -r '.bounds.per_run_budget_usd // empty')"
  npc="$(echo "$json"   | jq -r '.no_progress_count // 0')"
  timeout="$(echo "$json" | jq -r '.bounds.timeout_minutes // empty')"
  started="$(echo "$json" | jq -r '.started_at // empty')"
  [[ "$iter" -ge "$cap" ]] && { echo "max_iterations"; return; }
  if [[ -n "$budget" ]] && awk "BEGIN{exit !($cost >= $budget)}"; then echo "budget_exceeded"; return; fi
  [[ "$npc" -ge 2 ]] && { echo "no_progress"; return; }
  if [[ -n "$timeout" && -n "$started" ]]; then
    now="$(date -u +%s 2>/dev/null)"; started="$(date -u -d "$started" +%s 2>/dev/null || date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$started" +%s 2>/dev/null)"
    if [[ -n "$now" && -n "$started" ]]; then elapsed=$(( (now - started) / 60 )); [[ "$elapsed" -ge "$timeout" ]] && { echo "timeout"; return; }; fi
  fi
  echo "ok"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-loop-engineering.sh`
Expected: PASS (all ok, FAIL=0).

- [ ] **Step 5: Commit**

```bash
git add skills/loop-engineer/loop_lib.sh tests/test-loop-engineering.sh
git commit -m "feat(loop-eng): state hash, spec validation, bound checks"
```

---

## Task 3: `loop-stop.sh` — the fail-closed Stop hook

**Files:**
- Create: `hooks/loop-stop.sh`
- Test: `tests/test-loop-engineering.sh`

**Contract:** stdin is hook JSON incl. `stop_hook_active`. Output `{"decision":"block","reason":"..."}` to keep working; exit 0 with no output to allow stop. Fail-closed = on any ambiguity (no/expired/malformed state, `stop_hook_active`, met, bound tripped) → **allow stop**.

- [ ] **Step 1: Write the failing tests** (append)

```bash
STOP="$REPO_ROOT/hooks/loop-stop.sh"
run_stop() { echo "$2" | LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$STOP"; }

mkdir -p "$HOME/.claude/session-state"

# no active loop -> allow stop (empty output)
loop_write_state '{"active":false}'
out="$(run_stop '' '{"stop_hook_active":false}')"
[[ -z "$out" ]] && ok "stop: inactive -> allow" || bad "stop inactive out=$out"

# stop_hook_active true -> always allow (no infinite block)
loop_write_state '{"active":true,"iteration":1,"bounds":{"max_iterations":99},"success_criterion":{"type":"shell","command":"false"},"started_at":"2999-01-01T00:00:00Z","no_progress_count":0,"cost_so_far_usd":0}'
out="$(run_stop '' '{"stop_hook_active":true}')"
[[ -z "$out" ]] && ok "stop: stop_hook_active -> allow" || bad "stop active-flag out=$out"

# criterion passes -> mark met, allow stop
loop_write_state '{"active":true,"iteration":1,"bounds":{"max_iterations":99},"success_criterion":{"type":"shell","command":"true"},"started_at":"2999-01-01T00:00:00Z","no_progress_count":0,"cost_so_far_usd":0}'
out="$(run_stop '' '{"stop_hook_active":false}')"
[[ -z "$out" ]] && ok "stop: criterion met -> allow" || bad "stop met out=$out"
[[ "$(loop_read_state | jq -r '.status')" == "met" ]] && ok "stop: status=met" || bad "stop status not met"

# criterion fails, bounds remain -> block (keep working)
loop_write_state '{"active":true,"iteration":1,"bounds":{"max_iterations":99},"success_criterion":{"type":"shell","command":"false"},"started_at":"2999-01-01T00:00:00Z","no_progress_count":0,"cost_so_far_usd":0}'
out="$(run_stop '' '{"stop_hook_active":false}')"
echo "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "stop: unmet -> block" || bad "stop unmet out=$out"

# malformed state -> allow stop (fail-closed)
printf '%s' 'not json' > "$HOME/.claude/session-state/loop-state.json"
out="$(run_stop '' '{"stop_hook_active":false}')"
[[ -z "$out" ]] && ok "stop: malformed -> allow (fail-closed)" || bad "stop malformed out=$out"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-loop-engineering.sh`
Expected: FAIL ("loop-stop.sh" not found / no output assertions fail).

- [ ] **Step 3: Implement**

Create `hooks/loop-stop.sh`:

```bash
#!/usr/bin/env bash
# Stop hook for the loop-engineering control plane.
# Blocks the session from stopping while a loop's goal is unmet and bounds
# remain; releases (allows stop) when met, bound-tripped, or anything is
# ambiguous. FAIL-CLOSED: on doubt, allow the stop.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
[[ -f "$LIB" ]] || { LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"; }
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0   # no lib -> allow stop

INPUT="$(cat 2>/dev/null || echo '{}')"
SHA="$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[[ "$SHA" == "true" ]] && exit 0       # never re-block: allow stop

STATE="$(loop_read_state)"
ACTIVE="$(echo "$STATE" | jq -r '.active // false' 2>/dev/null)"
[[ "$ACTIVE" == "true" ]] || exit 0    # no active loop -> allow stop

# Malformed (read returned {} but file exists non-empty) -> fail-closed
echo "$STATE" | jq -e '.bounds' >/dev/null 2>&1 || exit 0

mark() { loop_write_state "$(echo "$STATE" | jq -c --arg s "$1" '.active=false | .status=$s')" 2>/dev/null || true; }

# 1) External termination: run the success criterion command.
CMD="$(echo "$STATE" | jq -r '.success_criterion.command // empty' 2>/dev/null)"
if [[ -n "$CMD" ]]; then
  if bash -c "$CMD" >/dev/null 2>&1; then mark "met"; exit 0; fi
fi

# 2) No-progress: compare state hash; bump count if unchanged.
PREV="$(echo "$STATE" | jq -r '.last_state_hash // empty' 2>/dev/null)"
CUR="$(loop_state_hash "$PWD")"
NPC="$(echo "$STATE" | jq -r '.no_progress_count // 0' 2>/dev/null)"
if [[ -n "$PREV" && "$PREV" == "$CUR" ]]; then NPC=$((NPC+1)); else NPC=0; fi

# 3) Advance iteration + hash, then check bounds on the advanced state.
STATE="$(echo "$STATE" | jq -c --arg h "$CUR" --argjson n "$NPC" \
  '.iteration=((.iteration//0)+1) | .last_state_hash=$h | .no_progress_count=$n')"
TRIP="$(loop_check_bounds "$STATE")"
if [[ "$TRIP" != "ok" ]]; then
  loop_write_state "$(echo "$STATE" | jq -c --arg s "$TRIP" '.active=false | .status=$s')" 2>/dev/null || true
  exit 0   # bound tripped -> allow stop (escalation surfaced via status)
fi

# 4) Unmet + bounds remain + progress -> keep working.
loop_write_state "$STATE" 2>/dev/null || true
REM="$(echo "$STATE" | jq -r '"iter \(.iteration)/\(.bounds.max_iterations // "∞")"' 2>/dev/null)"
jq -nc --arg r "Loop '$(echo "$STATE" | jq -r '.loop_id // "loop"')' goal unmet ($REM). Continue toward: $(echo "$STATE" | jq -r '.goal // ""')" \
  '{decision:"block", reason:$r}' 2>/dev/null || true
exit 0
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-loop-engineering.sh`
Expected: PASS (all ok, FAIL=0).

- [ ] **Step 5: Commit**

```bash
git add hooks/loop-stop.sh tests/test-loop-engineering.sh
git commit -m "feat(loop-eng): fail-closed Stop hook (loop-stop.sh)"
```

---

## Task 4: `irreversible-deny.sh` — block destructive Bash during an active loop

**Files:**
- Create: `hooks/irreversible-deny.sh`
- Test: `tests/test-loop-engineering.sh`

- [ ] **Step 1: Write the failing tests** (append)

```bash
DENY="$REPO_ROOT/hooks/irreversible-deny.sh"
run_deny() { echo "$1" | LOOP_STATE_DIR="$HOME/.claude/session-state" bash "$DENY"; }

# active loop + push -> deny
loop_write_state '{"active":true}'
out="$(run_deny '{"tool_input":{"command":"git push origin main"}}')"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 && ok "deny: push during loop" || bad "deny push out=$out"

# active loop + read-only -> no deny (empty)
out="$(run_deny '{"tool_input":{"command":"git status"}}')"
[[ -z "$out" ]] && ok "deny: status allowed" || bad "deny status out=$out"

# no active loop + push -> no deny (don't interfere with normal work)
loop_write_state '{"active":false}'
out="$(run_deny '{"tool_input":{"command":"git push origin main"}}')"
[[ -z "$out" ]] && ok "deny: push allowed outside loop" || bad "deny push-noloop out=$out"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-loop-engineering.sh`
Expected: FAIL ("irreversible-deny.sh" not found).

- [ ] **Step 3: Implement**

Create `hooks/irreversible-deny.sh`:

```bash
#!/usr/bin/env bash
# PreToolUse[Bash] hook: during an ACTIVE loop, deny irreversible commands so
# an unattended loop cannot push/merge/deploy/delete/move money. Outside a
# loop, stays silent. Red-team owns the pattern list. Best-effort: exit 0.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
[[ -f "$LIB" ]] || LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

[[ "$(loop_read_state | jq -r '.active // false' 2>/dev/null)" == "true" ]] || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -z "$CMD" ]] && CMD="${CLAUDE_TOOL_INPUT_command:-}"
[[ -z "$CMD" ]] && exit 0

# Irreversible patterns (word-boundary-ish; conservative).
PATTERN='git[[:space:]]+push|git[[:space:]]+merge|git[[:space:]]+reset[[:space:]]+--hard|rm[[:space:]]+-rf|deploy-edge|supabase[[:space:]].*(delete|drop)|drop[[:space:]]+table|truncate[[:space:]]|stripe[[:space:]]|gh[[:space:]]+pr[[:space:]]+merge'

if echo "$CMD" | grep -qiE "$PATTERN"; then
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny",
    permissionDecisionReason:"irreversible-deny: an active loop may not run irreversible actions (push/merge/deploy/delete/money). Pause the loop or get a human checkpoint, then run this outside the loop."}}' 2>/dev/null || true
fi
exit 0
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-loop-engineering.sh`
Expected: PASS (all ok, FAIL=0).

- [ ] **Step 5: Commit**

```bash
git add hooks/irreversible-deny.sh tests/test-loop-engineering.sh
git commit -m "feat(loop-eng): irreversible-deny hook (active-loop scoped)"
```

---

## Task 5: `loop_policy` schema + template

**Files:**
- Modify: `schemas/stack-config-schema.json` (insert after the `session_prefs` property block, before `workflow_roster`)
- Modify: `templates/stack-config.template.json`
- Test: `tests/test-loop-engineering.sh`

- [ ] **Step 1: Write the failing test** (append)

```bash
SCHEMA="$REPO_ROOT/schemas/stack-config-schema.json"
# loop_policy is a defined property (schema is additionalProperties:false)
jq -e '.properties.loop_policy.properties.max_iterations' "$SCHEMA" >/dev/null 2>&1 \
  && ok "schema: loop_policy defined" || bad "schema: loop_policy missing"
# template ships a default loop_policy
TMPL="$REPO_ROOT/templates/stack-config.template.json"
jq -e '.loop_policy.default_autonomy' "$TMPL" >/dev/null 2>&1 \
  && ok "template: loop_policy default present" || bad "template: loop_policy missing"
# default autonomy is the safe floor
[[ "$(jq -r '.loop_policy.default_autonomy' "$TMPL")" == "checkpoint" ]] \
  && ok "template: default_autonomy=checkpoint" || bad "template autonomy not checkpoint"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-loop-engineering.sh`
Expected: FAIL ("schema: loop_policy missing").

- [ ] **Step 3: Implement**

In `schemas/stack-config-schema.json`, add this property (after the `session_prefs` object's closing `},`):

```json
    "loop_policy": {
      "type": "object",
      "additionalProperties": false,
      "description": "Governance for autonomous loops (ADR-019). Defaults ship safe; tier raises the ceiling.",
      "properties": {
        "enabled": { "type": "boolean", "default": true },
        "default_autonomy": { "type": "string", "enum": ["checkpoint", "bounded-checkpoint", "bounded-autonomous"], "default": "checkpoint" },
        "autonomy_ceiling": { "type": "string", "enum": ["checkpoint", "bounded-checkpoint", "bounded-autonomous"], "default": "checkpoint" },
        "max_iterations": { "type": "integer", "minimum": 1, "default": 25 },
        "max_recursion_depth": { "type": "integer", "minimum": 1, "default": 5 },
        "per_run_budget_usd": { "type": ["number", "null"], "default": 5 },
        "timeout_minutes": { "type": ["integer", "null"], "default": 180 },
        "no_progress_exit": { "type": "boolean", "default": true },
        "require_external_termination": { "type": "string", "enum": ["auto", "always", "never"], "default": "auto" },
        "commit_per_iteration": { "type": "boolean", "default": false },
        "irreversible_actions_break_loop": { "type": "boolean", "default": true }
      }
    },
```

In `templates/stack-config.template.json`, add the matching default block:

```json
  "loop_policy": {
    "enabled": true,
    "default_autonomy": "checkpoint",
    "autonomy_ceiling": "checkpoint",
    "max_iterations": 25,
    "max_recursion_depth": 5,
    "per_run_budget_usd": 5,
    "timeout_minutes": 180,
    "no_progress_exit": true,
    "require_external_termination": "auto",
    "commit_per_iteration": false,
    "irreversible_actions_break_loop": true
  },
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-loop-engineering.sh`
Expected: PASS. Also run `jq empty schemas/stack-config-schema.json && jq empty templates/stack-config.template.json` — Expected: no output (valid JSON).

- [ ] **Step 5: Commit**

```bash
git add schemas/stack-config-schema.json templates/stack-config.template.json tests/test-loop-engineering.sh
git commit -m "feat(loop-eng): loop_policy schema + template defaults"
```

---

## Task 6: `/loop-engineer` skill (front door + pre-flight gate)

**Files:**
- Create: `skills/loop-engineer/SKILL.md`
- Test: `tests/test-loop-engineering.sh`

The skill's enforcement lives in `loop_lib.sh` (Task 2's `loop_validate_spec`). The SKILL.md instructs the model to build a spec, validate it, and write loop-state only if valid.

- [ ] **Step 1: Write the failing test** (append — asserts the skill file + its contract)

```bash
SKILL="$REPO_ROOT/skills/loop-engineer/SKILL.md"
[[ -f "$SKILL" ]] && ok "skill: SKILL.md present" || bad "skill: SKILL.md missing"
grep -q 'loop_validate_spec' "$SKILL" && ok "skill: references validate" || bad "skill: no validate ref"
grep -q 'require_external_termination' "$SKILL" && ok "skill: documents termination" || bad "skill: no termination doc"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-loop-engineering.sh`
Expected: FAIL ("skill: SKILL.md missing").

- [ ] **Step 3: Implement**

Create `skills/loop-engineer/SKILL.md`:

```markdown
---
name: loop-engineer
description: Set up a governed autonomous loop. Use when the user wants an agent to iterate toward a verifiable goal until done (run-until-tests-pass, babysit-PRs, eval-until-threshold, long refactor) rather than a one-shot task. Validates a loop spec, applies the stack-config loop_policy ceiling, and writes loop-state so the Stop-hook enforces caps. Refuses unbounded loops.
tier_min: 2
user-invocable: true
model-invocable: true
recommendable: true
tools: Bash, Read
---

# /loop-engineer

Set up a **bounded, governed loop**. You are the front door; the `Stop` hook
(`loop-stop.sh`) does the enforcing. Your job: build a valid loop spec, clamp it
to the project's `loop_policy` ceiling, and write `loop-state.json`. **Refuse to
start an unbounded or unverifiable autonomous loop.**

## Steps

1. **Read the policy.** From `.claude/stack-config.json`, read `loop_policy`
   (ceiling, caps, `require_external_termination`). If absent, use the schema
   defaults (safe floor).

2. **Establish the goal + verification.** Ask the user (or infer) the goal and a
   **machine-checkable success criterion** — a shell command that exits 0 when
   done (e.g. `npm test && npm run lint`, an eval threshold script). This is the
   #1 lever; a loop without it is only as good as its iteration cap.

3. **Pick autonomy, clamp to ceiling.** Never exceed `autonomy_ceiling`. Default
   to `checkpoint` unless the user opts up and the tier/ultracode ceiling allows.

4. **Validate.** Build the spec JSON (see contract) and run:
   `bash skills/loop-engineer/loop_lib.sh` is sourced; call
   `loop_validate_spec "$SPEC"`. If it returns 2, **STOP** and tell the user what
   is missing (a bound, or — for `bounded-autonomous` — a success criterion).

5. **Write loop-state and announce the pattern.** On valid spec, source the lib
   and `loop_write_state "$SPEC_WITH_ACTIVE_TRUE"`. Print
   `pattern selected: <pattern> (<why>)` so a misroute is visible.

6. **Hand to the loop.** Begin the work. The Stop-hook will block stops until the
   criterion passes or a bound trips. To stop early, the user runs
   `/loop-engineer clear` (sets `active=false`).

## Spec contract

See `docs/superpowers/specs/2026-06-20-loop-engineering-design.md` §3 for the
`loop-state.json` shape. Required to start: `bounds` (>=1) and — for
`bounded-autonomous` with `require_external_termination` — `success_criterion.command`.

## Clearing a loop

`/loop-engineer clear` → source the lib, write `{"active":false,"status":"cleared"}`.

## What you do NOT do

- Do NOT write loop-state without passing `loop_validate_spec`.
- Do NOT raise autonomy above `autonomy_ceiling`.
- Do NOT run irreversible actions inside the loop (the deny hook blocks them).
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-loop-engineering.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/loop-engineer/SKILL.md tests/test-loop-engineering.sh
git commit -m "feat(loop-eng): /loop-engineer skill (pre-flight gate)"
```

---

## Task 7: foreman loop-shape detection

**Files:**
- Modify: `skills/foreman/SKILL.md` (insert a step between current step 3 "Classify the task" at line 22–32 and step 4 "Match the team" at line 34)
- Test: `tests/test-loop-engineering.sh`

- [ ] **Step 1: Write the failing test** (append)

```bash
FOREMAN="$REPO_ROOT/skills/foreman/SKILL.md"
grep -q 'Detect loop-shape' "$FOREMAN" && ok "foreman: loop-shape step present" || bad "foreman: no loop-shape step"
grep -q 'pattern selected' "$FOREMAN" && ok "foreman: visible pattern log" || bad "foreman: no visible log"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-loop-engineering.sh`
Expected: FAIL ("foreman: no loop-shape step").

- [ ] **Step 3: Implement**

In `skills/foreman/SKILL.md`, immediately after the step-3 classification list (the line ending `documentation` ... at line 32) and before `4. **Match the team.**`, insert a new step and renumber the rest is NOT required — insert as step "3b":

```markdown
3b. **Detect loop-shape (ADR-019).** If the task is iterate-until-verified
    (run-until-tests-pass, babysit-PRs, eval-until-threshold, long unattended
    refactor/migration), route it to a loop pattern and hand to `/loop-engineer`
    instead of a one-shot dispatch:

    | Task shape | Pattern |
    |---|---|
    | long refactor / migration | ralph |
    | skill / prompt / eval improvement | eval-driven |
    | review / audit gate | generator-critic |
    | recurring / scheduled | scheduled |
    | ad-hoc "until X" | /goal |
    | (default / unclear) | react |

    Tiebreak: most-specific shape wins; ties → `react`. **Always print
    `pattern selected: <pattern> (<why>)`** so a misroute is visible. Emit the
    `success_criterion` + `bound` into the loop spec for `/loop-engineer`. If the
    task is a normal one-shot, skip this step.
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-loop-engineering.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/foreman/SKILL.md tests/test-loop-engineering.sh
git commit -m "feat(loop-eng): foreman loop-shape detection + visible routing"
```

---

## Task 8: Register hooks + tier manifest + cost logging

**Files:**
- Modify: `hooks/hooks.json`
- Modify: `config/tier-manifests/tier-2.json`
- Modify: `skills/loop-engineer/loop_lib.sh` (add cost accrual)
- Test: `tests/test-loop-engineering.sh`

- [ ] **Step 1: Write the failing tests** (append)

```bash
HOOKS="$REPO_ROOT/hooks/hooks.json"
jq -e '.hooks.Stop[]?.hooks[]?.command | select(test("loop-stop.sh"))' "$HOOKS" >/dev/null 2>&1 \
  && ok "hooks.json: loop-stop registered" || bad "hooks.json: loop-stop missing"
jq -e '.hooks.PreToolUse[]? | select(.matcher=="Bash") | .hooks[]?.command | select(test("irreversible-deny.sh"))' "$HOOKS" >/dev/null 2>&1 \
  && ok "hooks.json: irreversible-deny registered" || bad "hooks.json: deny missing"
MAN="$REPO_ROOT/config/tier-manifests/tier-2.json"
jq -e '.files.global[]? | select(.to | test("loop-engineer/SKILL.md"))' "$MAN" >/dev/null 2>&1 \
  && ok "manifest: skill copied" || bad "manifest: skill missing"
# cost accrual fn
[[ "$(loop_write_state '{"cost_so_far_usd":1}'; loop_accrue_cost 0.5; loop_read_state | jq -r '.cost_so_far_usd')" == "1.5" ]] \
  && ok "lib: cost accrual" || bad "lib: cost accrual"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test-loop-engineering.sh`
Expected: FAIL ("hooks.json: loop-stop missing").

- [ ] **Step 3: Implement**

Add cost accrual to `skills/loop-engineer/loop_lib.sh`:

```bash
# Add an estimated USD delta to cost_so_far in loop-state (between-iteration).
# Also append a row to subagent-runs.jsonl so caps calibrate from real history.
loop_accrue_cost() {
  local delta="$1" state
  state="$(loop_read_state)"
  state="$(echo "$state" | jq -c --argjson d "$delta" '.cost_so_far_usd=((.cost_so_far_usd//0)+$d)')"
  loop_write_state "$state" 2>/dev/null || return 1
  local log="$HOME/.claude/logs/subagent-runs.jsonl"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  jq -nc --argjson d "$delta" --arg lid "$(echo "$state" | jq -r '.loop_id // "loop"')" \
    '{event:"loop_iteration", loop_id:$lid, cost_usd:$d}' >>"$log" 2>/dev/null || true
}
```

In `hooks/hooks.json`, add the `Stop` block and the `PreToolUse[Bash]` block (merge into existing `hooks` object — keep existing entries):

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/loop-stop.sh" } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/irreversible-deny.sh" } ] }
    ]
  }
}
```

(If `hooks.json` already has a `PreToolUse` array, append the `Bash` matcher object to it rather than creating a second array.)

In `config/tier-manifests/tier-2.json`, add to `files.global`:

```json
{ "from": "skills/loop-engineer/SKILL.md", "to": "~/.claude/skills/loop-engineer/SKILL.md" },
{ "from": "skills/loop-engineer/loop_lib.sh", "to": "~/.claude/skills/loop-engineer/loop_lib.sh", "executable": true },
{ "from": "hooks/loop-stop.sh", "to": "~/.claude/hooks/loop-stop.sh", "executable": true },
{ "from": "hooks/irreversible-deny.sh", "to": "~/.claude/hooks/irreversible-deny.sh", "executable": true }
```

And add to the manifest's `smoke_tests` array:

```json
"test -f ~/.claude/skills/loop-engineer/SKILL.md && test -x ~/.claude/hooks/loop-stop.sh"
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test-loop-engineering.sh && jq empty hooks/hooks.json && jq empty config/tier-manifests/tier-2.json`
Expected: PASS, no JSON errors.

- [ ] **Step 5: Commit**

```bash
git add hooks/hooks.json config/tier-manifests/tier-2.json skills/loop-engineer/loop_lib.sh tests/test-loop-engineering.sh
git commit -m "feat(loop-eng): register hooks, tier-2 manifest, cost accrual"
```

---

## Final verification

- [ ] Run the full suite: `bash tests/test-loop-engineering.sh` → PASS, FAIL=0.
- [ ] JSON validity: `for f in hooks/hooks.json schemas/stack-config-schema.json templates/stack-config.template.json config/tier-manifests/tier-2.json; do jq empty "$f" || echo "BAD: $f"; done` → no BAD lines.
- [ ] Dry-run install into a temp HOME: `HOME=$(mktemp -d) bash scripts/install.sh --tier=2 --skip-requirements` → ends "All checks passed."
- [ ] Manual loop smoke: in a throwaway git repo, set a loop with `success_criterion.command="test -f DONE"`, confirm the Stop-hook blocks until you `touch DONE`, then releases.

## Self-review notes (coverage vs spec)

- Spec §3 enforcement (pre-flight + Stop-hook + irreversible-deny) → Tasks 3, 4, 6.
- Spec §5 `loop_policy` + schema migration → Task 5.
- Spec §6 guardrails: termination (T3/T6), iteration/budget/timeout/no-progress bounds (T2/T3), recursion cap field (T5; enforcement of depth is a Phase-2 monitor — Phase-1 ships the field + iteration cap), irreversible checkpoint (T4), durable corrections (deferred to Phase 1.5 — not blocking), state-in-files (loop-state always; commit-per-iter opt-in, not built in P1).
- Spec §7 Stop-hook contract (stdin `stop_hook_active`, fail-closed) → Task 3.
- Spec §8 foreman detection → Task 7.
- Spec §11 instrument-alongside → Task 8 cost accrual.
- **Known Phase-1 residual (matches spec §6.3):** cost enforcement is between-iteration only; within-iteration runaway needs the Phase-2 live monitor. `max_recursion_depth` is stored + surfaced but not hard-enforced until Phase 2 (Phase-1 relies on `max_iterations`). Both are stated, not hidden.
```
