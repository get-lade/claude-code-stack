#!/usr/bin/env bash
# Stop hook: main-session turn accrual + once-per-session receipt fallback for
# the post-session model-fit receipt (ADR-033). Two jobs, one hook (the ADR's
# "one thin hook" — no separate nudge hook):
#
# 1. Appends ONE main-session turn row per Stop event to subagent-runs.jsonl,
#    tagged event:"main_turn" agent:"main" — the two structural tags that make
#    subagent exclusion trivial for the receipt (model_fit_receipt_line sums
#    only rows with both tags).
#
#    tool_counts is computed by reading the whole transcript file (the Stop
#    payload's transcript_path) and counting tool_use blocks by name emitted
#    since the last human prompt — same full-slurp idiom as
#    hooks/brevity-drift.sh. The "since last human prompt" scoping is a
#    LOGICAL bound (only this turn's tool calls are counted), not an I/O bound
#    — a very large transcript is still read in full on every Stop event. This
#    is a COUNT of tool calls in the completed turn, not a per-call accrual,
#    so a tool-heavy turn is still exactly one row (the PostToolUse-windowing
#    failure mode the ADR dropped).
#
#    model/in_tokens/out_tokens come straight from the Stop payload (same
#    extraction idiom as hooks/loop-cost-accrual.sh: .usage.input_tokens // 0).
#    Missing usage -> row written with 0 tokens; it still contributes to the
#    ratio via tool_counts (fail-safe, honest — no cost attributed for that
#    turn).
#
# 2. Fallback surface: at most once per session, prints the shared receipt
#    line (model_fit_receipt_line, loop_lib.sh) via <system-reminder> so users
#    who never run /handoff still see it. Dedupe flag
#    model-fit-receipt.<session_id>.printed, pruned at SessionStart exactly
#    like passive_suggest.*.nudged (hooks/session-prefs-init.sh).
#
# Gated on session_prefs.model_fit_receipt != off (governs BOTH jobs). Fail-safe:
# any error -> exit 0. ALWAYS exits 0 — this never blocks the stop; the sole
# output (if any) is an advisory system-reminder, never {"decision":"block"}.
set -uo pipefail

PREFS="$HOME/.claude/session-state/current-prefs.json"
if [[ -f "$PREFS" ]]; then
  MODE="$(jq -r '.model_fit_receipt // "on"' "$PREFS" 2>/dev/null || echo on)"
  [[ "$MODE" == "off" ]] && exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"

# Never re-trigger on a stop-hook-active loop iteration (mirrors loop-stop.sh):
# each Stop invocation should append at most one row for the turn it closes.
SHA="$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[[ "$SHA" == "true" ]] && exit 0

TRANSCRIPT="$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$CWD" ]] && CWD="$PWD"

_MODEL="$(echo "$INPUT" | jq -r '(.model // "claude-opus-4-8")' 2>/dev/null)"
[[ -z "$_MODEL" || "$_MODEL" == "null" ]] && _MODEL="claude-opus-4-8"
# Sanitize at the write site: model ids are always [A-Za-z0-9._-]. Strip
# anything else so a crafted/corrupt Stop-payload model string can never carry
# control characters, markup, or JSON into the log (write-side half of the
# injection fix; model_fit_receipt_line re-sanitizes on read as belt-and-suspenders).
_MODEL="$(printf '%s' "$_MODEL" | tr -cd 'A-Za-z0-9._-')"
[[ -z "$_MODEL" ]] && _MODEL="claude-opus-4-8"

_IN="$(echo "$INPUT"  | jq -r '(.usage.input_tokens  // 0)' 2>/dev/null)"
_OUT="$(echo "$INPUT" | jq -r '(.usage.output_tokens // 0)' 2>/dev/null)"
[[ "$_IN"  =~ ^[0-9]+$ ]] || _IN=0
[[ "$_OUT" =~ ^[0-9]+$ ]] || _OUT=0

# tool_counts: count tool_use blocks by name in assistant turns emitted after
# the last genuine human prompt (same "last human prompt" definition as
# brevity-drift.sh). No transcript -> all-zero counts (still writes a row;
# tool_counts.other stays 0, contributing nothing to edit_calls).
TOOL_COUNTS='{"edit":0,"write":0,"bash":0,"read":0,"agent":0,"other":0}'
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  TOOL_COUNTS="$(
    jq -rs '
      def is_human_user:
        .type == "user"
        and ((.message.content | type) == "string"
             or ([.message.content[]? | .type] | (index("tool_result") | not)));
      def bucket($name):
        if $name == "Edit" or $name == "MultiEdit" then "edit"
        elif $name == "Write" then "write"
        elif $name == "Bash" then "bash"
        elif $name == "Read" then "read"
        elif $name == "Agent" or $name == "Task" or $name == "Workflow" then "agent"
        else "other" end;
      (map(is_human_user) | rindex(true)) as $u
      | (if $u == null then . else .[$u + 1:] end)
      | [ .[] | select(.type == "assistant")
          | .message.content[]? | select(.type == "tool_use") | .name ]
      | map(bucket(.))
      | reduce .[] as $b ({"edit":0,"write":0,"bash":0,"read":0,"agent":0,"other":0}; .[$b] += 1)
    ' "$TRANSCRIPT" 2>/dev/null
  )" || TOOL_COUNTS='{"edit":0,"write":0,"bash":0,"read":0,"agent":0,"other":0}'
  [[ -z "$TOOL_COUNTS" ]] && TOOL_COUNTS='{"edit":0,"write":0,"bash":0,"read":0,"agent":0,"other":0}'
fi

PROJECT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"

SESSION_START=""
[[ -f "$HOME/.claude/state/session-start.txt" ]] && \
  SESSION_START="$(cat "$HOME/.claude/state/session-start.txt" 2>/dev/null || true)"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"

LOG="$HOME/.claude/logs/subagent-runs.jsonl"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0

jq -nc \
  --arg ts "$TS" \
  --arg session_start "$SESSION_START" \
  --arg project "$PROJECT" \
  --arg model "$_MODEL" \
  --argjson in_tok "$_IN" \
  --argjson out_tok "$_OUT" \
  --argjson tool_counts "$TOOL_COUNTS" \
  '{event:"main_turn", agent:"main", ts:$ts, session_start:$session_start, project:$project, model:$model, in_tokens:$in_tok, out_tokens:$out_tok, tool_counts:$tool_counts}' \
  >> "$LOG" 2>/dev/null || true

# --- Job 2: once-per-session receipt fallback ---

# No resolvable session_start -> the receipt cannot honestly scope to "this
# session," and must not silently widen to all-time project history. Skip
# Job 2 entirely rather than call the lib with an empty session_start (the
# lib itself also refuses an empty session_start, as belt-and-suspenders).
[[ -z "$SESSION_START" ]] && exit 0

SID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[[ -z "$SID" ]] && exit 0   # no session id -> can't dedupe safely, skip the print (row above already landed)
SID="${SID//[^A-Za-z0-9._-]/_}"   # filename-safe, blocks path traversal

STATE_DIR="$HOME/.claude/session-state"
FLAG="$STATE_DIR/model-fit-receipt.$SID.printed"
[[ -f "$FLAG" ]] && exit 0   # already printed this session

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
[[ -f "$LIB" ]] || LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

LINE="$(model_fit_receipt_line "$SESSION_START" "$PROJECT" "$LOG" 2>/dev/null || echo "")"

# Insufficient evidence / no data yet -> stay silent WITHOUT setting the flag,
# so a later Stop in the same session (once enough turns accrue) can still
# print. The flag is set only at the moment a receipt actually prints.
[[ -z "$LINE" ]] && exit 0

mkdir -p "$STATE_DIR" 2>/dev/null && : > "$FLAG" 2>/dev/null || true

# Print-site sanitization (third layer, defense in depth): strip any '<', '>',
# or raw newline from the composed line before it goes inside the
# <system-reminder> wrapper, so nothing in the receipt text — model ids are
# already sanitized upstream, but this also covers any future field added to
# the sentence — can break out of the wrapper or fake a JSON decision object
# on the hook's stdout. model_fit_receipt_line's output is a single sentence;
# collapsing embedded newlines to spaces changes nothing for legitimate output.
LINE="$(printf '%s' "$LINE" | tr '\n' ' ' | tr -d '<>')"

printf '<system-reminder>\n%s\n</system-reminder>\n' "$LINE"
exit 0
