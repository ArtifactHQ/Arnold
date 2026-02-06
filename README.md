# Arnold Pipeline

Agentic workflow system that transforms natural language descriptions into executable code. Describe an app, get working code — Arnold orchestrates AI agents through spec generation, task breakdown, GitHub-based execution, and iterative analysis.

## Quick Start (Standalone CLI)

```bash
gem install arnold_pipeline

export ANTHROPIC_API_KEY=sk-ant-...   # or OPENAI_API_KEY=sk-...
export GITHUB_TOKEN=ghp_...

arnold run "Build a todo list app with user auth and real-time updates" --repo owner/repo
# Trigger Claude to work on the generated issues:
arnold run "Build a todo list app" --repo owner/repo --issue-mention "@claude"
# Using OpenAI instead:
arnold run "Build a todo list app" --provider openai --repo owner/repo

# Run only part of the pipeline (see Partial Execution below):
arnold run "Build a todo list app" --repo owner/repo --stop-after tasks
arnold resume 1                     # Continue from where you left off
arnold resume 1 --stop-after published  # Resume and pause again at a later stage
```

That's it. Arnold will:
1. Match your description to the best persona and recipe from its library
2. Generate a structured specification
3. Break it into 5-20 dependency-ordered tasks
4. Create GitHub Issues and trigger execution
5. Poll for PR results with exponential backoff
6. Analyze results against the spec
7. Iterate up to 3 times until aligned (or flag for human review)

You can stop the pipeline at any stage and resume later — see [Partial Execution & Resume](#partial-execution--resume).

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
arnold status ID                     # Check a pipeline run
arnold list                          # List all runs
arnold version                       # Show version

# Options for `run`:
#   --config FILE              YAML config file
#   --provider NAME            LLM provider (anthropic/openai)
#   --model NAME               Model name
#   --repo OWNER/REPO          GitHub repository
#   --issue-mention MENTION    Include in issue body (e.g. @claude)
#   --stop-after STAGE         Pause after stage: spec, tasks, published, executed
#   --polling-interval SECS    Polling interval (default: 30)
#   --polling-timeout SECS     Max polling wait (default: 1800)
#   --verbose                  Debug logging

# Options for `resume`:
#   --stop-after STAGE         Pause again at a later stage

# Options for `spec`:
#   -o, --output FILE  Write to file instead of stdout
#   --json             Output structured JSON data instead of markdown
```

### Exporting Specifications

After a pipeline run, export the generated spec:

```bash
arnold spec 1                    # Print spec markdown to stdout
arnold spec 1 --json             # Print structured JSON instead
arnold spec 1 -o spec.md         # Write markdown to file
arnold spec 1 --json -o spec.json  # Write JSON to file
```

## Configuration Reference

| Option | Default | Env Var | Description |
|--------|---------|---------|-------------|
| `llm_provider` | `:anthropic` | — | `:anthropic` or `:openai` |
| `llm_api_key` | — | `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` | Auto-detected from provider |
| `llm_model` | per-provider | — | `claude-sonnet-4-20250514` (anthropic) / `gpt-4o` (openai) |
| `execution_provider` | `:github` | — | `:github` |
| `github_token` | — | `GITHUB_TOKEN` | GitHub personal access token |
| `github_repo` | — | — | Target repo (`owner/repo`) |
| `github_issue_mention` | `nil` | — | Mention added to issue body (e.g. `@claude`) |
| `max_iterations` | `3` | — | Feedback loop cap (1-10) |
| `polling_interval` | `30` | — | Seconds between PR polling checks |
| `polling_timeout` | `1800` | — | Max seconds to wait for PRs (30 min) |
| `polling_max_interval` | `300` | — | Backoff cap in seconds (5 min) |
| `tier_gate_enabled` | `true` | — | LLM validates each tier's output before next tier |
| `context_propagation_enabled` | `true` | — | Prepend tier summaries to next tier's issue bodies |
| `max_tier_retries` | `2` | — | Corrective retries per tier before pausing (0-5) |
| `library_path` | built-in | — | Custom personas/recipes dir |

## Architecture

```
NL Input
  |
  v
Library Manager ── find persona + recipe
  |
  v
Spec Generator ── NL + persona + recipe --> structured Markdown spec
  |
  v
Task Breaker ── spec --> 5-20 ordered tasks (JSON)
  |
  v
Executor ── tasks --> GitHub Issues, poll for PR diffs (exponential backoff)
  |                     (receives prior tier context when context_propagation_enabled)
  v
Tier Gate Check ── diffs --> pass/fail + context summary (per tier)
  |                          fail --> corrective tasks + retry (up to max_tier_retries)
  |                          still failing --> pause for human review
  v
Analyzer ── diffs + spec --> decision + confidence
  |
  |-- "done" (>=70% confidence) --> merge PRs, complete
  |-- "iterate_tasks" --> replace tasks, re-execute
  |-- "iterate_spec" --> refine spec, re-break, re-execute
  |
  v
Max 3 iterations, then stop. <70% confidence flags for human review.
```

**Agents** are stateless service objects — input in, output out. The **Orchestrator** owns state, persistence, and the feedback loop.

### Result Polling

After creating GitHub Issues, the Executor waits for external agents (GitHub Actions, Copilot, etc.) to produce PRs. It uses exponential backoff polling:

1. Check for PR diffs every `polling_interval` seconds (default: 30s)
2. Double the interval each cycle, capped at `polling_max_interval` (default: 5 min)
3. Stop when all tasks have results, or `polling_timeout` is reached (default: 30 min)

The pipeline transitions through `executing` -> `awaiting_results` -> `analyzing` as it waits. Tasks without an `external_id` (e.g. not submitted to GitHub) are skipped and don't block polling.

### Tier Gating & Context Propagation

Tasks are executed tier-by-tier (tier 0 first, then tier 1, etc.). After each tier's PRs are merged, two optional features kick in:

**Tier Gate Check** (`tier_gate_enabled`) — An LLM reviews the tier's diffs and decides pass/fail. If the tier fails:
1. Corrective tasks are created at the same tier and executed
2. The gate re-runs. If it still fails, retry up to `max_tier_retries` times
3. If retries are exhausted, the pipeline pauses with status `paused` and metadata indicating the failure — resume after manual review

Gate checks are lenient by default — only critical, build-breaking issues cause a failure. Minor issues are noted but don't block.

**Context Propagation** (`context_propagation_enabled`) — The gate check also produces a 2-3 sentence summary of what was built. This summary is accumulated across tiers and prepended to the next tier's GitHub issue bodies, giving coding agents explicit context about what already exists in the repo.

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

## Partial Execution & Resume

The pipeline can be paused at any stage and resumed later. This is useful for reviewing intermediate results before committing to the next step, or for recovering from failures.

### Stages

| `stop_after` | Stops after | What exists when paused |
|--------------|------------|------------------------|
| `:spec` | Spec generation | Specification (markdown + structured data) |
| `:tasks` | Task breakdown | Specification + 5-20 ordered tasks |
| `:published` | Issue creation | Tasks with GitHub Issue numbers |
| `:executed` | Result polling | Tasks with PR diffs and comments |
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

# Publish issues but don't wait for results
run = orchestrator.call(nl_input: "Build a todo app", stop_after: :published)
run.tasks.each { |t| puts "#{t.title} -> #{t.external_url}" }
```

### Resume

Resume a paused (or failed) pipeline run. The orchestrator infers where to pick up based on existing state:

```ruby
# Resume to completion
result = orchestrator.resume(pipeline_run: run)
result.status  # => "completed"

# Resume but pause again at a later stage
result = orchestrator.resume(pipeline_run: run, stop_after: :published)
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
| Tasks exist, no GitHub issue numbers | Issue publication |
| Tasks have issue numbers, incomplete results | Result polling |
| All tasks have results | Analysis |

If some tasks were published before a pause/failure and others weren't, resume will only publish the remaining tasks — already-published issues are not duplicated.

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

## License

MIT
