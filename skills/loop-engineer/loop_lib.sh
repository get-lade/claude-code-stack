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
