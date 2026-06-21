# Runbook: Cross-family review (Codex / OpenAI) stalls in a cloud/sandboxed session

Last updated: 2026-06-21
Severity: high

The adversarial-review gate (`reviewer`, `security-auditor`, `product-critic`)
must run a pass on a **non-Claude model family** — OpenAI/GPT-5.5 via the
`codex` CLI or the OpenAI API (ADR-011/015). In cloud/sandboxed sessions that
path stalls in four well-known ways. This runbook is the fix. See ADR-022.

## Symptom

- A reviewer / security-auditor agent reports cross-family review
  **unavailable**, or returns `401 "Missing bearer"`, or its `api.openai.com`
  call is **denied** by the sandbox.
- A PR sits with a **held auto-merge** and no review decision.
- Editing `.claude/settings.local.json` to allow the call is **also denied**.

## Diagnosis

Run the preflight probe — it classifies the failure in one step:

```bash
bash scripts/lib/cross-family-preflight.sh
```

Read the `VERDICT` line:

| Verdict | Failure mode | Meaning |
|---|---|---|
| `READY` | — | Path works. No action. |
| `BLOCKED_NOCREDS` | 1 | No `codex` CLI **and** no `OPENAI_API_KEY` in this shell. |
| `BLOCKED_NETWORK` | 2 | Key present, but `api.openai.com` is denied by the network policy / sandbox classifier. |
| `PROBE_SKIPPED` | — | No `curl` to probe with; treat as unverified. |

Confirm by hand if needed:

```bash
command -v codex            # CLI on PATH?
printenv OPENAI_API_KEY     # key reaching THIS (the subagent) shell?
curl -s -o /dev/null -w '%{http_code}\n' --max-time 6 https://api.openai.com/v1/models
# 401/200 => reachable; 000 => blocked
```

## Fix

The two layers that work are the **environment variables** (for the key) and the
**network policy** (for the endpoint). In-session `settings.local.json` does
**not** work — it is hard-denied by design (classifier-bypass). Do not try it.

### `BLOCKED_NOCREDS` — make the key reach the subagent shell (failure mode 1)

The key must be an **environment variable on the cloud environment**, not in any
in-repo settings file. That is the only place that propagates into the
subagent's shell env (`printenv`).

- **Cloud web / iOS (managed environment):** open the environment's settings in
  the Claude Code web UI → **Environment variables** → add
  `OPENAI_API_KEY = sk-…` → Save. Start a **fresh** session (variables are read
  at container boot). See <https://code.claude.com/docs/en/claude-code-on-the-web>.
- **Desktop sandbox:** export it in the shell that launches Claude Code (e.g. in
  your shell profile) so it is inherited by the sandboxed subagent shell:
  `export OPENAI_API_KEY=sk-…`. A key only in your Keychain/1Password but not
  exported will **not** reach the subagent.

Re-run the probe; expect `READY` (or `BLOCKED_NETWORK`, then do the next step).

### `BLOCKED_NETWORK` — allow `api.openai.com` at the network-policy layer (failure mode 2)

The sandbox classifier denies the call because it cannot tell a capability probe
from repo exfiltration — **correctly**. Do **not** weaken the classifier. Allow
the endpoint at the layer the classifier defers to:

- **Cloud web / iOS:** the environment's **network policy** governs outbound
  egress. Choose (or configure) a policy that permits `api.openai.com`. If the
  environment is on a restricted policy, the cross-family call cannot run there
  until the policy is widened — this is an **environment-owner decision**, made
  in the web UI, not from inside the session.
- **Desktop sandbox:** add the domain to the **environment-level / managed**
  sandbox allowlist (the settings the auto-mode classifier reads at startup —
  `sandbox.network.allowedDomains` in your **user/managed** `settings.json`, set
  **before** the session starts), not the in-session `.claude/settings.local.json`
  the classifier blocks mid-session.

> Why not `settings.local.json`? Failure mode 3: arming `autoMode.allow` /
> `sandbox.network.allowedDomains` from **inside** the session is itself denied
> as classifier-bypass. The allowlist must be in place **before** the session
> starts, at the environment / managed-settings layer.

Re-run the probe; expect `READY`.

## If you cannot fix it now — graceful degradation (do not strand the PR)

When the path is provably unavailable, the agent does **not** dead-stop. Per
ADR-022 it emits a **labeled Claude-only deviation** pass and hands back a
structured decision:

- **`re-run-with-key`** — apply the fix above, re-dispatch the agent.
- **`proceed-with-deviation`** — accept the Claude-only pass and merge.
  Acceptable when the change already had a cross-family critic pass at design
  time, or is low-risk (docs/config/tests/non-security refactor).
- **`merge-with-tracked-follow-up`** — merge now, open an issue to run
  cross-family review once the path is restored.

**Blocking case:** novel crypto / auth / payment / RLS code with **no** prior
cross-family review — the deviation is **not** acceptable. Hold the PR (no
auto-merge) and choose `re-run-with-key`.

## Prevention

- Set `OPENAI_API_KEY` and allow `api.openai.com` at the environment layer once,
  per environment, so every session boots `READY`.
- The agents run `scripts/lib/cross-family-preflight.sh` first, so a future
  break surfaces in seconds with the verdict — not five minutes into a review.
- Deviations are logged (`subagent-runs.jsonl`, `event:"cross_family_deviation"`)
  and surfaced by `/handoff`, so a tracked follow-up is visible next session.

## Related

- ADR: [ADR-022](../ADRs/022-cross-family-preflight-and-graceful-degradation.md),
  [ADR-011](../ADRs/011-codex-for-openai-family.md),
  [ADR-015](../ADRs/015-cloud-critic-fallback-ladder.md)
- Doc: [CLOUD.md](../CLOUD.md) — "External-model critics (Codex / Gemini) in cloud"
- Probe: `scripts/lib/cross-family-preflight.sh`
- Incident: Architect-for-Claude-Code PR #91 (T4b realtime)
