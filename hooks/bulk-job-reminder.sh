#!/usr/bin/env bash
# PreToolUse Bash hook: reminds about bulk-job safety.
# Points to /cost-gate and /coverage-snapshot skills if Tier 1+ installed.

set -uo pipefail

cmd="${CLAUDE_TOOL_INPUT_command:-}"
[[ -z "$cmd" ]] && exit 0

# Patterns that indicate a bulk job
pattern='scripts/(enrich|backfill|rescue|bulk-|brave-|serp-|seed-|migrate-)|--batch|--bulk'

if echo "$cmd" | grep -qE "$pattern"; then
  printf "\n[bulk-job guardrail] About to run: %s\n" "$cmd"
  printf "  - Confirm script MERGES with existing data, does NOT overwrite valid rows.\n"
  printf "  - For >100 rows or any LLM-per-row job: run /cost-gate first.\n"
  printf "  - For data-modifying scripts: run /coverage-snapshot first.\n\n"
fi

exit 0
