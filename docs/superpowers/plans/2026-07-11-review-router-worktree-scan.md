# Plan: review-router — scan working tree in rr_classify_stakes

**Date:** 2026-07-11 · **Status:** approved (user-specified fix, verbatim from session prompt)

## Problem
`rr_classify_stakes` (scripts/lib/review-router.sh) classifies review stakes from
`git diff --name-only <merge-base>..<head>` only. Uncommitted and untracked files are
invisible, so high-stakes patterns (seed/migration/auth regexes) silently miss.
Observed: two SpecOps reviews (Plan-3 Phase 2 and Phase 3, 2026-07-11) classified
"routine" against an empty commit-range diff while high-stakes files sat uncommitted.

## Fix (user-prescribed)
In `rr_classify_stakes`, when `head` resolves to the current checkout (`HEAD`), also
scan working-tree paths from `git status --porcelain -uall` (modified + staged +
untracked, including files inside untracked dirs) against `RR_HIGH_STAKES_RE`.
Scan always — not only when the commit-range diff is empty — per the router's
fail-safe bias (false-high costs money; false-routine sends risky code to the cheap
tier). `git status` failure → fail-safe high, matching existing error handling.
Skip the working-tree scan when `head` ≠ current `HEAD` (unrelated state).
No `git add -N` (mutates the index — side effect).

## Files
- `scripts/lib/review-router.sh` (source repo: Antigravity/claude-code-stack)
- `~/.claude/scripts/lib/review-router.sh` (installed copy — sync after edit)
- `tests/test-review-router.sh` — new section 12 regression tests

## Success criteria
- Repro case: empty commit-range diff + untracked `migrations/*.sql` → **high**
- Routine untracked file + empty diff → **routine**
- Modified tracked high-stakes file → **high**
- Routine committed diff + untracked high-stakes file → **high** (always-scan)
- File inside untracked dir → **high** (`-uall`)
- `head` ≠ current checkout → working tree ignored
- Full existing suite still passes (bash + zsh portability section included)
