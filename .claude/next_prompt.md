# Next-session handoff

_Written: 2026-07-23 06:01 PT_

## Branch & state
- Branch: `main` (worktree: N/A)
- Uncommitted: clean
- Behind/ahead of origin: **up to date** — all three features + this handoff are
  pushed to `origin/main` (commit `e1bf0b2`). CI on origin should be green.

## What shipped this session
All three M3 next-steps built, cross-family reviewed to clear, and **merged into
local `main`** (order #2 → #3 → #1). Full suite: **25/25 test files pass** on the
merged tree; zero real Cloudflare IDs tracked.
- `2781e0a` — Merge #2: `/publish` deploy path + secret-binder hardening (ADR-035)
- `884300d` — Merge #3: mirror-sync MVP — snapshot core to tenant mirror (ADR-036)
- `15b9f5f` — Merge #1: `/project-init` tenant-pack aware + CF-ID doc redaction (ADR-034)
- Feature commits: `68129ae` (#2), `13a38b6` (#3), `81fbb9a`+`1dd10fc` (#1)

Detail:
- **#1** — `scripts/lib/project-pack-vendor.sh` + 28-case test; `/project-init`
  stamps `tenant_id`, applies pack CLAUDE fragment, vendors `standards/`. Hardened
  over 9 rounds of GPT-5.5 review (symlink escapes, rollback data-loss, jq
  newline-fanout, canonical-dest dedup, a re-vendor regression, a skipped-sibling
  containment gap). bash-3.2 safe.
- **#2** — `scripts/publish.sh` + `/publish` skill (bind → `wrangler deploy` in
  one bash process, fail-hard), hardened `secret-binder.sh`, Pipedream contract
  doc. Fixed a `-e=`/`-c=` glued-arg bypass.
- **#3** — deny-by-default `.gitattributes`, `mirror-sync.sh` + `mirror-scrub.sh`,
  GitHub App workflow. Gemini caught a real IP leak (ADR-035 CF IDs); closed.

## What's blocked & why
- Nothing blocked. All merged + pushed to `origin/main`.

## Exact next steps
1. **Confirm CI green** on `origin/main` (`gh run list` / Actions tab).
2. **Clean up merged worktrees:**
   `git worktree remove .claude/worktrees/agent-a07a39dde750d63e8` and
   `git worktree remove .claude/worktrees/agent-a7b0389eab6823c29`
   (both branches are merged; safe to delete the branches too).
3. **Provision the lade GitHub App** (repo-scoped to the mirror, Contents:write)
   before enabling `.github/workflows/mirror-sync.yml` — the workflow references
   `vars.LADE_MIRROR_APP_ID` + `secrets.LADE_MIRROR_APP_PRIVATE_KEY` and stays
   inert until they exist.
4. **Wire secret-binder into the real deploy** — the Pipedream half is only a
   contract doc (`docs/plans/2026-07-22-pipedream-wrangler-secret-binding-contract.md`);
   implement it in the engine repo (`Architect-for-Claude-Code`).
5. **#3 Job B** (pack-version → app-repo `standards/` PRs) — now unblocked since
   #1's vendoring layout is on main. Engine-side, deferred.
6. Optional low-pri hardening: give `apply_project_claude_fragment` a `repo_root`
   param + `_ppv_dest_safe` check (defense-in-depth; no real bypass today).

## Gotchas
- Stack helper libs are **bash**; sourcing under the zsh session shell fails
  (misreports as `curl not found`). `/publish` + project-init pack steps run via
  `bash -c` — keep it.
- Real CF account/store IDs are scrubbed from the **working tree** but remain in
  **git history** (public repo). Owner's call: doesn't matter, no history rewrite.
- The mirror ships only the deny-by-default allowlist; adding a NEW top-level dir
  to the installable core means updating BOTH `.gitattributes` (`/dir` + `/dir/**`)
  AND `mirror-scrub.sh`'s allowlist, or install-completeness / scrub breaks.

## Cross-repo references
- Engine repo `Architect-for-Claude-Code` — owns the Pipedream Wrangler deploy
  step (#2 contract doc) and #3's Job B reconciler.
- CarboNet pack: `CarboNet-Nano/carbonet-vibe-coding-standards`.

## Team this session
- Used: architect ×2 (scoped #2/#3), reviewer/GPT-5.5 ×9 rounds (#1),
  security-auditor/GPT-5.5 (#2), architecture-critic/Gemini (#3 — caught IP leak),
  implementer ×2 (worktrees #2/#3). (Dispatch log under-recorded this session —
  counts from session memory, not `subagent-runs.jsonl`.)
- No misses — every credential/IP/high-stakes diff got its cross-family pass (ADR-025).
