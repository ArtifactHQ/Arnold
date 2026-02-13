# Arnold Pipeline

Agentic workflow system that transforms natural language descriptions into executable code. Describe an app, get working code — Arnold orchestrates AI agents through spec generation, task breakdown, execution via [GitHub](#execution-via-github) or [Claude Code](#execution-via-claude-code), and iterative analysis.

## Quick Start (Standalone CLI)

**With GitHub (default):**

```bash
gem install arnold_pipeline

export ANTHROPIC_API_KEY=sk-ant-...   # or OPENAI_API_KEY=sk-...
export GITHUB_TOKEN=ghp_...

arnold run "Build a todo list app with user auth and real-time updates" --repo owner/repo
# Trigger Claude to work on the generated issues:
arnold run "Build a todo list app" --repo owner/repo --issue-mention "@claude"
# Using OpenAI instead:
arnold run "Build a todo list app" --provider openai --repo owner/repo
```

**With Claude Code (local execution):**

```bash
gem install arnold_pipeline
npm install -g @anthropic-ai/claude-code

export ANTHROPIC_API_KEY=sk-ant-...

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

When installed, Arnold uses OpenSpec's merge engine during `iterate_spec` decisions for surgical spec updates (adding, modifying, or removing individual requirements). Without it, Arnold falls back to appending structured sections — functional but less precise. Disable explicitly with `openspec_enabled: false` in config.

That's it. Arnold will:
1. Match your description to the best persona and recipe from its library
2. Generate a structured specification using `### Requirement:` blocks with GIVEN/WHEN/THEN scenarios and `[REQ-*]` IDs for traceability
3. Break it into 5-20 dependency-ordered tasks
4. Dispatch tasks to the execution provider (GitHub Issues or Claude Code CLI)
5. Collect results (poll for PRs on GitHub, or capture diffs immediately with Claude Code)
6. Analyze results against the spec
7. Iterate up to 3 times until aligned — spec changes are structured deltas (added/modified/removed requirements), not free-text appends, so specs stay clean across iterations. <70% confidence flags for human review.

You can stop the pipeline at any stage and resume later — see [Partial Execution & Resume](#partial-execution--resume).

The CLI stores pipeline runs in a standalone SQLite database at `~/.arnold_pipeline/pipeline.sqlite3`. This is created automatically on first use and migrations are applied each time the CLI starts.

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

**Note:** The `llm_provider` / `llm_api_key` configuration is still required regardless of execution provider — it's used for spec generation, task breakdown, analysis, and tier gate checks. The execution provider only controls how tasks are dispatched and results collected.

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
  config.llm_model      = "claude-sonnet-4-20250514"
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
  config.execution_provider        = :claude_code
  config.claude_code_repo_path     = "/path/to/your/project"
  config.claude_code_model         = "sonnet"  # default
  config.claude_code_max_turns     = nil       # use Claude Code default
  config.claude_code_permission_mode = "auto"  # non-interactive pipeline use
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

# Async (via ActiveJob)
run = ArnoldPipeline::PipelineRun.create!(nl_input: "Build a dashboard app")
ArnoldPipeline::PipelineJob.perform_later(run.id)
```

## CLI Commands

```bash
arnold run "description" [options]   # Run the full pipeline
arnold resume ID [options]           # Resume a paused or failed run
arnold spec ID [options]             # Export a run's specification
arnold tasks ID [options]            # Export a run's tasks
arnold status ID                     # Check a pipeline run
arnold list                          # List all runs
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
#   --claude-code-permission-mode MODE  Permission mode (default: auto)
#   --stop-after STAGE         Pause after stage: spec, tasks, executed
#   --preview, --dry-run       Generate spec and tasks without publishing to execution provider (still makes LLM API calls)
#   --polling-interval SECS    Polling interval (default: 30)
#   --polling-timeout SECS     Max polling wait (default: 1800)
#   --verbose                  Debug logging

# Options for `resume` (accepts all `run` config flags):
#   --stop-after STAGE         Pause again at a later stage

# Options for `spec`:
#   -o, --output FILE  Write to file instead of stdout
#   --json             Output structured JSON data instead of markdown
#   --history          Show revision history (version, change source, delta summary)
#   --version N        Show spec content at a specific version

# Options for `tasks`:
#   -o, --output FILE  Write to file instead of stdout
#   --json             Output as JSON
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

Each revision records its `change_source` (`spec_generation` or `iterate_spec`) and a summary of what changed. When the analysis agent refines the spec, individual changes are tracked as deltas (added/modified/removed requirements with rationale), so you can see exactly what shifted between iterations.

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

| Option | Default | Env Var | Description |
|--------|---------|---------|-------------|
| `llm_provider` | `:anthropic` | — | `:anthropic` or `:openai` |
| `llm_api_key` | — | `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` | Auto-detected from provider |
| `llm_model` | per-provider | — | `claude-sonnet-4-20250514` (anthropic) / `gpt-4o` (openai) |
| `execution_provider` | `:github` | — | `:github`, `:claude_code`, or `:null` |
| `github_token` | — | `GITHUB_TOKEN` | GitHub personal access token |
| `github_repo` | — | — | Target repo (`owner/repo`) |
| `github_issue_mention` | `nil` | — | Mention added to issue body (e.g. `@claude`) |
| `claude_code_repo_path` | `nil` | — | Local repo path for Claude Code provider |
| `claude_code_model` | `"sonnet"` | — | Model for Claude Code CLI |
| `claude_code_max_turns` | `nil` | — | Max turns per task (nil = Claude Code default) |
| `claude_code_permission_mode` | `"auto"` | — | Permission mode for Claude Code CLI |
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
| `library_path` | built-in | — | Custom personas/recipes dir |

## Architecture

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

### Result Collection

How results are collected depends on the execution provider:

**GitHub (async):** After creating Issues, the Executor waits for external agents (GitHub Actions, Copilot, etc.) to produce PRs. It uses exponential backoff polling:

1. Check for PR diffs every `polling_interval` seconds (default: 30s)
2. Double the interval each cycle, capped at `polling_max_interval` (default: 5 min)
3. Stop when all tasks have results, or `polling_timeout` is reached (default: 30 min)

The pipeline transitions through `executing` -> `awaiting_results` -> `analyzing` as it waits. Tasks without an `external_id` (e.g. not submitted to GitHub) are skipped and don't block polling.

**Claude Code (sync):** Each task is dispatched to the Claude Code CLI in its own git worktree. Diffs are captured immediately after execution — no polling, no `awaiting_results` state. The pipeline transitions directly from `executing` to `analyzing`.

### Tier Gating & Context Propagation

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

Resume also works after failures — fix the underlying issue and retry:

```ruby
# A run that failed during spec generation
run = orchestrator.call(nl_input: "Build an app")  # raises if LLM is down
run = ArnoldPipeline::PipelineRun.last
run.status  # => "failed"

# Later, when the LLM is back:
result = orchestrator.resume(pipeline_run: run)
```

### How Resume Infers the Stage

The orchestrator inspects the pipeline run's existing data to determine where to continue:

| State | Resumes from |
|-------|-------------|
| No specification | Spec generation |
| Specification exists, no tasks | Task breakdown |
| Tasks exist, no external IDs | Task dispatch |
| Tasks have external IDs, incomplete results | Result collection |
| All tasks have results | Analysis |

If some tasks were published before a pause/failure and others weren't, resume will only publish the remaining tasks — already-published tasks are not duplicated.

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
