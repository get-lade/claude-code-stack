# Stack test suite

Tests for the stack itself. Run before any release / breaking change.

## Tests

- `test-install.sh` — install in a clean directory; verify all tiers reach pass, and that the installed `settings.json` never references a hook script that wasn't copied at that tier (the tier-0/1 team-hook dangling-reference guard).
- `test-tier-isolation.sh` — verify each tier installs cleanly without earlier tiers being polluted.
- `test-config-merger.sh` — JSON merge logic doesn't lose user data; includes a scalar-conflict scenario (non-interactive run keeps the user value).
- `test-merger-session-hooks.sh` (v1.1) — verify nested SessionStart hooks from multiple tiers merge correctly (Tier 0's hook + Tier 2's hook both fire after merge).
- `test-merger-interactive.sh` — verify the interactive conflict prompt (approve → stack value, decline → user value kept), driven through a pty via `expect`. Skips cleanly if `expect` is unavailable.
- `test-cloud-bootstrap.sh` — verify `scripts/cloud-bootstrap.sh` never hard-fails a cloud session: no-op outside cloud, warn+exit 0 on missing token, short-circuit on the per-boot marker. Offline-only (the clone+install path is covered by `test-install.sh`).
- `test-workflow-roster-check.sh` — unit tests for `hooks/workflow-roster-check.sh`: warn/block/quiet/off decision table, roster-name extraction (both quote forms), Tier<2 gate, always-log invariant, backward-compat with old rows lacking `roster_agents`, and the base/team settings-template split (`settings.global.template.json` vs the tier-2-only `settings.team.template.json`) plus re-merge idempotency.

## Running

```bash
cd tests
./test-install.sh
./test-tier-isolation.sh
./test-config-merger.sh
./test-merger-session-hooks.sh
./test-merger-interactive.sh
./test-workflow-roster-check.sh
```

All tests must pass for a release tag. CI runs this whole suite in the
`unit-tests` job, alongside a per-tier install/verify matrix — see
`.github/workflows/test-install.yml`.
