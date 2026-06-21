---
name: plan
description: Use BEFORE writing any code for non-trivial tasks (anything beyond a 1-line fix). Forces architect-style thinking — state assumptions, propose 2+ approaches with tradeoffs, define success criteria, get explicit user approval. Targets the Wrong Approach friction pattern (the #1 friction in May 2026 Insights). Output is a written plan in .claude/plans/<date>-<topic>.md. Wait for "proceed" before any implementation.
---

# /plan

Halt the impulse to code. Produce a plan, get approval, then code.

## When to use

- New feature
- Refactor touching >2 files
- Anything where you're tempted to start with "First, let me edit X..."
- Anything you're not 100% sure about
- Anything financial / auth / schema-related (always plan)

## When NOT to use

- 1-line bug fix in a single file
- Adding a console.log
- Formatting / typo
- User explicitly says "just do X"

## Steps

### 1. Restate the task

Read the user's request. Restate it in your own words. If the request is ambiguous, list interpretations and ask.

### 2. Surface assumptions

Write a list:
- What are you assuming about the existing code?
- What are you assuming about the user's intent?
- What are you assuming about constraints (perf, security, backward compatibility)?

### 3. Propose 2+ approaches

Each approach gets:
- One-line description
- Tradeoffs (pros AND cons; if you can't think of cons, you haven't thought hard enough)
- Estimated effort (S/M/L)
- Risks specific to this approach
- A pointer to the simpler approach if this one is the chosen one (so user knows what they're not getting)

### 4. Recommend one

Pick one. Justify in 2-3 sentences.

### 5. Define success criteria

In observable terms:
- What test will pass?
- What value will match?
- What screenshot will diff cleanly?
- What command will exit 0?

### 6. Write the plan

Save to `.claude/plans/<YYYY-MM-DD>-<short-slug>.md`:

```markdown
# Plan: <Title>

_Written: <date> by /plan_

## Task
<restated>

## Assumptions
- <...>
- <...>

## Approaches considered
### A: <name>
- Description
- Pros / Cons
- Effort: S/M/L
- Risk: <specific>

### B: <name>
- ...

## Recommended approach
**<A or B>** because <2-3 sentences>.

## Success criteria
- <observable>
- <observable>

## Implementation outline
1. <step>
2. <step>

## What I'm explicitly NOT doing
- <thing the user might expect but isn't in scope>
```

### 7. Stop and wait

Print the path to the plan + the recommended approach in one line. End with:
> "Type 'proceed' to implement, or tell me what to change."

Do NOT start implementing. Do NOT background it. Wait for the word.

### 8. On approval — clear the design-before-code gate (ADR-021)

When the user approves (says "proceed" or equivalent), write the approval marker
the design gate reads, so subsequent source edits are unblocked under ultracode:

```bash
mkdir -p ~/.claude/session-state
printf '{"active":true,"approved_at":"%s","plan":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "<plan-path>" \
  > ~/.claude/session-state/design-approved.json
```

This is a no-op when ultracode is off (the gate is inactive then). It is the
authoring path that satisfies `hooks/design-gate.sh` — `/plan` writes the marker,
the gate enforces it.
