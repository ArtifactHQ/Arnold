# Arnold Pipeline

Agentic workflow system that transforms natural language descriptions into executable code. Describe an app, get working code — Arnold orchestrates AI agents through spec generation, task breakdown, GitHub-based execution, and iterative analysis.

## Quick Start (Standalone CLI)

```bash
gem install arnold_pipeline

export ANTHROPIC_API_KEY=sk-ant-...   # or OPENAI_API_KEY=sk-...
export GITHUB_TOKEN=ghp_...

arnold run "Build a todo list app with user auth and real-time updates" --repo owner/repo
# Using OpenAI instead:
arnold run "Build a todo list app" --provider openai --repo owner/repo
```

That's it. Arnold will:
1. Match your description to the best persona and recipe from its library
2. Generate a structured specification
3. Break it into 5-20 dependency-ordered tasks
4. Create GitHub Issues and trigger execution
5. Poll for PR results with exponential backoff
6. Analyze results against the spec
7. Iterate up to 3 times until aligned (or flag for human review)

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

  # Polling: how long to wait for external agents to produce PRs
  config.polling_interval     = 30   # initial interval between checks (seconds)
  config.polling_timeout      = 1800 # max total wait time (seconds)
  config.polling_max_interval = 300  # backoff cap (seconds)
end
```

Use programmatically:

```ruby
# Synchronous
result = ArnoldPipeline::Orchestrator.new.call(nl_input: "Build a REST API for inventory management")
result.status       # => "completed"
result.tasks.count  # => 12
result.iterations   # => [#<Iteration decision="done" confidence=95>]

# Async (via ActiveJob)
run = ArnoldPipeline::PipelineRun.create!(nl_input: "Build a dashboard app")
ArnoldPipeline::PipelineJob.perform_later(run.id)
```

## CLI Commands

```bash
arnold run "description" [options]   # Run the full pipeline
arnold spec ID [options]             # Export a run's specification
arnold status ID                     # Check a pipeline run
arnold list                          # List all runs
arnold version                       # Show version

# Options for `run`:
#   --config FILE              YAML config file
#   --provider NAME            LLM provider (anthropic/openai)
#   --model NAME               Model name
#   --repo OWNER/REPO          GitHub repository
#   --polling-interval SECS    Polling interval (default: 30)
#   --polling-timeout SECS     Max polling wait (default: 1800)
#   --verbose                  Debug logging

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
| `max_iterations` | `3` | — | Feedback loop cap (1-10) |
| `polling_interval` | `30` | — | Seconds between PR polling checks |
| `polling_timeout` | `1800` | — | Max seconds to wait for PRs (30 min) |
| `polling_max_interval` | `300` | — | Backoff cap in seconds (5 min) |
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
  |
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
