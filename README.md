# Arnold Pipeline

Arnold Pipeline is a Ruby gem that orchestrates AI coding agents through a structured, multi-stage workflow. Give it a natural language description of an application; it generates a specification, breaks it into dependency-ordered tasks, dispatches those tasks to a pluggable execution backend (GitHub Issues + Copilot/Actions, Claude Code CLI, or your own), validates results through tier gate checks, and iterates via an analysis feedback loop until the implementation aligns with the spec — or flags low-confidence decisions for human review.

Arnold is not another AI code editor. It doesn't write code itself. It automates the methodology that separates good AI-assisted development from chaotic AI-assisted development: structured specs, dependency-ordered execution, quality gates between tiers, and iterative refinement. The actual code generation happens through whatever coding agent you plug in.

## How the Pipeline Works

```
NL Input
  |
  v
Library Manager ── find persona + recipe
  |
  v
Spec Generator ── NL + persona + recipe --> OpenSpec-format Markdown (### Requirement: headers, GIVEN/WHEN/THEN scenarios, [REQ-*] IDs)
  |
  v
Task Breaker ── spec --> 5-20 ordered tasks (JSON)
  |
  v
Executor ── tasks --> execution provider
  |            GitHub: create Issues, poll for PR diffs (exponential backoff)
  |            Claude Code: run CLI in worktrees, capture diffs immediately
  |            (receives prior tier context when context_propagation_enabled)
  v
Tier Gate Check ── diffs --> pass/fail + context summary (per tier)
  |                          fail --> corrective tasks + retry (up to max_tier_retries)
  |                          still failing --> pause for human review
  v
Analyzer ── diffs + spec --> decision + confidence
  |
  |-- "done" (>=70% confidence) --> merge results, complete
  |-- "iterate_tasks" --> replace tasks, re-execute
  |-- "iterate_spec" --> structured deltas (add/modify/remove requirements), re-break, re-execute
  |
  v
Max 3 iterations, then stop. <70% confidence flags for human review.
```

**Agents** are stateless service objects — input in, output out. The **Orchestrator** owns state, persistence, and the feedback loop.

## Quick Start (Standalone CLI)

**Try it in 60 seconds (preview mode):**

```bash
gem install arnold_pipeline
export ANTHROPIC_API_KEY=sk-ant-...   # or OPENAI_API_KEY=sk-...

arnold run "Build a todo list app with user auth and real-time updates" --preview
```

Preview mode generates a spec and task breakdown without any execution provider. No GitHub token, no Claude Code CLI, no repo — just the gem and an API key. If no API key is found, Arnold prompts you to enter one interactively.

**With GitHub (default):**

```bash
export GITHUB_TOKEN=ghp_...

arnold run "Build a todo list app with user auth and real-time updates" --repo owner/repo
# Trigger Claude to work on the generated issues:
arnold run "Build a todo list app" --repo owner/repo --issue-mention "@claude"
# Using OpenAI instead:
arnold run "Build a todo list app" --provider openai --repo owner/repo
```

**With Claude Code (local execution):**

```bash
npm install -g @anthropic-ai/claude-code

mkdir my-app && cd my-app && git init
arnold run "Build a todo list app with user auth and real-time updates" \
  --execution-provider claude_code \
  --claude-code-repo-path .
```

**Partial execution (either provider):**

```bash
arnold run "Build a todo list app" --stop-after tasks
arnold resume 1                        # Continue from where you left off
arnold resume 1 --stop-after executed  # Resume and pause again at a later stage
```

**Optional: OpenSpec CLI (improves spec iteration quality):**

```bash
npm install -g @fission-ai/openspec   # Requires Node.js
```

When installed, Arnold uses OpenSpec's merge engine during `iterate_spec` decisions for surgical spec updates (adding, modifying, or removing individual requirements). Without it, Arnold falls back to appending structured sections — functional but less precise. See [OpenSpec Integration](#openspec-integration) for details.

The CLI stores pipeline runs in a standalone SQLite database at `~/.arnold_pipeline/pipeline.sqlite3`. This is created automatically on first use and migrations are applied each time the CLI starts.

**User config file:** Arnold auto-loads `~/.arnold_pipeline/config.yml` on every CLI invocation. This is the lowest-priority config source — `--config FILE` overrides it, and CLI flags override everything. Use `arnold run --preview` to interactively set up your API key and save it to this file.

## Execution Providers

Arnold supports multiple execution backends. The execution provider controls how tasks are dispatched, how results are collected, and how code is merged. Everything else — spec generation, task breakdown, analysis, tier gating — is the same regardless of provider.

| | GitHub (default) | Claude Code |
|---|---|---|
| Execution model | Async (polling) | Sync (immediate) |
| Where code runs | GitHub-hosted (Actions/Copilot) | Local machine |
| Task format | GitHub Issues with Markdown | CLI prompt with context |
| Result capture | PR diffs + comment parsing | Git diff from worktree |
| Merge strategy | PR merge via API | Git merge locally |
| Requires | GitHub token, repo, coding agent | Claude Code CLI, local repo |
| Best for | Team workflows, CI integration | Solo development, rapid iteration |

### Execution via GitHub

The default. Arnold creates GitHub Issues for each task and waits for a coding agent (GitHub Actions, Copilot, etc.) to pick them up, work on branches, and open PRs. Results are collected by polling for PRs that reference the issue number. See [Setting Up a Coding Agent](#setting-up-a-coding-agent) for details.

**Prerequisites:**
- GitHub personal access token with repo scope (`GITHUB_TOKEN`)
- Target repository
- A coding agent configured on the repo (see [Setting Up a Coding Agent](#setting-up-a-coding-agent))

### Execution via Claude Code

Arnold dispatches tasks directly to the Claude Code CLI on your local machine. Each task runs in a git worktree, so work is isolated per task. File changes are captured as diffs immediately — no polling, no GitHub infrastructure needed.

**Prerequisites:**
- Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code`)
- `ANTHROPIC_API_KEY` set in environment (used by both Arnold's LLM calls and Claude Code's own execution)
- A local git repository to operate on

**Claude Code provider features:**

- **JSON output parsing** — The provider runs Claude Code with `--output-format json` and parses the structured response to extract cost, duration, turns, model, and session_id as `execution_metadata` on task records. This metadata is available for analysis and auditing after each task completes.
- **Library-driven CLAUDE.md generation** — Each worktree gets a generated `CLAUDE.md` assembled from the Library's persona, recipe, and domain type YAML files. When the target repo already has a `CLAUDE.md`, the generated file is written to `.claude/CLAUDE.md` instead. New Library additions flow through automatically.
- **System prompt separation** — Behavioral instructions (test running, commit rules, working directory constraints) are sent via `--append-system-prompt`, while task content is the main prompt. This preserves Claude Code's built-in instructions.
- **Failure diagnostics** — When a task fails, Claude's final message is captured as a comment for the analysis agent, providing visibility into what went wrong.

**Note:** The `llm_provider` / `llm_api_key` configuration is still required regardless of execution provider — it's used for spec generation, task breakdown, analysis, and tier gate checks. The execution provider only controls how tasks are dispatched and results collected.

## CLI Commands

```bash
arnold run "description" [options]   # Run the full pipeline
arnold resume ID [options]           # Resume a paused or failed run
arnold iterate ID "change" [options] # Iterate on a run's specification
arnold status ID [options]           # Check a pipeline run
arnold list [options]                # List all runs
arnold spec ID [options]             # Export a run's specification
arnold tasks ID [options]            # Export a run's tasks
arnold log ID [options]              # Show event audit trail
arnold doctor                        # Check environment health
arnold version                       # Show version
arnold tree                          # Print command tree

# Options for `run`:
#   --config FILE              YAML config file
#   --provider NAME            LLM provider (anthropic/openai)
#   --model NAME               Model name
#   --repo OWNER/REPO          GitHub repository
#   --issue-mention MENTION    Include in issue body (e.g. @claude)
#   --execution-provider NAME  Execution provider (github/claude_code/null)
#   --claude-code-repo-path PATH   Local repo path for Claude Code provider
#   --claude-code-model NAME       Claude Code model (default: sonnet)
#   --claude-code-max-turns N      Max turns for Claude Code execution
#   --claude-code-permission-mode MODE  Permission mode (default: bypassPermissions)
#   --stop-after STAGE         Pause after stage: spec, tasks, executed
#   --preview, --dry-run       Generate spec and tasks without publishing to execution provider (still makes LLM API calls)
#   --polling-interval SECS    Polling interval (default: 30)
#   --polling-timeout SECS     Max polling wait (default: 1800)
#   --verbose                  Enable verbose event logging

# Options for `resume` (accepts all `run` config flags):
#   --stop-after STAGE         Pause again at a later stage

# Options for `iterate`:
#   --config FILE              YAML config file
#   --provider NAME            LLM provider (anthropic/openai)
#   --model NAME               Model name
#   --dry-run                  Show proposed deltas without applying
#   --json                     Output delta details as JSON (with --dry-run)
#   --verbose                  Show full before/after for modified requirements
#   --yes, -y                  Skip confirmation prompt

# Options for `status`:
#   --json             Output as JSON

# Options for `list`:
#   --limit N          Number of runs to show (default: 20)
#   --json             Output as JSON

# Options for `spec`:
#   -o, --output FILE  Write to file instead of stdout
#   --json             Output structured JSON data instead of markdown
#   --history          Show revision history (version, change source, delta summary)
#   --version N        Show spec content at a specific version

# Options for `tasks`:
#   -o, --output FILE  Write to file instead of stdout
#   --json             Output as JSON

# Options for `log`:
#   --json             Output as JSON
#   --stage STAGE      Filter events by pipeline stage
#   --verbose          Include full event payloads
```

### Exporting Specifications

After a pipeline run, export the generated spec:

```bash
arnold spec 1                    # Print spec markdown to stdout
arnold spec 1 --json             # Print structured JSON instead
arnold spec 1 -o spec.md         # Write markdown to file
arnold spec 1 --json -o spec.json  # Write JSON to file
```

### Spec Revision History

Every spec change is snapshotted as a revision — both the initial generation and each `iterate_spec` refinement. Use `--history` to see the timeline and `--version` to retrieve a specific snapshot:

```bash
arnold spec 1 --history               # Show revision timeline with delta summaries
arnold spec 1 --version 2             # Show spec content at version 2
arnold spec 1 --version 2 -o v2.md    # Write version 2 to file
```

Each revision records its `change_source` (`spec_generation`, `iterate_spec`, or `user_iterate`) and a summary of what changed. When the analysis agent refines the spec, individual changes are tracked as deltas (added/modified/removed requirements with rationale), so you can see exactly what shifted between iterations.

### Spec Iteration

Refine a pipeline run's specification with natural language change requests using `arnold iterate`. This is useful for adjusting the spec after reviewing it, without restarting the pipeline from scratch.

```bash
arnold run "Build a chat app" --stop-after spec     # Generate spec, pause
arnold spec 1                                        # Review it
arnold iterate 1 "Add typing indicators"             # Refine spec
arnold iterate 1 "Remove the admin dashboard"        # Refine again
arnold spec 1 --history                              # See revision timeline
arnold resume 1                                      # Continue pipeline
```

Each `iterate` call generates structured deltas (add/modify/remove requirements) via a dedicated SpecIterationAgent, merges them into the spec through the same merge chain used by the analysis loop (OpenSpec CLI or structured append fallback), and marks existing tasks as superseded. When you `resume`, the pipeline re-runs task breakdown against the updated spec.

**Dry run** — Preview proposed changes without applying them:

```bash
arnold iterate 1 "Add WebSocket support" --dry-run
arnold iterate 1 "Add WebSocket support" --dry-run --json
```

**Iterating completed runs** — When you iterate a completed run, Arnold forks it into a new pipeline run with the updated spec. The original run is preserved unchanged:

```bash
arnold iterate 1 "Switch from REST to GraphQL"
# => New pipeline run created! New run ID: 2, Forked from: #1
arnold resume 2
```

### Exporting Tasks

After a pipeline run, export the generated tasks:

```bash
arnold tasks 1                      # Print tasks as markdown to stdout
arnold tasks 1 --json               # Print as JSON array instead
arnold tasks 1 -o tasks.md          # Write markdown to file
arnold tasks 1 --json -o tasks.json # Write JSON to file
```

Each task includes position, title, tier, priority, status, labels, dependencies, and description. JSON output additionally includes `id`, `external_id`, and `external_url`.

## Configuration Reference

### LLM Provider

| Option | Default | Env Var | Description |
|--------|---------|---------|-------------|
| `llm_provider` | `:anthropic` | — | `:anthropic` or `:openai` |
| `llm_api_key` | — | `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` | Auto-detected from provider |
| `llm_model` | per-provider | — | `claude-sonnet-4-6` (anthropic) / `gpt-4o` (openai) |
| `llm_request_timeout` | `600` | — | LLM API request timeout in seconds |

### Execution Provider (common)

| Option | Default | Description |
|--------|---------|-------------|
| `execution_provider` | `:github` | `:github`, `:claude_code`, or `:null` |

### GitHub Provider

| Option | Default | Env Var | Description |
|--------|---------|---------|-------------|
| `github_token` | — | `GITHUB_TOKEN` | GitHub personal access token |
| `github_repo` | — | — | Target repo (`owner/repo`) |
| `github_issue_mention` | `nil` | — | Mention added to issue body (e.g. `@claude`) |
| `workflow_status_enabled` | `true` | — | Check GitHub Actions workflow status before resolving tasks |
| `workflow_branch_pattern` | `/issue[-_]?\d+/i` | — | Regex to match branch names when checking workflow runs |

### Claude Code Provider

| Option | Default | Description |
|--------|---------|-------------|
| `claude_code_repo_path` | `nil` | Local repo path for Claude Code provider |
| `claude_code_model` | `"sonnet"` | Model for Claude Code CLI |
| `claude_code_max_turns` | `25` | Max turns per task (nil = unlimited) |
| `claude_code_permission_mode` | `"bypassPermissions"` | Permission mode for Claude Code CLI |
| `claude_code_max_concurrency` | `4` | Parallel task execution slots (1-16) |
| `claude_code_max_budget_usd` | `nil` | Per-task dollar budget limit via `--max-budget-usd` |
| `claude_code_tools` | `nil` | Tool whitelist via `--tools` (nil = all tools) |
| `claude_code_allowed_tools` | `nil` | Auto-approve tool patterns via `--allowedTools` |
| `claude_code_disallowed_tools` | `nil` | Block tool patterns via `--disallowedTools` |
| `merge_conflict_resolution_enabled` | `true` | Auto-resolve merge conflicts via LLM |
| `merge_conflict_max_files` | `10` | Max conflicted files to attempt resolution on |

### Pipeline Control

| Option | Default | Description |
|--------|---------|-------------|
| `max_iterations` | `3` | Feedback loop cap (1-10) |
| `library_path` | built-in | Custom personas/recipes directory |

### Polling (GitHub)

| Option | Default | Description |
|--------|---------|-------------|
| `polling_interval` | `30` | Seconds between polling checks |
| `polling_timeout` | `1800` | Max seconds to wait for results (30 min) |
| `polling_max_interval` | `300` | Backoff cap in seconds (5 min) |

### Tier Execution

| Option | Default | Description |
|--------|---------|-------------|
| `tier_gate_enabled` | `true` | LLM validates each tier's output before next tier |
| `context_propagation_enabled` | `true` | Prepend tier summaries to next tier's task bodies |
| `max_tier_retries` | `2` | Corrective retries per tier before pausing (0-5) |

### Diff Management

| Option | Default | Description |
|--------|---------|-------------|
| `max_diff_chars` | `100000` | Max total diff characters sent to LLM |
| `max_diff_per_file_chars` | `10000` | Max diff characters per file |

### OpenSpec

| Option | Default | Description |
|--------|---------|-------------|
| `openspec_enabled` | `true` | Use OpenSpec CLI for spec merging when available. Set `false` for append fallback |
| `openspec_cli_path` | `"openspec"` | Path to OpenSpec CLI binary |

### Event Logging

| Option | Default | Description |
|--------|---------|-------------|
| `event_logging_enabled` | `true` | Record pipeline events for audit trail |
| `verbose_event_logging` | `false` | Include full payloads in events (set via `--verbose` CLI flag) |

### Repo Context

| Option | Default | Description |
|--------|---------|-------------|
| `repo_context_scan_patterns` | `nil` | Glob patterns for repo context scanning (nil = Rails defaults) |
| `repo_context_scan_files` | `nil` | Specific files to include in repo context scan |

## Key Concepts

**Tiers** — Tasks are grouped into execution tiers computed from the `depends_on` DAG. Tier 0 tasks have no dependencies, tier 1 tasks depend only on tier 0 tasks, and so on. Each tier is published, executed, and merged before the next tier starts.

**Tier Gate Checks** — After each tier's results are merged, an LLM reviews the combined diffs and decides pass or fail. Failures generate corrective tasks that are executed and re-checked, up to `max_tier_retries` times. If retries are exhausted, the pipeline pauses for human review. Gate checks are lenient by default — only critical, build-breaking issues cause a failure.

**Context Propagation** — Each tier gate check produces a 2-3 sentence summary of what was built. These summaries are accumulated across tiers and prepended to the next tier's task bodies, giving coding agents explicit context about what already exists in the repo.

**Spec Deltas** — When the analysis agent decides `iterate_spec`, it produces structured requirement-level changes (add, modify, or remove) rather than free-text appends. Each delta includes an operation, section, requirement content, and rationale. This keeps specs clean across iterations.

**Personas, Recipes, and Domain Types** — Arnold's library system, loaded from YAML files. Personas define agent behavior (Software Architect, Domain Expert, QA Analyst). Recipes define application structure templates (Web App, API Service). Domain types provide a domain-specific prompting lens (FINTECH, GAME, HEALTH, etc. — 13 built-in types). The Library Manager matches your input description to the best combination via keyword matching, with generic fallbacks.

**Pipeline Events** — An audit trail of every stage transition and decision point: library selection, spec generation, task breakdown, tier execution, gate checks, analysis decisions, iteration outcomes, and pipeline lifecycle (pause/fail/complete). Viewable via `arnold log ID`.

## OpenSpec Integration

[OpenSpec](https://github.com/fission-ai/openspec) is an optional Node.js CLI that enables surgical spec merging during `iterate_spec` decisions. Instead of appending new requirements to the end of the spec, OpenSpec can add, modify, or remove individual requirements in-place.

**Installation:**

```bash
npm install -g @fission-ai/openspec
```

**How it works:** When the analysis agent decides to refine the spec, Arnold:

1. Writes the current spec and the structured deltas to a temporary workspace
2. Calls the OpenSpec CLI to merge the deltas into the base spec
3. Replaces the spec content with the merged result and creates a new `SpecRevision`

The base spec must follow OpenSpec format (`## Purpose`, `## Requirements` sections with `### Requirement:` headers).

**Fallback chain:** If OpenSpec is installed but the merge fails, Arnold falls back to structured appending (adding `## ADDED Requirements` / `## MODIFIED Requirements` / `## REMOVED Requirements` sections). If OpenSpec is not installed or is disabled, Arnold uses this append strategy directly.

**Configuration:**

```ruby
config.openspec_enabled = true       # default — use OpenSpec when available
config.openspec_enabled = false      # always use append fallback (no Node.js needed)
config.openspec_cli_path = "openspec" # default — or provide an absolute path
```

## Rails Integration

Add to your Gemfile:

```ruby
gem "arnold_pipeline"
```

Run the install generator:

```bash
bundle install
rails generate arnold_pipeline:install
rails db:migrate
```

Configure in `config/initializers/arnold_pipeline.rb`:

```ruby
ArnoldPipeline.configure do |config|
  config.llm_provider   = :anthropic
  config.llm_api_key    = ENV["ANTHROPIC_API_KEY"]
  config.llm_model      = "claude-sonnet-4-6"
  config.github_token   = ENV["GITHUB_TOKEN"]
  config.github_repo    = "owner/repo"
  config.max_iterations = 3

  # Mention to include in issue body so an agent picks up the issue
  config.github_issue_mention = "@claude"  # nil to disable

  # Polling: how long to wait for external agents to produce PRs
  config.polling_interval     = 30   # initial interval between checks (seconds)
  config.polling_timeout      = 1800 # max total wait time (seconds)
  config.polling_max_interval = 300  # backoff cap (seconds)

  # Tier gating: LLM validates each tier's output before proceeding
  config.tier_gate_enabled          = true  # fail-fast on broken tiers
  config.context_propagation_enabled = true  # pass summaries to next tier's issues
  config.max_tier_retries           = 2     # corrective retries before pausing (0-5)
end
```

To use Claude Code instead of GitHub, replace the GitHub-specific config:

```ruby
ArnoldPipeline.configure do |config|
  config.llm_provider   = :anthropic
  config.llm_api_key    = ENV["ANTHROPIC_API_KEY"]

  # Execution via Claude Code
  config.execution_provider          = :claude_code
  config.claude_code_repo_path       = "/path/to/your/project"
  config.claude_code_model           = "sonnet"  # default
  config.claude_code_max_turns       = 25        # default; set nil for unlimited
  config.claude_code_permission_mode = "auto"    # non-interactive pipeline use
  config.claude_code_max_budget_usd  = nil       # per-task dollar limit
  config.claude_code_tools           = nil       # tool whitelist (nil = all)
  config.claude_code_allowed_tools   = nil       # auto-approve patterns
  config.claude_code_disallowed_tools = nil      # blocked tool patterns

  # Optional: Post-merge hooks and verification checks
  config.post_merge_hooks = [
    {
      name: "Regenerate schema",
      trigger_paths: ["db/migrate/**/*.rb"],
      command: "bin/rails db:prepare && bin/rails db:schema:dump",
      commit_paths: ["db/schema.rb"],
      commit_message: "Regenerate schema.rb after tier merge"
    }
  ]

  config.verification_checks = [
    {
      name: "Boot check",
      command: "bin/rails runner 'ActiveRecord::Migration.check_all_pending!; SolidQueue::Job rescue nil; puts :ok'",
      type: :boot,
      required: true
    },
    {
      name: "Test suite",
      command: "bin/rails test",
      type: :test_suite,
      required: false
    }
  ]
end
```

Use programmatically:

```ruby
orchestrator = ArnoldPipeline::Orchestrator.new

# Full pipeline
result = orchestrator.call(nl_input: "Build a REST API for inventory management")
result.status       # => "completed"
result.tasks.count  # => 12
result.iterations   # => [#<Iteration decision="done" confidence=95>]

# Partial execution — stop after task breakdown
run = orchestrator.call(nl_input: "Build a dashboard app", stop_after: :tasks)
run.status  # => "paused"
# Review the spec and tasks, then continue:
result = orchestrator.resume(pipeline_run: run)

# User-initiated spec iteration (paused/failed runs)
run = orchestrator.call(nl_input: "Build a chat app", stop_after: :spec)
orchestrator.iterate_spec!(pipeline_run: run, change_request: "Add typing indicators")
result = orchestrator.resume(pipeline_run: run)

# Dry run — preview deltas without applying
preview = orchestrator.iterate_spec_dry_run!(pipeline_run: run, change_request: "Remove admin panel")
preview[:deltas]  # => [{"operation"=>"removed", "section"=>"Admin", ...}]

# Fork from completed run — creates a new run with iterated spec
result = orchestrator.fork!(pipeline_run: completed_run, change_request: "Switch to GraphQL")
result[:pipeline_run].id  # => new run ID

# Async (via ActiveJob)
run = ArnoldPipeline::PipelineRun.create!(nl_input: "Build a dashboard app")
ArnoldPipeline::PipelineJob.perform_later(run.id)
```

## Partial Execution & Resume

The pipeline can be paused at any stage and resumed later. This is useful for reviewing intermediate results before committing to the next step, or for recovering from failures.

### Stages

| `stop_after` | Stops after | What exists when paused |
|--------------|------------|------------------------|
| `:spec` | Spec generation | Specification (markdown + structured data) |
| `:tasks` | Task breakdown | Specification + 5-20 ordered tasks |
| `:executed` | Task dispatch + result collection | Tasks with external IDs, diffs, and comments |
| `nil` | Full pipeline | Everything including analysis iterations |

### Partial Execution

Stop the pipeline at any stage to review before continuing:

```ruby
orchestrator = ArnoldPipeline::Orchestrator.new

# Generate spec only
run = orchestrator.call(nl_input: "Build a todo app", stop_after: :spec)
run.status                    # => "paused"
run.metadata["paused_at"]     # => "spec"
puts run.specification.content  # Review the generated spec

# Generate spec + tasks
run = orchestrator.call(nl_input: "Build a todo app", stop_after: :tasks)
run.tasks.each { |t| puts "#{t.position}: #{t.title}" }

# Execute (dispatch tasks and collect results) but don't run analysis
run = orchestrator.call(nl_input: "Build a todo app", stop_after: :executed)
run.tasks.each { |t| puts "#{t.title} -> #{t.external_url}" }
```

### Resume

Resume a paused (or failed) pipeline run. The orchestrator infers where to pick up based on existing state:

```ruby
# Resume to completion
result = orchestrator.resume(pipeline_run: run)
result.status  # => "completed"

# Resume but pause again at a later stage
result = orchestrator.resume(pipeline_run: run, stop_after: :executed)
result.status  # => "paused"
```

Each task includes position, title, tier, priority, status, labels, dependencies, and description. JSON output additionally includes `id`, `external_id`, and `external_url`.

## Configuration Reference

| Option | Default | Env Var | Description |
|--------|---------|---------|-------------|
| `llm_provider` | `:anthropic` | — | `:anthropic` or `:openai` |
| `llm_api_key` | — | `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` | Auto-detected from provider |
| `llm_model` | per-provider | — | `claude-sonnet-4-6` (anthropic) / `gpt-4o` (openai) |
| `execution_provider` | `:github` | — | `:github`, `:claude_code`, or `:null` |
| `github_token` | — | `GITHUB_TOKEN` | GitHub personal access token |
| `github_repo` | — | — | Target repo (`owner/repo`) |
| `github_issue_mention` | `nil` | — | Mention added to issue body (e.g. `@claude`) |
| `claude_code_repo_path` | `nil` | — | Local repo path for Claude Code provider |
| `claude_code_model` | `"sonnet"` | — | Model for Claude Code CLI |
| `claude_code_max_turns` | `25` | — | Max turns per task (nil = unlimited) |
| `claude_code_permission_mode` | `"auto"` | — | Permission mode for Claude Code CLI |
| `claude_code_max_budget_usd` | `nil` | — | Per-task dollar budget limit via `--max-budget-usd` |
| `claude_code_tools` | `nil` | — | Tool whitelist via `--tools` (nil = all tools) |
| `claude_code_allowed_tools` | `nil` | — | Auto-approve tool patterns via `--allowedTools` |
| `claude_code_disallowed_tools` | `nil` | — | Block tool patterns via `--disallowedTools` |
| `max_iterations` | `3` | — | Feedback loop cap (1-10) |
| `polling_interval` | `30` | — | Seconds between polling checks (async providers) |
| `polling_timeout` | `1800` | — | Max seconds to wait for results (30 min, async providers) |
| `polling_max_interval` | `300` | — | Backoff cap in seconds (5 min, async providers) |
| `tier_gate_enabled` | `true` | — | LLM validates each tier's output before next tier |
| `context_propagation_enabled` | `true` | — | Prepend tier summaries to next tier's task bodies |
| `max_tier_retries` | `2` | — | Corrective retries per tier before pausing (0-5) |
| `workflow_status_enabled` | `true` | — | Check GitHub Actions workflow status before resolving tasks |
| `workflow_branch_pattern` | `/issue[-_]?\d+/i` | — | Regex to match branch names when checking workflow runs |
| `openspec_enabled` | `true` | — | Use OpenSpec CLI for spec merging when available. Set `false` to use append fallback (no Node.js needed) |
| `openspec_cli_path` | `"openspec"` | — | Path to OpenSpec CLI binary |
| `post_merge_hooks` | `[]` | — | Array of hook definitions (see [Post-Merge Hooks](#post-merge-hooks--verification-checks)) |
| `verification_checks` | `[]` | — | Array of check definitions (see [Verification Checks](#post-merge-hooks--verification-checks)) |
| `library_path` | built-in | — | Custom personas/recipes dir |

```ruby
# A run that failed during spec generation
run = orchestrator.call(nl_input: "Build an app")  # raises if LLM is down
run = ArnoldPipeline::PipelineRun.last
run.status  # => "failed"

# Later, when the LLM is back:
result = orchestrator.resume(pipeline_run: run)
```
NL Input
  |
  v
Library Manager ── find persona + recipe
  |
  v
Spec Generator ── NL + persona + recipe --> OpenSpec-format Markdown (### Requirement: headers, GIVEN/WHEN/THEN scenarios, [REQ-*] IDs)
  |
  v
Task Breaker ── spec --> 5-20 ordered tasks (JSON)
  |
  v
Executor ── tasks --> execution provider (tier-by-tier)
  |            GitHub: create Issues, poll for PR diffs (exponential backoff)
  |            Claude Code: run CLI in worktrees, capture diffs immediately
  |            (receives prior tier context when context_propagation_enabled)
  v
[After each tier merge:]
  Post-Merge Hooks ── fix derived files (e.g., regenerate schema.rb, bundle install)
  |
  v
  Verification Checks ── empirical validation (boot check, test suite, custom commands)
  |                       required checks short-circuit on failure
  v
  Tier Gate Check ── diffs + verification results --> pass/fail + context summary
  |                   fail --> corrective tasks + retry (up to max_tier_retries)
  |                   still failing --> pause for human review
  v
Analyzer ── diffs + spec --> decision + confidence
  |
  |-- "done" (>=70% confidence) --> merge results, complete
  |-- "iterate_tasks" --> replace tasks, re-execute
  |-- "iterate_spec" --> structured deltas (add/modify/remove requirements), re-break, re-execute
  |
  v
Max 3 iterations, then stop. <70% confidence flags for human review.
```

**Agents** are stateless service objects — input in, output out. The **Orchestrator** owns state, persistence, and the feedback loop.

### Result Collection

How results are collected depends on the execution provider:

### How Resume Infers the Stage

The orchestrator inspects the pipeline run's existing data to determine where to continue:

| State | Resumes from |
|-------|-------------|
| No specification | Spec generation |
| Specification exists, no tasks | Task breakdown |
| All tasks superseded (after `iterate`) | Task breakdown |
| Tasks exist, no external IDs | Task dispatch |
| Tasks have external IDs, incomplete results | Result collection |
| All tasks have results | Analysis |

If some tasks were published before a pause/failure and others weren't, resume will only publish the remaining tasks — already-published tasks are not duplicated.

## Tier Gating & Context Propagation

Tasks are executed tier-by-tier (tier 0 first, then tier 1, etc.). After each tier's results are merged, two optional features kick in:

**Tier Gate Check** (`tier_gate_enabled`) — An LLM reviews the tier's diffs and decides pass/fail. If the tier fails:
1. Corrective tasks are created at the same tier and executed
2. The gate re-runs. If it still fails, retry up to `max_tier_retries` times
3. If retries are exhausted, the pipeline pauses with status `paused` and metadata indicating the failure — resume after manual review

Gate checks are lenient by default — only critical, build-breaking issues cause a failure. Minor issues are noted but don't block.

**Context Propagation** (`context_propagation_enabled`) — The gate check also produces a 2-3 sentence summary of what was built. This summary is accumulated across tiers and prepended to the next tier's task bodies, giving coding agents explicit context about what already exists in the repo.

Both features use a single LLM call per tier. If the gate check errors (e.g. LLM timeout), it's treated as non-fatal and the pipeline continues.

```ruby
# Disable both features for faster execution (no per-tier LLM calls)
config.tier_gate_enabled = false
config.context_propagation_enabled = false

# Keep context but skip gate enforcement
config.tier_gate_enabled = false
config.context_propagation_enabled = true

# Zero retries = pause immediately on first gate failure
config.max_tier_retries = 0
```

## Post-Merge Hooks & Verification Checks

After each tier merges, Arnold can run **post-merge hooks** to fix derived files and **verification checks** to validate the build. This feature applies to the **Claude Code execution provider** — hooks and checks run locally in the repository. For the GitHub provider, these features are available but require `claude_code_repo_path` to be configured (so the local repo can be updated in sync with the remote).

### Post-Merge Hooks

Hooks trigger when changed files match configured glob patterns. Use them to regenerate derived files after tier merges (e.g., `db/schema.rb` after migrations, lock files after dependency changes).

Each hook runs a shell command. If the command succeeds (exit code 0) and `commit_paths` are specified, changed files at those paths are committed automatically.

**Configuration:**

```ruby
config.post_merge_hooks = [
  {
    name: "Regenerate database schema",
    trigger_paths: ["db/migrate/**/*.rb"],
    command: "bin/rails db:prepare && bin/rails db:schema:dump",
    commit_paths: ["db/schema.rb"],
    commit_message: "Regenerate schema.rb after tier merge"
  },
  {
    name: "Bundle install on Gemfile changes",
    trigger_paths: ["Gemfile", "Gemfile.lock"],
    command: "bundle install",
    commit_paths: ["Gemfile.lock"],
    commit_message: "Update Gemfile.lock after tier merge"
  }
]
```

**YAML config:**

```yaml
post_merge_hooks:
  - name: "Regenerate database schema"
    trigger_paths:
      - "db/migrate/**/*.rb"
    command: "bin/rails db:prepare && bin/rails db:schema:dump"
    commit_paths:
      - "db/schema.rb"
    commit_message: "Regenerate schema.rb after tier merge"

  - name: "Bundle install on Gemfile changes"
    trigger_paths:
      - "Gemfile"
      - "Gemfile.lock"
    command: "bundle install"
    commit_paths:
      - "Gemfile.lock"
    commit_message: "Update Gemfile.lock after tier merge"
```

**Fields:**
- `name` — Human-readable hook name (for logging)
- `trigger_paths` — Array of glob patterns. Hook runs if any changed file matches any pattern (uses `File.fnmatch` with `File::FNM_PATHNAME`)
- `command` — Shell command to execute in the repo directory
- `commit_paths` — (Optional) Array of file paths to commit if they changed after the command
- `commit_message` — (Optional) Git commit message for auto-committed files

Hooks run sequentially after tier merge, before verification checks and tier gate.

### Verification Checks

Checks run shell commands to verify application health. Use them to catch build-breaking issues before the analysis loop (e.g., boot failures, test regressions).

Each check has a `type` (`:boot`, `:test_suite`, or `:custom`) and can be marked `required`. Required checks short-circuit the sequence on failure — if a required check fails, subsequent checks are skipped.

Check results (pass/fail, stdout/stderr, exit code) are passed to the tier gate check agent via the `verification_results:` parameter, so the gate can factor empirical evidence into its decision.

**Configuration:**

```ruby
config.verification_checks = [
  {
    name: "Boot check",
    command: "bin/rails runner 'ActiveRecord::Migration.check_all_pending!; SolidQueue::Job rescue nil; puts Rails.version'",
    type: :boot,
    required: true  # Pipeline pauses if this fails — catches pending migrations and missing Solid Queue tables
  },
  {
    name: "Test suite",
    command: "bin/rails test",
    type: :test_suite,
    required: false  # Gate sees results but doesn't auto-fail on test failures
  }
]
```

**YAML config:**

```yaml
verification_checks:
  - name: "Boot check"
    command: "bin/rails runner 'ActiveRecord::Migration.check_all_pending!; SolidQueue::Job rescue nil; puts Rails.version'"
    type: boot
    required: true

  - name: "Test suite"
    command: "bin/rails test"
    type: test_suite
    required: false
```

> **Why `SolidQueue::Job rescue nil`?** A common failure mode with Rails 8's Solid stack is that `bin/rails runner` passes (the web app loads), but `bin/dev` crashes because Solid Queue tables are missing. This happens when `database.yml` only defines queue/cache/cable databases for production, not development. The `SolidQueue::Job` probe catches this: if Solid Queue is installed but its tables are missing, the boot check fails early instead of passing silently.

**Fields:**
- `name` — Human-readable check name
- `command` — Shell command to execute in the repo directory
- `type` — `:boot`, `:test_suite`, or `:custom` (informational, for logging clarity)
- `required` — Boolean (default: `false`). If `true`, failure stops the check sequence immediately

**Short-circuiting example:**

If the boot check (required) fails, database migration and test suite checks are skipped. The tier gate receives partial results indicating the boot failure, and the gate agent can decide whether to create corrective tasks or pass the tier.

### Non-Fatal by Design

Hook and check failures do not crash the pipeline. Results are captured and passed to the tier gate check agent, which decides whether to fail the tier (triggering corrective tasks) or pass despite issues. This keeps the feedback loop intact even when empirical validation finds problems.

## Setting Up a Coding Agent

This section applies to the **GitHub execution provider**. When using Claude Code as the execution provider, Arnold dispatches tasks directly to the Claude Code CLI — no coding agent setup is needed.

Arnold creates GitHub Issues but doesn't write code itself — it expects a coding agent on your repo to pick up those issues, do the work on a branch, and open a PR. Without this, Arnold will create issues and then time out waiting for results.

### What Arnold Creates

Each issue body contains:

1. **Task description** — what to build or change
2. **Prior implementation context** (if `context_propagation_enabled`) — a summary of what earlier tiers already built, so the agent knows what exists in the repo
3. **Agent mention** (if `github_issue_mention` is set) — e.g. `@claude` or `@copilot`
4. **Dependency references** — e.g. `**Depends on:** #1, #2` linking to prerequisite issues
5. **Pipeline run footer** — e.g. `_Pipeline Run #42_`

### What Arnold Expects Back

A **pull request** whose title or body contains `#<issue_number>`. Arnold finds PRs by scanning all repo PRs for this substring reference — no special labels or webhook integration required.

- **Open PR with a diff** = task resolved (Arnold will merge it after the tier completes)
- **No PR + closed issue** = task failed
- **Only WIP comments** (e.g. "working on this", "starting work") = still in progress, keep polling
- **Substantive comments** (e.g. "unable to complete", "created PR") = task resolved

Arnold merges open PRs after each tier completes, then creates the next tier's issues. The final merge happens after the analysis agent approves.

### Option A: GitHub Actions + Claude Code

Create `.github/workflows/arnold-agent.yml`:

```yaml
name: Arnold Agent (Claude Code)

on:
  issues:
    types: [opened]

jobs:
  solve:
    if: contains(github.event.issue.body, 'Pipeline Run')
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
      issues: read

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Install Claude Code
        run: npm install -g @anthropic-ai/claude-code

      - name: Create branch
        run: |
          BRANCH="arnold/issue-${{ github.event.issue.number }}"
          git checkout -b "$BRANCH"

      - name: Run Claude Code
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        run: |
          claude -p "You are working on issue #${{ github.event.issue.number }}.

          ${{ github.event.issue.body }}

          Make the changes described above. Commit your work when done."

      - name: Push and open PR
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          BRANCH="arnold/issue-${{ github.event.issue.number }}"
          git push origin "$BRANCH"
          gh pr create \
            --title "Resolve #${{ github.event.issue.number }}: ${{ github.event.issue.title }}" \
            --body "Resolves #${{ github.event.issue.number }}" \
            --head "$BRANCH"
```

Add `ANTHROPIC_API_KEY` to your repo's **Settings > Secrets and variables > Actions**.

### Option B: GitHub Actions + OpenAI Codex

Create `.github/workflows/arnold-agent.yml`:

```yaml
name: Arnold Agent (Codex)

on:
  issues:
    types: [opened]

jobs:
  solve:
    if: contains(github.event.issue.body, 'Pipeline Run')
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
      issues: read

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Install Codex
        run: npm install -g @openai/codex

      - name: Create branch
        run: |
          BRANCH="arnold/issue-${{ github.event.issue.number }}"
          git checkout -b "$BRANCH"

      - name: Run Codex
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
        run: |
          codex --approval-mode full-auto \
            -q "You are working on issue #${{ github.event.issue.number }}.

          ${{ github.event.issue.body }}

          Make the changes described above."

      - name: Push and open PR
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          BRANCH="arnold/issue-${{ github.event.issue.number }}"
          git push origin "$BRANCH"
          gh pr create \
            --title "Resolve #${{ github.event.issue.number }}: ${{ github.event.issue.title }}" \
            --body "Resolves #${{ github.event.issue.number }}" \
            --head "$BRANCH"
```

Add `OPENAI_API_KEY` to your repo's **Settings > Secrets and variables > Actions**.

### Option C: GitHub Copilot Coding Agent

The shortest path — no workflow file needed. [GitHub Copilot Coding Agent](https://docs.github.com/en/copilot/using-github-copilot/using-copilot-coding-agent) can be assigned to issues directly.

1. Enable Copilot Coding Agent on your repo (requires GitHub Copilot Enterprise or Copilot Business with agent support)
2. Configure Arnold to mention Copilot:
   ```ruby
   config.github_issue_mention = "@copilot"
   ```
3. Copilot will automatically pick up issues mentioning `@copilot`, work on a branch, and open a PR referencing the issue

No workflow file, no API keys beyond your existing Copilot subscription.

### Tips

- **PR must reference the issue number** — Arnold matches `#<issue_number>` as a substring in the PR title or body. Use formats like `Resolves #42` or `Fix #42` in your PR template.
- **Set `polling_timeout` long enough** — Complex tasks may take 5-10 minutes. The default 30 minutes works for most cases, but adjust if your agent is slower.
- **Dependency ordering is automatic** — Later-tier issues won't appear until earlier tiers merge, so your agent only sees issues it can work on.
- **Use the pipeline run footer as a filter** — The `if: contains(github.event.issue.body, 'Pipeline Run')` check prevents your workflow from triggering on non-Arnold issues. You can also filter by labels if your tasks include them.
- **Context propagation helps your agent** — When enabled, each issue body includes a summary of what prior tiers built, so the coding agent doesn't have to guess what already exists.

## Architecture for Contributors

### Directory Structure

```
lib/arnold_pipeline/
  agents/
    base_agent.rb          # Shared agent interface (call method, LLM client setup)
    analyzer.rb            # Post-execution analysis: diffs vs spec, confidence scoring
    executor.rb            # Dispatches tasks to execution provider, collects results
    spec_generator.rb      # NL input → structured specification
    spec_iterator.rb       # User change request → structured spec deltas
    task_breaker.rb        # Specification → ordered task list (JSON)
    tier_gate_check.rb     # Per-tier diff validation, corrective task generation
  library/
    domain_type.rb         # Data.define value object for domain types
    manager.rb             # Keyword-based retrieval of personas, recipes, domain types
    persona.rb             # Data.define value object for personas
    recipe.rb              # Data.define value object for recipes
  prompts/                 # ERB prompt templates for each agent
  services/
    claude_md_generator.rb # Library-driven CLAUDE.md generation for worktrees
  providers/
    execution/
      base.rb              # Execution provider interface and registry
      claude_code.rb       # Claude Code CLI provider (worktrees, parallel execution)
      github.rb            # GitHub Issues/PRs provider (polling, merge)
      null.rb              # No-op provider for testing and dry runs
    llm/
      anthropic.rb         # Anthropic API adapter (ruby-anthropic gem)
      base.rb              # LLM provider interface
      open_ai.rb           # OpenAI API adapter
  analysis_loop.rb         # Iteration logic: analyze → decide → iterate or done
  cli.rb                   # Thor-based CLI (arnold command)
  configuration.rb         # Config object with defaults and validation
  delta_merger.rb          # Shared delta merge logic (OpenSpec → append fallback)
  diff_summarizer.rb       # Truncates large diffs to fit LLM context
  engine.rb                # Rails engine mount point
  openspec_bridge.rb       # OpenSpec CLI workspace lifecycle and merge
  orchestrator.rb          # Main pipeline driver: state machine, stage sequencing
  pipeline_event_recorder.rb # Event audit trail recording (non-fatal)
  repo_context_scanner.rb  # Git ls-tree scanning for baseline-aware gate checks
  resume_inferrer.rb       # Determines resume stage from pipeline run state
  tier_calculator.rb       # Computes execution tiers from depends_on DAG
  tier_execution_engine.rb # Tier-by-tier publish → await → merge loop
  version.rb               # Gem version constant

app/models/arnold_pipeline/
  application_record.rb    # Engine base model
  iteration.rb             # Feedback loop iteration (decision, confidence, review flag)
  pipeline_event.rb        # Audit trail event (stage, type, summary, payload, timing)
  pipeline_run.rb          # Top-level run record (status, metadata, associations)
  spec_delta.rb            # Individual requirement change (operation, section, content)
  spec_revision.rb         # Spec version snapshot (content, change_source, delta_summary)
  specification.rb         # Generated spec (content, structured_data, version)
  task.rb                  # Pipeline task (title, tier, deps, external_id, diff, status)
```

### Key Classes

- **Orchestrator** — The pipeline driver. `call(nl_input:, stop_after:)` for new runs, `resume(pipeline_run:, stop_after:)` for continuation, `iterate_spec!(pipeline_run:, change_request:)` for user-initiated spec refinement, `fork!(pipeline_run:, change_request:)` for iterating completed runs. Owns the state machine and delegates to agents.
- **AnalysisLoop** — Extracted iteration logic. Runs the analyzer, interprets the decision (`done`, `iterate_tasks`, `iterate_spec`), and drives the next cycle. Includes a version skew guard that suppresses `iterate_spec` when the spec has been user-iterated past the task generation version.
- **DeltaMerger** — Shared service for applying structured deltas to specs. Used by both AnalysisLoop (analysis-driven iteration) and Orchestrator (user-initiated iteration). Handles the merge chain: OpenSpec CLI merge, structured append fallback, delta persistence, and revision snapshots.
- **TierExecutionEngine** — Manages tier-by-tier execution: publish tasks for a tier, await results, run gate check, merge, advance to next tier.
- **Agents** — Stateless service objects with a `call(**kwargs)` interface. Each agent builds an LLM prompt, makes an API call, and parses the response. Includes SpecIterator for user-initiated spec changes.
- **Providers** — Pluggable backends. LLM providers (Anthropic, OpenAI) handle API calls. Execution providers (GitHub, Claude Code, Null) handle task dispatch and result collection. Both use a `build` factory pattern.
- **Library::Manager** — Loads personas, recipes, and domain types from YAML files. Matches input descriptions via keyword overlap with generic fallbacks.

### Testing

```bash
bundle exec rails test              # Full suite (1075+ tests)
bundle exec rails test test/agents/ # Specific directory
bundle exec rails test test/agents/analyzer_test.rb:42  # Specific line
```

- **Mocha** (`mocha/minitest`) for stubs and mocks — `stubs` for default behavior, `expects` for assertions
- **WebMock** for HTTP stubs (Anthropic API, GitHub API, OpenAI API)
- `ArnoldPipeline.reset_configuration!` in test teardown to avoid config leaking between tests
- Integration tests use dynamic WebMock responses based on request body content
- Dummy Rails app at `test/dummy/` provides the engine test harness

## Extending

### Custom Personas

Create YAML files in a custom directory:

```yaml
# my_library/personas/fintech_expert.yml
name: Fintech Expert
role: domain_analysis
keywords: [fintech, banking, payments, trading, compliance]
description: Specializes in financial technology applications
system_prompt: You are a fintech domain expert...
```

```ruby
ArnoldPipeline.configure do |config|
  config.library_path = "path/to/my_library"
end
```

### Custom Recipes

```yaml
# my_library/recipes/mobile_app.yml
name: Mobile App
type: mobile_app
keywords: [mobile, ios, android, react native, flutter]
description: Native or cross-platform mobile application
sections:
  - name: Screens
    description: UI screens and navigation flow
  - name: API Integration
    description: Backend API calls and data sync
```

### Custom Execution Providers

See [docs/execution_providers.md](docs/execution_providers.md) for the provider development guide and [docs/provider_conformance_checklist.md](docs/provider_conformance_checklist.md) for the conformance checklist.

## License

MIT
