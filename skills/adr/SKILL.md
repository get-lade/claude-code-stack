---
name: adr
description: Create or update an Architecture Decision Record. Captures decisions worth more than 5 minutes of thinking, in a format successors can read cold. Use when architect (or user) makes a non-trivial design decision. Output goes to docs/ADRs/<NNN>-<slug>.md.
---

# /adr

Document an architectural decision.

## Steps

### 1. Find next ADR number
- List `docs/ADRs/`. Find the highest 3-digit prefix. Increment.

### 2. Gather inputs
Ask user (or read from architect-handoff if invoked by architect):
- Title (short, 2-6 words)
- Context (what's the situation, what forces are at play)
- Decision (what you decided to do)
- Status (proposed | accepted | deprecated | superseded)
- Consequences (positive, negative, neutral — what happens because of this)
- Alternatives considered (what else you looked at and why you didn't pick it)

### 3. Generate slug
From title: lowercase, hyphenated, max 5 words.
Example: "Use Pipedream Connect for Slack delivery" → `use-pipedream-connect-slack`

### 4. Write file
`docs/ADRs/<NNN>-<slug>.md`:

```markdown
# ADR <NNN>: <title>

Date: <YYYY-MM-DD>
Status: <status>
Author: <user>

## Context

<paragraph: what's the situation, what forces, what constraints>

## Decision

<paragraph: what we decided, in active voice>

## Consequences

### Positive
- <bullet>
- <bullet>

### Negative
- <bullet>
- <bullet>

### Neutral
- <bullet>

## Alternatives considered

### <Alternative A>
<one paragraph: what it was, why we didn't pick it>

### <Alternative B>
<one paragraph>

## References
- <link to related ADR>
- <link to spec/doc>
- <link to discussion>
```

### 5. Commit
- `git add docs/ADRs/<NNN>-<slug>.md`
- `git commit -m "docs: add ADR <NNN> — <title>"`

### 6. Confirm
Print the path. Ask if any cross-references in other ADRs / docs need updating.
