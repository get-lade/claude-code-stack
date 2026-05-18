# Operating Claude Code with the Stack

How to work day-to-day now that the Claude Code Stack is installed and all
repos are on it. If you read one doc, read this one.

You operate as the **architect**. Foreman + the subagents are the dev team.
You set direction and approve at gates; you do not micromanage routing.

## What you actively do

| When | Do this | Why |
|---|---|---|
| Start of a session | Run `/goodmorning` | Loads the last handoff, git state, open PRs, CI. The SessionStart hook also auto-reads the handoff. |
| End of a session | Run `/handoff` | Writes `.claude/next_prompt.md` so the next session resumes cleanly. Do it before you close. |
| Starting a new project | Run `/project-init` | Generates `.claude/stack-config.json`, scaffolds CLAUDE.md, ensures `docs/`. Without it, foreman refuses to dispatch (strict mode). |
| Before a bulk LLM job (>100 records) | Run `/budget-guard` or `/cost-gate` | Samples 10 records, projects total cost, refuses to run without your approval. Stops surprise bills. |
| Want to see config | Run `/default-settings` | Read-only view of global defaults + this project's stack-config. |

## What happens automatically (you don't drive it)

- **Foreman orchestrates.** It reads the repo's `.claude/stack-config.json`,
  classifies the task, and dispatches the right subagents in the right order.
  You don't pick subagents.
- **`domain_mode` enforces extra review**, per repo:
  - `financial-code` — full review chain (architect → implementer → validator
    → tester → red-team → security-auditor → reviewer); the validator
    cross-checks real numbers, not just shapes.
  - `ui-design` — a designer inventory before build, a `/design-match` diff
    before merge.
  - `data-operation` — mandatory coverage snapshots around bulk writes.
- **Approval gates.** Claude will PAUSE and ask for your OK at set points
  (e.g. after architect, after validator, before merge). That pause is the
  stack working — not a bug. Answer it to proceed.
- **Caveman communication mode** is on by default every session.

## How each repo is configured

Every repo carries `.claude/stack-config.json` — its tier and domain mode.
You don't need to memorize these; foreman reads them. A typical spread
across repos of differing complexity:

| Repo (example) | Tier | domain_mode |
|---|---|---|
| a thin monitoring repo | 1 | — |
| an isolated service / MCP server | 2 | — |
| a delivery pipeline | 3 | financial-code |
| a complex application | 4 | financial-code |
| a bulk data pipeline | 5 | data-operation |
| a dashboard suite | 5 | ui-design |

## Where to look when you need detail

Every audited repo now has:
- `docs/ADRs/` — why the big decisions were made.
- `docs/runbooks/` — what to do when a specific thing breaks.
- `docs/ONBOARDING.md` — a successor's first-day walkthrough.
- `docs/architecture/data-flow.md` — what the repo reads and writes.

Point new people — or a future session — at those.

## The rules that bite if you forget them

- A repo with no `stack-config.json` → foreman refuses. Run `/project-init`.
- Don't skip `/handoff` at session end — the next session starts blind
  without it.
- Bulk LLM jobs without `/budget-guard` are how surprise bills happen.
- An approval-gate pause is intentional. Don't treat it as the agent being
  stuck.

## Glossary

- **Tier (0–5)** — how much stack machinery a repo gets. Higher = more
  subagents, more guardrails.
- **domain_mode** — extra, domain-specific review rules layered on the tier.
- **Foreman** — the orchestrator skill. Routes work to subagents.
- **Subagent** — a specialized worker (architect, implementer, validator,
  reviewer, …) foreman dispatches.
- **Approval gate** — a point where Claude pauses for your explicit OK.
