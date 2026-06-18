---
name: foreman
description: The orchestrator. Read at the start of any non-trivial task. Reads stack-config.json (refuses in strict mode if missing), classifies the task, determines the right subagent team and sequence, surfaces approval gates, composes results. The main Claude Code thread invokes the actual subagents based on this skill's guidance. In agent-teams orchestration mode, foreman-team-lead subagent takes over; this skill stays the source of truth for routing logic.
---

# /foreman

You orchestrate the team. You don't write code, design, test, or review yourself — you decide who does what, in what order, and you compose the results. The main thread (or, in agent-teams mode, the team-lead session) follows this skill's guidance to invoke subagents.

## Boot sequence (every invocation)

1. **Read `.claude/stack-config.json`.**
   - If missing AND project is Tier 2+: **STOP.** Tell user: "This project doesn't have stack-config.json. Run `/project-init` first."
   - If present, read tier, active_subagents, required_approvals, model_overrides, domain_mode, orchestration_mode.

2. **Check orchestration mode.**
   - `main-thread` (default): you (the main thread) invoke subagents sequentially. This skill guides which and in what order.
   - `agent-teams`: spawn an Agent Team via "create an agent team for <task>". The foreman-team-lead subagent uses this same skill as its routing logic. **Experimental** — parallelize read-only work (review, audit, adversarial investigation) only; keep all file-writing work sequential. See *Parallel-mode safety* below.
   - `hybrid` (recommended over pure agent-teams): the **critical write path runs main-thread** (architect → implementer → validator → reviewer); only **parallel review/audit/exploration** fans out to Agent Teams. Never parallelize implementers.
   - `dynamic-workflows` (Opus 4.8 research preview): for large **read-only fan-out** — codebase-wide audits, multi-angle research, bug hunts. Gated behind `/cost-gate` and **read-only by default**. See *Dynamic-workflows guardrails* below. Not for write-heavy work.

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

6. **Apply domain modes.** If `domain_mode` is set, read its entry in
   `~/.claude/config/domain-modes.json` and apply:
   - `required_subagents_for_change` — add these subagents to the team.
   - `approval_gates` — the domain-mode review checkpoints. Stop and ask the
     user at each checkpoint as it is reached (e.g. `after_architect`,
     `after_validator`, `before_merge`, `after_data_engineer`, `before_apply`,
     `before_deploy`, `after_deploy_verify`, `after_designer_inventory`).
   - `required_skills`, `validator_must_cross_check`, `require_adr`,
     `require_rollback_plan` — enforce where present.

   Quick reference (authoritative source is `domain-modes.json`):
   - `financial-code`: validator + red-team + security-auditor on any merge;
     validator cross-checks real values.
   - `schema-migration`: dry-run-against-prod-clone before approval;
     architect + data-engineer + reviewer + ops; ADR + rollback plan required.
   - `deploy`: ops pre+post; verifies branch != main without explicit approval.
   - `ui-design`: designer inventory before build; `/design-match` before merge.
   - `data-operation`: `/cost-gate` + `/coverage-snapshot` mandatory.

7. **Apply tier approval gates.** The `required_approvals` field in
   stack-config.json lists project-specific tier gates (see
   `~/.claude/config/approval-gates.json`). Stop and ask the user before:
   - Pre-merge (if `pre-merge` in `required_approvals`)
   - Pre-deploy (if `pre-deploy` in `required_approvals`)
   - Pre-schema-change (if `pre-schema-change` in `required_approvals`)
   - Pre-bulk-job (if `pre-bulk-job` in `required_approvals`)

   An empty `required_approvals` means "use tier defaults" — the gates in
   `approval-gates.json` are `default_enabled_at_tier: 2`, so at Tier 2+ treat
   the relevant gates as on. The domain-mode checkpoints from step 6 apply
   independently of this field.

8. **Review-pass gate (v1.1).** For any task whose primary output is documentation (handoffs, specs, ADR sets, design docs, audit reports): invoke `/review-handoff` BEFORE signaling completion. This applies regardless of orchestration mode. Documenter subagent owns this responsibility.

## Dispatch protocol

For each subagent in the team:
1. Tell the user which subagent you're invoking and why.
2. Invoke the subagent with a clear scope (link to architect-handoff.md, validator-report.md, etc.).
3. Wait for completion.
4. Read the subagent's report.
5. Move to next subagent (parallel where the team is parallel).

### Parallel-mode safety (agent-teams / hybrid / dynamic-workflows)

Anthropic's docs warn: **two teammates editing the same file leads to overwrites.** When any work runs in parallel, enforce these rules. (Note: a Workflow whose `agent()` calls pass `agentType: <roster-name>` is a sanctioned parallel route — it keeps the named roles and their cross-model wiring in play.)

1. **No two parallel agents may write the same file.** Before dispatching a parallel batch, partition the work by file/path ownership and state each agent's owned paths in its scope. If two agents would touch the same file, serialize them (run on main-thread) instead.
2. **Only read-only roles parallelize freely.** reviewer, red-team, security-auditor, accessibility-auditor, validator (read-only checks), and audit-task specialists can run concurrently — they don't write source.
3. **Writers stay sequential.** implementer, data-engineer, and any subagent that edits files run one-at-a-time on the critical path, even in `agent-teams`/`hybrid` mode. Parallelism buys you faster *review and investigation*, not faster *editing*.
4. **On overlap detected mid-run** (two teammates report touching the same file): stop, surface to user, prefer the main-thread result, discard/redo the conflicting one.

### Dynamic-workflows guardrails

`dynamic-workflows` mode uses Opus 4.8's research-preview workflow runtime (fans out up to 16 concurrent / 1,000 total subagents). Its biggest risk is **uncapped token spend** (launch-window incident: ~1.7M tokens burned in a runaway loop, no built-in spend cap, no refunds), and its subagents **auto-approve file edits regardless of session permission mode**. Treat it as experimental and only enter this mode when ALL of these hold:

1. **Read-only by default.** Use it for audits, research sweeps, and bug hunts — not write-heavy tasks. If a workflow must write, it stays out of this mode (route to main-thread).
2. **`/cost-gate` first, every time.** Before launching a workflow, run `/cost-gate` on a scoped sample and get the explicit "proceed". A workflow launch counts as a bulk job — the `pre-bulk-job` gate applies.
3. **Never headless without a sandbox.** Do not run dynamic workflows under `claude -p` / Agent SDK on a writable tree (no interactive edit confirmation there).
4. **Kill-switch known.** If anything looks runaway, stop the run; org-level disable is `disableWorkflows` in settings / `CLAUDE_CODE_DISABLE_WORKFLOWS=1`.
5. **Honor domain modes.** `financial-code`, `schema-migration`, and `sensitivity: confidential` require explicit user override (log it, same as agent-teams).
6. **Use the roster, not generic agents.** A Workflow's default `agent()` spawns a *generic* worker — it does NOT carry the named roster's cross-model wiring (reviewer/security-auditor → Codex, red-team/architecture-critic → Gemini). When a workflow does review/audit/security/architecture work, pass `agentType: '<roster-name>'` to each `agent()` call so the real role (and its non-Claude pass) runs. A workflow is never a reason to drop cross-family review. Write-heavy workflows that name no roster `agentType` trip the `workflow-roster-check` PreToolUse hook: under `workflow_roster:"warn"` (default) it emits an advisory system-reminder (non-blocking); under `workflow_roster:"block"` the run is denied; `workflow_roster:"off"` disables warn/deny but the run is still logged. The `agentType` convention applies across `agent-teams`, `hybrid`, and `dynamic-workflows` — any `agent()` call doing review/audit/security/architecture work should pass a roster name. A Workflow whose `agent()` calls pass `agentType: <roster-name>` is the sanctioned multi-agent write path.

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
- **Capability reported "unavailable" in a cloud session**: before relaying any "X is unavailable" — especially the critic gate (reviewer / security-auditor / product-critic / red-team / architecture-critic / historian) — verify it yourself. A missing CLI is **not** a missing capability. Check the environment: `printenv OPENAI_API_KEY` / `printenv GEMINI_API_KEY` and `command -v codex` / `command -v gemini` (PATH). Confirm the agent actually walked its CLI → key → API/ad-hoc-install fallback ladder. "CLI missing" ≠ "capability missing." Only surface "unavailable" once **both** the binary and its key (the API/install fallback) are confirmed absent. In cloud, keys live in the environment's variables — that is the intended mechanism.
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
