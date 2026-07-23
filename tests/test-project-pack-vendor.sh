#!/usr/bin/env bash
# Test: per-project tenant-pack consumption (M3, ADR-034 §4) —
# resolve_installed_pack, set_config_tenant_id, apply_project_claude_fragment,
# vendor_tenant_standards. Value-checking (not shape-only): asserts the tenant
# id lands in the config, the fragment lands in the overlay region, the mapped
# standards files land in the repo, and every failure path is fail-closed.

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/config-merger.sh"
source "$REPO_ROOT/scripts/lib/pack-lint.sh"
source "$REPO_ROOT/scripts/lib/project-pack-vendor.sh"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

fail() { echo "FAIL: $1"; exit 1; }

# --- Fixtures: a landed pack + a fake ~/.claude + a project repo ---------------

PACK="$TMP/packs/acme"
mkdir -p "$PACK/standards/sub"
cat > "$PACK/tenant.json" << 'EOF'
{
  "tenant_id": "acme",
  "pack_version": "1.0.0",
  "github": { "org": "acme-org" },
  "claude_fragment_path": "CLAUDE.fragment.md",
  "standards": {
    "security": "standards/security.md",
    "nested": "standards/sub/style.md"
  }
}
EOF
printf 'ACME security rules.\n' > "$PACK/standards/security.md"
printf 'ACME nested style.\n'   > "$PACK/standards/sub/style.md"
printf 'ACME org overlay body.\n' > "$PACK/CLAUDE.fragment.md"

CLAUDE_DIR="$TMP/dot-claude"
mkdir -p "$CLAUDE_DIR"
cat > "$CLAUDE_DIR/stack-defaults.json" << EOF
{ "tenant_pack": { "tenant_id": "acme", "path": "$PACK", "pack_version": "1.0.0" } }
EOF

REPO="$TMP/repo"
mkdir -p "$REPO/.claude"
cat > "$REPO/.claude/stack-config.json" << 'EOF'
{ "stack_version": "1.1.5", "stack_tier": 2, "purpose": "x", "change_history": [] }
EOF

# --- 1. resolve_installed_pack: valid pack resolves to id|dir ------------------

if ! out="$(resolve_installed_pack "$CLAUDE_DIR")"; then
  fail "resolve_installed_pack returned nonzero on a valid pack"
fi
[[ "$out" == "acme|$PACK" ]] || fail "resolve_installed_pack wrong output: $out"

# --- 2. resolve_installed_pack: no tenant_pack -> rc1 (single-tenant fallback) -

NOPACK="$TMP/dot-claude-empty"
mkdir -p "$NOPACK"
echo '{ "tier": 2 }' > "$NOPACK/stack-defaults.json"
if resolve_installed_pack "$NOPACK" >/dev/null 2>&1; then
  fail "resolve_installed_pack should fail when no tenant_pack is present"
fi

# --- 3. resolve_installed_pack: id mismatch between defaults and pack -> rc1 ---

MISMATCH="$TMP/dot-claude-mismatch"
mkdir -p "$MISMATCH"
cat > "$MISMATCH/stack-defaults.json" << EOF
{ "tenant_pack": { "tenant_id": "wrongid", "path": "$PACK", "pack_version": "1.0.0" } }
EOF
if resolve_installed_pack "$MISMATCH" >/dev/null 2>&1; then
  fail "resolve_installed_pack should fail on tenant_id mismatch"
fi

# --- 4. set_config_tenant_id: value lands, config stays valid JSON -------------

CFG="$REPO/.claude/stack-config.json"
set_config_tenant_id "$CFG" "acme" "$REPO" || fail "set_config_tenant_id returned nonzero"
got="$(jq -r '.tenant_id' "$CFG")"
[[ "$got" == "acme" ]] || fail "tenant_id not written (got: $got)"
# untouched fields survive
[[ "$(jq -r '.stack_tier' "$CFG")" == "2" ]] || fail "set_config_tenant_id clobbered stack_tier"
jq -e . "$CFG" >/dev/null || fail "stack-config.json is no longer valid JSON"

# --- 5. apply_project_claude_fragment: fragment lands in overlay region --------

PC="$REPO/CLAUDE.md"
printf '# My project\n\nProject body.\n' > "$PC"
apply_project_claude_fragment "$PACK" "$PC" || fail "apply_project_claude_fragment nonzero"
grep -q '<!-- ORG_OVERLAY_MANAGED -->'  "$PC" || fail "overlay start marker missing"
grep -q '<!-- /ORG_OVERLAY_MANAGED -->' "$PC" || fail "overlay end marker missing"
grep -q 'ACME org overlay body.'        "$PC" || fail "fragment body not applied"
grep -q 'Project body.'                 "$PC" || fail "project body was lost"

# idempotent: second apply replaces the region, does not duplicate it
apply_project_claude_fragment "$PACK" "$PC" || fail "second apply nonzero"
n="$(grep -c '<!-- ORG_OVERLAY_MANAGED -->' "$PC")"
[[ "$n" == "1" ]] || fail "overlay region duplicated on re-apply (count: $n)"

# --- 6. apply_project_claude_fragment: no fragment file -> no-op success -------

NOFRAG="$TMP/packs/nofrag"
mkdir -p "$NOFRAG"
echo '{ "tenant_id": "nofrag", "pack_version": "1.0.0", "github": {"org":"x"} }' > "$NOFRAG/tenant.json"
PC2="$REPO/CLAUDE2.md"
printf 'body only\n' > "$PC2"
apply_project_claude_fragment "$NOFRAG" "$PC2" || fail "no-fragment case should succeed"
grep -q 'ORG_OVERLAY_MANAGED' "$PC2" && fail "no-fragment case should not add an overlay region"

# --- 7. vendor_tenant_standards: mapped files land preserving pack-relative path

vendor_tenant_standards "$PACK" "$REPO" || fail "vendor_tenant_standards nonzero"
[[ -f "$REPO/standards/security.md" ]]  || fail "security.md not vendored"
[[ -f "$REPO/standards/sub/style.md" ]] || fail "nested style.md not vendored"
grep -q 'ACME security rules.' "$REPO/standards/security.md" || fail "vendored content wrong"

# --- 8. vendor_tenant_standards: traversal path -> fail closed, nothing copied -

EVIL="$TMP/packs/evil"
mkdir -p "$EVIL"
cat > "$EVIL/tenant.json" << 'EOF'
{ "tenant_id": "evil", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": { "escape": "../../etc/passwd" } }
EOF
EVILREPO="$TMP/evilrepo"
mkdir -p "$EVILREPO"
if vendor_tenant_standards "$EVIL" "$EVILREPO" >/dev/null 2>&1; then
  fail "vendor_tenant_standards should fail closed on a traversal path"
fi
[[ -z "$(ls -A "$EVILREPO")" ]] || fail "vendor left files behind after a fail-closed abort"

# --- 9. vendor_tenant_standards: no standards map -> no-op success -------------

NOSTD="$TMP/norepo"
mkdir -p "$NOSTD"
vendor_tenant_standards "$NOFRAG" "$NOSTD" || fail "no-standards-map case should succeed"
[[ -z "$(ls -A "$NOSTD")" ]] || fail "no-standards case should copy nothing"

# --- 10. vendor: SYMLINKED source escapes the pack -> fail closed -------------

SYM="$TMP/packs/symsrc"
mkdir -p "$SYM/standards"
SECRET="$TMP/outside-secret.md"
printf 'TOP SECRET not in any pack\n' > "$SECRET"
ln -s "$SECRET" "$SYM/standards/leak.md"
cat > "$SYM/tenant.json" << 'EOF'
{ "tenant_id": "symsrc", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": { "leak": "standards/leak.md" } }
EOF
SYMREPO="$TMP/symrepo"
mkdir -p "$SYMREPO"
if vendor_tenant_standards "$SYM" "$SYMREPO" >/dev/null 2>&1; then
  fail "vendor must reject a symlinked standards source (pack escape)"
fi
[[ -z "$(ls -A "$SYMREPO")" ]] || fail "symlink-source case left files behind"

# --- 11. vendor: SYMLINKED destination escapes the repo -> fail closed --------

DSTREPO="$TMP/dstrepo"
mkdir -p "$DSTREPO"
OUTDIR="$TMP/escape-target"
mkdir -p "$OUTDIR"
# repo's standards/ is a symlink pointing outside the repo
ln -s "$OUTDIR" "$DSTREPO/standards"
if vendor_tenant_standards "$PACK" "$DSTREPO" >/dev/null 2>&1; then
  fail "vendor must reject a symlinked destination dir (repo escape)"
fi
[[ -z "$(ls -A "$OUTDIR")" ]] || fail "vendor wrote through a symlink to outside the repo"

# --- 12. vendor: malformed standards (not an object) -> hard fail -------------

BADSTD="$TMP/packs/badstd"
mkdir -p "$BADSTD/standards"
printf 'x\n' > "$BADSTD/standards/a.md"
cat > "$BADSTD/tenant.json" << 'EOF'
{ "tenant_id": "badstd", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": ["standards/a.md"] }
EOF
BADREPO="$TMP/badrepo"
mkdir -p "$BADREPO"
if vendor_tenant_standards "$BADSTD" "$BADREPO" >/dev/null 2>&1; then
  fail "vendor must hard-fail on a non-object standards map, not silently no-op"
fi
[[ -z "$(ls -A "$BADREPO")" ]] || fail "malformed-standards case copied something"

# --- 13. vendor: non-string standards value -> hard fail ----------------------

BADVAL="$TMP/packs/badval"
mkdir -p "$BADVAL"
cat > "$BADVAL/tenant.json" << 'EOF'
{ "tenant_id": "badval", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": { "n": 42 } }
EOF
BVREPO="$TMP/bvrepo"; mkdir -p "$BVREPO"
if vendor_tenant_standards "$BADVAL" "$BVREPO" >/dev/null 2>&1; then
  fail "vendor must hard-fail on a non-string standards value"
fi

# --- 14. vendor: mid-loop copy failure rolls back (no half-vendored tree) -----

# First entry lands in a writable dir (copy succeeds), second targets a
# read-only dir (copy fails) — proving the first copy is rolled back.
HALF="$TMP/packs/half"
mkdir -p "$HALF/a" "$HALF/b"
printf 'one\n' > "$HALF/a/one.md"
printf 'two\n' > "$HALF/b/two.md"
cat > "$HALF/tenant.json" << 'EOF'
{ "tenant_id": "half", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": { "one": "a/one.md", "two": "b/two.md" } }
EOF
HALFREPO="$TMP/halfrepo"
mkdir -p "$HALFREPO/b"
if [[ "$(id -u)" -ne 0 ]]; then   # chmod-based failure trigger is meaningless as root
  chmod 500 "$HALFREPO/b"   # read-only: cp into b/ fails after a/one.md copied
  if vendor_tenant_standards "$HALF" "$HALFREPO" >/dev/null 2>&1; then
    chmod u+w "$HALFREPO/b"
    fail "vendor should fail when a copy cannot complete"
  fi
  chmod u+w "$HALFREPO/b"   # restore so trap cleanup can remove TMP
  # a/one.md must have been rolled back — no half-vendored tree.
  [[ ! -f "$HALFREPO/a/one.md" ]] || fail "mid-loop failure left a half-vendored file (one.md)"
fi

# --- 15. apply_project_claude_fragment: symlinked fragment source -> fail ------

SYMFRAG="$TMP/packs/symfrag"
mkdir -p "$SYMFRAG"
echo '{ "tenant_id": "symfrag", "pack_version": "1.0.0", "github": {"org":"x"} }' > "$SYMFRAG/tenant.json"
ln -s "$SECRET" "$SYMFRAG/CLAUDE.fragment.md"
PCSYM="$TMP/pcsym.md"; printf 'body\n' > "$PCSYM"
if apply_project_claude_fragment "$SYMFRAG" "$PCSYM" >/dev/null 2>&1; then
  fail "apply must reject a symlinked fragment source"
fi
grep -q 'TOP SECRET' "$PCSYM" && fail "symlinked fragment leaked outside content into CLAUDE.md"

# --- 16. vendor: empty-string standards value -> hard fail (not silent drop) --

EMPTYV="$TMP/packs/emptyv"
mkdir -p "$EMPTYV"
cat > "$EMPTYV/tenant.json" << 'EOF'
{ "tenant_id": "emptyv", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": { "x": "" } }
EOF
EVR="$TMP/evr"; mkdir -p "$EVR"
if vendor_tenant_standards "$EMPTYV" "$EVR" >/dev/null 2>&1; then
  fail "vendor must hard-fail on an empty standards path value, not silently no-op"
fi

# --- 17. vendor: rollback RESTORES a pre-existing file (no data loss) ----------

# entry one overwrites an existing repo file; entry two fails (read-only dir);
# the pre-existing file must be restored to its ORIGINAL content, not deleted.
PRE="$TMP/packs/pre"
mkdir -p "$PRE/a" "$PRE/b"
printf 'PACK one\n' > "$PRE/a/one.md"
printf 'PACK two\n' > "$PRE/b/two.md"
cat > "$PRE/tenant.json" << 'EOF'
{ "tenant_id": "pre", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": { "one": "a/one.md", "two": "b/two.md" } }
EOF
PREREPO="$TMP/prerepo"
mkdir -p "$PREREPO/a" "$PREREPO/b"
printf 'ORIGINAL repo content\n' > "$PREREPO/a/one.md"   # pre-existing, must survive
if [[ "$(id -u)" -ne 0 ]]; then   # chmod-based failure trigger is meaningless as root
  chmod 500 "$PREREPO/b"                                  # force entry-two cp to fail
  if vendor_tenant_standards "$PRE" "$PREREPO" >/dev/null 2>&1; then
    chmod u+w "$PREREPO/b"; fail "vendor should fail when second copy cannot complete"
  fi
  chmod u+w "$PREREPO/b"
  [[ -f "$PREREPO/a/one.md" ]] || fail "rollback DELETED a pre-existing file (data loss)"
  grep -q 'ORIGINAL repo content' "$PREREPO/a/one.md" \
    || fail "rollback did not restore pre-existing file's original content"
fi

# --- 18. apply_project_claude_fragment: symlinked "$target.new" -> refuse ------

NEWSYM="$TMP/newsym"
mkdir -p "$NEWSYM"
PCN="$NEWSYM/CLAUDE.md"
printf 'body\n' > "$PCN"
OUTNEW="$TMP/outside-new-target"
ln -s "$OUTNEW" "$PCN.new"     # pre-placed symlink at the predictable temp path
if apply_project_claude_fragment "$PACK" "$PCN" >/dev/null 2>&1; then
  fail "apply must refuse when \$target.new is a pre-placed symlink (write-through)"
fi
[[ ! -e "$OUTNEW" ]] || fail "apply wrote through the .new symlink to outside the repo"

# --- 19. vendor: duplicate destination (two keys -> same path) -> hard fail ----

DUP="$TMP/packs/dup"
mkdir -p "$DUP/standards"
printf 'x\n' > "$DUP/standards/a.md"
cat > "$DUP/tenant.json" << 'EOF'
{ "tenant_id": "dup", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": { "k1": "standards/a.md", "k2": "standards/a.md" } }
EOF
DUPREPO="$TMP/duprepo"; mkdir -p "$DUPREPO"
if vendor_tenant_standards "$DUP" "$DUPREPO" >/dev/null 2>&1; then
  fail "vendor must hard-fail on a duplicate destination path"
fi

# --- 20. vendor: pre-existing NON-regular dest (a directory) -> hard fail ------

NRD="$TMP/packs/nrd"
mkdir -p "$NRD/standards"
printf 'x\n' > "$NRD/standards/a.md"
cat > "$NRD/tenant.json" << 'EOF'
{ "tenant_id": "nrd", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": { "a": "standards/a.md" } }
EOF
NRDREPO="$TMP/nrdrepo"
mkdir -p "$NRDREPO/standards/a.md"   # a DIRECTORY where the file must go
if vendor_tenant_standards "$NRD" "$NRDREPO" >/dev/null 2>&1; then
  fail "vendor must reject a pre-existing non-regular destination"
fi

# --- 21. apply_project_claude_fragment: pre-existing regular "$target.new" -----

HN="$TMP/hn"
mkdir -p "$HN"
PCHN="$HN/CLAUDE.md"
printf 'body\n' > "$PCHN"
printf 'squatter\n' > "$PCHN.new"    # pre-existing regular file (hardlink class)
if apply_project_claude_fragment "$PACK" "$PCHN" >/dev/null 2>&1; then
  fail "apply must refuse a pre-existing \$target.new (write-through risk)"
fi

# --- 22. vendor: case-insensitive duplicate destination -> hard fail -----------

CASE="$TMP/packs/case"
mkdir -p "$CASE/standards"
printf 'x\n' > "$CASE/standards/a.md"
printf 'y\n' > "$CASE/standards/A.md" 2>/dev/null || true   # may collide on APFS
cat > "$CASE/tenant.json" << 'EOF'
{ "tenant_id": "case", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": { "lower": "standards/a.md", "upper": "standards/A.md" } }
EOF
CASEREPO="$TMP/caserepo"; mkdir -p "$CASEREPO"
if vendor_tenant_standards "$CASE" "$CASEREPO" >/dev/null 2>&1; then
  fail "vendor must reject case-insensitive duplicate destinations (macOS on-disk collision)"
fi

# --- 23. vendor: "." / "//" components rejected (not silently normalized) ------

DOT="$TMP/packs/dot"
mkdir -p "$DOT/standards"
printf 'x\n' > "$DOT/standards/a.md"
cat > "$DOT/tenant.json" << 'EOF'
{ "tenant_id": "dot", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": { "a": "standards/./a.md" } }
EOF
DOTREPO="$TMP/dotrepo"; mkdir -p "$DOTREPO"
if vendor_tenant_standards "$DOT" "$DOTREPO" >/dev/null 2>&1; then
  fail "vendor must reject a '.' path component (unclean relative path)"
fi

# --- 24. vendor: embedded newline in a value -> caught by count cross-check ----

# One map entry whose value contains a newline must NOT fan into two vendored
# files; jq -r splits it into 2 lines, count != .standards|length -> fail closed.
NL="$TMP/packs/nl"
mkdir -p "$NL/standards"
printf 'x\n' > "$NL/standards/a.md"
printf 'y\n' > "$NL/standards/b.md"
# jq --arg builds a value with a literal newline safely.
jq -n --arg v $'standards/a.md\nstandards/b.md' \
  '{tenant_id:"nl", pack_version:"1.0.0", github:{org:"x"}, standards:{combined:$v}}' \
  > "$NL/tenant.json"
NLREPO="$TMP/nlrepo"; mkdir -p "$NLREPO"
if vendor_tenant_standards "$NL" "$NLREPO" >/dev/null 2>&1; then
  fail "vendor must fail closed when a value embeds a newline (one entry != two files)"
fi
[[ -z "$(ls -A "$NLREPO")" ]] || fail "newline-split case vendored files it should not have"

# --- 25. vendor: re-vendor over an already-vendored file succeeds (idempotent) -

# The overwrite path: dest already exists as a regular file. _ppv_canon_dest
# must canonicalize it (not cd into the file), and the copy must update content.
REV="$TMP/packs/rev"
mkdir -p "$REV/standards"
printf 'v1\n' > "$REV/standards/s.md"
cat > "$REV/tenant.json" << 'EOF'
{ "tenant_id": "rev", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": { "s": "standards/s.md" } }
EOF
REVREPO="$TMP/revrepo"; mkdir -p "$REVREPO"
vendor_tenant_standards "$REV" "$REVREPO" || fail "first vendor failed"
grep -q 'v1' "$REVREPO/standards/s.md" || fail "first vendor content wrong"
# pack updates the file; re-vendor must succeed and overwrite (not abort)
printf 'v2\n' > "$REV/standards/s.md"
vendor_tenant_standards "$REV" "$REVREPO" || fail "re-vendor over existing file failed (canon_dest regression)"
grep -q 'v2' "$REVREPO/standards/s.md" || fail "re-vendor did not update content to v2"

# canon_dest directly: an existing file resolves without error
canon_out="$(_ppv_canon_dest "$REVREPO/standards/s.md")" || fail "_ppv_canon_dest errored on an existing file"
[[ "$canon_out" == */standards/s.md ]] || fail "_ppv_canon_dest wrong output: $canon_out"

# --- 26. apply_project_claude_fragment: FIFO fragment source -> reject (no hang)

if [[ "$(id -u)" -ne 0 ]]; then
  FIFO="$TMP/packs/fifo"
  mkdir -p "$FIFO"
  echo '{ "tenant_id": "fifo", "pack_version": "1.0.0", "github": {"org":"x"} }' > "$FIFO/tenant.json"
  mkfifo "$FIFO/CLAUDE.fragment.md"
  PCFIFO="$TMP/pcfifo.md"; printf 'body\n' > "$PCFIFO"
  # Must return non-zero PROMPTLY, not block on the FIFO read. Poll for exit;
  # if still alive after ~5s it HUNG -> that is a failure (distinct from a
  # prompt nonzero rejection, which is the pass condition).
  ( apply_project_claude_fragment "$FIFO" "$PCFIFO" ) >/dev/null 2>&1 &
  ap_pid=$!
  ap_hung=1
  for _i in $(seq 1 50); do
    kill -0 "$ap_pid" 2>/dev/null || { ap_hung=0; break; }
    sleep 0.1
  done
  if [[ "$ap_hung" -eq 1 ]]; then
    kill -9 "$ap_pid" 2>/dev/null; wait "$ap_pid" 2>/dev/null || true
    fail "apply HUNG on a FIFO fragment source (should reject promptly)"
  fi
  ap_rc=0; wait "$ap_pid" || ap_rc=$?   # guarded: bare wait would trip set -e
  [[ "$ap_rc" -ne 0 ]] || fail "apply must reject a FIFO fragment source (returned success)"
fi

# --- 28. set_config_tenant_id: symlinked .claude escaping repo -> reject -------

SC="$TMP/screpo"
mkdir -p "$SC"
SCOUT="$TMP/sc-outside"
mkdir -p "$SCOUT"
printf '{ "stack_tier": 2 }\n' > "$SCOUT/stack-config.json"
ln -s "$SCOUT" "$SC/.claude"   # repo/.claude -> outside the repo
if set_config_tenant_id "$SC/.claude/stack-config.json" "acme" "$SC" >/dev/null 2>&1; then
  fail "set_config_tenant_id must refuse a config that resolves outside the repo"
fi
grep -q 'tenant_id' "$SCOUT/stack-config.json" && fail "set_config wrote outside the repo via symlinked .claude"

# --- 27. vendor: destination path crosses a non-directory -> hard fail --------

XDIR="$TMP/packs/xdir"
mkdir -p "$XDIR/standards"
printf 'x\n' > "$XDIR/standards/s.md"
cat > "$XDIR/tenant.json" << 'EOF'
{ "tenant_id": "xdir", "pack_version": "1.0.0", "github": {"org":"x"},
  "standards": { "s": "standards/s.md" } }
EOF
XREPO="$TMP/xrepo"; mkdir -p "$XREPO"
printf 'I am a file, not a dir\n' > "$XREPO/standards"   # blocks standards/s.md
if vendor_tenant_standards "$XDIR" "$XREPO" >/dev/null 2>&1; then
  fail "vendor must reject a destination path that crosses a non-directory"
fi

echo "PASS: project-pack-vendor (28 cases)"
