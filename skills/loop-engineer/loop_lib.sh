#!/usr/bin/env bash
# Shared library for the loop-engineering control plane.
# Sourced by the /loop-engineer skill helper and the loop hooks.
# All functions are fail-safe: errors never crash the caller.
set -uo pipefail

# Safe HOME fallback: avoid expanding $HOME when it may be unset under set -u.
_loop_home="${HOME:-/tmp}"
LOOP_STATE_DIR="${LOOP_STATE_DIR:-${_loop_home}/.claude/session-state}"

# Loop-state is per-session (ADR-020): two live sessions must not share one
# state file, or they fight over a single Stop-hook iteration counter and one
# session gets trapped by a loop another armed. The path is resolved lazily so
# the session id can be set after this lib is sourced (the Stop hook exports it
# from the hook payload before reading state).
#   precedence: LOOP_STATE_FILE override  >  per-session file  >  legacy file
_loop_state_file() {
  if [[ -n "${LOOP_STATE_FILE:-}" ]]; then
    printf '%s' "$LOOP_STATE_FILE"; return 0
  fi
  local sid="${CLAUDE_CODE_SESSION_ID:-}"
  sid="${sid//[^A-Za-z0-9._-]/_}"   # filename-safe; blocks path traversal
  if [[ -n "$sid" ]]; then
    printf '%s/loop-state.%s.json' "$LOOP_STATE_DIR" "$sid"
  else
    printf '%s/loop-state.json' "$LOOP_STATE_DIR"
  fi
}

loop_read_state() {
  local f; f="$(_loop_state_file)"
  if [[ -f "$f" ]]; then
    jq -c '.' "$f" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

loop_write_state() {
  # Default to empty object so zero-arg invocation is safe under set -u.
  # Two-step: bash closes ${1:-{}} at the first }, so use an intermediate var.
  local json tmp f
  json="${1:-}"
  [[ -z "$json" ]] && json="{}"
  f="$(_loop_state_file)"
  # All failure paths return 0 so set -e callers are not terminated.
  mkdir -p "$LOOP_STATE_DIR" 2>/dev/null || return 0
  # Use mktemp to avoid predictable PID-based tmp names (symlink attack).
  tmp="$(mktemp "${f}.tmp.XXXXXX" 2>/dev/null)" || return 0
  printf '%s\n' "$json" | jq -c '.' >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 0; }
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
    # Phase-2 (d): include the byte-contents of untracked, non-ignored files so a
    # loop that only edits an untracked file is detected as making progress.
    # --exclude-standard honors .gitignore; -z + xargs -0 are filename-safe.
    git -C "$cwd" ls-files --others --exclude-standard -z 2>/dev/null \
      | (cd "$cwd" 2>/dev/null && xargs -0 cat 2>/dev/null)
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
  # Integer bounds must be a positive integer (>= 1); 0 is rejected (schema minimum:1).
  [[ -n "$_mi" && ! "$_mi" =~ ^[1-9][0-9]*$ ]] && return 2
  # per_run_budget_usd allows decimal but must be a valid non-negative number.
  [[ -n "$_pb" && ! "$_pb" =~ ^[0-9]+(\.[0-9]+)?$ ]] && return 2
  # timeout_minutes must also be a positive integer (>= 1).
  [[ -n "$_to" && ! "$_to" =~ ^[1-9][0-9]*$ ]] && return 2
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
  local iter cap cost budget npc npe started now elapsed timeout depth dcap
  iter="$(echo "$json"  | jq -r '.iteration // 0')"
  cap="$(echo "$json"   | jq -r '.bounds.max_iterations // 1000000')"
  # Phase-2 (c): recursion depth is now a hard bound (was advisory in Phase 1).
  # Callers increment .recursion_depth on fan-out; bound is .bounds.max_recursion_depth.
  depth="$(echo "$json" | jq -r '.recursion_depth // 0')"
  dcap="$(echo "$json"  | jq -r '.bounds.max_recursion_depth // empty')"
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
  # Recursion depth check (before iteration): a non-integer cap is treated as tripped.
  if [[ -n "$dcap" ]]; then
    [[ "$depth" =~ ^[0-9]+$ ]] || depth=0
    if [[ ! "$dcap" =~ ^[0-9]+$ ]]; then echo "max_recursion_depth"; return; fi
    [[ "$depth" -ge "$dcap" ]] && { echo "max_recursion_depth"; return; }
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

# Phase-2 (b): live within-iteration cost for a loop. Sums cost_usd/cost across
# all subagent-runs.jsonl rows tagged with this loop_id (optionally only those at
# or after started_at when the row carries a .ts). This is the authoritative
# mid-flight figure the live monitor compares to the budget — unlike the
# between-iteration cost_so_far_usd snapshot, it does not wait for the Stop hook.
# Prints a number (0 when no data). Fail-safe.
#
# Event semantics (ADR-024): this intentionally sums ALL loop-tagged cost rows
# regardless of event. The two cost-bearing events are DISJOINT spend segments,
# never overlapping, so the sum is correct (not double-counted):
#   - loop_tool_cost  (loop-cost-accrual.sh) — real per-tool token cost, the only
#                       per-call cost source in normal operation.
#   - loop_iteration  (loop_accrue_cost)     — legacy between-iteration estimate,
#                       written only if a caller explicitly accrues one.
loop_live_cost() {
  local lid="${1:-}" since="${2:-}"
  local log="${_loop_home}/.claude/logs/subagent-runs.jsonl"
  [[ -z "$lid" || ! -f "$log" ]] && { echo 0; return 0; }
  jq -rs --arg lid "$lid" --arg since "$since" '
    [ .[]
      | select(.loop_id == $lid)
      | select( ($since == "") or ((.ts // "") == "") or (.ts >= $since) )
      | ((.cost_usd // .cost // 0) | tonumber? // 0)
    ] | add // 0
  ' "$log" 2>/dev/null || echo 0
}

# Phase-2 telemetry: record one finished loop run. Always appends a row to the
# local JSONL telemetry log (always-on); additionally POSTs to the Supabase
# stack.loop_runs table (004-loop-runs.sql) IFF both SUPABASE_URL and
# SUPABASE_SERVICE_KEY are set and curl exists. No-op-safe: missing creds, missing
# curl, or any network error never crash the caller (matches the cost-log pattern).
# Usage: loop_runs_record '<loop-state-json-with-terminal-status>'
loop_runs_record() {
  local state="${1:-}"
  [[ -z "$state" ]] && return 0
  # Phase-3 polish (ADR-024): record REAL spend. cost_so_far_usd is the
  # between-iteration snapshot; loop_live_cost sums the per-tool loop_tool_cost
  # rows accrued by loop-cost-accrual.sh. Take the larger so /loop-review's avg $
  # reflects actual per-tool cost, not just the snapshot. Fail-safe -> snapshot.
  local _lid _started _snap _live _cost
  _lid="$(echo "$state" | jq -r '.loop_id // empty' 2>/dev/null)"
  _started="$(echo "$state" | jq -r '.started_at // empty' 2>/dev/null)"
  _snap="$(echo "$state" | jq -r '.cost_so_far_usd // 0' 2>/dev/null)"
  [[ "$_snap" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _snap=0
  _live="$(loop_live_cost "$_lid" "$_started" 2>/dev/null || echo 0)"
  [[ "$_live" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _live=0
  _cost="$(awk -v a="$_snap" -v b="$_live" 'BEGIN{printf "%.6f", (a>b?a:b)}' 2>/dev/null)" || _cost="$_snap"
  # Build the row from loop-state fields.
  local row
  row="$(echo "$state" | jq -c --argjson cost "${_cost:-0}" '{
    loop_id:         (.loop_id // "loop"),
    session_id:      (env.CLAUDE_CODE_SESSION_ID // null),
    pattern:         (.pattern // null),
    autonomy:        (.autonomy // null),
    goal:            (.goal // null),
    status:          (.status // "unknown"),
    iterations:      (.iteration // 0),
    recursion_depth: (.recursion_depth // 0),
    cost_usd:        $cost,
    started_at:      (.started_at // null),
    ended_at:        (now | todateiso8601)
  }' 2>/dev/null)" || return 0
  [[ -z "$row" ]] && return 0

  # Always-on local telemetry.
  local log="${_loop_home}/.claude/logs/loop-runs.jsonl"
  mkdir -p "$(dirname "$log")" 2>/dev/null && printf '%s\n' "$row" >>"$log" 2>/dev/null || true

  # Optional Supabase rollup (Tier 3+). Graceful no-op without creds/curl.
  [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_KEY:-}" ]] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -sf -X POST "${SUPABASE_URL%/}/rest/v1/loop_runs" \
    -H "apikey: ${SUPABASE_SERVICE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}" \
    -H "Content-Type: application/json" \
    -H "Content-Profile: stack" \
    -H "Prefer: return=minimal" \
    --data "$row" >/dev/null 2>&1 || true
  return 0
}

# Phase-3 (ADR-023): aggregate loop telemetry from the local loop-runs.jsonl into
# per-pattern stats. Prints a JSON array (one object per pattern). Empty/no log ->
# []. Fail-safe. Optional arg overrides the log path (for tests).
loop_stats() {
  local log="${1:-${_loop_home}/.claude/logs/loop-runs.jsonl}"
  [[ -f "$log" ]] || { echo '[]'; return 0; }
  jq -rs '
    def pct($p): (sort | if length==0 then 0 else .[ ([(((length * $p) | ceil) - 1), 0] | max) ] end);
    group_by(.pattern // "unknown")
    | map({
        pattern: (.[0].pattern // "unknown"),
        runs: length,
        met_pct:              ((map(select(.status=="met"))            | length) * 100 / length),
        budget_exceeded_pct:  ((map(select(.status=="budget_exceeded"))| length) * 100 / length),
        iter_cap_pct:         ((map(select(.status=="max_iterations")) | length) * 100 / length),
        p50_iterations:       ([ .[].iterations // 0 ] | pct(0.50)),
        p95_iterations:       ([ .[].iterations // 0 ] | pct(0.95)),
        avg_cost_usd:         (((map(.cost_usd // 0) | add) / length) | (.*1000000|round)/1000000)
      })
  ' "$log" 2>/dev/null || echo '[]'
}

# Phase-3 polish (ADR-024): render loop_stats as an aligned text table for
# /loop-review (so rendering is deterministic, not left to model discretion).
# Same source as loop_stats (optional log-path arg). Empty history -> prints
# nothing (the caller emits the "no history" message). Fail-safe: any error ->
# prints nothing.
loop_stats_table() {
  local stats; stats="$(loop_stats "${1:-}")"
  [[ -z "$stats" || "$stats" == "[]" ]] && return 0
  local fmt='%-14s %5s %6s %8s %8s %5s %5s %9s\n'
  {
    # shellcheck disable=SC2059
    printf "$fmt" PATTERN RUNS MET% BUDGET% ITERCAP% P50 P95 'AVG$'
    echo "$stats" | jq -r '
      def r1: (.*10|round)/10;
      .[] | [
        (.pattern // "unknown"),
        (.runs // 0),
        ((.met_pct // 0)             | r1),
        ((.budget_exceeded_pct // 0) | r1),
        ((.iter_cap_pct // 0)        | r1),
        (.p50_iterations // 0),
        (.p95_iterations // 0),
        (.avg_cost_usd // 0)
      ] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r pat runs met bud cap p50 p95 avg; do
        # shellcheck disable=SC2059
        printf "$fmt" "$pat" "$runs" "$met" "$bud" "$cap" "$p50" "$p95" "$avg"
      done
  } 2>/dev/null || return 0
}

# Propose (print only — never auto-apply) a loop_policy.max_iterations bump per
# pattern: ceil(p95 * 1.2), floored at the current default. Reads loop_stats.
# Prints a JSON array of {pattern, observed_p95, proposed_max_iterations}.
loop_calibrate() {
  local current="${1:-25}" log="${2:-}"
  [[ "$current" =~ ^[0-9]+$ ]] || current=25
  local stats; stats="$(loop_stats "$log")"
  echo "$stats" | jq -c --argjson cur "$current" '
    map({
      pattern: .pattern,
      runs: .runs,
      observed_p95: .p95_iterations,
      proposed_max_iterations: ([ ($cur), (((.p95_iterations * 1.2) | ceil)) ] | max)
    })
  ' 2>/dev/null || echo '[]'
}

# Phase-3 (ADR-023): convert token usage to USD via the single audited price
# table (config/model-routing.json -> providers.*.models[id].pricing_per_million_*).
# Usage: loop_cost_from_usage <input_tokens> <output_tokens> [model_id]
# Prints a USD number (0 on any error / unknown model). Fail-safe.
loop_cost_from_usage() {
  local in_tok="${1:-0}" out_tok="${2:-0}" model="${3:-claude-opus-4-8}"
  [[ "$in_tok"  =~ ^[0-9]+$ ]] || in_tok=0
  [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0
  # Resolve the price table: explicit override, then installed, then repo-relative.
  local pt="${LOOP_PRICE_TABLE:-}"
  if [[ -z "$pt" ]]; then
    if [[ -f "${_loop_home}/.claude/config/model-routing.json" ]]; then
      pt="${_loop_home}/.claude/config/model-routing.json"
    else
      local _here; _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
      [[ -f "${_here}/../../config/model-routing.json" ]] && pt="${_here}/../../config/model-routing.json"
    fi
  fi
  [[ -z "$pt" || ! -f "$pt" ]] && { echo 0; return 0; }
  jq -rn --slurpfile t "$pt" --arg m "$model" --argjson i "$in_tok" --argjson o "$out_tok" '
    ([ ($t[0].providers // {})[] | .models? // {} ] | add // {}) as $models
    | ($models[$m] // {}) as $mdl
    | ( (($mdl.pricing_per_million_input  // 0) * $i / 1000000)
      + (($mdl.pricing_per_million_output // 0) * $o / 1000000) )
  ' 2>/dev/null || echo 0
}

# Phase-3 (spec §6.7): durable corrections. When a loop exits without meeting its
# goal (no_progress / escalated / a bound trip), append a structured note so the
# lesson compounds — /handoff folds unresolved corrections into the next session.
# Always-on local append; fail-safe (never crashes the Stop hook).
# Usage: loop_record_correction '<loop-state-json>' [hint]
loop_record_correction() {
  local state="${1:-}" hint="${2:-}"
  [[ -z "$state" ]] && return 0
  local row
  row="$(echo "$state" | jq -c --arg hint "$hint" '{
    ts:       (now | todateiso8601),
    loop_id:  (.loop_id // "loop"),
    status:   (.status // "unknown"),
    goal:     (.goal // null),
    iteration:(.iteration // 0),
    hint:     (if $hint == "" then null else $hint end),
    resolved: false
  }' 2>/dev/null)" || return 0
  [[ -z "$row" ]] && return 0
  local f="${LOOP_STATE_DIR}/loop-corrections.jsonl"
  mkdir -p "$LOOP_STATE_DIR" 2>/dev/null && printf '%s\n' "$row" >>"$f" 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# Ultracode signal (Phase 2 / spec open-question 1)
# ---------------------------------------------------------------------------
# Ultracode is a session-scoped risk dial: when on, the loop autonomy ceiling is
# raised one level above the tier default (capped at bounded-autonomous). It is
# deliberately NOT persisted in stack-config — it is a per-session opt-in, set by
# env (CLAUDE_ULTRACODE) or the /ultracode skill's session-state flag.
# Returns rc 0 when active, rc 1 otherwise. Fail-safe: any error -> inactive.
loop_ultracode_active() {
  local v="${CLAUDE_ULTRACODE:-}"
  # bash 3.2 (macOS default) lacks ${v,,}; match case-insensitively instead.
  case "$v" in
    1|[Tt][Rr][Uu][Ee]|[Oo][Nn]|[Yy][Ee][Ss]) return 0 ;;
  esac
  local f="${LOOP_STATE_DIR:-${HOME:-/tmp}/.claude/session-state}/ultracode-state.json"
  if [[ -f "$f" ]]; then
    [[ "$(jq -r '.active // false' "$f" 2>/dev/null)" == "true" ]] && return 0
  fi
  return 1
}

# Compute the effective autonomy ceiling given the tier ceiling and whether
# ultracode is active. Ultracode raises one level, capped at bounded-autonomous.
# Usage: loop_effective_ceiling <tier_ceiling> <true|false>
loop_effective_ceiling() {
  local base="${1:-checkpoint}" ultra="${2:-false}"
  if [[ "$ultra" != "true" ]]; then printf '%s' "$base"; return 0; fi
  case "$base" in
    checkpoint)          printf 'bounded-checkpoint' ;;
    bounded-checkpoint)  printf 'bounded-autonomous' ;;
    bounded-autonomous)  printf 'bounded-autonomous' ;;   # already at cap
    *)                   printf '%s' "$base" ;;            # unknown -> identity
  esac
}
