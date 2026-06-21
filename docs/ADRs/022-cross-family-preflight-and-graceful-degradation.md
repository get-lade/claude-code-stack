# ADR 022: Cross-family review preflight + graceful degradation when it is unavailable

**Status:** Accepted (amends ADR-011 and ADR-015)
**Date:** 2026-06-21
**Author:** the maintainer + Claude (Opus 4.8)

> Numbering note: this is ADR-**022**, not 021. A separate in-flight branch
> (PR #42, unmerged at authoring time) reserves 021 for the superpowers
> design-before-code gate. Taking 022 avoids a collision if both land.

## Context

ADR-011 routes the adversarial-review gate (`reviewer`, `security-auditor`,
`product-critic`) through a **non-Claude model family** — OpenAI/GPT-5.5 via the
`codex` CLI. ADR-015 added a fallback ladder so a missing CLI with the API key
in the environment still counts as capable: *CLI on PATH → else env key (ad-hoc
install or direct API) → STOP only if both absent.*

ADR-015 fixed the **"binary ≠ model"** conflation. It did **not** anticipate
that the env-key rung itself can be structurally blocked in a cloud/sandboxed
session, in four distinct ways observed in production (incident:
Architect-for-Claude-Code **PR #91**, T4b realtime — the Gemini *design* critic
passed, but **both** Codex implementation passes were blocked and auto-merge had
to be held by hand):

1. **Key not in the subagent shell.** The OpenAI key is configured on the cloud
   environment but does not reach the subagent's shell env → `codex` /
   direct API return `401 "Missing bearer"`.
2. **Classifier hard-deny.** When the key *is* present, the auto-mode sandbox
   classifier **hard-denies** the outbound call to `api.openai.com` as
   data-exfiltration (private repo source → external endpoint). This is
   **correct by design** and must not be weakened.
3. **In-session remediation is itself denied.** Writing
   `.claude/settings.local.json` with `autoMode.allow` /
   `sandbox.network.allowedDomains` to arm the path is hard-denied as
   classifier-bypass + exfiltration enablement.
4. **Net effect.** The agent follows the ADR-011/015 ladder, exhausts it,
   discovers the break ~5 minutes in (mid-`codex exec`), and **STOPs** — the PR
   sits with a held auto-merge and **no decision**.

ADR-015's rung 3 ("STOP, never fall back") was written for *absence* of
capability. Failure modes 2–3 are a different thing: the capability exists but
is **structurally gated at a layer the session cannot change from inside**. A
literal STOP there is the worst outcome — it strands work with no path forward
and no human decision.

## Decision

Three changes, none of which weaken the exfiltration classifier or auto-arm any
external call (deliverable D — the fix is **plumbing at the right layer + an
explicit human decision gate**, never a bypass):

### A. Preflight probe — fail fast, up front

`scripts/lib/cross-family-preflight.sh` (`cfp_run`) runs **first**, before any
review work, and classifies the path in one cheap step:

- `codex` on PATH? (`command -v`)
- `OPENAI_API_KEY` reaching **this** shell? (`printenv`, not a settings file)
- `api.openai.com` reachable under the network policy? (an **unauthenticated**
  GET to `/v1/models` — carries no key and no repo data, so it is not itself an
  exfil vector; any HTTP status = reachable, a refused/timed-out connection =
  blocked)

Verdicts: `READY`, `BLOCKED_NETWORK` (failure mode 2), `BLOCKED_NOCREDS`
(failure mode 1), `PROBE_SKIPPED`. The agent relays the verdict immediately
instead of failing five minutes in.

### B. Document the only layer that works

`docs/runbooks/cross-family-review-cloud.md` + the CLOUD.md critics section
state plainly: the key must live in the **environment's variables** (so it
reaches the subagent shell), and `api.openai.com` must be allowed at the
**environment / network-policy** layer. In-session `settings.local.json` is
classifier-blocked by design (failure mode 3) and is **not** a remediation path.
Covers both the desktop sandbox and the cloud-web/managed-settings surfaces.

### C. Graceful degradation — never dead-stop, always hand back a decision

When the probe proves cross-family is unavailable (`BLOCKED_NETWORK` /
`BLOCKED_NOCREDS` / `PROBE_SKIPPED`), the agent does **not** STOP silently. It:

1. Emits a **clearly-labeled Claude-only pass** as an explicit, logged
   **ADR-011 DEVIATION** (`cfp_log_deviation` → `subagent-runs.jsonl`). The
   report header states the deviation and why the cross-family pass was
   impossible — the Claude-only findings are never presented as the mandated
   cross-family review.
2. Hands back a **structured decision** so the orchestrator/user chooses —
   never leaving the PR stranded:
   - **`re-run-with-key`** — fix env/network per the runbook, re-dispatch.
   - **`proceed-with-deviation`** — accept the Claude-only pass, merge.
   - **`merge-with-tracked-follow-up`** — merge now, open a tracked issue to run
     cross-family review when the path is restored.

**When a deviation is acceptable vs blocking:**

| Situation | Verdict |
|---|---|
| Change already received a cross-family critic pass at design time (e.g. Gemini `architecture-critic` / `product-critic` reviewed the design), and the diff is routine | Deviation **acceptable** → `proceed-with-deviation` or `merge-with-tracked-follow-up` |
| Low-risk diff (docs, config, tests, non-security refactor) | Deviation **acceptable** → `merge-with-tracked-follow-up` |
| **Novel crypto / auth / payment / RLS code with no prior cross-family review** | Deviation **BLOCKING** → `re-run-with-key`; do **not** merge on a Claude-only pass. Hold (no auto-merge) until the path is fixed. |

The agent recommends a verdict but **does not self-approve**: deliverable C is a
human/orchestrator decision gate, not an automatic merge.

## Alternatives considered

- **A: Keep ADR-015's literal STOP.** Rejected — it is exactly what stranded
  PR #91. STOP is right when capability is *absent*, wrong when it is *gated at
  a layer the session can't reach* with no decision handed back.
- **B: Auto-arm the call (write `settings.local.json` / relax the classifier).**
  Rejected outright — failure mode 3 is the classifier *correctly* refusing
  exfiltration enablement. Weakening it to unblock review inverts the security
  posture. The fix belongs at the environment layer, with a human in the loop.
- **C (chosen): preflight + documented environment-layer fix + logged deviation
  with a structured decision gate.** Fails fast, keeps the classifier intact,
  and never strands the PR.

## Consequences

- **Positive:** the review→merge pipeline always reaches a decision; breaks are
  surfaced in seconds, not minutes; the environment-layer fix is documented in
  one place; deviations are logged and auditable. The classifier and the
  non-Claude-family requirement are both fully intact.
- **Negative:** the two agent prompts grow a preflight + degradation section;
  `proceed-with-deviation` admits a Claude-only pass in bounded, logged cases
  (never for novel crypto/auth). Operators must set the key + allowlist at the
  environment layer to get the real cross-family pass.
- **Locked in:** ADR-015's rung-3 STOP is replaced, for the structurally-gated
  case, by "labeled deviation + structured decision." The hard STOP survives
  only as the *blocking* recommendation for novel crypto/auth with no prior
  cross-family review.

## References

- ADR-011 (Codex for the OpenAI/GPT-5.5 family) — amended here.
- ADR-015 (cloud critic fallback ladder) — amended here.
- `scripts/lib/cross-family-preflight.sh` — the probe + deviation logger.
- `docs/runbooks/cross-family-review-cloud.md` — environment-layer setup.
- `docs/CLOUD.md` — "External-model critics … in cloud."
- Agents: `reviewer`, `security-auditor`.
- Incident: Architect-for-Claude-Code PR #91 (T4b realtime).
