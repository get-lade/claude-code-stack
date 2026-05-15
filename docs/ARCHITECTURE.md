# Architecture

## High-level

The stack is a **configuration layer** on top of stock Claude Code. Nothing is forked. Nothing is compiled. The stack is markdown, JSON, and shell scripts that live in `~/.claude/` globally and `<project>/.claude/` per-project.

```
┌─────────────────────────────────────────────────────────────┐
│  User (the maintainer)                                                │
│       │                                                     │
│       ▼                                                     │
│  Claude Code (CLI)                                          │
│       │                                                     │
│       ▼                                                     │
│  ~/.claude/  (global config)                                │
│  ├── CLAUDE.md  (behavioral principles)                     │
│  ├── settings.json  (hooks, permissions)                    │
│  ├── agents/  (21 subagent definitions)                     │
│  ├── skills/  (15 skills)                                   │
│  └── hooks/  (6 hook scripts)                                │
│       │                                                     │
│       ▼                                                     │
│  <project>/.claude/  (per-project config)                   │
│  ├── stack-config.json  (tier + overrides)                  │
│  ├── CLAUDE.md  (project-specific facts)                    │
│  ├── settings.json  (project hooks)                         │
│  └── handoffs/  (session archive)                           │
│       │                                                     │
│       ▼                                                     │
│  Foreman (orchestrator subagent)                            │
│       │                                                     │
│       ├──► Architect (Opus)                                 │
│       ├──► Implementer (Sonnet)                             │
│       ├──► Validator (Sonnet)                               │
│       ├──► Reviewer (Codex)                                 │
│       ├──► Tester (Sonnet)                                  │
│       ├──► Documenter (Sonnet)                              │
│       ├──► Scribe (Haiku)                                   │
│       ├──► Ops (Haiku)                                      │
│       ├──► Product-critic (GPT-5)                           │
│       ├──► Designer (Opus)                                  │
│       ├──► Red-team (Gemini)                                │
│       ├──► Security-auditor (Codex)                         │
│       └──► [12 more on the specialist + meta bench]         │
│       │                                                     │
│       ▼                                                     │
│  Operational state                                          │
│  ├── Supabase (cost_log, subagent_runs, model_audits)       │
│  ├── macOS Keychain (API keys)                              │
│  └── ~/.claude.backup.*/  (install backups)                 │
└─────────────────────────────────────────────────────────────┘
```

## Subagent invocation flow

1. User types a request to Claude Code.
2. Foreman receives the request along with `stack-config.json`.
3. Foreman decides team composition based on:
   - Task type (read from request)
   - Project tier (from stack-config.json)
   - Domain mode (financial-code, schema-migration, deploy, if applicable)
4. Foreman dispatches to first subagent in the chain (usually architect or implementer depending on novelty).
5. Each subagent writes its output to `<project>/.claude/context/<session-id>/<subagent-name>.md`.
6. Next subagent reads previous subagent's output + the request + relevant repo files.
7. At approval gates (configured per task type), foreman pauses and asks user.
8. After completion, scribe writes session handoff.

## Context handoff between subagents

Each subagent has its own context window. Subagents communicate via:
- **Files in `<project>/.claude/context/<session-id>/`** — primary mechanism.
- **Git state** — branch, uncommitted changes, last N commits.
- **Subagent_runs table** — historical context, scoped to recent runs.

This avoids the "tell each subagent everything" antipattern. Each subagent reads only what it needs.

## Conflict resolution

When reviewer rejects implementer's work:
1. Reviewer writes specific objections to `<context>/reviewer-feedback.md`.
2. Foreman dispatches implementer with feedback as additional context.
3. Implementer addresses or pushes back (writes `<context>/implementer-response.md`).
4. Reviewer reads response and either approves or escalates.
5. After 2 rounds without convergence: foreman escalates to user.

The 2-round rule prevents infinite loops. User gets the disagreement summarized.

## Cost tracking

Every subagent invocation writes to Supabase `cost_log`:
- session_id, subagent, model, input_tokens, output_tokens, cost_usd, wall_time_ms, status

`subagent_runs` table has higher-level rollup:
- session_id, task_summary, subagents_invoked, total_cost, outcome (success/escalated/abandoned), duration_min

These feed `/agent-performance-review` at Tier 4.

## Failure modes the architecture protects against

| Failure | Protection |
|---|---|
| Shipping before validating | architect → implementer split; validator subagent required by foreman |
| Wrong-approach pivots | architect produces ADR + approval gate before implementer starts |
| Buggy code reaching main | reviewer (Codex) is adversarial; tests required before merge |
| Cost runaway | /cost-gate skill mandatory for bulk LLM jobs |
| Coverage regression | /coverage-snapshot before bulk data operations |
| Wrong branch deploy | branch-check hook in PreToolUse Bash |
| Lost context across sessions | /handoff + SessionStart auto-load |
| Bus-factor risk | ADRs + runbooks + onboarding docs required at Tier 2+ |
| MCP auth surprises | mcp-health-check hook at session start |
| Same-model blind spots in review | adversarial diversity (Codex / Gemini / GPT-5 for review roles) |

## What the architecture does NOT protect against

- **User-introduced bugs in skill/agent definitions.** We have a test suite but a poorly-written skill can still produce bad output. Mitigation: skill peer review when sharing across users.
- **API outages.** If Anthropic, OpenAI, or Google are down, the subagents using those providers are offline. Tier 5 (Ollama) provides a partial fallback.
- **Model behavior drift.** Anthropic updates Sonnet; subagent behavior changes subtly. Mitigation: /agent-performance-review surfaces this monthly.
- **Foreman misrouting.** Foreman picks the wrong team for a task. Mitigation: `/dispatch` skill lets user override; foreman decisions are logged and reviewed monthly.
