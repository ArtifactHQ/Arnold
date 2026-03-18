# Decision 001: Arnold v2 Expansion Scope

**Date:** 2026-03-18
**Who Decided:** Chris Sotraidis + Claude
**Status:** Accepted

---

## The Situation

After hands-on testing of Arnold Lite (March 16, 2026), a comprehensive expansion plan was drafted identifying 10 issues and proposing 7 new commands plus structural changes. The plan was thorough but risked doubling Arnold's surface area from 11 to 18+ commands, threatening the simplicity that makes Arnold effective.

Arnold's core value proposition is: pure markdown prompts, no runtime, installs in 2 minutes, 11 commands that cover the full docs-first lifecycle. Any expansion needs to preserve that simplicity.

## What We Chose

**3 new commands + 4 enhanced commands** — a selective, consolidated approach.

### New Commands

| Command | Purpose | Why It's Needed |
|---------|---------|-----------------|
| `/arnold:bug` | Structured bug recording with severity, repro steps, affected feature | Bugs were being shoehorned into `unknowns.md`, which is meant for open questions. Fundamentally different item types need different tracking. |
| `/arnold:archive` | Move stale/reference docs to `docs/archive/` or `docs/reference/` | No doc lifecycle management existed. Active, reference, and archived docs were indistinguishable. Supports `--reference` flag for informational-but-not-authoritative docs. |
| `/arnold:milestone` | Define and track phased work with feature rollup | Projects with implementation phases had no way to track milestone-level progress. Phases were manually added to `status.md` as a table with no rollup. |

### Enhanced Commands

| Command | Enhancement | Why |
|---------|-------------|-----|
| `/arnold:diff` | Truly incremental — git-diff-based, only checks files changed since last snapshot | Was too similar to a mini `/arnold:check`. Needs to be fast enough for "did I break anything?" after a small change. |
| `/arnold:update` | Add `--quick` batch mode for post-sprint catch-up | During rapid development, docs fall behind immediately. Quick mode scans recent git changes and presents batch status updates for fast confirmation instead of one-by-one. |
| `/arnold:init` + `/arnold:spec` | Feature-prefixed filenames (e.g., `tts-overview.md` not `overview.md`), milestone support in templates | Ambiguous `overview.md` filenames caused confusion during testing — can't tell which feature without navigating to the folder. |
| `/arnold:status` | Show bug count, milestone progress, feature request count | Status needs to surface information from the new tracking structures (issues, milestones, requests). |

### Structural Changes

| Change | Description |
|--------|-------------|
| `docs/issues/` folder | Structured bug tracking — severity, symptom, cause, affected feature, fix, status |
| `docs/requests.md` | Feature requests separated from unknowns |
| `docs/archive/` folder | First-class archive for stale docs |
| `docs/reference/` folder | First-class reference for legacy informational docs |
| `docs/milestones.md` | Phase and milestone tracking with feature rollup |
| Feature-prefixed filenames | Default to `tts-overview.md` instead of `overview.md` in templates |
| Item type separation | Bugs, feature requests, and unknowns tracked in their own structures |

## What We Rejected

### Rejected: Separate `/arnold:quick-update` + `/arnold:catch-up` commands
**Why rejected:** Both are "lighter update." Adding two new commands for variations of the same action bloats the command list. Instead, we enhanced `/arnold:update` with a `--quick` flag. One command, two modes.

### Rejected: Separate `/arnold:reference` command
**Why rejected:** Reference docs and archived docs are both about doc lifecycle. One command (`/arnold:archive`) with a `--reference` flag covers both without adding another entry to the command list.

### Rejected: Per-platform status tracking
**Why rejected:** Too project-specific. Not all projects are multi-platform. Users who need Android/Desktop/Frontend tracking can add platform sections manually to their feature overviews. Arnold shouldn't assume project topology.

### Rejected: Code review integration (pre-commit hooks, CI)
**Why rejected:** Arnold is a pure prompt toolkit — no runtime, no server, no background process. CI integration requires infrastructure that's outside Arnold's design. This is Arnold Engine territory (the separate, private server component).

### Rejected: Automatic status inference
**Why rejected:** Requires reliable file-to-feature mapping that doesn't exist. Too fragile — false positives would erode trust. Users explicitly marking status is more reliable than guessing.

## Consequences

- Arnold grows from 11 to 14 commands (27% increase, not 64%)
- install.sh must be updated to handle 3 new command files
- CLAUDE.md template must reflect new doc structure (issues/, archive/, reference/, milestones.md, requests.md)
- README must be updated with new commands and structure
- Help command must be updated
- Example project (fitness-studio-booking) should demonstrate new structures
- The `--quick` flag on update and `--reference` flag on archive establish a pattern for command variants via flags rather than new commands

## Implementation Priority

1. **Feature-prefixed filenames** — template change across init/spec/plan (low effort, immediate clarity)
2. **`/arnold:bug`** — new command + `docs/issues/` structure
3. **`/arnold:diff` fix** — make it truly incremental via git diff
4. **`/arnold:update --quick`** — batch mode enhancement
5. **`/arnold:archive`** — doc lifecycle management
6. **`/arnold:milestone`** — phase tracking
7. **`/arnold:status` enhancement** — surface new tracking data
8. **Structural updates** — CLAUDE.md template, install.sh, README, help, example
