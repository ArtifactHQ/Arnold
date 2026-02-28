# Test Audit Report

**Project:** arnold_pipeline (Rails 8 mountable engine gem)
**Auditor:** test-auditor agent
**Date:** 2026-02-27
**Test Framework:** Minitest via `bundle exec rails test`

---

## Summary

| Metric | Result |
|---|---|
| Suite status | RED — 2 consistent failures, 2 intermittent errors |
| Total tests | 1,918 runs |
| Assertions | 6,482 |
| Passing | 1,916 |
| Failing | 2 (consistent, same failures across seeds) |
| Errors | 0–2 (intermittent SQLite locking under non-default seed) |
| Skipped | 0 |
| Coverage | Not measured — SimpleCov not configured |
| Portability issues | 3 (1 critical, 2 moderate) |
| CI status | Present but contains invalid action version (`actions/checkout@v6`) |
| Bootstrap | `bin/setup` is absent — must use `bundle install && bin/rails db:test:prepare` manually |

---

## Phase 1: Bootstrap

### `bin/setup` Status: ABSENT

No `bin/setup` script exists. The `bin/` directory contains only `bin/rails` and `bin/rubocop`. New contributors have no documented bootstrap path.

**What a new contributor must do manually:**

```sh
bundle install
bin/rails db:test:prepare
bundle exec rails test
```

The project is a Rails engine gem. Its test database is a SQLite file at `test/dummy/storage/test.sqlite3`. `bin/rails db:test:prepare` runs without errors and is idempotent.

**Recommended `bin/setup` to scaffold:**

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "==> Installing Ruby dependencies"
bundle install

echo "==> Preparing test database"
bin/rails db:test:prepare

echo "==> Arnold Pipeline is ready for development."
echo "    Run tests: bundle exec rails test"
```

**Missing from any documented setup:** git must be installed on the PATH. Several tests (dedup migration, claude_code provider, post_merge_hook_runner) call `git` via `system()` and will fail silently or raise if git is absent. This is not documented anywhere.

---

## Phase 2: Test Results

### Consistent Failures (2)

Both failures originate in `test/e2e/plugin_compatibility_test.rb` and are caused by a **false-positive in the test's regex logic**, not a genuine bug in Arnold.

**Failure 1:** `test_plugin_agent_does_not_reference_nonexistent_tools` (line 42)
**Failure 2:** `test_all_plugin_commands_reference_only_valid_tools` (line 71)

**Root cause:** The tests scan for backtick-quoted snake_case identifiers in plugin Markdown files and assert each one is a registered Arnold MCP tool. The identifier `open_questions` appears in backticks in:
- `arnold-claude-code-plugin/agents/arnold.md` (lines 91, 106, 172)
- `arnold-claude-code-plugin/commands/arnold-new.md` (line 26)

`open_questions` is a **JSON response field** returned by `create_product` and `explore_capability` (defined in `lib/arnold_pipeline/mcp/tools/create_product.rb:59` and `explore_capability.rb:22`). It is not a tool name. The test's regex over-captures it because it includes an underscore and is lowercase — the same heuristic used to identify tool names.

**Fix:** Add an allowlist for known non-tool backtick terms, or restrict the regex to only match terms that appear in a list-context (e.g., following `call`, `use`, `invoke`). The simplest fix is to add `open_questions` to an exclusion list in the test:

```ruby
# In test/e2e/plugin_compatibility_test.rb
NON_TOOL_IDENTIFIERS = %w[open_questions].freeze

tool_like_names = backtick_names
  .select { |n| n.include?("_") && n == n.downcase }
  .reject { |n| NON_TOOL_IDENTIFIERS.include?(n) }
```

### Intermittent Errors (order-dependent, 0–2)

When run with seed `12345`, two additional `ActiveRecord::StatementTimeout: SQLite3::BusyException: database is locked` errors appear:

- `ArnoldPipeline::PipelineJobTest#test_performs_by_calling_orchestrator_with_existing_pipeline_run`
- `ArnoldPipeline::Providers::Execution::GithubTest#test_validate_configuration!_raises_on_missing_github_repo`
- `ArnoldPipeline::Mcp::Tools::ProposeChangeTest#test_call_returns_summary_from_analysis`

These do not appear under random seed (default run). They are triggered by test execution order where a prior test leaves a SQLite transaction open — most likely the `McpSmokeTest` which uses a background thread for the MCP server and may not cleanly close the DB connection before the next test class acquires a lock.

**Assessment:** Classic SQLite concurrency limitation. The `McpSmokeTest` spawns a `Thread.new { @server.start }` in its `setup`. If that thread holds an ActiveRecord connection when teardown runs, the next test in a certain order sees a locked database. The teardown does `@server_thread.join(2)` with a 2-second timeout — if the server thread doesn't exit cleanly, the AR connection leaks.

**Severity:** Moderate. These errors do not appear in the default random seed run, making CI green most of the time, but they will bite reproducible seed runs and may manifest in CI if a specific ordering is hit.

### Tests Missing Assertions (3 warnings, not failures)

Three tests produce `Test is missing assertions` warnings:

1. `tier_execution_engine_test.rb:963` — `test_runs_post-merge_hooks_after_merge_and_before_gate_check`
2. `tier_execution_engine_test.rb:1008` — `test_runs_verification_checks_after_hooks_and_before_gate_check`
3. `shared_provider_tests.rb:33` — `test_fetch_results_execution_metadata_shape`

The first two tests verify that `execute_tiers!` runs without errors when hooks/checks are configured but do not assert any specific outcome (no `assert_*` calls, only mocha stubs). They function as "smoke tests that don't raise." The third uses an early `return` guard that skips the assertions when subclasses don't implement `setup_fetch_results_for_metadata_test`. In all three cases the intent is real but the assertion coverage is absent.

### Side Effect: Git Commits During Test Run

The `TierExecutionEngineTest#test_dedup_migration_timestamps!_renames_duplicate_timestamp_migrations` test makes `git commit` calls against a `Dir.mktmpdir` repository. The commit output (`[master 83365dc] fix: deduplicate migration timestamps after parallel merge`) appears in stdout during the test run. This is cosmetically noisy but harmless — the commit targets the tmpdir, not the actual project repo. The `[master ...]` branch indicator is the branch name inside the temp repo, not the project branch.

However, this test requires `git` to be on PATH and `git commit` to succeed (which requires a configured `user.email` and `user.name`). In CI environments without a pre-configured git identity, this will silently fail (the call uses `system()` which returns false on failure rather than raising). The test does not configure a git identity in the tmpdir, relying on the global git config inherited from the CI environment. This is a portability concern (see Phase 3).

---

## Phase 3: Portability Issues

### Issue 1: CRITICAL — WebMock not globally enabled

**Files:** `test/test_helper.rb`

WebMock is required per-file only in four test files:
- `test/lib/arnold_pipeline/providers/llm/anthropic_test.rb`
- `test/lib/arnold_pipeline/providers/llm/open_ai_test.rb`
- `test/lib/arnold_pipeline/providers/execution/github_test.rb`
- `test/integration/pipeline_end_to_end_test.rb`

`WebMock.disable_net_connect!` is **not called globally** in `test_helper.rb`. The vast majority of tests use Mocha stubs to inject fake LLM/GitHub clients at the object level (which is correct), but a test that accidentally constructs a real provider without stubbing its HTTP client would make a live network call without any guard preventing it.

**Risk:** If a future test initializes an `Anthropic` or `OpenAI` client without stubbing and calls `chat`, it will hit the real API. This will fail in CI (no API keys) but may silently succeed in local environments where developer keys are present in ENV.

**Recommended fix** (1 line in `test/test_helper.rb`):

```ruby
require "webmock/minitest"
WebMock.disable_net_connect!(allow_localhost: true)
```

Add this after the `require "rails/test_help"` line. The `allow_localhost: true` option is needed because the `McpSmokeTest` tests use local IO pipes (not actual localhost TCP), but it's a safe default.

### Issue 2: MODERATE — Plugin compatibility test depends on machine-local path

**File:** `test/e2e/plugin_compatibility_test.rb:7`

```ruby
PLUGIN_PATH = File.expand_path("~/Documents/Projects/artifact/arnold-claude-code-plugin")
```

This hardcodes `~/Documents/Projects/artifact/` as the expected location of the `arnold-claude-code-plugin` repo. The test does guard with `skip "Plugin repo not found"` in `setup`, so it correctly skips on machines where the path doesn't exist. However:

1. The path reveals the developer's personal directory layout.
2. There is no documented alternative (e.g., `ARNOLD_PLUGIN_PATH` environment variable) for CI or other contributors to provide the path.
3. When the path DOES exist (as it does on this machine), the tests run and currently produce 2 failures.

**Recommended fix:** Use an environment variable with a fallback:

```ruby
PLUGIN_PATH = File.expand_path(
  ENV.fetch("ARNOLD_PLUGIN_PATH", "~/Documents/Projects/artifact/arnold-claude-code-plugin")
)
```

And document `ARNOLD_PLUGIN_PATH` in the contributing guide.

### Issue 3: MODERATE — Git identity not configured for dedup_migration test

**File:** `test/lib/arnold_pipeline/tier_execution_engine_test.rb:152–181`

The `test_dedup_migration_timestamps!_renames_duplicate_timestamp_migrations` test calls `system("git", "commit", ...)` inside a tmpdir repo without setting `user.email` or `user.name` in the local git config. In a CI environment with no global git identity (common on GitHub Actions runners), the commit will silently fail with a non-zero exit code. The method's `rescue => e` swallows the error, so the test passes anyway — but the assertion that files were renamed could still pass even if the commit failed, because the rename is done via `File.rename` before the commit.

Compare with `post_merge_hook_runner_test.rb:13–14` which correctly configures git identity:

```ruby
system("git", "-C", @tmpdir, "config", "user.email", "test@example.com")
system("git", "-C", @tmpdir, "config", "user.name", "Test")
```

The dedup test should do the same. Additionally, CI yaml should add:

```yaml
- name: Configure git identity for tests
  run: |
    git config --global user.email "ci@example.com"
    git config --global user.name "CI"
```

### Non-Issues (verified clean)

- **No hardcoded machine paths in lib/:** All source code uses relative paths or configurable paths.
- **No embedded API keys or tokens:** Search across all test fixtures and cassettes found no embedded secrets.
- **No private internal endpoints:** No internal hostnames, IPs, or private registry references.
- **No Redis/PostgreSQL/Elasticsearch dependencies:** The test environment uses only SQLite via the dummy app.
- **Binary dependencies declared:** Git and Claude CLI (`claude`) are used in integration/e2e tests, but all claude_code provider tests stub `execute_claude_code` rather than calling the binary.
- **Mocha injection pattern is portable:** The primary test pattern (stub LLM/provider at the object level via Mocha) is fully portable and correct. No VCR cassettes are used.

---

## Phase 4: Coverage Analysis

### SimpleCov: Not Configured

SimpleCov is not present in the Gemfile or test_helper.rb. No coverage data was collected during this audit. Quantitative line/branch coverage percentages are unavailable.

**To add SimpleCov**, insert at the **top** of `test/test_helper.rb` (before any other requires):

```ruby
require "simplecov"
SimpleCov.start "rails" do
  add_filter "/test/"
  add_filter "/lib/generators/"
  minimum_coverage 80
  coverage_dir "coverage"
end
```

And add to `Gemfile`:

```ruby
group :test do
  gem "simplecov", require: false
end
```

### Coverage Assessment by Critical Component

Coverage assessment is based on code inspection of test files vs. source files.

#### Orchestrator (`lib/arnold_pipeline/orchestrator.rb`) — WELL COVERED

Three dedicated test files totaling 1,565 lines:
- `test/lib/arnold_pipeline/orchestrator_test.rb` (921 lines)
- `test/lib/arnold_pipeline/orchestrator_partial_test.rb` (383 lines)
- `test/lib/arnold_pipeline/orchestrator_tier_gate_test.rb` (261 lines)

Covers: `call`, `resume`, partial execution (`stop_after:`), tier gate integration, analysis loop, pause/resume checkpoints.

#### Tier Calculator (`lib/arnold_pipeline/tier_calculator.rb`) — ADEQUATELY COVERED

`test/lib/arnold_pipeline/tier_calculator_test.rb` (90 lines) covers DAG-based tier computation and cycle detection.

**Gap:** No test for the topological sort auto-repair path (Kahn's algorithm correcting backwards `depends_on`). The source comment confirms this was added empirically, but the test file doesn't exercise the repair path directly.

#### Tier Execution Engine (`lib/arnold_pipeline/tier_execution_engine.rb`) — WELL COVERED

`test/lib/arnold_pipeline/tier_execution_engine_test.rb` is the largest test file at 2,643 lines. Covers tier execution loop, gate failures, retries, dedup, post-merge hooks, verification checks, corrective task generation, context propagation.

**Gap:** Two tests (`test_runs_post-merge_hooks...` and `test_runs_verification_checks...`) are assertion-free smoke tests (no `assert_*`). They verify no exception is raised, but do not verify that the hooks/checks were actually invoked in the correct order relative to the gate check.

#### Execution Provider Conformance (`SharedProviderTests`) — ADEQUATELY COVERED

All three execution providers (GitHub, ClaudeCode, Null) include `SharedProviderTests`, ensuring interface conformance. The `test_fetch_results_execution_metadata_shape` shared test uses a guard that effectively skips it for all current providers that don't implement `setup_fetch_results_for_metadata_test`.

**Gap:** `setup_fetch_results_for_metadata_test` is not implemented by any provider test class. The conformance test for `execution_metadata` shape is always skipped. This is the highest-value uncovered conformance contract in the project.

#### Analysis Loop (`lib/arnold_pipeline/analysis_loop.rb`) — ADEQUATELY COVERED

`test/lib/arnold_pipeline/analysis_loop_test.rb` covers iteration limit enforcement, `iterate_tasks`, `iterate_spec`, confidence scoring, and convergence.

#### LLM Providers (`lib/arnold_pipeline/providers/llm/`) — WELL COVERED

Both Anthropic and OpenAI provider tests use WebMock to test actual HTTP interaction. Error paths (rate limiting, 400s, timeouts, truncation) are covered.

#### MCP Tools (`lib/arnold_pipeline/mcp/tools/`) — WELL COVERED

All 20 registered MCP tools have dedicated test files under `test/lib/arnold_pipeline/mcp/tools/`. Integration tests in `test/lib/arnold_pipeline/mcp/integration/` and `test/e2e/mcp_lifecycle_test.rb` cover multi-step tool flows.

#### Specification Model (`app/models/arnold_pipeline/specification.rb`) — GAP

There is **no dedicated test file** for the `Specification` model. It is exercised indirectly through orchestrator, MCP tool, and integration tests, but validations, callbacks, and scopes on the model itself are not unit tested. The model handles spec versioning — a critical business operation.

#### Drift Detector (`lib/arnold_pipeline/agents/drift_detector.rb`) — ADEQUATELY COVERED

`test/lib/arnold_pipeline/agents/drift_detector_test.rb` exists. The drift detection is also exercised via MCP tool tests.

#### SpecTestGeneration Prompt (`lib/arnold_pipeline/prompts/spec_test_generation.rb`) — GAP

There is **no test file** for `prompts/spec_test_generation.rb`. All other prompt modules have dedicated tests (`analysis_test.rb`, `spec_generation_test.rb`, `spec_iteration_test.rb`, `task_breakdown_test.rb`, `tier_gate_test.rb`). The spec test generation prompt is the only untested one.

### Coverage Gap Report

#### Critical Gaps (must fix)

- **`app/models/arnold_pipeline/specification.rb` — no unit tests**
  The Specification model manages spec content, versioning, and the relationship to SpecRevisions. Validations (required fields, version uniqueness) and any scopes or callbacks have no unit test coverage. Breakage here would corrupt the spec history workflow.

- **`SharedProviderTests#test_fetch_results_execution_metadata_shape` never executes**
  In `test/lib/arnold_pipeline/providers/execution/shared_provider_tests.rb:33`, the method returns early for all three providers because none implements `setup_fetch_results_for_metadata_test`. The `execution_metadata` shape contract (must be nil or Hash, must be JSON-serializable) is the key contract enabling the tier gate and corrective task generator to consume provider output. If a provider returns non-serializable metadata, it will silently break the pipeline event recorder and corrective task descriptions.

#### Moderate Gaps (should fix)

- **`lib/arnold_pipeline/prompts/spec_test_generation.rb` — no prompt test**
  All five other prompt modules have tests verifying prompt content, required keywords, and parameter interpolation. `spec_test_generation.rb` has none. Prompt regressions in this file would not be caught until a pipeline run exercises it.

- **`tier_execution_engine_test.rb:963,1008` — smoke tests without assertions**
  The two tests that verify hook/verification execution ordering have no `assert_*` calls. They confirm the code doesn't raise, but don't verify that `PostMergeHookRunner.call` was actually invoked (which the mocha stub enables). Adding `expects` assertions would convert these from "runs without crashing" to "runs in the expected order."

- **TierCalculator: `auto_repair_backwards_depends_on` path not tested**
  The Kahn's algorithm topological sort repair (which corrects LLM-generated tasks with backwards dependency declarations) is a critical correctness guarantee. It appears to be tested indirectly through task_breaker tests but deserves a direct unit test in `tier_calculator_test.rb`.

#### Minor Gaps (nice to have)

- **`lib/arnold_pipeline/services/claude_md_generator.rb`** — one test file exists but is small. Generator behavior with varied repo contents (schema.rb present/absent, routes.rb present/absent) could use more edge case coverage.

- **`lib/arnold_pipeline/cli.rb` error paths** — the CLI tests cover the happy paths and help flag, but `rescue` blocks in `run`, `resume`, and `status` commands are untested.

- **`lib/arnold_pipeline/resume_inferrer.rb`** — the inferrer has a dedicated test file but it only covers 5 scenarios. Edge cases around partially-executed tiers and mixed task statuses within a tier are absent.

---

## Phase 5: CI Workflow

### Status: Present, but contains a non-existent action version

**File:** `.github/workflows/ci.yml`

#### Valid aspects

- Three jobs: `lint` (RuboCop), `test` (Minitest), `mutation` (Mutant).
- Correct Ruby version: `ruby-4.0.0`.
- `bundler-cache: true` on `ruby/setup-ruby@v1` — bundle caching is handled by the action.
- Test command `bin/rails db:test:prepare test` is correct and matches the local working command.
- `RAILS_ENV: test` is set.
- `continue-on-error: true` on mutation job is appropriate (mutation testing is advisory).
- `needs: test` on mutation job ensures tests pass first.
- Upload artifact step for screenshots on failure is present.

#### Issue 1: CRITICAL — `actions/checkout@v6` does not exist

All three jobs use `actions/checkout@v6`. As of early 2026, the latest stable release is `actions/checkout@v4`. Version 6 does not exist. GitHub Actions will fail with `Unable to resolve action` when this workflow runs.

**Fix:** Replace all three occurrences with `actions/checkout@v4`:

```yaml
# Line 16, 48, 77 — change:
uses: actions/checkout@v6
# to:
uses: actions/checkout@v4
```

Dependabot is configured for GitHub Actions (`github-actions` ecosystem in `.github/dependabot.yml`), so this should have been caught automatically. The fact that it was not suggests this workflow was recently added without a test run.

#### Issue 2: MODERATE — No git identity configured for tests

As noted in Phase 3, several tests call `git commit` in tmpdir repos. Without a global git identity in the CI environment, these will produce non-fatal silent failures. Add to the `test` job:

```yaml
- name: Configure git identity for tests
  run: |
    git config --global user.email "ci@example.com"
    git config --global user.name "Arnold CI"
```

#### Issue 3: MINOR — Coverage not uploaded to CI

No coverage collection or upload step exists. After adding SimpleCov (recommended in Phase 4), add:

```yaml
- name: Upload coverage report
  uses: actions/upload-artifact@v4
  if: always()
  with:
    name: coverage
    path: coverage/
    if-no-files-found: ignore
```

#### Issue 4: MINOR — Missing `bin/setup` step

The test job calls `bin/rails db:test:prepare` directly, which is correct. However, if `bin/setup` is added (recommended in Phase 1), the CI bootstrap step should be updated to use it for consistency.

### Corrected CI workflow snippet (test job only)

```yaml
test:
  runs-on: ubuntu-latest
  steps:
    - name: Checkout code
      uses: actions/checkout@v4         # FIXED: was v6

    - name: Set up Ruby
      uses: ruby/setup-ruby@v1
      with:
        ruby-version: ruby-4.0.0
        bundler-cache: true

    - name: Configure git identity for tests
      run: |
        git config --global user.email "ci@example.com"
        git config --global user.name "Arnold CI"

    - name: Run tests
      env:
        RAILS_ENV: test
      run: bin/rails db:test:prepare test

    - name: Keep screenshots from failed system tests
      uses: actions/upload-artifact@v4
      if: failure()
      with:
        name: screenshots
        path: ${{ github.workspace }}/tmp/screenshots
        if-no-files-found: ignore

    - name: Upload coverage report       # ADD after SimpleCov is configured
      uses: actions/upload-artifact@v4
      if: always()
      with:
        name: coverage
        path: coverage/
        if-no-files-found: ignore
```

---

## Recommended Actions

Priority order:

1. **Fix `actions/checkout@v6` in `.github/workflows/ci.yml`** (lines 16, 48, 77) — replace with `@v4`. This is a blocking CI bug. The workflow cannot run as written.

2. **Fix the 2 plugin compatibility test failures** — add `open_questions` to a non-tool identifier allowlist in `test/e2e/plugin_compatibility_test.rb:51` and `:84`. These are false positives: `open_questions` is a JSON response field, not a tool name.

3. **Add `WebMock.disable_net_connect!(allow_localhost: true)` to `test/test_helper.rb`** — prevents any future test from accidentally making live network calls. Add `require "webmock/minitest"` before this line.

4. **Add git identity configuration to CI `test` job** — prevents the dedup_migration and post_merge_hook tests from silently failing git commits in CI.

5. **Scaffold `bin/setup`** — provide a single idempotent bootstrap script for new contributors (content in Phase 1 above).

6. **Add SimpleCov to measure baseline coverage** — insert at the top of `test/test_helper.rb` as shown in Phase 4. This is required before coverage gaps can be quantified.

7. **Add a unit test file for `Specification` model** (`test/models/arnold_pipeline/specification_test.rb`) — cover validations, the `version` lifecycle, and the relationship with `SpecRevision`.

8. **Implement `setup_fetch_results_for_metadata_test` in provider tests** — at least one of the three provider test classes (GitHub or ClaudeCode) should implement this method so that the `execution_metadata` shape contract is actually verified by `SharedProviderTests`.

9. **Add assertion-level verification to the two smoke-only tier engine tests** — at `tier_execution_engine_test.rb:963` and `:1008`, add `ArnoldPipeline::PostMergeHookRunner.expects(:call).once` and `ArnoldPipeline::VerificationRunner.expects(:call).once` respectively.

10. **Add a prompt test for `spec_test_generation.rb`** — create `test/lib/arnold_pipeline/prompts/spec_test_generation_test.rb` following the pattern of the other 5 prompt test files.

11. **Investigate SQLite locking under fixed seed** — the `StatementTimeout` errors in `McpSmokeTest` teardown under seed 12345 suggest the background server thread is not cleanly releasing its AR connection. Consider calling `ActiveRecord::Base.connection_pool.release_connection` in the `teardown` block after `@server_thread.join`.
