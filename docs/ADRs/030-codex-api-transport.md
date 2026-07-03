# ADR-030 — OpenAI review via the API by default (Codex CLI becomes an opt-in transport)

- Status: Accepted
- Date: 2026-07-03
- Revises: ADR-011 (Codex CLI as the OpenAI-family transport)
- Related: ADR-015 (cloud cross-family via env key), ADR-022 (cross-family preflight + graceful degradation), ADR-027 (Gemini API, CLI retired), ADR-028 (OpenAI Keychain backup)

## Context

The three adversarial-review roles (reviewer, security-auditor, product-critic)
reach the non-Claude OpenAI/GPT-5.5 family (ADR-011). ADR-011 reached it through
the local Codex CLI (`codex exec`); ADR-015 named the OpenAI API as a fallback
rung; ADR-022 added a preflight probe + graceful degradation. All of that assumed
the failure mode was *the CLI is absent* or *the network is blocked*. A new
failure mode breaks that assumption.

On this environment the `codex` binary is present on PATH
(`/usr/local/bin/codex`) but is **blocked at EXECUTION by an OS malware/quarantine
warning**. The failure chain:

1. `scripts/lib/cross-family-preflight.sh` → `cfp_have_cli()` tested
   `command -v codex` — PATH *presence*, not *executability* — so it returned
   `yes` and the verdict was `READY`.
2. The agent ran `codex exec`; the OS hard-blocked it as malware.
3. The agents' API-fallback rung only fired on *"codex isn't on PATH"*. Codex IS
   on PATH, so the OpenAI-API rung was never reached. Result: a dead-stop with a
   stranded PR — the exact outcome ADR-022 exists to prevent, reappearing through
   a gap ADR-022 didn't cover (a present-but-unusable binary).

A contributing cause: `scripts/lib/openai-review.sh` — the helper the API rung
would call — **did not exist**. ADR-015 told the agent it *could* "call the
OpenAI API directly over HTTP," but left the agent to hand-build the request.
There was no `oair_call` analogous to `gmn_call` (ADR-027) or `dsr_run`
(ADR-026), so the API rung was aspirational, not wired.

ADR-027 solved this class for Gemini by **retiring the CLI entirely** (the Gemini
CLI is dead — IneligibleTierError — so there was nothing to keep). Codex is
different: the CLI still works for users whose environment doesn't quarantine it,
and it bills to the Codex account rather than an API key. So the Codex fix is not
"kill the CLI" — it is "make the API the default, keep the CLI as an opt-in, and
guarantee the API as its fallback."

## Decision

Reach the OpenAI/GPT-5.5 family through the **OpenAI Chat Completions API by
default**. The Codex CLI becomes an **opt-in transport**, never the default path,
and even when opted in it **falls back to the API** on any failure.

### 1. Setting `codex_transport` (api | cli), default `api`

`api` (default) → review calls the OpenAI API; the CLI is **never invoked**,
removing the malware-block failure class. `cli` → run `codex exec`; on ANY
failure (non-zero exit, quarantine block, not-authenticated, not-installed) fall
back to the API. Opt-in CLI must never strand a PR.

### 2. New helper `scripts/lib/openai-review.sh` — the single source of truth

The transport decision + fallback live in ONE place, not branched across three
markdown agent prompts (the review-rework: no duplicated bash, no drift). Mirrors
`scripts/lib/gemini-api.sh` / `deepseek-review.sh`:

- `oair_available` — 0 if a key resolves.
- `oair_transport` — echoes `api`|`cli` (resolution below).
- `oair_call <prompt> [model] [effort]` — context on stdin appended under a
  divider, size-capped; honors the transport; prints
  `.choices[0].message.content`; on failure prints a single
  `=== OpenAI API: UNAVAILABLE — <reason> ===` line and returns non-zero
  (exit-code contract mirrors `gmn_call`/`dsr_run`).
- Key resolution delegates to `openai-key.sh` (`oai_key`: env `OPENAI_API_KEY` →
  Keychain `openai-api-key`, trimmed; ADR-028). `set +x` guards xtrace.

The three agents now just call `oair_call` and relay its output — they do **not**
branch transports or run `codex exec` themselves.

### 3. `cli` mode falls back — and preflight probes EXECUTABILITY

`oair_call` in `cli` mode runs `codex exec`; on any failure it calls the API. And
`cfp_have_cli()` now uses `codex --version >/dev/null 2>&1` (actually invoking the
binary) instead of `command -v codex`, so a quarantined/blocked codex reports
"not runnable" at **preflight** time — the ADR-022-intended detection that PATH
presence had masked.

### 4. Precedence (highest wins) — three layers

1. env `REVIEW_CODEX_TRANSPORT` — set by `/session` for the session.
2. project `.claude/stack-config.json` → `.review.codex_transport` — written by
   `/project-init`.
3. built-in default `api`.

An invalid value at any layer is ignored (falls through), never treated as a
novel transport. (A fourth `config/model-routing.json` layer was considered and
dropped — see Alternatives; the built-in default already covers the stack-wide
case, and a 2-value setting doesn't warrant four layers.)

### 5. Preflight is transport-aware

In `api` mode a runnable CLI does NOT by itself count as a usable path — `READY`
hinges on **key present + API reachable**. In `cli` mode a runnable CLI OR a key
counts (ADR-022 behavior preserved). The verdict block gains `codex_transport`
and `codex CLI runnable` lines.

### 6. Cross-family invariant enforced in the helper (ADR-011)

`oair_call` pins an OpenAI-only endpoint and **refuses a Claude-family model id**
(`oair_guard_model`, regex `claude|anthropic|opus|sonnet|haiku|fable`) — so a
stray base-URL/model override cannot silently point "cross-family" review at a
Claude endpoint. Belt-and-suspenders alongside `review-router.sh`'s `RR_CLAUDE_RE`.

### 7. Scope is Codex-only (YAGNI)

Gemini (ADR-027) and DeepSeek (ADR-026/029) are already API-only. This ADR adds
one Codex-specific setting; it deliberately does **not** build a general
cross-family transport abstraction.

### 8. Install: the codex CLI check becomes advisory

`command -v codex` in the tier-2/tier-3 manifests moves from a hard requirement /
smoke test to **advisory** (`requirements[].advisory: true` +
`advisory_smoke_tests[]`): a missing codex CLI now WARNS, never fails an install,
since the default (`api`) transport doesn't use it. Only `codex_transport=cli`
needs the binary.

Config version bumps (`config/model-routing.json` doc, `stack_version`).

## Consequences

### Positive
- The malware-block / present-but-unusable-CLI failure class is gone from the
  default path — `api` mode never touches the CLI.
- The ADR-015 API rung is finally real (`oair_call`), so even `cli` mode has a
  working fallback and can never dead-stop a PR.
- Transport logic has ONE home (`openai-review.sh`), not three markdown copies —
  no drift, testable in isolation.
- Symmetric with ADR-027 (Gemini) and ADR-026/028: every non-Claude family now
  has a `*_call`/`*_key` helper resolving a key from env-or-Keychain.
- Cross-family invariant (ADR-011) hardened: the helper refuses a Claude model.

### Negative
- OpenAI **API** spend is billed to the API key and is NOT metered into
  `cost_log` — the same gap as Codex-CLI/Gemini/DeepSeek today, but now the
  DEFAULT path incurs it (previously the Codex-CLI account was the default
  billing surface). If Codex-CLI billing is flat-rate vs. API metered-per-token,
  this can be a cost *increase*, not just a visibility loss. Flagged for the next
  /model-audit; users who prefer the Codex account can opt into
  `codex_transport=cli`.
- The preflight + helper carry a transport branch (contained to the helper).

### Neutral
- ADR-011's intent (cross-family OpenAI review) is unchanged; only the default
  transport changes. The CLI survives as a setting, unlike ADR-027's outright
  retirement.
- "codex" now names two orthogonal things: the review-tier engine
  (`RR_ENGINE=codex`, ADR-025) and this transport setting (`codex_transport`).
  The tier says *which model*; the transport says *how it is reached*.

## Alternatives considered

- **Retire the Codex CLI entirely (mirror ADR-027).** Rejected by the maintainer:
  the Gemini CLI was *dead*, so nothing was lost; the Codex CLI still works and
  bills to a separate account. Keeping it as opt-in preserves that at no cost to
  the default path.
- **Fix `cfp_have_cli` to probe executability, keep CLI as default.** Rejected as
  the primary fix: it patches this env's symptom but leaves the CLI a single
  point of failure and still needs the missing helper for any fallback. (Adopted
  as a *secondary* hardening for `cli` mode — decision 3.)
- **Four-layer precedence** (add `config/model-routing.json` as a stack default).
  Rejected: `review-router.sh`'s `rr_resolve` handles a harder problem (multi-
  model tiers) in three layers; a 2-value boolean doesn't warrant a fourth. The
  built-in `api` default covers the stack-wide case.
- **Teach the three agent prompts to branch `api`/`cli` and run `codex exec`.**
  Rejected (the critic's highest-value change): fragile raw bash duplicated
  across three markdown files, guaranteed to drift. The decision + fallback live
  in `openai-review.sh` instead.
- **Responses API (`/v1/responses`) for native `reasoning.effort`.** Rejected:
  Chat Completions matches the in-repo DeepSeek precedent (`dsr_run`); effort is
  passed best-effort via `reasoning_effort`.
- **Build a general `<family>_transport` abstraction.** Rejected (YAGNI): only
  Codex has two live transports.
