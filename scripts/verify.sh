#!/usr/bin/env bash
# Verify a tier install.
# Usage: ./verify.sh --tier=N

set -euo pipefail

TIER=""
for arg in "$@"; do
  case $arg in
    --tier=*) TIER="${arg#*=}" ;;
  esac
done

[[ -z "$TIER" ]] && { echo "Usage: $0 --tier=N"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

failures=0
passes=0

run_test() {
  local cmd="$1"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "  [PASS] $cmd"
    passes=$((passes + 1))
  else
    echo "  [FAIL] $cmd"
    failures=$((failures + 1))
  fi
}

for ((t=0; t<=TIER; t++)); do
  manifest="$REPO_ROOT/config/tier-manifests/tier-$t.json"
  [[ -f "$manifest" ]] || continue

  echo "Verifying tier $t..."
  tests="$(jq -r '.smoke_tests // [] | .[]' "$manifest")"
  while IFS= read -r test; do
    [[ -z "$test" ]] && continue
    run_test "$test"
  done <<< "$tests"
done

echo ""
echo "Results: $passes passed, $failures failed"

if [[ "$failures" -gt 0 ]]; then
  echo ""
  echo "Some checks failed. Common fixes:"
  echo "  - Missing Keychain item: security add-generic-password -s '<name>' -a \"\$USER\" -w '<value>' -U"
  echo "  - Missing command: brew install <tool>"
  echo "  - Missing schema: apply via Supabase SQL editor"
  exit 1
fi

echo "All checks passed."
