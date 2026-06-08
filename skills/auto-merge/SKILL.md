---
name: auto-merge
description: Per-repo opt-in for GitHub auto-merge gated on a required `run-tests` status check. /auto-merge on <repo> enables allow_auto_merge, creates a per-repo ruleset requiring the run-tests check, and installs an auto-enable workflow so PRs merge themselves once tests pass. /auto-merge off <repo> reverts all three. /auto-merge status <repo> shows current state. Use when a repo's PRs should merge automatically on green CI instead of waiting for a manual merge.
---

# /auto-merge

Turn auto-merge on or off for a single repo. **Always per-repo and opt-in** — never org-wide. Auto-merge only fires when a *required* status check is pending, so this skill wires three things together:

1. `allow_auto_merge = true` on the repo (makes the button available).
2. A **per-repo ruleset** requiring the `run-tests` status check (gives auto-merge something to gate on).
3. An **auto-enable workflow** (`.github/workflows/auto-merge.yml`) that clicks "Enable auto-merge" on every PR, so merging is truly hands-off.

Without a required check, GitHub merges immediately and never offers auto-merge. Without `run-tests` actually running in the repo, enabling this would lock every PR forever — so step 1 of `on` is a hard precheck.

## Usage

```
/auto-merge status <repo>     # show current state (default action if arg omitted)
/auto-merge on <repo>         # enable auto-merge gated on run-tests
/auto-merge off <repo>        # revert ruleset + flag + workflow
```

`<repo>` may be `name` (assumes `CarboNet-Nano` org) or `owner/name`. Resolve to `OWNER/REPO` before any API call.

## Required check contract

The gate is the status check named **`run-tests`**. This is deliberate: auto-merge should wait on a real test job, not on CodeQL/Dependabot noise. A repo must produce a check named exactly `run-tests` (a workflow job named `run-tests`, or a workflow whose check context is `run-tests`) before auto-merge can be enabled.

## Steps

### 1. Resolve + status

- Resolve `<repo>` to `OWNER/REPO`.
- Read current state and print it:
  - `allow_auto_merge`: `gh api repos/OWNER/REPO --jq '.allow_auto_merge'`
  - per-repo ruleset present: `gh api repos/OWNER/REPO/rulesets --jq '[.[] | select(.name=="auto-merge-required-checks")] | length'`
  - workflow present: `gh api repos/OWNER/REPO/contents/.github/workflows/auto-merge.yml --jq '.path' 2>/dev/null`
  - whether the repo currently emits a `run-tests` check (see step 2 detection)
- For bare `/auto-merge` or `status`, stop here.

### 2. `on` — precheck `run-tests` exists (HARD GATE)

Detect whether the repo produces a `run-tests` check on its default branch HEAD:

```
DB=$(gh api repos/OWNER/REPO --jq '.default_branch')
SHA=$(gh api repos/OWNER/REPO/commits/$DB --jq '.sha')
gh api repos/OWNER/REPO/commits/$SHA/check-runs --jq '[.check_runs[].name] | index("run-tests")'
```

Also check for a workflow job named `run-tests`:

```
gh api repos/OWNER/REPO/contents/.github/workflows 2>/dev/null --jq '.[].name'
# then grep candidate workflow files for a job key or name "run-tests"
```

- If **neither** is found: **refuse**. Print:
  > Repo OWNER/REPO has no `run-tests` check. Enabling auto-merge now would block every PR permanently (the required check would never report). Add a test workflow whose job/check is named `run-tests`, then re-run `/auto-merge on`.
  Offer to scaffold a minimal `run-tests` workflow if the user wants — but do not enable auto-merge until the check exists.
- If found: continue.

### 3. `on` — enable the flag

```
gh api -X PATCH repos/OWNER/REPO -f allow_auto_merge=true -f allow_squash_merge=true -f delete_branch_on_merge=true
```

### 4. `on` — create/update the per-repo ruleset

Create a ruleset named `auto-merge-required-checks` on the default branch requiring the `run-tests` check. This sits beside the org-level `main-branch-protection` ruleset (rulesets compose; required checks from all matching rulesets apply).

```
DB=$(gh api repos/OWNER/REPO --jq '.default_branch')
gh api -X POST repos/OWNER/REPO/rulesets \
  -f name='auto-merge-required-checks' \
  -f target='branch' \
  -f enforcement='active' \
  -F 'conditions[ref_name][include][]=~DEFAULT_BRANCH' \
  -F 'rules[][type]=required_status_checks' \
  -F 'rules[][parameters][strict_required_status_checks_policy]=true' \
  -F 'rules[][parameters][required_status_checks][][context]=run-tests'
```

If a ruleset named `auto-merge-required-checks` already exists, PATCH it (`gh api -X PUT repos/OWNER/REPO/rulesets/<id> ...`) instead of creating a duplicate.

`~DEFAULT_BRANCH` is GitHub's literal token for "the repo's default branch" — pass it verbatim.

### 5. `on` — install the auto-enable workflow (via PR)

The workflow file lives at `.github/workflows/auto-merge.yml`. **It cannot be pushed to the default branch directly** — the org ruleset blocks direct pushes and requires a PR (and this sandbox cannot push to main / cannot `gh pr create`; see CLAUDE.md). So:

1. Copy the template from `<skill-dir>/templates/auto-merge.yml`.
2. Create a branch `chore/auto-merge-bootstrap`, commit the file.
3. Open a PR. **This first PR is merged manually** (chicken-and-egg: the workflow that auto-merges isn't on the default branch yet). Every PR after it auto-merges once `run-tests` passes.

If the sandbox cannot open the PR, **hand off**: print the file path, the branch name, and the exact `git`/`gh` commands for the user to run.

### 6. `off` — revert all three

- Delete the ruleset:
  ```
  ID=$(gh api repos/OWNER/REPO/rulesets --jq '.[] | select(.name=="auto-merge-required-checks") | .id')
  [ -n "$ID" ] && gh api -X DELETE repos/OWNER/REPO/rulesets/$ID
  ```
- Disable the flag: `gh api -X PATCH repos/OWNER/REPO -F allow_auto_merge=false`
- Remove the workflow: open a PR deleting `.github/workflows/auto-merge.yml` (same push constraint as step 5 — hand off if needed).
- Note: existing queued auto-merges on open PRs will cancel when the flag flips off.

### 7. Confirm

Print a 2-line summary: repo, what changed (flag / ruleset / workflow PR#), and the next manual step if a PR is awaiting manual merge.

## Gotchas

- **First PR merges manually.** The auto-enable workflow only takes effect once it's on the default branch. Bootstrap PR is the exception.
- **`run-tests` must be the exact check context.** Rulesets match by context string. CodeQL's `Analyze (python)` etc. are *not* `run-tests` and won't satisfy the gate.
- **Org ruleset still applies.** `main-branch-protection` (linear history, no force-push, PR required) composes with this one. Don't duplicate those rules here.
- **GITHUB_TOKEN PRs.** PRs opened by `GITHUB_TOKEN` don't trigger downstream workflows, so the auto-enable workflow uses `pull_request` events from real authors / Dependabot; that's the intended path.
