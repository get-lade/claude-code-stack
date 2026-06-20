#!/usr/bin/env bash
# PreToolUse[Bash] hook: during an ACTIVE loop, deny irreversible commands so
# an unattended loop cannot push/merge/deploy/delete/move money. Outside a
# loop, stays silent. Red-team owns the pattern list. Best-effort: exit 0.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/../skills/loop-engineer/loop_lib.sh"
# Guard against unset HOME before using it as a fallback path.
if [[ ! -f "$LIB" ]]; then
  [[ -n "${HOME:-}" ]] && LIB="$HOME/.claude/skills/loop-engineer/loop_lib.sh"
fi
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

[[ "$(loop_read_state | jq -r '.active // false' 2>/dev/null)" == "true" ]] || exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"
CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -z "$CMD" ]] && CMD="${CLAUDE_TOOL_INPUT_command:-}"
[[ -z "$CMD" ]] && exit 0

# --- normalize the command for token-aware matching ---
#
# Problems with raw substring grep:
#   - git -C repo push, command git push, /usr/bin/git push evade git patterns
#   - git p'ush', git pu\sh (shell quoting) evade subcommand detection
#   - rm -fr, rm -r -f evade rm -rf
#   - git merge-base falsely matches git merge (no right boundary)
#
# Strategy:
#   1. Strip shell quoting noise (backslashes outside strings, paired quotes)
#      so p'ush' -> push and pu\sh -> push.
#   2. Strip leading path from first token (/usr/bin/git -> git).
#   3. Strip "command " / "exec " prefixes so command git push -> git push.
#   4. For git: skip global options (-C <path>, --git-dir=..., etc.) to
#      reach the actual subcommand, then match it with a word boundary.
#   5. For rm: collect all flags and check if both -r/-R and -f appear.

# Step 1: strip backslash-letter sequences and paired single/double quotes
# (conservative: remove \<char> and 'str' / "str" wrappers around word chars)
NORM="$CMD"
NORM="$(printf '%s' "$NORM" | sed "s/\\\\//g; s/'//g; s/\"//g")"

# Step 2+3: strip leading path and known shell dispatch prefixes repeatedly
strip_prefixes() {
  local s="$1"
  # strip path prefix from leading binary
  s="$(printf '%s' "$s" | sed -E 's|^[[:space:]]*/[^[:space:]]*/||')"
  # strip "command " / "exec " / "builtin " prefixes (repeat up to 3 times)
  local i
  for i in 1 2 3; do
    s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]*(command|exec|builtin)[[:space:]]+//')"
    # strip another path prefix that may have been revealed
    s="$(printf '%s' "$s" | sed -E 's|^[[:space:]]*/[^[:space:]]*/||')"
  done
  printf '%s' "$s"
}
NORM="$(strip_prefixes "$NORM")"

# Extract leading binary name from normalized command
BIN="$(printf '%s' "$NORM" | awk '{print $1}')"
REST="$(printf '%s' "$NORM" | cut -d' ' -f2-)"

# Step 4: for git, skip global options to find the subcommand
# Git global options that consume an argument: -C, --git-dir, --work-tree,
# --namespace, --super-prefix, -c, --config-env, --exec-path, --html-path,
# --man-path, --info-path. Flags: --version, --help, --no-pager, -p, --bare,
# --no-replace-objects, --literal-pathspecs, --glob-pathspecs, --noglob-pathspecs,
# --icase-pathspecs, --no-optional-locks, --no-advice.
git_subcommand() {
  local args="$1"
  local skip_next=false
  local tok
  for tok in $args; do
    if $skip_next; then
      skip_next=false
      continue
    fi
    case "$tok" in
      -C|--git-dir|--work-tree|--namespace|--super-prefix|-c|--config-env|--exec-path)
        skip_next=true ;;
      --git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*|-c=*|--config-env=*|--exec-path=*)
        ;;  # value embedded, skip nothing extra
      -*)
        ;;  # other flag, skip
      *)
        printf '%s' "$tok"
        return ;;
    esac
  done
}

# Step 5: for rm, check if -r/-R AND -f both appear across all tokens
rm_is_recursive_force() {
  local args="$1"
  local has_r=false has_f=false tok flag
  for tok in $args; do
    # each token: if it starts with - it's a flag group (e.g. -rf, -fr, -r, -f)
    case "$tok" in
      --recursive) has_r=true ;;
      --force)     has_f=true ;;
      -*)
        # strip leading dash(es) and iterate chars
        flag="${tok#-}"; flag="${flag#-}"
        case "$flag" in *r*|*R*) has_r=true ;; esac
        case "$flag" in *f*)     has_f=true ;; esac
        ;;
    esac
  done
  $has_r && $has_f
}

DENIED=false

if [[ "$BIN" == "git" ]]; then
  SUBCMD="$(git_subcommand "$REST")"
  case "$SUBCMD" in
    push|merge|"reset")
      # For reset, require --hard argument
      if [[ "$SUBCMD" == "reset" ]]; then
        printf '%s' "$REST" | grep -qwF -- '--hard' && DENIED=true
      else
        DENIED=true
      fi
      ;;
  esac
elif [[ "$BIN" == "rm" ]]; then
  rm_is_recursive_force "$REST" && DENIED=true
elif printf '%s' "$NORM" | grep -qiE \
  'deploy-edge|supabase[[:space:]].*delete|supabase[[:space:]].*drop|drop[[:space:]]+table([[:space:]]|$)|truncate[[:space:]]|stripe[[:space:]]|gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
  DENIED=true
fi

if $DENIED; then
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny",
    permissionDecisionReason:"irreversible-deny: an active loop may not run irreversible actions (push/merge/deploy/delete/money). Pause the loop or get a human checkpoint, then run this outside the loop."}}' 2>/dev/null || true
fi
exit 0
