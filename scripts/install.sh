#!/usr/bin/env bash
# Claude Code Stack — Master installer
# Usage:
#   ./install.sh --tier=N [--mode=merge|overwrite|fresh] [--include-ollama=laptop]
#
# Examples:
#   ./install.sh --tier=0
#   ./install.sh --tier=5 --include-ollama=laptop
#   ./install.sh --tier=2 --mode=fresh

set -euo pipefail

# Defaults
TIER=""
MODE="merge"
INCLUDE_OLLAMA=""

# Parse args
for arg in "$@"; do
  case $arg in
    --tier=*) TIER="${arg#*=}" ;;
    --mode=*) MODE="${arg#*=}" ;;
    --include-ollama=*) INCLUDE_OLLAMA="${arg#*=}" ;;
    --help) echo "Usage: $0 --tier=N [--mode=merge|overwrite|fresh] [--include-ollama=laptop]"; exit 0 ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

if [[ -z "$TIER" ]]; then
  echo "Error: --tier required"
  exit 1
fi

if [[ ! "$TIER" =~ ^[0-5]$ ]]; then
  echo "Error: --tier must be 0, 1, 2, 3, 4, or 5"
  exit 1
fi

if [[ ! "$MODE" =~ ^(merge|overwrite|fresh)$ ]]; then
  echo "Error: --mode must be merge, overwrite, or fresh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo "==============================================="
echo "Claude Code Stack installer"
echo "Tier: $TIER"
echo "Mode: $MODE"
echo "Source: $REPO_ROOT"
echo "Target: $CLAUDE_DIR"
echo "==============================================="

# Source library functions
source "$SCRIPT_DIR/lib/tier-installer.sh"
source "$SCRIPT_DIR/lib/config-merger.sh"

# Step 1: Backup if mode != fresh (fresh handles its own backup)
if [[ "$MODE" != "fresh" ]]; then
  echo "[1/5] Backing up current ~/.claude/..."
  "$SCRIPT_DIR/backup.sh"
else
  echo "[1/5] Fresh mode: archiving current ~/.claude/ and starting clean..."
  if [[ -d "$CLAUDE_DIR" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    mv "$CLAUDE_DIR" "$HOME/.claude.backup.fresh-$timestamp"
    echo "  Moved to ~/.claude.backup.fresh-$timestamp"
  fi
  mkdir -p "$CLAUDE_DIR"
fi

# Step 2: Install tiers 0 through TIER (cumulative)
echo "[2/5] Installing tiers 0 through $TIER..."
for ((t=0; t<=TIER; t++)); do
  echo "  Tier $t..."
  install_tier "$t" "$REPO_ROOT" "$CLAUDE_DIR" "$MODE"
done

# Step 3: Schemas (Tier 2+)
if [[ "$TIER" -ge 2 ]]; then
  echo "[3/5] Applying Supabase schemas..."
  apply_schemas "$REPO_ROOT" "$TIER"
fi

# Step 4: Ollama (Tier 5 with --include-ollama)
if [[ "$TIER" -ge 5 ]] && [[ "$INCLUDE_OLLAMA" == "laptop" ]]; then
  echo "[4/5] Installing Ollama..."
  install_ollama
fi

# Step 5: Verify
echo "[5/5] Verifying installation..."
"$SCRIPT_DIR/verify.sh" --tier="$TIER"

echo "==============================================="
echo "Install complete. Stack tier $TIER is live."
echo "==============================================="
echo
echo "Next steps:"
echo "  - cd into a project"
echo "  - run /project-init to set tier for that project"
echo "  - open Claude Code; SessionStart hook should fire"
echo
echo "If anything failed, see logs in /tmp/claude-stack-install.log"
