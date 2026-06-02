#!/usr/bin/env bash
# Claude Code Stack — cloud session bootstrap
#
# WHY: Claude Code *cloud* sessions (claude.ai/code on web + iOS) run in an
# ephemeral container. The repo is cloned fresh, but the user's laptop
# ~/.claude is NEVER synced up — so personal/global skills like /goodmorning
# and /handoff are not discoverable. This script installs the stack into the
# container's ~/.claude at session start so they load on every surface.
#
# USED TWO WAYS (see docs/CLOUD.md):
#   1. As the ENVIRONMENT setup script (configured per-environment in the
#      Claude Code web UI). Then EVERY cloud session of EVERY repo gets the
#      stack, without committing anything into each project.
#   2. Copied into a single repo's .claude/hooks/ by /project-init and wired
#      to that repo's SessionStart hook, so that repo self-bootstraps the
#      stack in cloud with no per-environment config.
#
# It clones this repo, then runs the idempotent installer: install.sh
# --mode=merge backs up ~/.claude and deep-merges JSON (user wins on conflict),
# so re-runs are safe.
#
# The repo is PUBLIC, so the clone needs no credential — no per-environment
# token, no setup-script secret. This makes the flow fully repo-driven:
# /project-init commits this script into a repo and the repo self-installs the
# stack in cloud with nothing configured on the environment.
#
# OPTIONAL ENV:
#   CLAUDE_STACK_REPO        default: github.com/bschonbrun/claude-code-stack
#   CLAUDE_STACK_REF         default: main
#   CLAUDE_STACK_TIER        default: 2
#   CLAUDE_STACK_REPO_TOKEN  only needed if the repo is ever made private
#                            again; if set, it is used (via GIT_ASKPASS, never
#                            in argv or .git/config). Never hardcode it.
#
# EXIT POLICY: best-effort. A network-blocked clone prints a prominent warning
# and exits 0 — it never hard-fails the cloud session.

set -uo pipefail

log() { printf '[stack-cloud-bootstrap] %s\n' "$*" >&2; }

# Only meaningful in the remote/cloud container. Local sessions install the
# stack themselves via ./scripts/install.sh, so this is a true no-op there.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Idempotency: run at most once per container boot. Both the environment
# setup script and a repo's committed hook may fire — whichever lands first
# wins; the rest no-op on this marker.
MARKER="/tmp/.claude-stack-cloud-bootstrap.done"
if [ -f "$MARKER" ]; then
  exit 0
fi

REPO="${CLAUDE_STACK_REPO:-github.com/bschonbrun/claude-code-stack}"
REF="${CLAUDE_STACK_REF:-main}"
TIER="${CLAUDE_STACK_TIER:-2}"

# Strip any scheme the caller supplied so we control the auth method.
REPO="${REPO#https://}"
REPO="${REPO#http://}"
REPO="${REPO%.git}"

TMP="$(mktemp -d)"
ASKPASS="$(mktemp)"
cleanup() { rm -rf "$TMP" "$ASKPASS"; }
trap cleanup EXIT

# Public repo → anonymous clone, no credential. If CLAUDE_STACK_REPO_TOKEN is
# set anyway (e.g. the repo was made private again), use it via GIT_ASKPASS so
# the token stays OUT of argv and .git/config: the username (x-access-token)
# lives in the URL and git asks the helper only for the password.
if [ -n "${CLAUDE_STACK_REPO_TOKEN:-}" ]; then
  export CLAUDE_STACK_REPO_TOKEN
  printf '#!/bin/sh\nexec printf "%%s" "$CLAUDE_STACK_REPO_TOKEN"\n' > "$ASKPASS"
  chmod +x "$ASKPASS"
  export GIT_ASKPASS="$ASKPASS"
  clone_url="https://x-access-token@${REPO}.git"
else
  clone_url="https://${REPO}.git"
fi

attempt=0
max=3
delay=2
until GIT_TERMINAL_PROMPT=0 \
      git clone --depth 1 --branch "$REF" "$clone_url" "$TMP/stack" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$max" ]; then
    log "WARNING: could not clone $REPO (ref $REF) after $max attempts."
    log "Check the environment's network policy allows GitHub."
    log "Continuing without the stack."
    exit 0
  fi
  log "clone attempt $attempt failed; retrying in ${delay}s..."
  sleep "$delay"
  delay=$((delay * 2))
done

log "cloned $REPO@$REF; installing tier $TIER into ~/.claude (merge mode)..."
if bash "$TMP/stack/scripts/install.sh" --tier="$TIER" --skip-requirements; then
  log "stack tier $TIER installed. Custom skills/commands are now available."
  : > "$MARKER"
else
  log "WARNING: install.sh exited non-zero; some stack pieces may be missing."
fi
