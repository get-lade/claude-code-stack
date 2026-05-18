# Privacy

## What leaves your machine

Stock Claude Code: every API call to Anthropic includes the conversation context.

Stack additions:
- API calls to OpenAI (Codex, GPT-5) include context for those subagents.
- API calls to Google (Gemini) include context for those subagents.
- Supabase writes for cost_log and subagent_runs include: subagent name, model, token counts, cost, wall time, task summary, outcome. **Does NOT include**: code contents, secrets, personally identifiable user data.

## What stays on your machine

- Ollama inference (Tier 5).
- File system operations.
- Git operations.
- Keychain operations.

## Handoff archive privacy

`docs/handoffs/<date>.md` are committed to git. If pushed to GitHub:
- Public repo: handoffs are public. Strip secrets before /handoff writes the file.
- Private repo: handoffs are private to repo collaborators.

The scribe subagent is responsible for never including secrets in handoffs. Reviewer should also flag any leaked secrets before merge.

## Publishing a fork of this repo

This repo ships parameterized — no live secrets and no personal identifiers.
If you fork it and customize it for your own work, scrub your additions
before publishing the fork. The full surface to check:

- **Secrets** — confirm no API keys, tokens, or connection strings landed in
  any tracked file. Keep secret handling by-reference (Keychain item names).
- **Identifiers** — replace your Supabase project ref/URL with placeholders;
  remove machine-specific absolute paths from examples.
- **Identity & business detail** — remove personal/company names, private
  repo names, vendor names tied to specific repos, and any deployed-component
  inventory from docs, ADRs, runbooks, and agent prompts.
- **Build exhaust** — delete install logs and personal handoff docs; they are
  not stack documentation.
- **History** — rewrite git history (`git filter-repo` or similar). Deleting
  a file in a new commit does not remove it from earlier commits.
- Audit every file under `docs/` for accidental leaks before flipping public.

## User data in subagent_runs

The `task_summary` and `input_summary` fields could leak sensitive context. The librarian subagent reviews these monthly and proposes scrubbing if needed.
