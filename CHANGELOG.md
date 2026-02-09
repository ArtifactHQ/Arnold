# Changelog

All notable changes to Arnold Pipeline will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- CLI commands: `run`, `resume`, `status`, `list`, `spec`, `version`
- Standalone CLI with automatic SQLite database at `~/.arnold_pipeline/`
- YAML config file support via `--config` flag
- Partial execution with `--stop-after` (spec, tasks, executed)
- Resume paused or failed pipeline runs
- Tiered task execution with dependency ordering
- Tier gate checking with corrective task retries
- Context propagation between tiers
- Workflow status checking before task resolution
- `--json` output for `list` and `status` commands
- GitHub Actions CI workflow
- Anthropic and OpenAI LLM provider support
- GitHub execution provider with issue creation, PR polling, and merge

## [0.1.0] - Unreleased

Initial release.
