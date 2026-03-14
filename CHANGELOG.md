# Changelog

All notable changes to Arnold will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- `/arnold:decide` command for recording architectural and product decisions in docs/decisions/
- Strengthened `/arnold:check` with vague-docs detection, flow tracing, env var handling, provenance-based prioritization
- `/arnold:resolve` — interactively fix drift items (choose docs or code)
- `/arnold:recap` — start-of-session briefing with project context
- Drift trend tracking in `/arnold:check` (Check History table in status.md)
- Team onboarding: `/arnold:init` now creates `docs/ABOUT.md` for new team members
- `/arnold:update` now reads previous check findings to propose targeted drift fixes
- Improved post-init guidance (nudges user toward first check)

### Fixed
- install.sh now installs `/arnold:help` (was missing from COMMANDS array)
