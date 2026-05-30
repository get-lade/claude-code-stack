#!/usr/bin/env bash
# Claude Code statusLine hook.
# Reads .claude/stack-config.json from current project and emits a chip
# showing orchestration mode, tier, strict/permissive, domain.
#
# stdin: JSON with { workspace: { current_dir }, cwd, model, ... }
# stdout: single-line status string

set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"
CWD="$(echo "$INPUT" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

CONFIG="$(bash "$HOME/.claude/lib/find-stack-config.sh" "$CWD")"

if [[ -z "$CONFIG" || ! -f "$CONFIG" ]]; then
  echo "⚪ uninit"
  exit 0
fi

MODE="$(jq -r '.orchestration_mode // "main-thread"' "$CONFIG")"
TIER="$(jq -r '.stack_tier // "?"' "$CONFIG")"
STRICT="$(jq -r '.strict_mode // false' "$CONFIG")"
DOMAIN="$(jq -r '.domain_mode // empty' "$CONFIG")"
SENS="$(jq -r '.sensitivity.level // "normal"' "$CONFIG")"

case "$MODE" in
  agent-teams)       ICON="🟢" ;;
  hybrid)            ICON="🟡" ;;
  dynamic-workflows) ICON="🔵" ;;
  main-thread)       ICON="⚪" ;;
  *)                 ICON="❔" ;;
esac

STRICT_LBL="permissive"
[[ "$STRICT" == "true" ]] && STRICT_LBL="strict"

OUT="$ICON $MODE · T$TIER · $STRICT_LBL"
[[ -n "$DOMAIN" ]] && OUT="$OUT · $DOMAIN"
[[ "$SENS" != "normal" ]] && OUT="$OUT · 🔒$SENS"

echo "$OUT"
