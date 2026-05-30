#!/bin/bash
# SessionStart hook for Claude Code on the web.
#
# Fresh web/remote containers are cloned from the repo but do NOT have the
# Claude Code Stack installed into ~/.claude — so the stack's own skills
# (/project-init, /foreman, /agent-teams, /cost-gate, ...) and subagents
# aren't discoverable. This hook installs the stack on session start so they
# load in every web session.
#
# Runs only in the remote environment; local sessions are expected to have
# installed the stack themselves via ./scripts/install.sh.
set -euo pipefail

# No-op outside Claude Code on the web (e.g. local CLI sessions).
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Tier 2 covers the orchestration stack (/foreman + 12 subagents) on top of
# Tier 0/1 friction-killer skills. --skip-requirements downgrades the
# missing-tool / Keychain checks (codex, gemini, Supabase) to warnings, since
# the web container doesn't ship those. install.sh --mode=merge is idempotent
# and backs up the existing ~/.claude first, so re-running is safe.
"$CLAUDE_PROJECT_DIR/scripts/install.sh" --tier=2 --skip-requirements
