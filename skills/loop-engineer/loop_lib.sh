#!/usr/bin/env bash
# Shared library for the loop-engineering control plane.
# Sourced by the /loop-engineer skill helper and the loop hooks.
# All functions are fail-safe: errors never crash the caller.
set -uo pipefail

# Safe HOME fallback: avoid expanding $HOME when it may be unset under set -u.
_loop_home="${HOME:-/tmp}"
LOOP_STATE_DIR="${LOOP_STATE_DIR:-${_loop_home}/.claude/session-state}"
LOOP_STATE_FILE="$LOOP_STATE_DIR/loop-state.json"

loop_read_state() {
  if [[ -f "$LOOP_STATE_FILE" ]]; then
    jq -c '.' "$LOOP_STATE_FILE" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

loop_write_state() {
  # Default to empty object so zero-arg invocation is safe under set -u.
  # Two-step: bash closes ${1:-{}} at the first }, so use an intermediate var.
  local json tmp
  json="${1:-}"
  [[ -z "$json" ]] && json="{}"
  # All failure paths return 0 so set -e callers are not terminated.
  mkdir -p "$LOOP_STATE_DIR" 2>/dev/null || return 0
  # Use mktemp to avoid predictable PID-based tmp names (symlink attack).
  tmp="$(mktemp "${LOOP_STATE_FILE}.tmp.XXXXXX" 2>/dev/null)" || return 0
  printf '%s\n' "$json" | jq -c '.' >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv "$tmp" "$LOOP_STATE_FILE" 2>/dev/null || { rm -f "$tmp"; return 0; }
}

# Hash of the working state: git HEAD + diff (content) + untracked names.
# Used by the no-progress detector. Stable when nothing changed.
loop_state_hash() {
  local cwd="${1:-$PWD}"
  # shasum is macOS; sha1sum is Linux. Try both, fallback to no-op.
  local _sha_cmd
  if command -v shasum >/dev/null 2>&1; then
    _sha_cmd="shasum"
  elif command -v sha1sum >/dev/null 2>&1; then
    _sha_cmd="sha1sum"
  else
    echo ""; return 0
  fi
  { git -C "$cwd" rev-parse HEAD 2>/dev/null
    git -C "$cwd" diff HEAD 2>/dev/null
    git -C "$cwd" status --porcelain 2>/dev/null
  } | $_sha_cmd 2>/dev/null | awk '{print $1}'
}

# Validate a loop spec. rc 0 = ok, rc 2 = refuse.
# Rule: must have >=1 bound. If autonomy==bounded-autonomous, a
# success_criterion.command is mandatory UNLESS require_external_termination is
# explicitly "never". The schema default "auto" means required for
# bounded-autonomous, so "auto" triggers the gate just like "always".
loop_validate_spec() {
  local json="${1:-}"
  [[ -z "$json" ]] && return 2
  # Reject non-integer numeric bounds to prevent bash arithmetic errors downstream.
  local _mi _pb _to
  _mi="$(echo "$json" | jq -r '.bounds.max_iterations // empty' 2>/dev/null)"
  _pb="$(echo "$json" | jq -r '.bounds.per_run_budget_usd // empty' 2>/dev/null)"
  _to="$(echo "$json" | jq -r '.bounds.timeout_minutes // empty' 2>/dev/null)"
  # Each present bound must be an integer (no decimal point).
  [[ -n "$_mi" && ! "$_mi" =~ ^[0-9]+$ ]] && return 2
  [[ -n "$_pb" && ! "$_pb" =~ ^[0-9]+(\.[0-9]+)?$ ]] && { :; }  # budget allows decimal
  [[ -n "$_to" && ! "$_to" =~ ^[0-9]+$ ]] && return 2
  echo "$json" | jq -e '.bounds.max_iterations or .bounds.per_run_budget_usd or .bounds.timeout_minutes' >/dev/null 2>&1 || return 2
  local auto ext cmd
  auto="$(echo "$json" | jq -r '.autonomy // "checkpoint"' 2>/dev/null)"
  ext="$(echo "$json" | jq -r '.require_external_termination // "auto"' 2>/dev/null)"
  cmd="$(echo "$json" | jq -r '.success_criterion.command // empty' 2>/dev/null)"
  # Require a success_criterion.command for bounded-autonomous unless the caller
  # explicitly opts out with "never". "auto" (the schema default) and "always"
  # and legacy boolean true all require the command.
  if [[ "$auto" == "bounded-autonomous" && "$ext" != "never" && -z "$cmd" ]]; then
    return 2
  fi
  return 0
}

# Return the first tripped bound, or "ok". Pure function of the state JSON.
loop_check_bounds() {
  local json="${1:-}"
  [[ -z "$json" ]] && { echo "ok"; return; }
  local iter cap cost budget npc npe started now elapsed timeout
  iter="$(echo "$json"  | jq -r '.iteration // 0')"
  cap="$(echo "$json"   | jq -r '.bounds.max_iterations // 1000000')"
  cost="$(echo "$json"  | jq -r '.cost_so_far_usd // 0')"
  budget="$(echo "$json"| jq -r '.bounds.per_run_budget_usd // empty')"
  npc="$(echo "$json"   | jq -r '.no_progress_count // 0')"
  # Use explicit false-check: jq's // alternative treats false as falsy, so
  # '.no_progress_exit // true' returns true even when the field is false.
  npe="$(echo "$json" | jq -r 'if .no_progress_exit == false then "false" else "true" end' 2>/dev/null)"
  timeout="$(echo "$json" | jq -r '.bounds.timeout_minutes // empty')"
  started="$(echo "$json" | jq -r '.started_at // empty')"
  # Validate numeric fields before arithmetic to prevent injection or crash under set -u.
  # max_iterations and timeout_minutes must be integers; a float value is treated as
  # the bound already tripped (safe: trips the cap rather than silently ignoring it).
  [[ "$iter"  =~ ^[0-9]+$ ]] || iter=0
  if [[ ! "$cap" =~ ^[0-9]+$ ]]; then
    # Non-integer cap (e.g. 2.5) — treat as bound tripped.
    echo "max_iterations"; return
  fi
  [[ "$npc"   =~ ^[0-9]+(\.[0-9]+)?$ ]] || npc=0
  [[ "$cost"  =~ ^[0-9]+(\.[0-9]+)?$ ]] || cost=0
  [[ -n "$budget"  && ! "$budget"  =~ ^[0-9]+(\.[0-9]+)?$ ]] && budget=""
  if [[ -n "$timeout" && ! "$timeout" =~ ^[0-9]+$ ]]; then
    # Non-integer timeout — treat as bound tripped.
    echo "timeout"; return
  fi
  [[ "$iter" -ge "$cap" ]] && { echo "max_iterations"; return; }
  # Use awk -v to pass values to avoid code injection via string interpolation.
  if [[ -n "$budget" ]] && awk -v c="$cost" -v b="$budget" 'BEGIN{exit !(c >= b)}'; then echo "budget_exceeded"; return; fi
  # Only trip no_progress when no_progress_exit is not explicitly false.
  [[ "$npe" != "false" ]] && [[ "$npc" -ge 2 ]] && { echo "no_progress"; return; }
  if [[ -n "$timeout" && -n "$started" ]]; then
    now="$(date -u +%s 2>/dev/null)"; started="$(date -u -d "$started" +%s 2>/dev/null || date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$started" +%s 2>/dev/null)"
    if [[ -n "$now" && -n "$started" ]]; then elapsed=$(( (now - started) / 60 )); [[ "$elapsed" -ge "$timeout" ]] && { echo "timeout"; return; }; fi
  fi
  echo "ok"
}

# Add an estimated USD delta to cost_so_far in loop-state (between-iteration).
# Also append a row to subagent-runs.jsonl so caps calibrate from real history.
loop_accrue_cost() {
  local delta="${1:-0}" state new_state
  # Reject negative deltas: they could drive cost_so_far_usd negative, permanently
  # bypassing the per_run_budget_usd cap.
  if ! awk -v d="$delta" 'BEGIN{exit !(d >= 0)}' 2>/dev/null; then
    return 1
  fi
  state="$(loop_read_state)"
  new_state="$(echo "$state" | jq -c --argjson d "$delta" '.cost_so_far_usd=((.cost_so_far_usd//0)+$d)' 2>/dev/null)" || return 0
  loop_write_state "$new_state" 2>/dev/null || return 1
  state="$new_state"
  local log="${_loop_home}/.claude/logs/subagent-runs.jsonl"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  jq -nc --argjson d "$delta" --arg lid "$(echo "$state" | jq -r '.loop_id // "loop"')" \
    '{event:"loop_iteration", loop_id:$lid, cost_usd:$d}' >>"$log" 2>/dev/null || true
}
