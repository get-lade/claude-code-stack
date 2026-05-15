# Routing Rule

When you notice a friction pattern in Claude Code's behavior, this is how you decide what kind of fix it deserves.

## The rule

Ask these three questions in order. First "yes" wins. If none get a yes, the friction isn't worth a fix yet.

### 1. Can a shell command detect or prevent it deterministically? → Hook

**Test:** The question has a yes/no answer that a script can decide.

**Examples:**
- "Did the typecheck pass?" → `tsc --noEmit` after edit
- "Are we on main?" → `git branch --show-current` before deploy
- "Do we have a coverage snapshot before this bulk run?" → file check before bulk script

**Where it lives:** `~/.claude/settings.json` (global) or `<project>/.claude/settings.json` (per-project), with the actual script in `hooks/` directory.

### 2. Is it a repeatable multi-step workflow you'd otherwise re-explain? → Skill

**Test:** Would you write the same paragraph of instructions more than twice?

**Examples:**
- Handoff at end of session → `/handoff`
- Cost projection before bulk LLM job → `/cost-gate`
- Design parity check against prototype → `/design-match`

**Where it lives:** `~/.claude/skills/<name>/SKILL.md` (global) or `<project>/.claude/skills/<name>/SKILL.md` (per-project).

### 3. Is it a fact you'd re-explain that the AI can't read from code? → CLAUDE.md line

**Test:** Past-failure warning OR environmental constraint the AI can't discover by reading disk.

**Examples:**
- "Sandbox can't push to main; hand off instead." → global CLAUDE.md
- "Re-enrichment must MERGE, never overwrite." → data-pipeline-repo CLAUDE.md
- "Never use `supabase functions deploy` — path mismatch." → per-repo CLAUDE.md

**Where it lives:** `~/.claude/CLAUDE.md` (global) or `<project>/CLAUDE.md` (per-project).

### 4. Anything else → cut it

It's noise that competes with signal. Don't add speculative rules. Don't pre-document failures that haven't happened. Don't paste in best-practices from blog posts. Wait for evidence.

## Corollaries

### Hooks and CLAUDE.md don't duplicate

If `tsc` runs as a hook, delete "always run tsc" from CLAUDE.md. The hook is the source of truth. The CLAUDE.md line is dilution.

### Skill descriptions trigger invocation

A skill's `description:` frontmatter field is what Claude reads to decide if the skill applies. It's not a summary — it's a set of trigger conditions. "Use when X" or "Run before Y" is the right voice.

### Global vs per-repo split

- **Global** = behavioral + universally true. Applies to every repo you'd ever work on.
- **Per-repo** = operationally unique to *this* repo. Past failures, secret locations, deploy commands, infrastructure quirks.

Test for "should this be global": *would this apply in a brand-new repo I open tomorrow?* Yes → global. No → per-repo.

### When in doubt, cut

The default for any new line/skill/hook is: don't add it. Context budget is real. Skill proliferation is real. Each addition has a maintenance cost. Make additions earn their place.
