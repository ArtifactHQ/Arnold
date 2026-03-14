# Arnold Lite — Claude Code Project Instructions

## What This Project Is

Arnold is a **documentation-first development toolkit** that runs as a native Claude Code extension. It helps developers write product requirements in plain English, organize them as structured markdown docs next to their code, and then check whether the code matches the docs (detecting "documentation drift").

- **Internal name:** Arnold Lite
- **Public name:** Arnold
- **Built by:** Artifact (https://artifact.new)
- **Authors:** Chris Sotraidis + Claude

## What It Ships

- **5 slash command files** in `commands/arnold/` (legacy) and `skills/` (plugin) — meta-prompts for generating, maintaining, and checking project docs
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

Arnold ships both `commands/` (for install.sh) and `skills/` (for the Claude Code plugin). Both contain the same prompts. `skills/` takes precedence in Claude Code if both are active.

```
arnold/
├── .claude-plugin/
│   ├── plugin.json                        # Plugin manifest (name: arnold)
│   └── marketplace.json                   # Self-contained marketplace
├── README.md                              # Project pitch and install instructions
├── LICENSE                                # MIT
├── install.sh                             # Shell installer (any AI tool)
├── CLAUDE.md                              # Template (installed into user projects)
├── CONTRIBUTING.md                        # Contributor guidelines
├── commands/                              # Legacy commands (for install.sh path)
│   └── arnold/
│       ├── init.md                        # /arnold:init
│       ├── plan.md                        # /arnold:plan
│       ├── check.md                       # /arnold:check
│       ├── update.md                      # /arnold:update
│       └── status.md                      # /arnold:status
├── skills/                                # Plugin skills (for Claude Code plugin path)
│   ├── init/SKILL.md                      # /arnold:init (auto-namespaced by plugin)
│   ├── plan/SKILL.md                      # /arnold:plan
│   ├── check/SKILL.md                     # /arnold:check
│   ├── update/SKILL.md                    # /arnold:update
│   ├── status/SKILL.md                    # /arnold:status
│   └── arnold-rules/SKILL.md             # Background knowledge (user-invocable: false)
├── examples/
│   └── fitness-studio-booking/            # Worked example with full doc set
└── docs/
    ├── ARNOLD-LITE-BUILD-SPEC.md          # Master build specification
    └── PLUGIN-MIGRATION-PLAN.md           # Plugin & cross-agent strategy
```

## Slash Commands

| Command | Purpose |
|---------|---------|
| `/arnold:init` | Scaffold a `docs/` folder from a project description |
| `/arnold:plan` | Generate or refine feature docs, identify gaps |
| `/arnold:check` | Compare docs to code — find drift, missing docs, undocumented code |
| `/arnold:update` | Sync docs after coding — propose updates based on changes |
| `/arnold:status` | Quick snapshot — what's done, in progress, blocked |

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
4. `commands/arnold/init.md`
5. `commands/arnold/status.md`
6. `commands/arnold/plan.md`
7. `commands/arnold/check.md` (most complex — the signature feature)
8. `commands/arnold/update.md`
9. `examples/fitness-studio-booking/` (all doc files)
10. End-to-end test: install → init → plan → check → update
