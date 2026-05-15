# Claude Code Stack

A tiered, opinionated configuration of Anthropic's Claude Code, designed for technical users who want a multi-agent development team rather than a single AI assistant.

**Status:** Private development. Open-source release planned post-audit.

## What this is

21 specialized subagents covering the full software development lifecycle, multi-provider model routing (Anthropic, OpenAI, Google, optional local Ollama), self-improving via monthly audits, and 5 installation tiers from "stop repeating mistakes" to "set it and forget it" enterprise.

## Quick start

```bash
git clone git@github.com:bschonbrun/claude-code-stack.git
cd claude-code-stack
./scripts/install.sh --tier=0   # foundation only
# or
./scripts/install.sh --tier=5 --include-ollama=laptop   # everything
```

## Tiers

| Tier | Name | Time | Adds |
|---|---|---|---|
| 0 | Foundation | 5 min | Friction-killer hooks + handoff skills |
| 1 | Discipline | 30 min | Plan/cost-gate/validate-output skills |
| 2 | Team | 2-3 hr | 12 subagents + foreman + cost log |
| 3 | Specialist Bench | 1-2 hr | 9 more subagents + multi-provider |
| 4 | Self-Improving | 1 hr | Monthly audits + perf reviews |
| 5 | Local + Offline | varies | Ollama integration |

Each tier is fully functional standalone. See `docs/INSTALL.md` for details.

## Documentation

- `docs/PHILOSOPHY.md` — why this exists, what it optimizes for
- `docs/ARCHITECTURE.md` — system architecture
- `docs/ROUTING.md` — hook vs skill vs CLAUDE.md decision rule
- `docs/MODEL-STRATEGY.md` — which model does what and why
- `docs/HARDWARE.md` — laptop sizing for Tier 5
- `docs/PROVIDERS.md` — API setup per provider
- `docs/ADRs/` — architecture decision records

## Contributing

See `CONTRIBUTING.md`. PRs welcome once the repo opens publicly.

## License

Apache 2.0. See `LICENSE`. Rationale in `docs/ADRs/001-license-apache-2.md`.
