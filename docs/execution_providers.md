# Execution Provider Development Guide

## 1. Overview

Arnold Pipeline delegates task publication, result collection, and code merging to **execution providers** — pluggable backends behind a common interface defined in `Providers::Execution::Base`. The orchestration layer (`TierExecutionEngine`, `Executor`, `AnalysisLoop`) never imports provider-specific libraries; all provider-specific logic lives inside the provider class.

Two providers ship today: **`:github`** (async, creates GitHub Issues, polls for PRs) and **`:null`** (sync, returns canned responses, useful for testing). Third-party providers register via a symbol-keyed registry.

## 2. Interface Contract

Source: `lib/arnold_pipeline/providers/execution/base.rb`

### `create_tasks(tasks:, pipeline_run:, prior_context: nil)`

Publishes tasks to the execution backend.

**Arguments:**
- `tasks` — `Array<Task | Hash>` with `"title"`, `"description"`, `"labels"`, `"position"`, `"depends_on"` keys. Pre-filtered to unpublished tasks only.
- `pipeline_run` — `PipelineRun` ActiveRecord model.
- `prior_context` — `String?` Markdown context from prior tiers: `"## Prior Implementation Context\n\n**Tier 0 completed:** ..."`. `nil` for first tier.

**Returns:** `Array<Hash>`, one per task:

```ruby
{ external_id: String, external_url: String?, title: String }
```

**Call chain:** Providers are never called directly by the engine. The engine calls `executor.call()`, which filters unpublished tasks, calls `provider.create_tasks(tasks: unpublished, ...)`, then matches results to Task records via `find_by(title: result[:title])` (`executor.rb:25`) and saves `external_id`/`external_url`. The `title` must exactly match the input — a mismatch silently skips the update.

**Required:** Yes — `Base` raises `NotImplementedError`.

### `fetch_results(pipeline_run:, tasks: nil)`

Retrieves current results for published tasks.

**Arguments:**
- `pipeline_run` — `PipelineRun`
- `tasks` — `Array<Task>?` Scope to these tasks (tier-scoped). `nil` = all tasks.

**Returns:** `Array<Hash>`, one per task with an `external_id`:

```ruby
{
  task_id: Integer,           # Task.id — used to find record (executor.rb:43)
  external_id: String,        # Echoed for debug logging (executor.rb:51)
  diffs: Array<Hash>,         # Serialized via .to_json, stored in task.result_diff (executor.rb:44)
  comments: Array<Hash>,      # Stored in task.result_comments when present (executor.rb:45)
  issue_state: String,        # NOT consumed by call sites — GitHub-ism, safe to omit
  status: Symbol,             # Only :failed triggers task status update (executor.rb:46)
  workflow_active: Boolean,   # true blocks task resolution in polling loop (executor.rb:47)
  workflow_details: String    # Debug logging only (executor.rb:54)
}
```

**Diff element shape:** `{ filename: String, patch: String, status: String }`. The array is serialized to JSON. Downstream consumers (Analysis Agent, Tier Gate) concatenate all diffs into a plain-text string for LLM analysis — the internal structure is never parsed programmatically. Any human-readable format works.

**Comment element shape:** `{ source: String, author: String, body: String, created_at: String }`. Accessed with **string keys** (not symbols) at `tier_execution_engine.rb:86` and `task.rb:57,69`. The `body` is matched against `RESOLUTION_PATTERNS`/`WIP_PATTERNS` in the Task model.

**Required:** Yes — `Base` raises `NotImplementedError`.

### `merge_results(pipeline_run:, tasks: nil)`

Finalizes completed work (e.g., merging PRs). Same arguments as `fetch_results`.

**Returns:** `Array<Hash>` — provider-specific, **not consumed** by call sites. Return `[]` for a valid no-op.

Errors matching `recoverable_errors` are swallowed during merge calls (`tier_execution_engine.rb:68-70, 95-101`).

**Required:** Yes — `Base` raises `NotImplementedError`.

### `async?`

Whether the provider requires polling to collect results.

| Value | Behavior (source: `tier_execution_engine.rb:34-41`) |
|-------|------|
| `true` | Engine transitions to `awaiting_results`, enters polling loop via `executor.await_results` |
| `false` | Engine calls `executor.fetch_results` once — no polling, no `awaiting_results` state |

**Default:** `true`.

### `recoverable_errors`

Exception classes swallowed during merge operations. Uses `error.is_a?(klass)` for subclass matching.

**Returns:** `Array<Class>`. **Default:** `[]` (all merge errors re-raise).

Only applies to `merge_all_results!` and `merge_tier_results!`. Errors from `create_tasks`/`fetch_results` always propagate.

### `self.validate_configuration!(config)`

Class method. Receives the `Configuration` object. Raise `ConfigurationError` on invalid config, return anything on success. `ConfigurationError` is defined in the `ArnoldPipeline` module and is available after requiring `base.rb`.

**Default:** No-op. Called during `Configuration#validate!` unless `stop_after` is `:spec` or `:tasks`.

### `self.build_from_config(config, **options)`

Class method. Factory that constructs a provider from config. `**options` override config values (passed from `Execution.build`).

**Default:** `new(**options)`.

**Example** (GitHub, `github.rb:33-39`):

```ruby
def self.build_from_config(config, **options)
  new(
    token: options[:token] || config.github_token,
    repo: options[:repo] || config.github_repo,
    issue_mention: options[:issue_mention] || config.github_issue_mention
  )
end
```

## 3. Sync vs. Async Execution

```
 Async (async? = true):
 executing -> create_tasks -> awaiting_results -> await_results (poll loop) -> merge -> gate

 Sync (async? = false):
 executing -> create_tasks -> fetch_results (once) -> merge -> gate
```

**Async polling** (`agents/executor.rb:61-103`): Calls `fetch_results` repeatedly with exponential backoff (`polling_interval` doubling to `polling_max_interval`). Exits when all tasks are resolved or `polling_timeout` exceeded. A task is resolved when `workflow_active == false` AND at least one of: non-empty `result_diff`, `failed?` status, or substantive comments.

**Sync task reload (handled by engine):** After `executor.call()` sets `external_id` in the database, the `TierExecutionEngine` automatically reloads task objects before calling `fetch_results` on sync providers. Providers do not need to reload tasks themselves.

**State machine** (`pipeline_run.rb:20`): `executing` can transition to both `awaiting_results` (async) and `analyzing` (sync). Both paths reach `analyzing`.

## 4. Configuration

### Validation Flow

```
Configuration#validate! -> validate_execution_provider!    (checks name is known)
                        -> validate_execution_config!      (skipped for :spec/:tasks)
                             -> Provider.validate_configuration!(self)
```

### Config Keys

| Key | Default | Used By |
|-----|---------|---------|
| `execution_provider` | `:github` | All — selects provider |
| `github_token` | `ENV["GITHUB_TOKEN"]` | GitHub only |
| `github_repo` | `nil` | GitHub only |
| `github_issue_mention` | `nil` | GitHub only |
| `polling_interval` | `30` | Async providers |
| `polling_timeout` | `1800` | Async providers |
| `polling_max_interval` | `300` | Async providers |
| `workflow_status_enabled` | `true` | GitHub only |
| `workflow_branch_pattern` | `/issue[-_]?\d+/i` | GitHub only |

To add provider-specific keys: add `attr_accessor` to `Configuration`, set defaults in `initialize`, validate in your `validate_configuration!`.

## 5. Registration

```ruby
# At the bottom of your provider file:
ArnoldPipeline::Providers::Execution.register(:my_provider, MyProvider)
```

Built-in providers (`:github`, `:null`) are auto-loaded on demand. Custom providers must register before use — in a Rails initializer or gem require path. Registration must happen **before** `Configuration#validate!` runs, because validation checks the registry dynamically via `Providers::Execution.registered_providers`. There is no need to modify the `VALID_EXECUTION_PROVIDERS` constant — the registry lookup is sufficient.

`Execution.build` resolves the provider via registry:

```ruby
def self.build(provider: nil, **options)
  config = ArnoldPipeline.configuration
  provider ||= config.execution_provider
  klass = provider_class_for(provider)
  klass.build_from_config(config, **options)
end
```

## 6. Building a New Provider

Complete skeleton for a hypothetical **Local** provider:

```ruby
# lib/arnold_pipeline/providers/execution/local.rb
require_relative "base"

module ArnoldPipeline
  module Providers
    module Execution
      class Local < Base
        def async? = false
        def recoverable_errors = []

        def self.validate_configuration!(config)
          # TODO: raise ConfigurationError for missing config
        end

        def self.build_from_config(config, **options)
          new # TODO: pass config keys to constructor
        end

        def create_tasks(tasks:, pipeline_run:, prior_context: nil)
          tasks.each_with_index.map do |task, i|
            # Tasks can be ActiveRecord objects or Hashes — use dual-access pattern
            title = task.respond_to?(:title) ? task.title : task["title"]
            description = task.respond_to?(:description) ? task.description : task["description"]
            labels = task.respond_to?(:labels) ? task.labels : (task["labels"] || [])
            # TODO: execute the task locally using title, description, labels
            { external_id: "local-#{pipeline_run.id}-#{i}", external_url: nil, title: title }
          end
        end

        def fetch_results(pipeline_run:, tasks: nil)
          (tasks || pipeline_run.tasks).filter_map do |task|
            next unless task.external_id
            # TODO: collect real diffs/status
            { task_id: task.id, external_id: task.external_id, diffs: [],
              comments: [], issue_state: "closed", status: :completed,
              workflow_active: false, workflow_details: "local execution" }
          end
        end

        def merge_results(pipeline_run:, tasks: nil) = []
      end

      register(:local, Local)
    end
  end
end
```

### Test file

```ruby
# test/lib/arnold_pipeline/providers/execution/local_test.rb
require "test_helper"
require "arnold_pipeline/providers/execution/local"
require_relative "shared_provider_tests"

module ArnoldPipeline
  module Providers
    module Execution
      class LocalTest < ActiveSupport::TestCase
        include SharedProviderTests

        def provider_instance = @provider

        setup do
          @provider = Local.new
          @pipeline_run = PipelineRun.create!(nl_input: "Build an app")
        end

        test "create_tasks returns valid external_ids" do
          tasks = [{ "title" => "Setup", "description" => "Init project" }]
          results = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)
          assert_equal "Setup", results.first[:title]
          assert results.first[:external_id].present?
        end

        test "fetch_results returns completed status" do
          @pipeline_run.tasks.create!(title: "Setup", position: 0, external_id: "local-1-0")
          results = @provider.fetch_results(pipeline_run: @pipeline_run)
          assert_equal :completed, results.first[:status]
        end

        test "Execution.build works" do
          ArnoldPipeline.configure { |c| c.execution_provider = :local }
          assert_kind_of Local, Execution.build
        ensure
          ArnoldPipeline.reset_configuration!
        end
      end
    end
  end
end
```

Run: `bundle exec rails test test/lib/arnold_pipeline/providers/execution/local_test.rb`

## 7. Return Shape Reference

### `create_tasks` return element

| Key | Type | Required | Accessed At |
|-----|------|----------|-------------|
| `external_id` | `String` | Yes | `executor.rb:29` |
| `external_url` | `String?` | Yes (nil ok) | `executor.rb:30` |
| `title` | `String` | Yes | `executor.rb:25` — exact match for `find_by` |

### `fetch_results` return element

| Key | Type | Required | Accessed At |
|-----|------|----------|-------------|
| `task_id` | `Integer` | Yes | `executor.rb:43` |
| `external_id` | `String` | Yes | `executor.rb:51` (logging) |
| `diffs` | `Array<Hash>` | Yes | `executor.rb:44` (`.to_json`), `executor.rb:51` (`.size`) |
| `comments` | `Array<Hash>?` | No | `executor.rb:45` |
| `issue_state` | `String` | No | Not accessed — GitHub-ism |
| `status` | `Symbol` | Yes | `executor.rb:46` — only `:failed` checked |
| `workflow_active` | `Boolean` | Yes | `executor.rb:47` |
| `workflow_details` | `String?` | No | `executor.rb:54` (logging) |

### Comment element

| Key | Type | Required | Accessed At |
|-----|------|----------|-------------|
| `source` | `String` | Yes | `tier_execution_engine.rb:86` (string key) |
| `author` | `String` | Yes | `tier_execution_engine.rb:86` (string key) |
| `body` | `String` | Yes | `tier_execution_engine.rb:86`, `task.rb:57,69` (pattern matching) |
| `created_at` | `String` | No | Not accessed |

### `merge_results` — return not consumed. `[]` is valid.

## 8. Common Pitfalls

**`title` matching is exact.** `find_by(title: result[:title])` — any modification silently breaks the match.

**`workflow_active` gates resolution.** Sync providers must return `false`. Returning `true` blocks the polling loop indefinitely.

**`issue_state` is a GitHub-ism.** Not accessed by any call site. Safe to include or omit.

**Comment `body` triggers resolution patterns.** The Task model matches bodies against patterns like `/finished/i`, `/created? pr/i`, `/\bfailed\b/i` (`task.rb:14-25`). These determine whether a task is "resolved" when it has no diffs. Be aware that comments containing these keywords will trigger resolution.

**Comment keys are string-keyed.** `c['source']`, `c['author']`, `c['body']` — not symbols. Symbol keys work if stored via JSON (serialization converts to strings), but values must be meaningful strings.

**`prior_context` is Markdown.** Providers should embed it in task bodies for execution backend context. Ignoring it (like Null does) is acceptable for testing but means later tiers lose context.

**Sync providers skip `awaiting_results`.** State goes `executing -> analyzing` directly. Polling config is irrelevant.

**Stale objects after publish (handled by engine).** After `create_tasks`, in-memory Task objects may have `nil` `external_id` even though the DB was updated. The `TierExecutionEngine` reloads tasks automatically before calling `fetch_results` on sync providers. Providers should NOT reload tasks themselves.

**`recoverable_errors` only covers merge.** Errors from `create_tasks`/`fetch_results` always propagate regardless of this list.

**Diffs are opaque.** Downstream LLM consumers receive diffs as concatenated plain text — they never parse the structure. Any human-readable format works, but `diffs` must be an `Array` (`.to_json` and `.size` are called on it).

## 9. Testing Your Provider

### Shared compliance tests

```ruby
include ArnoldPipeline::Providers::Execution::SharedProviderTests
def provider_instance = @provider
```

Source: `test/lib/arnold_pipeline/providers/execution/shared_provider_tests.rb`

| Test | Assertion |
|------|-----------|
| `test_responds_to_create_tasks` | `respond_to?(:create_tasks)` |
| `test_responds_to_fetch_results` | `respond_to?(:fetch_results)` |
| `test_responds_to_merge_results` | `respond_to?(:merge_results)` |
| `test_responds_to_async` | `respond_to?(:async?)` |
| `test_responds_to_recoverable_errors` | `respond_to?(:recoverable_errors)` |
| `test_recoverable_errors_returns_array` | `kind_of?(Array)` |
| `test_async_returns_boolean` | `true` or `false` |

### Additional tests to write

1. `create_tasks` returns correct shape (`external_id`, `external_url`, `title` keys)
2. `fetch_results` returns correct shape (`task_id`, `diffs`, `status`, `workflow_active`)
3. `fetch_results` skips tasks without `external_id`
4. `merge_results` returns without error
5. `validate_configuration!` rejects/accepts config
6. `build_from_config` constructs correct instance
7. `Execution.build(provider: :your_name)` end-to-end factory test

Run: `bundle exec rails test`

## 10. Integration Testing

To verify your provider works through the full engine pipeline (not just unit tests), write an integration test that exercises `TierExecutionEngine`.

### Setup

```ruby
require "arnold_pipeline/agents/executor"
require "arnold_pipeline/tier_execution_engine"

# Build your provider
provider = Providers::Execution.build

# Wrap in an Executor
executor = Agents::Executor.new(provider:, logger: Logger.new(File::NULL))

# TierExecutionEngine requires three constructor args:
engine = TierExecutionEngine.new(
  executor: executor,
  tier_gate_check: stub(call: nil),  # stub to avoid LLM calls
  logger: Logger.new(File::NULL)
)
```

### Recommended config for integration tests

```ruby
ArnoldPipeline.configure do |c|
  c.execution_provider = :your_provider
  # ... your provider-specific config ...
  c.tier_gate_enabled = false            # avoid LLM stub routing conflicts
  c.context_propagation_enabled = false  # simplify test scope
end
```

### Key assertions for sync providers

- `provider.async?` returns `false`
- After `engine.execute_tiers!(pipeline_run)`, all tasks have `external_id` and `result_diff`
- `pipeline_run.status` is never `"awaiting_results"`
