# Automated project provisioning — moved

This plan was tenant-specific (CarboNet, tenant #1) and moved to the CarboNet tenant
pack repo at `docs/stack-history/2026-07-19-automated-project-provisioning.md` during
the lade privatization (M1 scrub).

The provisioning **engine** design it referenced is the standalone plan:
`Architect-for-Claude-Code/docs/plans/2026-07-19-provisioning-engine-standalone.md`.
The stack keeps only thin client pieces: the `provisioner` agent, `/project-init`
provisioning step, `/publish`, `/project-teardown`.
