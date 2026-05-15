# Contributing to Claude Code Stack

Thanks for considering a contribution. This stack is opinionated, so PRs that change philosophy go through ADRs. PRs that add subagents, skills, or hooks within the existing philosophy can move faster.

## Philosophy (read before contributing)

See `docs/PHILOSOPHY.md` and `docs/ROUTING.md`. The short version:
- Hooks for deterministic checks. Skills for repeatable workflows. CLAUDE.md for facts code can't reveal. Cut everything else.
- Liu's test for every line in any markdown file we ship: "Would removing this cause Claude to make a mistake it couldn't recover from?" If no, cut it.
- Models match tasks, not roles. Adversarial roles MUST use different model families than what they review.

## Process

1. **For new subagents or skills:** open an issue first with the use case. We'd rather discuss before you write 200 lines.
2. **For new hooks:** include the deterministic check the hook performs and evidence of the friction it prevents.
3. **For model routing changes:** must cite a benchmark. Don't change defaults on vibes.
4. **For tier changes:** requires ADR. Tier boundaries are load-bearing.
5. **For CLAUDE.md template changes:** apply Liu's test in the PR description.

## PR checklist

- [ ] Tested locally with `./scripts/install.sh --mode=fresh --tier=<N>` in a clean dir
- [ ] `./scripts/verify.sh` passes after install
- [ ] If adding a subagent, model assignment is justified
- [ ] If adding a skill, description field clearly states trigger conditions
- [ ] CHANGELOG.md updated
- [ ] If philosophy-affecting: ADR added

## What we won't accept

- Skills that overlap existing skills without consolidating
- Subagents whose role overlaps an existing subagent
- CLAUDE.md additions that fail Liu's test
- Hooks that block instead of warn without a strong rationale
- Anything that hardcodes a specific user's environment

## Code of conduct

See `CODE_OF_CONDUCT.md`. Be kind. Disagree with ideas, not people.
