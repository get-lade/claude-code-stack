# Installation Guide

## Pre-requisites

| Requirement | Tier needed | Notes |
|---|---|---|
| Claude Code installed | All | Stock Claude Code (any recent version) |
| `gh` CLI authenticated | Stack repo bootstrap | `brew install gh && gh auth login` |
| Node.js 18+ | All (for skills using TS) | `brew install node` |
| `jq` | All (config merging) | `brew install jq` |
| Anthropic API key | All | Already configured if Claude Code works |
| OpenAI API key | Tier 2+ | Codex access; configure in Keychain |
| Google AI Studio API key | Tier 3+ | Gemini 2.5 Pro; configure in Keychain |
| Supabase project | Tier 2+ | For cost_log; can reuse the maintainer's `<your-supabase-ref>` |
| Ollama | Tier 5 | `brew install ollama` |

All API keys live in macOS Keychain (NOT in `.env` files):
```bash
security add-generic-password -s anthropic-api-key -a "$USER" -w '<key>' -U
security add-generic-password -s openai-api-key -a "$USER" -w '<key>' -U
security add-generic-password -s google-ai-api-key -a "$USER" -w '<key>' -U
```

## Install commands

### Tier 0 (foundation)
```bash
cd ~/code/claude-code-stack
./scripts/install.sh --tier=0 --mode=merge
./scripts/verify.sh --tier=0
```

### Tier 1
```bash
./scripts/install.sh --tier=1
./scripts/verify.sh --tier=1
```

### Tier 2
```bash
# First: apply Supabase schema
./scripts/apply-schema.sh schemas/001-cost-log.sql

./scripts/install.sh --tier=2
./scripts/verify.sh --tier=2
```

### Tier 3
```bash
./scripts/install.sh --tier=3
./scripts/verify.sh --tier=3
```

### Tier 4
```bash
./scripts/apply-schema.sh schemas/002-subagent-runs.sql
./scripts/apply-schema.sh schemas/003-model-audits.sql

./scripts/install.sh --tier=4
./scripts/verify.sh --tier=4
```

### Tier 5
```bash
./scripts/install.sh --tier=5 --include-ollama=laptop
./scripts/verify.sh --tier=5
```

## Modes

- `--mode=merge` (default): preserves user customizations, adds new stack content. Safe for re-runs.
- `--mode=overwrite`: replaces stack-managed files, preserves user-owned files outside stack scope.
- `--mode=fresh`: backs up `~/.claude/` to `~/.claude.backup.<timestamp>/`, installs cleanly.

## What gets installed where

| What | Where | Owner |
|---|---|---|
| Global CLAUDE.md | `~/.claude/CLAUDE.md` | Stack (user can override) |
| Global settings.json | `~/.claude/settings.json` | Stack (merge with user) |
| Subagents | `~/.claude/agents/` | Stack |
| Skills | `~/.claude/skills/` | Stack |
| Hooks scripts | `~/.claude/hooks/` | Stack |
| Per-project CLAUDE.md | `<proj>/.claude/CLAUDE.md` | User (template provided) |
| Per-project stack-config | `<proj>/.claude/stack-config.json` | User (via /project-init) |
| Cost projections | `~/.claude/cost-projections/` | Skill output, gitignored |
| Backups | `~/.claude.backup.<timestamp>/` | Auto-created by install |

## Verification

`./scripts/verify.sh --tier=<N>` runs:
- File existence checks
- Hook execute permissions
- Command availability (tsc, gh, jq, etc.)
- API key reachability (without printing keys)
- Foreman test invocation (Tier 2+)
- Tier-specific smoke tests

Failures include remediation guidance.

## Uninstall

```bash
./scripts/uninstall.sh   # interactive, asks before each removal
```

This backs up current state before removal. Recovery: copy `~/.claude.backup.<latest>/` back to `~/.claude/`.
