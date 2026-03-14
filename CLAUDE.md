# Arnold Lite — Claude Code Project Instructions

## What This Project Is

Arnold is a **documentation-first development toolkit** that runs as a native Claude Code extension. It helps developers write product requirements in plain English, organize them as structured markdown docs next to their code, and then check whether the code matches the docs (detecting "documentation drift").

- **Internal name:** Arnold Lite
- **Public name:** Arnold
- **Built by:** Artifact (https://artifact.new)
- **Authors:** Chris Sotraidis + Claude

## What It Ships

- **5 slash command files** (`.claude/commands/*.md`) — meta-prompts for generating, maintaining, and checking project docs
- **1 CLAUDE.md template** — rules file encoding the doc-centered philosophy
- **1 install script** (`install.sh`) — one-line installer that copies commands into any project
- **1 README** — the pitch, how-to, and install instructions
- **1 worked example** (`examples/fitness-studio-booking/`) — complete project with 15-20 doc files showing the system in action

## What It Is NOT

- Not a server, database, or background process
- Not an MCP server
- Not something that requires Ruby, Python, Node, or any runtime
- Not an agentic loop
- Not automated drift detection (Arnold Engine is separate and private)

## Key Constraints

- Works with Claude Max subscription — NO separate API key required
- Installs in under 2 minutes
- No build step, no dependencies
- Jurassic Park personality ("Hold on to your docs." / 🦕)
- Docs organized by feature, not by type

## Master Spec

The complete build specification lives at `docs/ARNOLD-LITE-BUILD-SPEC.md`. This is the PRD and single source of truth for everything that needs to be built. Refer to it for exact file contents, prompt engineering, templates, and edge cases.

## Repository Structure (Target)

```
arnold/
├── README.md                              # Project pitch and install instructions
├── LICENSE                                # MIT
├── install.sh                             # One-line installer
├── CLAUDE.md                              # This file (also serves as template)
├── commands/
│   ├── init.md                            # /init — scaffold docs
│   ├── plan.md                            # /plan — generate/refine specs
│   ├── check.md                           # /check — compare docs to code (key feature)
│   ├── update.md                          # /update — sync docs after coding
│   └── status.md                          # /status — quick project overview
└── examples/
    └── fitness-studio-booking/            # Worked example with full doc set
```

## Slash Commands

| Command | Purpose |
|---------|---------|
| `/init` | Scaffold a `docs/` folder from a project description |
| `/plan` | Generate or refine feature docs, identify gaps |
| `/check` | Compare docs to code — find drift, missing docs, undocumented code |
| `/update` | Sync docs after coding — propose updates based on changes |
| `/status` | Quick snapshot — what's done, in progress, blocked |

## Doc Organization Philosophy

Docs are organized **by feature** (like a wiki), not by document type (like a filing cabinet):

```
docs/
├── overview.md           # Project north star
├── status.md             # Current state
├── [feature-name]/       # One folder per feature
│   ├── overview.md       # What it does, core rules
│   ├── [flow].md         # Step-by-step user flows
│   └── edge-cases.md     # Error handling, unusual scenarios
├── decisions/            # Why we chose what we chose
└── unknowns.md           # Open questions and bets
```

## Conventions

- Feature folder names: lowercase, hyphen-separated (`auth/`, `calendar-sync/`)
- Named by what the feature IS, not what it does (`auth` not `login`)
- Status markers: 🟢 Implemented, 🟡 In Progress, 🔵 Not Started, 🔴 Drifted, ❓ Unknown
- Source provenance: (user-stated), (domain-derived), (Arnold-inferred), (decided)
- Decision records: auto-numbered `001-title.md`, `002-title.md`
- Personality: Jurassic Park themed, 🦕 used exactly twice per command output (start + end)

## Build Order

1. `README.md` + `LICENSE`
2. `install.sh`
3. `CLAUDE.md` (template for target projects)
4. `commands/init.md`
5. `commands/status.md`
6. `commands/plan.md`
7. `commands/check.md` (most complex — the signature feature)
8. `commands/update.md`
9. `examples/fitness-studio-booking/` (all doc files)
10. End-to-end test: install → init → plan → check → update
