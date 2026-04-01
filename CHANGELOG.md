# Changelog

All notable changes to Arnold will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-04-01

### Added
- /arnold:feature — feature completeness matrix, deep status, or deep plan with completion enforcement
- /arnold:build — build code from docs with criterion-to-code verification gate
- /arnold:review — critique docs for usability, product, and technical quality (three lenses)
- docs/spec.md — new technical specification file separating tech decisions from product requirements
- sync-skills.sh — generates skills/ from commands/ to eliminate dual-maintenance
- Completeness gates in /arnold:spec (Step 4.5) and /arnold:plan (Step 6.5)
- Spec auto-archive (Step 5.5) — moves source spec to docs/reference/ after decomposition
- Tech stack split — /arnold:spec generates docs/spec.md, feature docs stay tech-agnostic
- Acceptance criteria section added to feature overview template
- Troubleshooting section in /arnold:help for collision detection
- Contextual hint in /arnold:status suggesting /arnold:recap for recent changes

### Changed
- /arnold:check now verifies code against docs/spec.md tech stack (Step 3.5)
- /arnold:decide offers to update docs/spec.md for technology decisions
- /arnold:init brownfield path generates docs/spec.md from codebase scan (Step B3.5)
- /arnold:plan flags tech decisions mixed into feature docs
- install.sh updated to install all 17 commands (was 14)
- CONTRIBUTING.md updated to reference sync-skills.sh workflow
- Doc structure diagrams updated across all files to include spec.md
- Version bumped to 0.4.0 across install.sh, plugin.json, marketplace.json

### Fixed
- CLAUDE.md template doc structure now uses consistent [feature-name]-overview.md format
- Stale build spec (v0.1) moved to docs/reference/ with reference header
- Duplicate ARNOLD-RALPH-INTEGRATION-PLAN.md removed (kept only in docs/reference/)
- Planning docs (update plan, migration plan) archived to docs/reference/
- Example fitness-studio-booking CLAUDE.md updated to v0.4.0 template

## [0.3.0] - 2026-03-18

### Added
- /arnold:bug — structured bug recording in docs/issues/ with severity, repro steps, auto-numbering
- /arnold:milestone — define and track phased work with feature rollup status
- /arnold:archive — move stale docs to docs/archive/ or reference docs to docs/reference/
- /arnold:update --quick — batch mode for rapid post-sprint doc sync
- New doc structure: docs/issues/, docs/archive/, docs/reference/, docs/milestones.md, docs/requests.md
- Milestone progress rollup in /arnold:status
- Bug and feature request counts in /arnold:status
- Decision record: docs/decisions/001-v2-expansion-scope.md documenting expansion choices

### Changed
- Feature-prefixed filenames: docs/auth/auth-overview.md instead of docs/auth/overview.md
- /arnold:diff rewritten for truly incremental scanning (3 detection paths based on available data)
- /arnold:status shows milestones, bugs, and requests sections (when present)
- arnold-rules background skill updated with full command list and expanded doc structure
- Version bumped across install.sh, plugin.json, marketplace.json

## [0.2.0] - 2026-03-14

### Added
- /arnold:spec — decompose a spec/PRD into feature-based docs
- /arnold:diff — quick lightweight drift scan without full check
- Drift trend tracking in /arnold:check (Check History table in status.md)
- Context-aware /arnold:help with personalized suggestions
- Monorepo detection and multi-package support in /arnold:init
- Team onboarding: /arnold:init creates docs/ABOUT.md for new team members
- Check-to-update pipeline: /arnold:update reads previous check findings

### Improved
- /arnold:check: vague-docs quality gate, flow tracing, env var handling
- /arnold:check: provenance-based drift prioritization (user-stated first)
- /arnold:init: double-run protection, empty docs/ handling
- /arnold:init: improved brownfield post-init guidance
- install.sh: plugin detection, CLAUDE.md source fix, Ctrl-D handling

### Fixed
- install.sh: help.md was advertised but never installed
- install.sh: CLAUDE_MD_SOURCE used user's own file during curl install
- Removed invalid AskUserQuestion from allowed-tools

## [0.1.0] - 2026-03-14

### Added
- 9 slash commands: `/arnold:init`, `/arnold:plan`, `/arnold:check`, `/arnold:update`, `/arnold:status`, `/arnold:decide`, `/arnold:resolve`, `/arnold:recap`, `/arnold:help`
- Claude Code plugin support (`.claude-plugin/plugin.json` + marketplace)
- Agent Skills format (`skills/`) for cross-agent compatibility
- Shell installer (`install.sh`) with install, uninstall (`--uninstall`), and upgrade support
- CLAUDE.md template with documentation-first development rules
- Brownfield project detection in `/arnold:init` (scans existing codebases)
- Feature scoping via `$ARGUMENTS` for plan, check, and update commands
- Pre-init guards on all commands (graceful error if docs/ missing)
- Worked example: fitness studio booking platform with 17 doc files
- Background knowledge skill (`arnold-rules`) for plugin users
- Marker-based CLAUDE.md injection/removal for clean install/uninstall

### Fixed
- install.sh now installs `/arnold:help` (was missing from COMMANDS array)
