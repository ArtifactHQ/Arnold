# Design: Preview Mode & Doctor Command

**Date:** 2026-02-18
**Status:** Approved

## Overview

Two DX features to reduce Arnold's time-to-first-value:

1. **`arnold run "..." --preview`** — Zero-config preview that generates spec + tasks with just a gem install and an API key
2. **`arnold doctor`** — Environment health checker that reports pass/fail/warn for all dependencies

## Phase 1: `--preview` Mode

### Problem

New users must configure an execution provider (GitHub token + repo, or Claude Code CLI + repo path) before seeing any value from Arnold. The core intellectual value — spec generation and task decomposition — requires none of that infrastructure.

### Design

**`--preview` wires three existing mechanisms together:**

1. Auto-set `execution_provider: :null` when `--preview` is passed
2. Auto-set `stop_after: :tasks` when `--preview` is passed
3. Skip execution-related config validation in preview mode
4. Print formatted spec + task breakdown to stdout

**Interactive API key setup** (when no key found in preview mode):

- Detect missing key before pipeline starts
- Use `tty-prompt` gem for masked input and provider selection
- Offer to save to `~/.arnold_pipeline/config.yml`

**Config file auto-loading** (new capability):

- On every CLI invocation, check for `~/.arnold_pipeline/config.yml`
- Load as base config (lowest priority)
- Layering order: `~/.arnold_pipeline/config.yml` < `--config FILE` < CLI flags < env vars

**Output format** (stdout):

```
--- Arnold Preview ---

-- Specification --
[full spec markdown]

-- Tasks (12 tasks, 4 tiers) --
Tier 0:
  1. [Setup database schema] - Create SQLite tables for...
  2. [Initialize Rails app] - ...
Tier 1:
  3. [User authentication] - ... (depends on: 1, 2)
  ...

--- Preview complete. Run without --preview to execute. ---
```

### Key Decisions

- **Stdout only** — no file output by default (pipe-friendly, no cleanup)
- **tty-prompt** for interactive key prompting (masked input, provider menu)
- **`~/.arnold_pipeline/config.yml`** for saved config (consistent with existing `~/.arnold_pipeline/pipeline.sqlite3`)

## Phase 2: `arnold doctor`

### Problem

When `arnold run` fails due to missing dependencies, users get raw stack traces instead of actionable guidance. There's no single command to verify environment readiness.

### Design

**New Thor subcommand** that checks environment readiness.

**Checks:**

| Check | Pass | Warn | Fail |
|-------|------|------|------|
| Ruby version | >= 3.2 | < 3.2 but >= 3.0 | Not found |
| Git | Available | -- | Not found |
| API keys | ANTHROPIC or OPENAI key in env or config | -- | Neither found |
| SQLite | Available | -- | Not found |
| Node.js | >= 18 | < 18 but present | -- (optional) |
| OpenSpec CLI | Installed | -- | -- (optional) |
| Claude Code CLI | Installed | -- | -- (optional) |

Each failing/warning check includes a one-line fix command.

**Output format** (flutter doctor style):

```
Arnold Doctor
--------------
[pass] Ruby 4.0.0
[pass] Git 2.43.0
[pass] API key: ANTHROPIC_API_KEY configured
[pass] SQLite3 available
[warn] Node.js 16.0.0 - recommend >= 18 for OpenSpec
       -> brew install node
[fail] OpenSpec CLI not found (optional - needed for spec merging)
       -> npm install -g @fission-ai/openspec
[pass] Claude Code CLI installed

6 checks passed, 1 warning, 1 optional missing
```

**Error path integration:**

- Append `Run 'arnold doctor' to check your setup` to config/provider errors in `with_error_handling`

### Implementation Notes

- Simple `which`-based checks via shell + `ENV` reads + version parsing
- No new dependencies — uses existing Thor CLI infrastructure
- Exit code 0 if all required checks pass, 1 if any required check fails
