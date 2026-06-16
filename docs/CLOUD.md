# Cloud sessions (Claude Code on the web + iOS)

How to make the stack's custom skills/commands (`/goodmorning`, `/handoff`,
`/foreman`, …) work in Claude Code **cloud** sessions — not just the Mac
Desktop app.

## Why this is needed

The Mac Desktop app runs Claude Code locally and reads your real home
directory: `~/.claude/skills/` and `~/.claude/commands/`. That's where your
personal commands live, so they "just work."

**Cloud sessions (web/iOS) run in an isolated, ephemeral container.** The repo
is cloned fresh at container start, but your laptop's `~/.claude` is **never**
synced up. A cloud session only ever sees skills/commands from two places:

1. **The repo itself** — anything committed under the repo's `.claude/`
   (`.claude/skills/<name>/SKILL.md`, `.claude/settings.json`, `.claude/hooks/…`).
   Cloned with the repo; works on every surface.
2. **The container's `~/.claude/`** — starts essentially empty, and is only
   populated by whatever the environment's **SessionStart setup script** runs
   at boot.

That's the whole reason a project-committed skill works in cloud but a personal
`~/.claude/` skill does not.

> **Note on terminology:** in this stack, every slash command *is* a skill
> (`skills/<name>/SKILL.md`). There is no separate `commands/` directory.
> `/goodmorning`, `/handoff`, etc. are all skills. When the docs say
> "skills/commands," they mean these SKILL.md directories.

## The repo is public → no token, no secrets

The stack repo is **public**, so the bootstrap clones it **anonymously**. There
is no `CLAUDE_STACK_REPO_TOKEN` to set, no environment secret, and nothing
secret committed anywhere. (If the repo is ever made private again, set
`CLAUDE_STACK_REPO_TOKEN` on the environment; the bootstrap will pick it up via
`GIT_ASKPASS`. Otherwise ignore it.)

## Two distribution paths

| Path | Mechanism | Scope | Set up where |
|---|---|---|---|
| **B. Repo-driven (recommended)** | `/project-init` commits a bootstrap hook + portable-core skills into the repo's `.claude/` | **One** repo, travels with it | Per repo, via `/project-init` — **nothing** on the environment |
| **A. Environment-wide (optional)** | A setup script on the environment clones this repo and runs `install.sh` into `~/.claude` | **Every** cloud session using that environment | Once per environment, in the web UI |

Path B is the primary, fully repo-driven flow: the stack sets each repo up and
the repo self-installs in cloud with **zero** environment configuration. Path A
is an optional convenience if you'd rather configure an environment once than
run `/project-init` per repo — but note cloud environments are configured
**individually**, so Path A must be repeated for each environment.

Both paths run the **same** logic — `scripts/cloud-bootstrap.sh` → anonymous
clone → `install.sh --tier=2 --skip-requirements` (idempotent: backs up
`~/.claude`, deep-merges JSON, user wins on conflict). They share a per-boot
marker (`/tmp/.claude-stack-cloud-bootstrap.done`), so if both fire, the first
wins and the second no-ops.

---

## Path A — register the environment setup script (covers every repo)

Setup scripts are configured **per environment**, not stored in a target repo.
See the official docs:
<https://code.claude.com/docs/en/claude-code-on-the-web>.

### 1. Confirm the network policy allows the clone

The clone needs the environment's **network policy** to permit outbound git to
GitHub (the default allowlist does). If a restricted policy blocks it, the
bootstrap warns and exits 0 — the session still works, just without the stack.

### 2. Register the setup script

Run **`/cloud-setup`** in any local session to print these steps plus the
one-liner, or paste this directly into the environment's **Setup script** field
and **Save**. No token, no env vars — the repo is public, so the clone is
anonymous:

```bash
rm -rf /tmp/ccs && git clone --depth 1 https://github.com/bschonbrun/claude-code-stack /tmp/ccs && bash /tmp/ccs/scripts/install.sh --tier=2 --skip-requirements
```

`install.sh --mode=merge` (default) backs up `~/.claude` and deep-merges, so
re-running each session boot is safe. Change `--tier=2` to pick a tier. This is
the same install the committed [`scripts/cloud-bootstrap.sh`](../scripts/cloud-bootstrap.sh)
runs (that variant adds retries and an idempotency marker, used by Path B).

Repeat per environment — cloud environments are configured individually.

---

## Path B — make a single repo self-bootstrap (no env config)

Run `/project-init` in the target repo and accept the **cloud-session support**
prompt. It commits, idempotently:

- `.claude/hooks/cloud-bootstrap.sh` — a copy of this repo's bootstrap.
- A `SessionStart` entry in `.claude/settings.json` that runs it.
- A **portable-core** skill set (`config/portable-core-skills.json`:
  `goodmorning`, `handoff`, `operating`, `project-init`) copied into
  `.claude/skills/` so the core workflow exists even before the clone finishes
  or if the network policy blocks it.

No token or environment config is needed — the full stack arrives via an
anonymous clone of the public repo, and the committed portable-core skills work
even if the network policy blocks the clone.

---

## External-model critics (Codex / Gemini) in cloud

The adversarial-review agents reach a **non-Claude model family** on purpose
(ADR-011, ADR-012): `reviewer`, `security-auditor`, `product-critic` use
OpenAI/GPT-5.5 (the `codex` CLI); `red-team`, `architecture-critic`, `historian`
use Gemini (the `gemini` CLI). What the gate requires is the *model*, not the
*binary*.

**In cloud, the keys belong in the environment's variables.** That is the
intended mechanism — set `OPENAI_API_KEY` and/or `GEMINI_API_KEY` in the cloud
environment's variable settings (web UI), the same place you set any secret for
a cloud session. Do **not** avoid this; the agents are built to consume them.

What happens at session start and at agent runtime:

- **Bootstrap install (best-effort).** [`scripts/cloud-bootstrap.sh`](../scripts/cloud-bootstrap.sh)
  checks each key with `printenv` and, when present, installs the matching CLI
  (`npm i -g @openai/codex` / `@google/gemini-cli`) so the critic gate runs
  natively. A failed install never blocks the session.
- **Agent fallback ladder.** Even if the bootstrap didn't install them, each
  critic agent walks: CLI on PATH → else key in env (`printenv OPENAI_API_KEY` /
  `printenv GEMINI_API_KEY`) → reach the model another way (ad-hoc
  `npm i -g …`, or call the API directly over HTTP) → STOP **only** if both the
  CLI and the key are absent. See ADR-015.

**"CLI missing" ≠ "capability missing."** A cloud session with the keys set but
the CLIs not preinstalled is fully capable; the gate must not declare itself
unavailable. `printenv` is how to detect the keys.

---

## Verify `/goodmorning` resolves in a fresh cloud session

1. Start a fresh cloud session (web or iOS) on the repo.
2. The SessionStart bootstrap should print an install log (the same one
   `install.sh` emits). Confirm it ends with `All checks passed.`
3. In the session, run a quick check:
   ```bash
   ls ~/.claude/skills/goodmorning/SKILL.md && echo "goodmorning present"
   ```
4. Type `/goodmorning`. It should resolve and run the boot summary.

If it doesn't resolve:
- **No install log at all** → the setup script isn't registered (Path A) or the
  repo's hook isn't committed/executable (Path B).
- **`could not clone … after 3 attempts`** → the network policy is blocking
  GitHub. (The committed portable-core skills still work.)

---

## Should we package this as a Claude Code plugin instead?

**Recommendation: not yet — and a plugin would not replace the bootstrap
anyway.** Reasoning:

- **A plugin doesn't solve the cloud problem on its own.** The container starts
  with an empty `~/.claude`. A plugin would still have to be *installed* at
  session start — i.e. you'd still need a setup-script step
  (`claude plugin marketplace add … && claude plugin install …`). And a
  **private** marketplace needs the same token handling we just built. So the
  bootstrap (or its equivalent) is required either way; the plugin would only
  change the *install command*, not remove the setup step.
- **ADR-007 already deferred plugins until "v1 proven,"** and
  [`PHASE-2-PLUGIN.md`](./PHASE-2-PLUGIN.md) lists the triggers (Tier 4 live
  30+ days, repos audited, no breaking changes for 2 weeks, privacy scrub,
  polished README). Those gates haven't been met. Converting now trades a
  working, iterable git-clone flow for an opinionated format mid-iteration.
- **What we built is plugin-compatible.** When the Phase-2 triggers hit, the
  cloud story becomes a one-line swap inside the *same* setup script: replace
  the `git clone … && install.sh` step with `claude plugin install …`. The
  token mechanism, network-policy caveat, idempotency marker, and `/project-init`
  wiring all carry over.

**Verdict:** keep the git-clone bootstrap as the cloud mechanism now; revisit
the plugin packaging as part of Phase 2, at which point it's an install-command
swap rather than a re-architecture.
