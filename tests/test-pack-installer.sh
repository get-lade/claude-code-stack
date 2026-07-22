#!/usr/bin/env bash
# Test: install_pack composes a tenant pack over core with pack-wins semantics
# (M3, ADR-034 §2, ADR-013 amendment #1).

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/config-merger.sh"
source "$REPO_ROOT/scripts/lib/pack-lint.sh"
source "$REPO_ROOT/scripts/lib/pack-installer.sh"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

# --- Fixtures: mini core repo, installed ~/.claude, project, tenant pack ---

CORE="$TMP/core"
mkdir -p "$CORE/config" "$CORE/skills/sample-skill"
cat > "$CORE/config/settings.json" << 'EOF'
{ "shared": "core", "core_only": true, "list": ["a", "b"] }
EOF
cat > "$CORE/skills/sample-skill/SKILL.md" << 'EOF'
# Sample skill
Core version of the skill.
EOF

HOME_FIX="$TMP/home"
CLAUDE="$HOME_FIX/.claude"
mkdir -p "$CLAUDE"
cat > "$CLAUDE/settings.json" << 'EOF'
{ "shared": "core", "core_only": true, "preexisting": "keep-me", "list": ["a", "b"],
  "hooks": { "PostToolUse": [ { "matcher": "Edit", "hooks": [ { "command": "core-hook.sh" } ] } ] } }
EOF
cat > "$CLAUDE/CLAUDE.md" << 'EOF'
# My global CLAUDE.md

<!-- CLAUDE_CODE_STACK_MANAGED -->
core managed content
<!-- /CLAUDE_CODE_STACK_MANAGED -->
EOF
mkdir -p "$CLAUDE/skills/sample-skill"
cp "$CORE/skills/sample-skill/SKILL.md" "$CLAUDE/skills/sample-skill/SKILL.md"

PROJECT="$TMP/project"
mkdir -p "$PROJECT/.claude"
cat > "$PROJECT/.claude/stack-config.json" << 'EOF'
{ "stack_version": "1.0.0", "stack_tier": 2, "purpose": "fixture", "created": "2026-07-22",
  "session_prefs": { "communication_style": "terse" } }
EOF

PACK="$TMP/pack"
mkdir -p "$PACK/config" "$PACK/skills/sample-skill" "$PACK/standards"
cat > "$PACK/tenant.json" << 'EOF'
{
  "tenant_id": "carbonet",
  "pack_version": "1.2.0",
  "display_name": "CarboNet",
  "github": { "org": "CarboNet-Nano", "merge_policy": "squash" },
  "database": { "default": "neon" },
  "deploy": { "default": "cloudflare" },
  "secrets": ["CARBONET_API_TOKEN", "CARBONET_S3_API_ENDPOINT"]
}
EOF
cat > "$PACK/config/settings.json" << 'EOF'
{ "shared": "pack", "pack_only": "new", "list": ["b", "c"],
  "hooks": { "PostToolUse": [ { "matcher": "Edit", "hooks": [ { "command": "core-hook.sh" }, { "command": "pack-hook.sh" } ] } ] } }
EOF
cat > "$PACK/CLAUDE.fragment.md" << 'EOF'
Org overlay content v1.
EOF
cat > "$PACK/skills/sample-skill/SKILL.md" << 'EOF'
# Sample skill
Pack replacement of the skill.
EOF
cat > "$PACK/standards/naming.md" << 'EOF'
Tenant naming standard — vendored per-repo, never installed globally.
EOF

# --- Install ---

install_pack "$PACK" "$CLAUDE" "$CORE" > /dev/null

# 1. Pack scalar wins over core (the ADR-013 amendment #1 overlay-wins test)
if ! jq -e '.shared == "pack"' "$CLAUDE/settings.json" > /dev/null; then
  echo "FAIL: pack scalar did not win over core value"
  exit 1
fi

# 2. Core-only and pre-existing-target-only keys survive
if ! jq -e '.core_only == true and .preexisting == "keep-me" and .pack_only == "new"' \
  "$CLAUDE/settings.json" > /dev/null; then
  echo "FAIL: non-conflicting keys lost in pack merge"
  exit 1
fi

# 3. Arrays concatenated + order-stable deduped; hook groups collapse
if ! jq -e '.list == ["a", "b", "c"]' "$CLAUDE/settings.json" > /dev/null; then
  echo "FAIL: array merge wrong: $(jq -c '.list' "$CLAUDE/settings.json")"
  exit 1
fi
if ! jq -e '.hooks.PostToolUse | length == 1 and .[0].hooks == [{"command":"core-hook.sh"},{"command":"pack-hook.sh"}]' \
  "$CLAUDE/settings.json" > /dev/null; then
  echo "FAIL: hook groups did not collapse to one block"
  exit 1
fi

# 4. .pack-overrides lists exactly the overwritten scalar paths
if ! jq -e 'length == 1 and .[0].path == ["shared"] and .[0].previous == "core" and .[0].pack == "pack"' \
  "$CLAUDE/settings.json.pack-overrides" > /dev/null 2>&1; then
  echo "FAIL: pack-overrides report missing or wrong"
  exit 1
fi

# 5a. Nothing written outside the fixture ~/.claude (project untouched)
if ! jq -e '.session_prefs.communication_style == "terse"' \
  "$PROJECT/.claude/stack-config.json" > /dev/null; then
  echo "FAIL: project stack-config.json was touched by install_pack"
  exit 1
fi

# 5b. Read-time chain: project value wins over a pack-written global default
cat > "$CLAUDE/stack-defaults.json" << 'EOF'
{ "stack_version": "1.0.0", "default_tier": 2,
  "default_orchestration_mode": "main-thread", "default_strict_mode": false,
  "session_prefs_defaults": { "communication_style": "thorough" } }
EOF
mkdir -p "$CLAUDE/lib"
cp "$REPO_ROOT/lib/find-stack-config.sh" "$CLAUDE/lib/find-stack-config.sh"
HOME="$HOME_FIX" CLAUDE_PLUGIN_ROOT="$CLAUDE" \
  bash "$REPO_ROOT/hooks/session-prefs-init.sh" <<< "{\"cwd\": \"$PROJECT\"}" >/dev/null 2>&1 || true
RESOLVED_STYLE="$(jq -r '.communication_style // empty' "$CLAUDE/session-state/current-prefs.json" 2>/dev/null)"
if [[ "$RESOLVED_STYLE" != "terse" ]]; then
  echo "FAIL: read-time chain returned '$RESOLVED_STYLE', project value should win over pack default"
  exit 1
fi

# 6. Marker region replaced, not appended — apply the fragment again
MARKER_COUNT_1="$(grep -c 'ORG_OVERLAY_MANAGED' "$CLAUDE/CLAUDE.md")"
CORE_REGION_1="$(sed -n '/<!-- CLAUDE_CODE_STACK_MANAGED -->/,/<!-- \/CLAUDE_CODE_STACK_MANAGED -->/p' "$CLAUDE/CLAUDE.md")"
cat > "$PACK/CLAUDE.fragment.md" << 'EOF'
Org overlay content v2.
EOF
install_pack "$PACK" "$CLAUDE" "$CORE" > /dev/null
MARKER_COUNT_2="$(grep -c 'ORG_OVERLAY_MANAGED' "$CLAUDE/CLAUDE.md")"
CORE_REGION_2="$(sed -n '/<!-- CLAUDE_CODE_STACK_MANAGED -->/,/<!-- \/CLAUDE_CODE_STACK_MANAGED -->/p' "$CLAUDE/CLAUDE.md")"
if [[ "$MARKER_COUNT_1" != "$MARKER_COUNT_2" ]]; then
  echo "FAIL: overlay region appended instead of replaced"
  exit 1
fi
if ! grep -q 'Org overlay content v2.' "$CLAUDE/CLAUDE.md" \
  || grep -q 'Org overlay content v1.' "$CLAUDE/CLAUDE.md"; then
  echo "FAIL: overlay region content not replaced with second fragment"
  exit 1
fi
if [[ "$CORE_REGION_1" != "$CORE_REGION_2" ]]; then
  echo "FAIL: core CLAUDE_CODE_STACK_MANAGED region changed"
  exit 1
fi

# 7. *.md whole-file replace — no concatenation, no core remnants
if ! diff -q "$CLAUDE/skills/sample-skill/SKILL.md" "$PACK/skills/sample-skill/SKILL.md" > /dev/null; then
  echo "FAIL: skill not replaced whole-file"
  exit 1
fi

# 7b. standards/ never installed globally
if [[ -e "$CLAUDE/standards" ]]; then
  echo "FAIL: standards/ was installed globally"
  exit 1
fi

# 8. Idempotency — a second run converges (recursive diff empty)
SNAP="$TMP/snap"
cp -R "$CLAUDE" "$SNAP"
install_pack "$PACK" "$CLAUDE" "$CORE" > /dev/null
if ! diff -r "$SNAP" "$CLAUDE" > /dev/null; then
  echo "FAIL: second install_pack run changed the tree"
  diff -r "$SNAP" "$CLAUDE" | head -5
  exit 1
fi

# 9. Secret-value guard — pack containing a live-key shape aborts Phase 0
BADPACK="$TMP/badpack"
cp -R "$PACK" "$BADPACK"
echo 'STRIPE_KEY=sk_live_abc123' > "$BADPACK/config/oops.json"
BEFORE="$TMP/before"
cp -R "$CLAUDE" "$BEFORE"
if install_pack "$BADPACK" "$CLAUDE" "$CORE" > /dev/null 2>&1; then
  echo "FAIL: secret-value pack was not rejected"
  exit 1
fi
# 10. Phase-0 failure leaves ~/.claude bit-identical (fail-closed)
if ! diff -r "$BEFORE" "$CLAUDE" > /dev/null; then
  echo "FAIL: failed install wrote to ~/.claude"
  exit 1
fi

# 11. Manifest validation
INVALID="$TMP/invalid"
cp -R "$PACK" "$INVALID"
jq 'del(.tenant_id)' "$INVALID/tenant.json" > "$INVALID/tenant.json.tmp" && mv "$INVALID/tenant.json.tmp" "$INVALID/tenant.json"
if install_pack "$INVALID" "$CLAUDE" "$CORE" > /dev/null 2>&1; then
  echo "FAIL: manifest without tenant_id accepted"
  exit 1
fi
cp -R "$PACK" "$TMP/badsecret" && BADSECRET="$TMP/badsecret"
jq '.secrets = ["lowercase_name"]' "$BADSECRET/tenant.json" > "$BADSECRET/tenant.json.tmp" && mv "$BADSECRET/tenant.json.tmp" "$BADSECRET/tenant.json"
if install_pack "$BADSECRET" "$CLAUDE" "$CORE" > /dev/null 2>&1; then
  echo "FAIL: lowercase secret name accepted"
  exit 1
fi

# 12. --pack spec parse unit cases
assert_parse() {
  local spec="$1" want="$2" got
  got="$(parse_pack_ref "$spec")"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: parse_pack_ref '$spec' -> '$got', want '$want'"
    exit 1
  fi
}
assert_parse "https://github.com/org/repo.git" "https://github.com/org/repo.git|"
assert_parse "https://github.com/org/repo.git@v1" "https://github.com/org/repo.git|v1"
assert_parse "git@github.com:org/repo.git@v1" "git@github.com:org/repo.git|v1"
assert_parse "git@github.com:org/repo.git" "git@github.com:org/repo.git|"

# Local path mode: resolve_pack_source returns the dir itself, no clone
RESOLVED="$(resolve_pack_source "$PACK")"
if [[ "$RESOLVED" != "$PACK|$PACK|" ]]; then
  echo "FAIL: local path resolve wrong: $RESOLVED"
  exit 1
fi

# 13. Install stamp written with tenant/version
if ! jq -e '.tenant_id == "carbonet" and .pack_version == "1.2.0"' \
  "$PACK/.pack-install.json" > /dev/null; then
  echo "FAIL: .pack-install.json stamp missing or wrong"
  exit 1
fi

echo "PASS: pack installer composes pack-wins correctly"
