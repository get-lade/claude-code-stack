#!/usr/bin/env bash
# Tenant-pack install logic (M3, ADR-034). Sourced by install.sh.
# Requires config-merger.sh (merge_json_pack_wins) and pack-lint.sh
# (lint_pack_deltas) to be sourced alongside.

# Splits an optional @ref off a git pack spec: echoes "<url>|<ref>".
# The ref is split from the RIGHT, only when the suffix contains no "/" and,
# for scp-style git@host:org/repo.git@v1, at least one "@" remains in the URL
# part. Ref must match ^[A-Za-z0-9._-]+$. Do not "simplify" the right-split
# rule — it is what keeps git@host:org/repo.git (no ref) intact.
parse_pack_ref() {
  local spec="$1"
  local url="$spec" ref=""
  local candidate_ref="${spec##*@}"
  local candidate_url="${spec%@*}"
  if [[ "$spec" == *"@"* ]] \
    && [[ "$candidate_ref" != */* ]] \
    && [[ "$candidate_ref" =~ ^[A-Za-z0-9._-]+$ ]] \
    && { [[ "$candidate_url" != git@* ]] || [[ "$candidate_url" == *"@"* ]]; }; then
    url="$candidate_url"
    ref="$candidate_ref"
  fi
  echo "$url|$ref"
}

# Parses a --pack spec into "<local_dir>|<source>|<ref>" on stdout.
# Existing directory -> local path mode (no clone). Otherwise git mode:
# @ref is split from the RIGHT, only when the suffix contains no "/" and,
# for scp-style git@host:org/repo.git@v1, at least one "@" remains in the
# URL part. Clone lands in a mktemp dir the caller owns.
resolve_pack_source() {
  local spec="$1"

  if [[ -d "$spec" ]]; then
    echo "$spec|$spec|"
    return 0
  fi

  local url ref
  IFS='|' read -r url ref <<< "$(parse_pack_ref "$spec")"

  local clone_dir
  clone_dir="$(mktemp -d)"

  local -a git_args=(clone --depth 1)
  [[ -n "$ref" ]] && git_args+=(--branch "$ref")

  local token="${CLAUDE_STACK_PACK_TOKEN:-${CLAUDE_STACK_REPO_TOKEN:-}}"
  if [[ -n "$token" && "$url" == https://* ]]; then
    # Token via extraheader, never interpolated into a logged URL (ADR-034 §1).
    local b64
    b64="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
    git_args=(-c "http.extraheader=Authorization: basic $b64" "${git_args[@]}")
  fi

  if ! GIT_TERMINAL_PROMPT=0 git "${git_args[@]}" "$url" "$clone_dir" >/dev/null 2>&1; then
    rm -rf "$clone_dir"
    echo "  [pack-fail] Could not clone $url${ref:+ @$ref}" >&2
    return 1
  fi

  echo "$clone_dir|$url|$ref"
}

# Copies a resolved pack into its durable home ~/.claude/packs/<tenant_id>/
# (.git/ retained for future ref updates). tenant_id is read and validated
# BEFORE landing — that is what makes the landing path trustworthy.
# Echoes the landing dir.
land_pack() {
  local src_dir="$1"
  local claude_dir="$2"

  local tenant_id
  tenant_id="$(jq -r '.tenant_id // empty' "$src_dir/tenant.json" 2>/dev/null)" || tenant_id=""
  if [[ ! "$tenant_id" =~ ^[a-z][a-z0-9-]{1,62}$ ]]; then
    echo "  [pack-fail] tenant.json missing or tenant_id invalid" >&2
    return 1
  fi

  local landing="$claude_dir/packs/$tenant_id"
  mkdir -p "$landing"
  rsync -a --delete "$src_dir/" "$landing/"
  echo "$landing"
}

# install_pack <pack_dir> <claude_dir> <core_repo_root>
# Phase 0 validates (fail closed, zero writes), Phase 1 composes the pack
# over the installed core with pack-wins semantics (ADR-034 §2).
# Optional env for the success stamp: PACK_SOURCE, PACK_REF.
install_pack() {
  local pack_dir="$1"
  local claude_dir="$2"
  local core_repo_root="$3"

  # ---- Phase 0: validate, then apply (zero writes on failure) ----
  if ! jq -e . "$pack_dir/tenant.json" >/dev/null 2>&1; then
    echo "  [pack-fail] tenant.json missing or unparseable" >&2
    return 1
  fi

  # Required fields + patterns (jq checks; the JSON-schema is normative docs +
  # pack-repo CI, not a runtime dependency — Working Principle 8).
  if ! jq -e '
      (.tenant_id | type == "string" and test("^[a-z][a-z0-9-]{1,62}$")) and
      (.pack_version | type == "string" and test("^\\d+\\.\\d+\\.\\d+$")) and
      (.github.org | type == "string" and length > 0) and
      ((.secrets // []) | all(type == "string" and test("^[A-Z][A-Z0-9_]*$")))
    ' "$pack_dir/tenant.json" >/dev/null 2>&1; then
    echo "  [pack-fail] tenant.json invalid: requires tenant_id (^[a-z][a-z0-9-]{1,62}\$), pack_version (semver), github.org; secrets must be UPPER_SNAKE names" >&2
    return 1
  fi

  if ! lint_pack_deltas "$pack_dir" "$core_repo_root"; then
    echo "  [pack-fail] deltas-only lint failed — pack ships verbatim core content (ADR-013 amendment)" >&2
    return 1
  fi

  # Secret VALUES never ship in a pack (ADR-034) — cheap mechanical grep.
  local secret_hits
  secret_hits="$(grep -rEl --exclude-dir=.git \
    'sk_live_|sk-ant-|AKIA[0-9A-Z]{16}|-----BEGIN( [A-Z]+)? PRIVATE KEY-----' \
    "$pack_dir" 2>/dev/null || true)"
  if [[ -n "$secret_hits" ]]; then
    echo "  [pack-fail] secret-value shapes found in pack files:" >&2
    echo "$secret_hits" | sed 's/^/    /' >&2
    return 1
  fi

  # ---- Phase 1: compose, type-dispatched ----
  local tenant_id pack_version
  tenant_id="$(jq -r '.tenant_id' "$pack_dir/tenant.json")"
  pack_version="$(jq -r '.pack_version' "$pack_dir/tenant.json")"

  if [[ -d "$pack_dir/config" ]]; then
    local pack_file rel dest
    while IFS= read -r pack_file; do
      rel="${pack_file#"$pack_dir"/config/}"
      dest="$claude_dir/$rel"
      mkdir -p "$(dirname "$dest")"
      if [[ -f "$dest" ]]; then
        merge_json_pack_wins "$pack_file" "$dest"
        echo "    [pack-merge] $dest"
      else
        cp "$pack_file" "$dest"
        echo "    [pack-copy] $dest"
      fi
    done < <(find "$pack_dir/config" -type f -name '*.json')
  fi

  local fragment_rel
  fragment_rel="$(jq -r '.claude_fragment_path // "CLAUDE.fragment.md"' "$pack_dir/tenant.json")"
  if [[ -f "$pack_dir/$fragment_rel" ]]; then
    touch "$claude_dir/CLAUDE.md"
    apply_org_overlay_section "$pack_dir/$fragment_rel" "$claude_dir/CLAUDE.md"
    echo "    [pack-overlay] $claude_dir/CLAUDE.md"
  fi

  # skills/agents/commands: whole-file replace/add. standards/, design/ and
  # tenant.json are consumed later from ~/.claude/packs/<tenant_id>/ by
  # /project-init and the provisioner — never installed globally.
  local md_root
  for md_root in skills agents commands; do
    [[ -d "$pack_dir/$md_root" ]] || continue
    local f rel dest
    while IFS= read -r f; do
      rel="${f#"$pack_dir"/}"
      dest="$claude_dir/$rel"
      mkdir -p "$(dirname "$dest")"
      cp "$f" "$dest"
      echo "    [pack-copy] $dest"
    done < <(find "$pack_dir/$md_root" -type f)
  done

  local sha
  sha="$(git -C "$pack_dir" rev-parse HEAD 2>/dev/null || echo "")"
  jq -n \
    --arg tenant_id "$tenant_id" \
    --arg pack_version "$pack_version" \
    --arg source "${PACK_SOURCE:-$pack_dir}" \
    --arg ref "${PACK_REF:-}" \
    --arg sha "$sha" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{tenant_id:$tenant_id, pack_version:$pack_version, source:$source, ref:$ref, sha:$sha, installed_at:$at}' \
    > "$pack_dir/.pack-install.json"

  echo "  Pack $tenant_id@$pack_version composed over core."
}

# Clone of append_stack_section for the tenant overlay region (ADR-013
# amendment #3). The core CLAUDE_CODE_STACK_MANAGED region is never touched;
# both regions coexist and stay independently re-writable.
apply_org_overlay_section() {
  local source="$1"
  local target="$2"

  local marker="<!-- ORG_OVERLAY_MANAGED -->"
  local end_marker="<!-- /ORG_OVERLAY_MANAGED -->"

  if grep -q "$marker" "$target" 2>/dev/null; then
    awk -v source="$source" -v marker="$marker" -v end_marker="$end_marker" '
      BEGIN { in_section = 0 }
      index($0, marker) && !index($0, end_marker) { in_section = 1; print; while ((getline line < source) > 0) print line; next }
      index($0, end_marker) { in_section = 0; print; next }
      !in_section { print }
    ' "$target" > "$target.new"
    mv "$target.new" "$target"
  else
    {
      echo ""
      echo "$marker"
      cat "$source"
      echo "$end_marker"
    } >> "$target"
  fi
}
