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
