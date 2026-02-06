# Arnold Pipeline

Agentic workflow system that transforms natural language descriptions into executable code. Describe an app, get working code — Arnold orchestrates AI agents through spec generation, task breakdown, GitHub-based execution, and iterative analysis.

## Quick Start (Standalone CLI)

```bash
gem install arnold_pipeline

export ANTHROPIC_API_KEY=sk-ant-...
export GITHUB_TOKEN=ghp_...

arnold run "Build a todo list app with user auth and real-time updates" --repo owner/repo
```

That's it. Arnold will:
1. Match your description to the best persona and recipe from its library
2. Generate a structured specification
3. Break it into 5-20 dependency-ordered tasks
4. Create GitHub Issues and trigger execution
5. Analyze results against the spec
6. Iterate up to 3 times until aligned (or flag for human review)

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
arnold status ID                     # Check a pipeline run
arnold list                          # List all runs

# Options for `run`:
#   --config FILE      YAML config file
#   --provider NAME    LLM provider (anthropic/openai)
#   --model NAME       Model name
#   --repo OWNER/REPO  GitHub repository
#   --verbose          Debug logging
```

## Configuration Reference

| Option | Default | Env Var | Description |
|--------|---------|---------|-------------|
| `llm_provider` | `:anthropic` | — | `:anthropic` or `:openai` |
| `llm_api_key` | — | `ANTHROPIC_API_KEY` | API key for the LLM provider |
| `llm_model` | `claude-sonnet-4-20250514` | — | Model identifier |
| `execution_provider` | `:github` | — | `:github` |
| `github_token` | — | `GITHUB_TOKEN` | GitHub personal access token |
| `github_repo` | — | — | Target repo (`owner/repo`) |
| `max_iterations` | `3` | — | Feedback loop cap (1-10) |
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
Executor ── tasks --> GitHub Issues, fetch PR diffs
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
