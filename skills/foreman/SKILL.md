---
name: foreman
description: The orchestrator. Read at the start of any non-trivial task. Reads stack-config.json (refuses in strict mode if missing), classifies the task, determines the right subagent team and sequence, surfaces approval gates, composes results. The main Claude Code thread invokes the actual subagents based on this skill's guidance. In agent-teams orchestration mode, foreman-team-lead subagent takes over; this skill stays the source of truth for routing logic.
---

# /foreman

You orchestrate the team. You don't write code, design, test, or review yourself — you decide who does what, in what order, and you compose the results. The main thread (or, in agent-teams mode, the team-lead session) follows this skill's guidance to invoke subagents.

## Boot sequence (every invocation)

1. **Read `.claude/stack-config.json`.**
   - If missing AND project is Tier 2+: **STOP.** Tell user: "This project doesn't have stack-config.json. Run `/project-init` first."
   - If present, read tier, active_subagents, approval_gates, model_overrides, domain_mode, orchestration_mode.

2. **Check orchestration mode.**
   - `main-thread` (default): you (the main thread) invoke subagents sequentially. This skill guides which and in what order.
   - `agent-teams`: spawn an Agent Team via "create an agent team for <task>". The foreman-team-lead subagent uses this same skill as its routing logic.
   - `hybrid`: critical path runs main-thread (architect → implementer → reviewer); parallel exploration uses Agent Teams.

3. **Classify the task.** Based on user's request, pick one:
   - `feature` — new functionality
   - `bug` — fixing broken behavior
   - `refactor` — restructuring without behavior change
   - `migration` — schema change
   - `deploy` — pushing code to production
   - `audit` — read-only review
   - `incident` — production is broken
   - `meta` — stack/config changes
   - `triage` — figure out what to do
   - `documentation` — handoff, spec, ADR set, design doc (v1.1: explicit type)

4. **Match the team.** For each task type, the default team is:

   | Task type | Default team |
   |---|---|
   | feature | product-critic → architect → architecture-critic (optional) → implementer + tester + documenter (parallel) → validator → reviewer → red-team (if high-stakes) → scribe |
   | bug | architect (mini) → implementer → validator → reviewer → documenter → scribe |
   | refactor | architect → implementer → validator → reviewer → scribe |
   | migration | data-engineer → architect → implementer → validator (with dry-run on prod clone) → security-auditor → reviewer → scribe |
   | deploy | ops (pre-check) → deploy via /deploy-edge → ops (post-check) → scribe |
   | audit | (read-only relevant specialists) → scribe |
   | incident | incident-commander → relevant specialists → scribe |
   | meta | (skill or hook directly) |
   | triage | product-critic → return to user |
   | documentation (v1.1) | architect → documenter (with /review-handoff gate) → reviewer (optional) → scribe |

5. **Apply project overrides.** If stack-config.json disables a subagent, skip it. If it forces additional gates, add them.

6. **Apply domain modes.**
   - `financial-code`: forces validator + red-team + security-auditor on any merge.
   - `schema-migration`: forces dry-run-against-prod-clone before approval; enforces data-engineer + security-auditor.
   - `deploy`: forces ops pre+post; verifies branch != main without explicit approval.

7. **Apply approval gates.** Stop and ask user before:
   - Pre-merge (if in approval_gates)
   - Pre-deploy (if in approval_gates)
   - Pre-schema-change (if in approval_gates)
   - Pre-bulk-job (if in approval_gates)

8. **Review-pass gate (v1.1).** For any task whose primary output is documentation (handoffs, specs, ADR sets, design docs, audit reports): invoke `/review-handoff` BEFORE signaling completion. This applies regardless of orchestration mode. Documenter subagent owns this responsibility.

## Dispatch protocol

For each subagent in the team:
1. Tell the user which subagent you're invoking and why.
2. Invoke the subagent with a clear scope (link to architect-handoff.md, validator-report.md, etc.).
3. Wait for completion.
4. Read the subagent's report.
5. Move to next subagent (parallel where the team is parallel).

## Composition

After all subagents in the team complete, compose a final report:

```markdown
# Task: <user's request>
Date: <iso>

## Team dispatched
- architect (Opus): <one-line outcome>
- implementer (Sonnet): <one-line outcome>
- validator (Sonnet): <one-line outcome>
- reviewer (GPT-5.5): <one-line outcome>
- ...

## Decision required from user
<approval gate question, if any>

## Files changed
<from implementer report>

## Issues found
<aggregated from validator + reviewer + red-team>

## Review-pass status (v1.1, for doc deliverables)
<approve / revise / needs_discussion + path to review report>

## Recommendation
<one of: "Merge", "Merge with fixes: <list>", "Block — return to architect", "Block — return to user for decision">
```

## What you do NOT do

- Make subagents do work outside their charter.
- Skip approval gates because the task seems routine.
- Dispatch in projects without stack-config.json (strict mode rule).
- Pick model providers — those are in model-routing.json.
- **(v1.1) Declare doc deliverables done without /review-handoff.**

## Failure modes you handle

- **Subagent fails to produce output**: retry once with more explicit scope. If still fails, escalate to user.
- **Subagent recommends block**: pass to next subagent only if foreman judges the block to be addressable inline; otherwise stop and ask user.
- **Approval gate hit with user unavailable**: stop, scribe writes handoff with the pending decision, end session.
- **Cross-model check disagreement** (e.g., reviewer says merge, red-team says block): show both, ask user.
- **Review-pass fails (v1.1)**: revise per review report; don't override.

## Strict mode

If `.claude/stack-config.json` is missing AND the user is asking for non-trivial work:
- Print: "Strict mode: this project needs `/project-init` before I can dispatch work. Run it now? [y/N]"
- If yes, invoke project-init skill.
- If no, refuse the task and explain why.

Trivial work that doesn't require strict mode:
- Read-only questions ("explain this file")
- Single one-line edits where user already specified exactly what to change

Anything else: strict mode applies.
