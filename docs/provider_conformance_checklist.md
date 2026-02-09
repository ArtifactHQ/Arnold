# Execution Provider Conformance Checklist

Run through this checklist before submitting a new execution provider.
Every item is pass/fail. All items must pass.

## Prerequisites

- [ ] `SharedProviderTests` included in test file and all 7 tests passing
      **Verify:** `include SharedProviderTests` + `def provider_instance = @provider` in test class
- [ ] Provider class extends `Providers::Execution::Base`
      **Verify:** `grep "< Base" lib/arnold_pipeline/providers/execution/your_provider.rb`

## 1. create_tasks

### Return shape

- [ ] Returns `Array<Hash>`, one element per input task
      **Verify:** `assert_equal tasks.size, results.size`
- [ ] Each element has `:external_id` key (String)
      **Source:** `executor.rb:29` — saved to task record
- [ ] Each element has `:external_url` key (String or nil)
      **Source:** `executor.rb:30` — saved to task record
- [ ] Each element has `:title` key (String)
      **Source:** `executor.rb:25` — used for `find_by(title:)` matching
- [ ] `:title` exactly matches the input task's title — no modification, truncation, or reformatting
      **Why:** `Executor` uses `find_by(title: result[:title])` — mismatch silently skips the DB update
      **Verify:** `assert_equal input_title, result[:title]`

### Argument handling

- [ ] Handles `tasks` as ActiveRecord `Task` objects (`.title`, `.description`, `.labels`)
- [ ] Handles `tasks` as Hashes with string keys (`"title"`, `"description"`, `"labels"`)
      **Verify:** Test both paths: `task.respond_to?(:title)` and `task["title"]`
- [ ] Uses `prior_context` when non-nil (embeds in task body or prompt)
      **Verify:** Assert output changes when `prior_context` is provided
- [ ] Functions correctly when `prior_context` is nil (first tier)

## 2. fetch_results

### Return shape

- [ ] Returns `Array<Hash>`
- [ ] Each element has `:task_id` (Integer) — must be a valid `Task.id`
      **Source:** `executor.rb:43` — used with `find(result[:task_id])`
- [ ] Each element has `:external_id` (String)
      **Source:** `executor.rb:51` — used in debug logging
- [ ] Each element has `:diffs` (Array)
      **Source:** `executor.rb:44` — `.to_json` called; `executor.rb:51` — `.size` called
- [ ] Each element has `:status` (Symbol)
      **Source:** `executor.rb:46` — only `:failed` (symbol) triggers status update
- [ ] Each element has `:workflow_active` (Boolean)
      **Source:** `executor.rb:47` — stored on task record, gates resolution in polling
- [ ] `:diffs` responds to `.to_json` without error
      **Verify:** `assert_nothing_raised { result[:diffs].to_json }`
- [ ] `:diffs` responds to `.size`
      **Verify:** `assert_respond_to result[:diffs], :size`
- [ ] `:diffs` is `Array` even when empty (never nil)
      **Verify:** `assert_kind_of Array, result[:diffs]`

### Filtering

- [ ] Skips tasks without `external_id` (returns no result for unpublished tasks)
      **Verify:** Create task with `external_id: nil`, assert `fetch_results` returns empty
- [ ] Scopes to `tasks:` argument when provided (does not return all tasks)
- [ ] Returns results for all published tasks when `tasks:` is nil

### Comments (if provided)

- [ ] Comment elements use string-compatible keys: `"source"`, `"author"`, `"body"`
      **Why:** `tier_execution_engine.rb` accesses `c['source']`, `c['author']`, `c['body']`
      **Why:** `task.rb` matches `comment["body"]` against `RESOLUTION_PATTERNS`/`WIP_PATTERNS`
- [ ] Comment `body` values are strings (not nil) — `body.to_s.match?` is called on them
- [ ] If no comment system exists, return `comments: []`

## 3. merge_results

- [ ] Returns without raising (for successfully merged work)
- [ ] Return value is an Array (`[]` is valid — return value is not consumed)
      **Source:** `tier_execution_engine.rb` merge methods don't use the return value
- [ ] Errors listed in `recoverable_errors` are swallowed by the engine during merge
      **Source:** `tier_execution_engine.rb` — `recoverable_merge_error?` checks `error.is_a?(klass)`
- [ ] `recoverable_errors` elements are exception classes (supports subclass matching via `is_a?`)

## 4. Sync / async behavior

### If `async?` returns `false`

- [ ] `workflow_active` is always `false` in every `fetch_results` return element
      **Why:** `true` blocks polling resolution indefinitely
      **Verify:** `assert_equal false, result[:workflow_active]` for every result
- [ ] Pipeline run never transitions to `awaiting_results` status
      **Verify:** After `engine.execute_tiers!`, `refute_equal "awaiting_results", pipeline_run.status`
- [ ] Provider does NOT call `.reload` on task objects
      **Why:** Engine reloads tasks automatically in the sync path
      **Verify:** `grep -r "\.reload" lib/arnold_pipeline/providers/execution/your_provider.rb` returns nothing

### If `async?` returns `true`

- [ ] `fetch_results` is safe to call repeatedly (idempotent per poll cycle)
- [ ] `workflow_active` accurately reflects whether background work is still running

## 5. Configuration

### validate_configuration!

- [ ] Defined as a class method (`def self.validate_configuration!(config)`)
- [ ] Receives a `Configuration` object (not individual config values)
- [ ] Raises `ArnoldPipeline::ConfigurationError` on invalid config (not `ArgumentError` etc.)
      **Why:** `ConfigurationError` is the expected type; available after `require_relative "base"`
- [ ] Does not raise for valid configuration
      **Verify:** `assert_nothing_raised { Provider.validate_configuration!(valid_config) }`
- [ ] Validates all provider-specific required config keys

### build_from_config

- [ ] Defined as a class method (`def self.build_from_config(config, **options)`)
- [ ] Returns an instance of the provider class
      **Verify:** `assert_kind_of YourProvider, YourProvider.build_from_config(config)`
- [ ] `**options` values override config values (not the other way around)
      **Verify:** `build_from_config(config, key: "override")` uses `"override"`
- [ ] Provider-specific config keys added as `attr_accessor` on `Configuration`
- [ ] Defaults set in `Configuration#initialize`

## 6. Registration

- [ ] Provider registered at bottom of provider file: `register(:name, Klass)`
      **Verify:** `grep "register(" lib/arnold_pipeline/providers/execution/your_provider.rb`
- [ ] `Execution.build(provider: :name)` returns an instance of the provider
      **Verify:** `assert_kind_of YourProvider, Execution.build(provider: :your_name)`
- [ ] Provider file is loaded before `Configuration#validate!` runs
      **Why:** Validation checks `Providers::Execution.registered_providers`; unregistered providers fail

## 7. Pitfall avoidance

- [ ] Title returned from `create_tasks` is never modified, truncated, or reformatted
      **Verify:** Test with a long title, special characters, Unicode
- [ ] `:status` uses the symbol `:failed` (not string `"failed"`) when indicating failure
- [ ] If comments are included, `body` values that accidentally match resolution patterns
      (`/finished/i`, `/\bfailed\b/i`, `/created? pr/i`) will trigger task resolution
      **Advisory:** Be aware of this when generating comment bodies

## 8. Integration

- [ ] `Executor.new(provider:).call(tasks:, pipeline_run:)` sets `external_id` on task records
      **Verify:** `task.reload.external_id.present?` after `executor.call`
- [ ] `executor.fetch_results` populates `result_diff` on task records
      **Verify:** `task.reload.result_diff.present?` after `executor.fetch_results`
- [ ] `TierExecutionEngine.new(executor:, tier_gate_check:, logger:).execute_tiers!` completes
      without error (with tier gate disabled)
      **Verify:** Stub provider internals, disable `tier_gate_enabled` and `context_propagation_enabled`
