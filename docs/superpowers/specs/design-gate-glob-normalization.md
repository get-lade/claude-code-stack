# Spec: design-gate approved_paths glob normalization

**Date:** 2026-07-12 · **Origin:** SpecOps session 2026-07-12 (two recurring marker-authoring bugs)

## Problem

`hooks/design-gate.sh` matches `approved_paths` globs against the **absolute**
file path from the hook payload using a bash `case` statement. Two authoring
mistakes silently never match:

1. **Bare relative globs** — `"lib/data/readings.ts"` never matches
   `/Users/.../repo/lib/data/readings.ts`. Every entry needed a `**/` or `*/`
   prefix the author had to remember.
2. **Next.js dynamic segments** — `"app/sites/[deviceId]/page.tsx"` is parsed
   as a bash character class (`[deviceId]` = one char of that set), so it
   never matches the literal directory name.

Both fail silently: the implementer gets the generic "no approved design"
denial with no hint the marker was *almost* right.

## Design

Normalize inside the glob loop (hook only; marker format unchanged):

1. **Bracket escaping (default):** rewrite `[` → `\[`, `]` → `\]` before
   matching, so brackets are literal. Marker authors who genuinely want char
   classes opt in with top-level `"glob_char_classes": true`.
2. **Relative-glob fallback:** after trying the glob as written, if it starts
   with neither `/` nor `*`, also try `*/<glob>`. In `case` patterns `*`
   crosses `/`, so this matches the path at any depth. Trying the original
   first preserves back-compat with relative file paths (existing tests).
3. **Diagnostic denial:** when the marker is active and path-scoped but no
   glob matches, deny with a message naming the target path, the tried globs,
   and any near-miss (a bracketed glob that would match if `[ ]` were literal
   while `glob_char_classes` is on).

## Success criteria

`tests/test-design-gate-globs.sh` passes, covering: bare relative glob,
`**/`-prefixed glob, `[deviceId]` segment, `(dashboard)` route group, combined
path, relative-FP back-compat, scoped denial message content, near-miss hint,
and `glob_char_classes` opt-in. Existing `test-loop-engineering.sh` gate tests
stay green. Installed copy at `~/.claude/hooks/design-gate.sh` synced.
