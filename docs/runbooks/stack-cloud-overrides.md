# Runbook: subagent model pins in 1M-context sessions

**Status:** F1 fixed + spawn-verified 2026-06-04 (fresh 1M boot, no `[1m]` error).
F2 root-caused + FIXED 2026-06-04 — **stack bug, not upstream**: `agents/*.md`
declared `tools:` as a lowercase YAML list, but Claude Code tool names are
PascalCase, so the toolset resolved empty and agents emitted tool calls as text.
Fix: rewrite every `tools:` block as a CSV of PascalCase names. Verified PASS on
a fresh 1M boot (`designer`, `tool_uses: 1`, accurate facts).

## Symptom

Every custom subagent in the stack fails to run when the **parent** Claude Code
session is in 1M-context mode (model id `claude-opus-4-8[1m]`):

```
There's an issue with the selected model (anthropic/claude-opus-4-8[1m]).
It may not exist or you may not have access to it.
```

Spawn fails immediately, 0 tokens. Built-in `general-purpose` (no model pin)
works fine in the same session.

## Two faults

### F1 — model-pin × 1M suffix propagation  (FIXED HERE)

**Root cause.** Agents pinned a fully-qualified model id
(`model: anthropic/claude-opus-4-8`). When the parent session runs the 1M
variant, the harness appends the parent's `[1m]` context suffix to the pinned
id → `anthropic/claude-opus-4-8[1m]`, which is not a valid subagent model id.
This affects **every** anthropic-pinned agent (sonnet/haiku too:
`...sonnet-4-6[1m]`, `...haiku-4-5[1m]` are equally invalid), not just opus.
The installer is innocent — `scripts/install.sh` copies `agents/*.md` verbatim;
the suffix is appended at runtime by the harness.

**Fix.** Replace fully-qualified anthropic pins with Claude-Code-native **bare
aliases** in `agents/*.md`:

| Old (broken in 1M)                 | New          |
|------------------------------------|--------------|
| `anthropic/claude-opus-4-8`        | `opus`       |
| `anthropic/claude-sonnet-4-6`      | `sonnet`     |
| `anthropic/claude-haiku-4-5-20251001` | `haiku`   |

Applies to both `model:` and `escalation_model:`. `local-ops` (`ollama/...`) is
left untouched — it is not an anthropic id and not part of this bug. Bare
aliases preserve the model-tiering intent (opus for heavy reasoning, sonnet for
mid, haiku for cheap) and are the form the harness resolves natively.

**Fallback if bare aliases STILL break in a fresh 1M session.** If verification
(below) shows `opus`/`sonnet`/`haiku` also get a `[1m]` suffix appended, drop
the pins entirely so every agent inherits the parent the way `general-purpose`
does (which is known to work). Either delete the `model:`/`escalation_model:`
lines or set them to `inherit`. Tradeoff: loses tiering — cheaper agents run on
the parent's (opus) model.

### F2 — dead tool bridge for custom agents  (STACK BUG — FIXED 2026-06-04)

**Root cause:** `tools:` was a lowercase YAML list (`- read`, `- web_search`).
Claude Code tool names are PascalCase (`Read`, `WebSearch`); lowercase matched
nothing → empty toolset → the agent could not emit real `tool_use` and wrote
`<invoke name="Read">…` as literal text, hallucinating results. **Fix:** every
`tools:` block rewritten as CSV PascalCase (e.g. `tools: Read, Grep, Glob, Bash`).
Applied to all 14 agents that declared a `tools:` list; synced to `~/.claude`.

**Confirm run 2026-06-04 (fresh 1M boot, parent `claude-opus-4-8[1m]`).**
`designer` (fixed first, as the test vector) → `tool_uses: 1`, line 1 `---`,
`model: opus`, line count accurate. PASS → hypothesis confirmed, rolled out to
the remaining 13.

---

_Original (pre-fix) investigation, kept for provenance:_


Even with a valid model (e.g. forcing opus/sonnet via the Agent tool's `model:`
override to get past the F1 spawn error), pinned/custom agents **emit tool calls
as literal text** (`<invoke name="Read">…`) and **hallucinate results** —
`tool_uses: 0`. Built-in `general-purpose` calls tools for real in the same
session.

This points at a Claude Code harness bug in how custom agent definitions wire
the tool channel, not a stack bug. If F1 is fixed but F2 persists:

1. Capture the exact subagent transcript (the literal `<invoke …>` text +
   `tool_uses: 0`).
2. File upstream to Anthropic with the transcript and the parent model id.
3. Note the date and Anthropic ticket here.

**Verification run 2026-06-04 (fresh 1M boot, parent `claude-opus-4-8[1m]`).**
Dispatched `designer` (frontmatter pin `model: opus`, NO Agent-tool override) to
Read `agents/designer.md` and report line 1 / line count / `model:` value.
- Spawn: **OK** — no `[1m]` model error → F1 fix confirmed live.
- Tool channel: **DEAD** — `tool_uses: 0`; the Read call was emitted as literal
  text `<invoke name="Read">…`.
- Result: **hallucinated** — agent reported `14` lines + `model: sonnet` and a
  fabricated in-file `<system-reminder>` block. Ground truth (Bash, same session):
  line 1 `---`, **105** lines, `model: opus` (line 3), `escalation_model: opus`
  (line 4). No `tools:` line at the reported position; no system-reminder in file.
- Verdict: **F2** (upstream harness bug). Stack `agents/*.md` left unchanged.
- Anthropic ticket: _pending — file with this transcript + parent model id._

## Verification (MUST be a FRESH 1M session)

Agent definitions are cached at session start. A **resumed** session will NOT
pick up edits, and the `[1m]` bug only reproduces on a clean 1M-context boot.

1. Make the change in `agents/*.md` (done).
2. Install to `~/.claude` (this repo syncs all installed agents; or
   `scripts/install.sh --tier=N --mode=merge`).
3. **Fully quit and relaunch** Claude Code — new session, 1M mode — in any
   consumer repo.
4. Dispatch `designer` with a real Read smoke test. Confirm:
   - spawn succeeds (no model error),
   - `tool_uses >= 1`,
   - returned file content is **accurate** — verify line 1 and line count
     against the actual file (not hallucinated).
   Only then is F1 fixed.
5. If tool calls are still emitted as text → F2 (upstream). See above.
