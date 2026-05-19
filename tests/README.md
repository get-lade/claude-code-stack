# Stack test suite

Tests for the stack itself. Run before any release / breaking change.

## Tests

- `test-install.sh` — install in a clean directory; verify all tiers reach pass.
- `test-tier-isolation.sh` — verify each tier installs cleanly without earlier tiers being polluted.
- `test-config-merger.sh` — JSON merge logic doesn't lose user data; includes a scalar-conflict scenario (non-interactive run keeps the user value).
- `test-merger-session-hooks.sh` (v1.1) — verify nested SessionStart hooks from multiple tiers merge correctly (Tier 0's hook + Tier 2's hook both fire after merge).
- `test-merger-interactive.sh` — verify the interactive conflict prompt (approve → stack value, decline → user value kept), driven through a pty via `expect`. Skips cleanly if `expect` is unavailable.

## Running

```bash
cd tests
./test-install.sh
./test-tier-isolation.sh
./test-config-merger.sh
./test-merger-session-hooks.sh
./test-merger-interactive.sh
```

All tests must pass for a release tag. CI (`.github/workflows/test-install.yml`) runs install + verify across tiers; this unit suite is run manually before release.
