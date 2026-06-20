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
