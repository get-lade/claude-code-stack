# Changelog

All notable changes to the Claude Code Stack are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning is [SemVer](https://semver.org/).

## [Unreleased]

## [1.0.0] — 2026-05-15

### Added
- Initial stack release: Tiers 0-5
- 21 subagent definitions
- 15 skills
- 6 hooks
- Multi-provider model routing (Anthropic, OpenAI, Google, Ollama)
- Self-improvement skills (model-audit, agent-performance-review)
- Per-project tier selection via /project-init
- Strict mode foreman orchestration
- Apache 2.0 license
- 8 initial ADRs

### Notes
- Tier 4 self-improvement requires 30 days of subagent_runs data to be meaningful
- Phase 2 (Claude Code Plugin distribution) deferred until v1 proven across the maintainer's 7 production repos
