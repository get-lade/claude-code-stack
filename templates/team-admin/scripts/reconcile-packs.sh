#!/usr/bin/env bash
# Claude Code Stack — org reconciler, Job B: tenant pack distribution
# (ADR-034 §5). Sibling to reconcile.sh (Job A / cloud bootstrap).
#
# When a tenant's pack repo bumps `pack_version`, this opens one pull request
# per consuming app repo re-vendoring the pack's `standards/` files into the
# repo (the same layout /project-init lands via vendor_tenant_standards).
# Idempotent: a `.claude/.pack-version` stamp per app repo means a repo already
# on the current pack version is skipped, so no-op runs open no PRs.
#
# Scope = repos in $org tagged with GitHub topic $pack_topic. Delivery = pull
# request per repo. Runs from the same team-admin Action as Job A.
#
# MVP scope is the `standards/` map only (per handoff #5). The pack CLAUDE
# fragment overlay is intentionally NOT re-applied here yet — that is a
# separate follow-up; keeping this job to one responsibility.
#
# SAFETY: refuses to open PRs unless config `enabled: true`. Until then it
# forces dry-run (lists intended changes, writes nothing). Manual runs default
# to dry-run too. No-op (exit 0) when `pack_repo` is unset — Job B is opt-in.
#
# Env:
#   GH_TOKEN    (required)  PAT with, across in-scope repos: Contents: write,
#                           Pull requests: write, plus repo read/metadata.
#   DRY_RUN     true|false  Overridden to true whenever enabled != true.
#   CONFIG      path to config.yml (default: ./config.yml)
#   STACK_REPO  public stack URL (default: github.com/bschonbrun/claude-code-stack)

set -euo pipefail

CONFIG="${CONFIG:-config.yml}"
STACK_REPO="${STACK_REPO:-https://github.com/bschonbrun/claude-code-stack}"
DRY_RUN="${DRY_RUN:-false}"

log() { printf '[reconcile-packs] %s\n' "$*"; }
cfg() { sed -nE "s/^$1:[[:space:]]*//p" "$CONFIG" | head -n1 | tr -d '\r'; }

command -v jq >/dev/null 2>&1 || { log "ERROR: jq is required"; exit 1; }
[ -f "$CONFIG" ] || { log "ERROR: $CONFIG not found"; exit 1; }

ENABLED="$(cfg enabled)"
ORG="$(cfg org)"
PACK_REPO="$(cfg pack_repo)"
PACK_TOPIC="$(cfg pack_topic)"
BRANCH="$(cfg pack_branch)"; BRANCH="${BRANCH:-chore/claude-stack-pack-update}"
EXCLUDE="$(cfg exclude)"

# Job B is opt-in: no pack_repo configured → nothing to distribute.
[ -z "$PACK_REPO" ] && { log "no 'pack_repo' in $CONFIG → Job B not configured, nothing to do."; exit 0; }

[ -z "${GH_TOKEN:-}" ] && { log "ERROR: GH_TOKEN not set (add the STACK_RECONCILE_TOKEN secret)."; exit 1; }
[ -z "$ORG" ] && { log "ERROR: 'org' not set in $CONFIG"; exit 1; }
[ -z "$PACK_TOPIC" ] && { log "ERROR: 'pack_topic' not set in $CONFIG"; exit 1; }

# Safety gate.
if [ "$ENABLED" != "true" ]; then
  log "config 'enabled' != true → forcing DRY_RUN (no PRs will be opened)."
  DRY_RUN=true
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# The pack repo carries tenant.json (pack_version + standards map). Clone it and
# the stack (for vendor_tenant_standards) shallow.
if ! git clone --depth 1 "$PACK_REPO" "$WORKDIR/pack" >/dev/null 2>&1; then
  log "ERROR: could not clone pack repo $PACK_REPO"; exit 1
fi
if ! git clone --depth 1 "$STACK_REPO" "$WORKDIR/stack" >/dev/null 2>&1; then
  log "ERROR: could not clone $STACK_REPO"; exit 1
fi
# shellcheck source=/dev/null
source "$WORKDIR/stack/scripts/lib/project-pack-vendor.sh"

PACK_DIR="$WORKDIR/pack"
[ -f "$PACK_DIR/tenant.json" ] || { log "ERROR: pack repo has no tenant.json at root"; exit 1; }
TENANT_ID="$(jq -r '.tenant_id // empty' "$PACK_DIR/tenant.json" 2>/dev/null || true)"
PACK_VERSION="$(jq -r '.pack_version // empty' "$PACK_DIR/tenant.json" 2>/dev/null || true)"
[ -n "$TENANT_ID" ]   || { log "ERROR: tenant.json missing tenant_id"; exit 1; }
[ -n "$PACK_VERSION" ] || { log "ERROR: tenant.json missing pack_version"; exit 1; }

# No standards map → nothing for Job B to vendor.
if ! jq -e '(.standards // {}) | length > 0' "$PACK_DIR/tenant.json" >/dev/null 2>&1; then
  log "pack $TENANT_ID has no standards map → nothing to distribute."; exit 0
fi

log "tenant=$TENANT_ID pack_version=$PACK_VERSION org=$ORG topic=$PACK_TOPIC dry_run=$DRY_RUN"

# In-scope repos: tagged with $pack_topic, not archived. (bash 3.2 — no mapfile.)
REPOS=()
while IFS= read -r _r; do
  [ -n "$_r" ] && REPOS+=("$_r")
done < <(gh search repos --owner "$ORG" --topic "$PACK_TOPIC" \
  --limit 1000 --json name --jq '.[].name' 2>/dev/null | sort -u)
log "${#REPOS[@]} repo(s) tagged '$PACK_TOPIC'"

is_excluded() { case ",${EXCLUDE// /}," in *",$1,"*) return 0 ;; esac; return 1; }

changed=0 skipped=0 failed=0
[ "${#REPOS[@]}" -eq 0 ] && { log "no repos in scope; nothing to do."; exit 0; }
for repo in "${REPOS[@]}"; do
  [ -z "$repo" ] && continue
  if is_excluded "$repo"; then log "skip $repo (excluded)"; skipped=$((skipped + 1)); continue; fi

  remote_ver="$(gh api "repos/$ORG/$repo/contents/.claude/.pack-version" \
    --jq '.content' 2>/dev/null | base64 --decode 2>/dev/null | tr -d '[:space:]' || true)"
  if [ "$remote_ver" = "$PACK_VERSION" ]; then
    log "ok $repo (current: $PACK_VERSION)"; skipped=$((skipped + 1)); continue
  fi

  log "needs pack update: $repo (has '${remote_ver:-none}', want $PACK_VERSION)"
  if [ "$DRY_RUN" = "true" ]; then changed=$((changed + 1)); continue; fi

  work="$WORKDIR/work-$repo"
  if ! git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/$ORG/$repo.git" "$work" >/dev/null 2>&1; then
    log "WARN: clone failed $repo"; failed=$((failed + 1)); continue
  fi
  if ( cd "$work"
    default="$(git rev-parse --abbrev-ref HEAD)"
    git checkout -B "$BRANCH" >/dev/null 2>&1
    # Re-vendor the pack's standards/ into the app repo (idempotent overwrite of
    # the vendored files; containment-checked inside vendor_tenant_standards).
    vendor_tenant_standards "$PACK_DIR" "$work" || exit 4
    mkdir -p .claude
    printf '%s\n' "$PACK_VERSION" > .claude/.pack-version
    git add standards .claude/.pack-version
    git -c user.name='claude-stack-bot' -c user.email='claude-stack-bot@users.noreply.github.com' \
      commit -q -m "chore: update $TENANT_ID standards to pack $PACK_VERSION" || exit 3
    git push -f origin "$BRANCH" >/dev/null 2>&1
    gh pr create --repo "$ORG/$repo" --base "$default" --head "$BRANCH" \
      --title "Update $TENANT_ID standards to pack $PACK_VERSION" \
      --body "Automated by the Claude Code Stack org reconciler (Job B, ADR-034 §5). Re-vendors the \`$TENANT_ID\` pack's \`standards/\` at pack version \`$PACK_VERSION\`." \
      >/dev/null 2>&1 || true
  ); then
    log "PR ready: $repo"; changed=$((changed + 1))
  else
    rc=$?
    if [ "$rc" = "3" ]; then log "ok $repo (no diff)"; skipped=$((skipped + 1))
    else log "WARN: failed $repo (rc=$rc)"; failed=$((failed + 1)); fi
  fi
done

log "done. changed=$changed skipped=$skipped failed=$failed dry_run=$DRY_RUN"
[ "$failed" -gt 0 ] && exit 1 || exit 0
