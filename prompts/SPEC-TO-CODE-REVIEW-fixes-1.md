Create an agent team to complete the following:

# The A-Team: Open-Source Software Agent Squad for Arnold Pipeline

## Foundational Principles

This agent team is designed from the intersection of four questions:

### What makes a great software team?
A great team isn't a collection of generalists — it's complementary specialists who share standards. The critical roles are: someone who owns correctness (does it work?), someone who owns usability (can people use it?), someone who owns durability (will it last?), and someone who owns clarity (can people understand it?). The best teams have a shared definition of "done" that includes tests, docs, and clean commits — not just working code.

### What matters most in open-source software?
In priority order: **correctness** (bugs erode trust fastest), **safety** (destructive operations need guardrails), **error clarity** (users can't file a bug report from a raw stack trace), **documentation honesty** (documenting unimplemented features is worse than no docs), **maintainability** (the next contributor is the most important user), **performance** (N+1 API calls become rate-limit walls), and **extensibility** (good boundaries enable contributions).

### What makes a great Ruby/Rails 8 engineer?
Idiomatic modern Ruby: keyword arguments, Data.define value objects, clean exception hierarchies, proper use of ActiveRecord scopes (never default_scope). Rails 8 thinking: convention-driven file placement, engine isolation, configuration objects over scattered constants, named scopes over default scopes. Testing discipline: Minitest or RSpec with real isolation, deterministic assertions, integration tests that exercise the binary. A great Ruby engineer makes the code read like the spec.

### What makes a great AI companion CLI tool?
It must be **trustworthy in automation**: correct exit codes, structured output, stderr/stdout separation. It must be **safe by default**: dry-run before destructive ops, confirmation prompts, input validation. It must be **discoverable**: help text with examples, shell completions, error messages that teach. And it must be **composable**: stdin/stdout piping, machine-readable output modes, idempotent operations.

---

## The Team

Five agents, each with a distinct ownership domain, a clear mandate, and assigned issues from the [Spec-to-Code Review](SPEC-TO-CODE-REVIEW.md). Every agent follows the same contract:

**Shared Standards:**
- Every code change includes tests. No exceptions.
- Every PR is a single logical change — small enough for a focused review.
- Commit messages follow: `fix(scope): description` / `feat(scope): description` / `docs(scope): description`
- Run the full test suite before marking any task complete: `bundle exec rake test`
- When modifying existing code, preserve surrounding style. When writing new code, follow existing patterns in the codebase.
- Never introduce a dependency unless the alternative is >50 lines of code.
- When a task touches the CLI, verify behavior manually: run the command, check stdout, stderr, and `$?`.

---

## Agent 1: The Guardian — Correctness & Safety Engineer

**Persona:** A meticulous Ruby engineer who treats every bug as a broken promise to the user. Thinks in edge cases. Writes tests first, then fixes. Believes that a silent failure is worse than a loud crash.

**Ownership:** Logic errors, data integrity, exception handling, input validation, defensive programming.

**Approach:**
1. Read the failing behavior described in the issue — understand what's broken and why.
2. Write a failing test that proves the bug exists. Run it. Watch it fail.
3. Fix the code with the minimum change that makes the test pass.
4. Check for similar patterns elsewhere — if this bug exists in one place, it likely exists in others.
5. Run the full test suite. Verify no regressions.
6. Write a clear commit message explaining what was broken and what the fix does.

**Assigned Issues:**

### ISSUE-005 [Critical] — PipelineJob Double-Run Bug
`app/jobs/arnold_pipeline/pipeline_job.rb:5-11`

**Problem:** `PipelineJob#perform` calls `Orchestrator.new.call(nl_input:)` which creates a NEW PipelineRun instead of using the existing one passed by ID. Every async job creates a duplicate run.

**Approach:**
1. Write a test in `test/jobs/arnold_pipeline/pipeline_job_test.rb` that:
    - Creates a PipelineRun in `pending` state
    - Calls `PipelineJob.perform_now(pipeline_run.id)`
    - Asserts that `PipelineRun.count` did NOT increase
    - Asserts the existing run's status changed (not a new record)
2. Fix `PipelineJob#perform` to find the existing record and either:
    - Call a new `Orchestrator#call_with_run(pipeline_run)` method for pending runs
    - Call `Orchestrator#resume(pipeline_run:)` for paused/failed runs
3. Add the `call_with_run` method to Orchestrator that accepts an existing PipelineRun instead of creating one.
4. Verify the resume path works by adding a test for a paused run.

### ISSUE-006 [Critical] — Iteration MAX_ITERATIONS Mismatch
`app/models/arnold_pipeline/iteration.rb:9` vs `lib/arnold_pipeline/configuration.rb:93-96`

**Problem:** Iteration model hardcodes `MAX_ITERATIONS = 3` in its validation. Configuration allows `max_iterations` between 1-10. If a user sets `max_iterations: 5`, the pipeline will crash with a validation error on iteration 4.

**Approach:**
1. Write a test that:
    - Sets `ArnoldPipeline.configuration.max_iterations = 5`
    - Creates iterations 1 through 5 for a pipeline run
    - Asserts all 5 are valid
    - Asserts iteration 6 is invalid
2. Remove `MAX_ITERATIONS = 3` constant from the Iteration model.
3. Change the validation to read from `ArnoldPipeline.configuration.max_iterations`.
4. Verify the Orchestrator's `analysis_loop!` still enforces the limit correctly.
5. Update any tests that reference the old constant.

### ISSUE-015 [Major] — N+1 PR API Calls
`lib/arnold_pipeline/providers/execution/github.rb:52-53`

**Problem:** `fetch_results` calls `@client.pull_requests(@repo, state: "all")` once per task. With 20 tasks, that's 20 identical API calls fetching ALL PRs each time.

**Approach:**
1. Write a test with WebMock that:
    - Sets up 5 tasks with external IDs
    - Stubs `pull_requests` to return matching PRs
    - Calls `fetch_results`
    - Asserts `pull_requests` was called exactly ONCE (use WebMock's `assert_requested`)
2. Refactor `fetch_results` to call `@client.pull_requests(@repo, state: "all")` once at the top, then iterate tasks against the in-memory PR list.
3. Handle pagination: if the repo has >100 PRs, use `auto_paginate: true` or implement pagination.
4. Run the full GitHub provider test suite to verify no regressions.

### ISSUE-016 [Major] — Overly Broad Rescue Clauses
`lib/arnold_pipeline/orchestrator.rb:291-300, 327-329` and `lib/arnold_pipeline/providers/execution/github.rb:162-163`

**Problem:** Bare `rescue => e` swallows all StandardError subclasses, masking auth failures, rate limiting, and programming errors.

**Approach:**
1. For each rescue site, determine the specific exceptions that should be caught:
    - `merge_results!` / `merge_tier_results!`: `Octokit::Error`, `Faraday::Error`
    - `run_tier_gate!`: Keep broad rescue but log at WARN level with full backtrace
    - `check_workflows_active?`: `Octokit::Error`, `Faraday::Error`
2. Write tests that verify unexpected exceptions (e.g., `NoMethodError`) bubble up instead of being swallowed.
3. Ensure the existing tests for rescued behavior still pass with the narrower clauses.
4. Add a test for the gate error logging: when gate raises, verify logger receives a warning.

### ISSUE-032 [Minor] — validate! Never Called Automatically
`lib/arnold_pipeline/configuration.rb:48-56`

**Problem:** Configuration has a `validate!` method but nobody calls it. Invalid config surfaces deep in the provider stack.

**Approach:**
1. Add `ArnoldPipeline.configuration.validate!` call at the top of `Orchestrator#initialize` or `Orchestrator#call`.
2. Write a test: configure with invalid provider → call Orchestrator → assert `ConfigurationError` raised immediately.
3. Ensure the error message from `validate!` is user-friendly (it already is — verify).

---

## Agent 2: The Shipwright — CLI & Developer Experience Engineer

**Persona:** A developer experience obsessive who has shipped CLI tools used by thousands. Thinks from the user's terminal inward. Every flag, every error message, every exit code is a UX decision. Believes the CLI is the product's front door — if it's broken, nothing else matters.

**Ownership:** CLI commands, flags, help text, error messages, exit codes, output formatting, input validation, safety features.

**Approach:**
1. Read the issue and identify the user-facing behavior change.
2. If adding a new command/flag: write the Thor definition first, then wire it to the existing service layer.
3. If fixing an error path: reproduce the error manually (`arnold run "" && echo $?`), then fix it.
4. Every CLI change gets an integration test that invokes the command and checks stdout, stderr, and exit code.
5. Test both the happy path AND the error path — a CLI command that works but fails silently on errors is worse than one that doesn't exist.
6. Update `--help` text to match the new behavior. If README claims it exists, it must actually work.

**Assigned Issues:**

### ISSUE-001 [Critical] — All Errors Exit Code 0
`lib/arnold_pipeline/cli.rb` (missing method)

**Problem:** Thor 1.5+ requires `exit_on_failure?` to return `true` for proper exit codes. Without it, every error — unknown command, missing args, invalid input — returns exit code 0. Scripts and CI cannot detect failures.

**Approach:**
1. Add one line to `ArnoldPipeline::Cli`:
   ```ruby
   def self.exit_on_failure? = true
   ```
2. Write integration tests that verify:
    - Unknown command → non-zero exit code
    - Missing required argument → non-zero exit code
    - Successful command → exit code 0
3. Verify the Thor deprecation warning disappears (it will — this fixes ISSUE-014/M6 simultaneously).
4. Test that the internal method name `run_pipeline` no longer leaks into error messages — if it still does, add `map "run" => :run_pipeline` (fixes ISSUE-014).

### ISSUE-002 [Critical] — `resume` Command Not Implemented
`lib/arnold_pipeline/cli.rb` (missing), `README.md:104,121-122`

**Problem:** README prominently documents `arnold resume ID [options]` in Quick Start and CLI Commands. Running it produces "Could not find command."

**Approach:**
1. Add the `resume` Thor command in `cli.rb`:
   ```ruby
   desc "resume ID", "Resume a paused or failed pipeline run"
   option :stop_after, type: :string, desc: "Stop after stage: spec, tasks, executed"
   option :config, type: :string, desc: "Path to YAML config file"
   option :verbose, type: :boolean, default: false
   def resume(id)
     setup_standalone!
     apply_config!(options[:config]) if options[:config]
     pipeline_run = ArnoldPipeline::PipelineRun.find_by(id: id)
     unless pipeline_run
       $stderr.puts "Pipeline run ##{id} not found"
       raise SystemExit.new(1)
     end
     orchestrator = ArnoldPipeline::Orchestrator.new(logger: logger)
     orchestrator.resume(pipeline_run: pipeline_run, stop_after: options[:stop_after]&.to_sym)
   end
   ```
2. Write tests:
    - Resume with valid paused run → calls orchestrator.resume
    - Resume with non-existent ID → stderr message + exit code 1
    - Resume with completed run → stderr message about already completed
3. Verify the README documentation matches the implemented flags.

### ISSUE-003 [Critical] — `--stop-after` Flag Not Implemented
`lib/arnold_pipeline/cli.rb:12-20` (missing option)

**Problem:** README documents `--stop-after STAGE` for both `run` and `resume`. The Orchestrator supports it, but the CLI never wires it through.

**Approach:**
1. Add `option :stop_after, type: :string, desc: "Stop after stage: spec, tasks, executed"` to the `run_pipeline` method in `cli.rb`.
2. Pass it through: `orchestrator.call(nl_input: description, stop_after: options[:stop_after]&.to_sym)`
3. Also add to `resume` (covered above).
4. Write tests:
    - `arnold run --stop-after spec "Build an app"` → orchestrator receives `stop_after: :spec`
    - `arnold run --stop-after invalid "test"` → handled gracefully (Orchestrator validates)
5. Add the valid stage names to the help text description.

### ISSUE-004 [Critical] — Raw Stack Traces on Common Errors
`lib/arnold_pipeline/cli.rb:23,159`

**Problem:** Missing API key dumps a 26-line `Anthropic::ConfigurationError` backtrace. Missing config file dumps `Errno::ENOENT`. Malformed YAML dumps `Psych::SyntaxError`. Users see internal gem paths instead of actionable messages.

**Approach:**
1. Wrap the `run_pipeline` method body in a rescue block:
   ```ruby
   rescue ArnoldPipeline::ConfigurationError => e
     $stderr.puts "Configuration error: #{e.message}"
     $stderr.puts "Run 'arnold help run' for usage information."
     raise SystemExit.new(1)
   rescue Anthropic::ConfigurationError, OpenAI::ConfigurationError => e
     $stderr.puts "Missing API key: Set ANTHROPIC_API_KEY or OPENAI_API_KEY in your environment."
     raise SystemExit.new(1)
   rescue Errno::ENOENT => e
     $stderr.puts "File not found: #{e.message}"
     raise SystemExit.new(1)
   rescue Psych::SyntaxError => e
     $stderr.puts "Invalid YAML in config file: #{e.message}"
     raise SystemExit.new(1)
   ```
2. Apply the same pattern to `resume` and `apply_config!`.
3. Write tests for each error path:
    - Missing API key → clean message on stderr, exit code 1
    - Missing config file → clean message, exit code 1
    - Malformed YAML → clean message, exit code 1
    - Empty description → "Description cannot be empty", exit code 1
4. Validate empty description at the top of `run_pipeline` before any setup.

### ISSUE-010 [Major] — No `--dry-run`
`lib/arnold_pipeline/cli.rb:21-41`

**Problem:** `run` creates real GitHub Issues immediately. A typo in `--repo` creates issues on the wrong repository. No preview mode.

**Approach:**
1. Add `option :dry_run, type: :boolean, default: false, desc: "Show what would happen without executing"`.
2. In dry-run mode, run through spec generation and task breakdown, then print a summary:
   ```
   DRY RUN — no changes will be made

   Repository: owner/repo
   Description: "Build a recipe card app"
   Tasks to create: 12
     Tier 0: 1 task (bootstrap)
     Tier 1: 5 tasks
     Tier 2: 6 tasks
   
   Run without --dry-run to execute.
   ```
3. This requires running the Orchestrator with `stop_after: :tasks` internally, then formatting the result. The spec generation and task breakdown don't touch GitHub.
4. Write a test: `arnold run --dry-run "test"` → no GitHub API calls, summary output on stdout.

### ISSUE-012 [Major] — No JSON Output on `list` and `status`
`lib/arnold_pipeline/cli.rb:44-87`

**Problem:** `list` and `status` produce human-readable text only. `spec` has `--json` but the other commands don't. Scripts cannot consume the output.

**Approach:**
1. Add `option :json, type: :boolean, default: false` to both `list` and `status`.
2. For `list --json`:
   ```ruby
   if options[:json]
     data = runs.map { |r| { id: r.id, status: r.status, description: r.nl_input, created_at: r.created_at } }
     puts JSON.pretty_generate(data)
   else
     # existing output
   end
   ```
3. For `status --json`: similar pattern with run details + task counts.
4. Write tests: `list --json` → valid JSON on stdout, parseable by `JSON.parse`.
5. Ensure `list --json | jq '.[0].id'` works.

### ISSUE-013 [Major] — `--version` Global Flag Broken
`lib/arnold_pipeline/cli.rb`

**Problem:** `arnold --version` outputs "Could not find command __version." Only `arnold version` works.

**Approach:**
1. Add `map "--version" => :version, "-v" => :version` to the Cli class.
2. Test: `arnold --version` → prints version string, exit code 0.

---

## Agent 3: The Surgeon — Architecture & Refactoring Engineer

**Persona:** A Ruby architect who makes large codebases smaller and simpler. Believes every class should fit in your head. Refactors by extracting, never by rewriting. Every change preserves existing tests — if a test breaks, the refactoring is wrong, not the test.

**Ownership:** Code structure, class extraction, pattern corrections, performance, internal code quality.

**Approach:**
1. Read the full class/module being refactored. Understand its responsibilities.
2. Identify the natural seam — the boundary where responsibilities change.
3. Extract: move methods to a new class, keeping the exact same signatures.
4. Wire: replace the original calls with delegation to the new class.
5. Run the full test suite after EVERY extraction. Green bar before moving on.
6. Never change behavior during a refactoring PR. Structural changes only.

**Assigned Issues:**

### ISSUE-026 [Minor] — Orchestrator Too Large (463 Lines)
`lib/arnold_pipeline/orchestrator.rb`

**Problem:** Orchestrator handles stage sequencing, tier execution, gate handling, context propagation, and resume inference. Six distinct responsibilities in one class.

**Approach:**
Extract in two PRs:

**PR 1: Extract `TierExecutionEngine`**
1. Create `lib/arnold_pipeline/tier_execution_engine.rb`
2. Move these methods from Orchestrator:
    - `execute!` (the tier loop)
    - `run_tier_gate!`
    - `handle_tier_gate_failure!`
    - `store_tier_context!`
    - `load_accumulated_context`
    - `build_prior_context`
    - `merge_tier_results!`
    - `tier_task_resolved?`
    - `gate_check_needed?`
3. Initialize with `executor:`, `tier_gate_check:`, `config:`, `logger:`
4. Orchestrator delegates: `TierExecutionEngine.new(...).execute_tiers!(pipeline_run)`
5. Move the corresponding tests to `test/lib/arnold_pipeline/tier_execution_engine_test.rb`
6. Run full suite — all existing Orchestrator tests must pass unchanged.

**PR 2: Extract `ResumeInferrer`**
1. Create `lib/arnold_pipeline/resume_inferrer.rb`
2. Move `infer_resume_stage` as a class method: `ResumeInferrer.call(pipeline_run)`
3. Orchestrator delegates: `stage = ResumeInferrer.call(pipeline_run)`
4. Move tests. Run suite.

After both PRs, Orchestrator should be ~200 lines: `call`, `resume`, `generate_spec!`, `break_tasks!`, `analysis_loop!`, and delegation.

### ISSUE-027 [Minor] — Recursive Gate Retry
`lib/arnold_pipeline/orchestrator.rb:332-399`

**Problem:** `handle_tier_gate_failure!` uses recursion bounded by `max_tier_retries`. Works correctly but is harder to debug and reason about.

**Approach:**
1. Replace the recursive call with an iterative loop:
   ```ruby
   def handle_tier_gate_failure!(pipeline_run, tier_num, tier_tasks, gate_result, accumulated_context)
     config.max_tier_retries.times do |attempt|
       corrective_tasks = create_corrective_tasks(gate_result, tier_num, pipeline_run)
       execute_corrective_tasks(corrective_tasks, pipeline_run, accumulated_context)
       new_result = run_tier_gate!(pipeline_run, tier_num, tier_tasks, accumulated_context)
       return if new_result&.dig("pass")
     end
     pipeline_run.update!(status: :paused)
   end
   ```
2. All existing gate retry tests must pass unchanged — the behavior is identical.
3. Do this as part of the TierExecutionEngine extraction PR (ISSUE-026) to avoid double-touching.

### ISSUE-028 [Minor] — `default_scope` on Task Model
`app/models/arnold_pipeline/task.rb:41`

**Problem:** `default_scope { order(:position) }` applies to ALL queries. Known Rails anti-pattern that causes unexpected behavior in JOINs, subqueries, and `unscoped` calls.

**Approach:**
1. Replace with a named scope: `scope :ordered, -> { order(:position) }`
2. Search the codebase for every `Task` query. Add `.ordered` where position ordering is needed.
3. Check for any code that relies on the default ordering implicitly (e.g., `pipeline_run.tasks` without explicit order).
4. Run the full test suite. Any test that depended on implicit ordering will fail — fix those by adding `.ordered`.

---

## Agent 4: The Librarian — Specification & Documentation Engineer

**Persona:** A technical writer who thinks documentation IS the product for open-source software. Treats every inaccuracy in a README as a bug with user-facing impact. Believes that documenting an unimplemented feature is actively harmful — it wastes a user's time and destroys trust.

**Ownership:** specification.md, README.md, CLAUDE.md, CONTRIBUTING.md, CHANGELOG.md, help text, inline code comments.

**Approach:**
1. Read the current document and the code it describes side by side.
2. For each claim in the document, verify it against the codebase.
3. Remove or mark anything that doesn't exist yet. Use `[PLANNED]` badges for genuinely planned features.
4. Add anything that exists but isn't documented.
5. Write for the reader who has never seen the project before.
6. Never document implementation details — document behavior and intent.

**Assigned Issues:**

### ISSUE-007 [Major] — specification.md References Python/LangChain
`specification.md`

**Problem:** The original spec was written for a Python/LangChain implementation. The project is Ruby/Rails.

**Approach:**
1. Replace all Python/LangChain references with Ruby/Rails equivalents.
2. Don't just find-and-replace — verify each section still makes sense in the Ruby context.
3. Keep the spec's structure and behavioral requirements intact — only the implementation technology references change.
4. Single commit: `docs(spec): update technology references from Python to Ruby/Rails`

### ISSUE-008 [Major] — specification.md References VibeKanban
`specification.md`

**Problem:** Spec describes a "VibeKanban" mode alongside "bypass mode" (GitHub). Only GitHub mode was ever implemented.

**Approach:**
1. Remove all VibeKanban references.
2. Remove the "mode" concept — there is one execution provider (GitHub).
3. Simplify the "bypass mode" language to just describe the GitHub integration directly.
4. If VibeKanban is planned for the future, add a single note in Future Considerations.

### ISSUE-009 [Major] — README Documents `:published` Stop-After Stage
`README.md`

**Problem:** README lists `:published` as a valid `stop_after` stage. The Orchestrator doesn't recognize it.

**Approach:**
1. Check with the codebase: does `:published` map to a meaningful checkpoint? (Answer: No — the executor publishes and then immediately begins polling. There's no pause point between publish and poll.)
2. Remove `:published` from the README's valid stages list.
3. Update the stop_after documentation to list only: `:spec`, `:tasks`, `:executed`.

### ISSUE-019 [Major] — Confidence >70% Not Enforced
`lib/arnold_pipeline/prompts/analysis.rb` (prompt text) vs code behavior

**Problem:** Spec says iterate_tasks requires >70% confidence. The prompt mentions it as a guideline. The code accepts any confidence level.

**Approach:**
1. This is a design decision, not a documentation fix. The two options:
    - **Option A (Recommended):** Update the spec and prompt to describe confidence as a *reporting guideline* that flags low-confidence decisions but doesn't gate behavior. This matches the current code.
    - **Option B:** Add enforcement in `Analyzer` or `Orchestrator` to reject `iterate_tasks` decisions below 70%. This would change behavior.
2. Document the chosen approach in specification.md under the Analysis Agent section.
3. If Option A: update `SPEC-ANALYSIS-002` to remove the hard constraint, keep as guideline.

### ISSUE-020 through ISSUE-025 [Minor] — Assorted Spec/Code Alignment
Various specification.md and README.md discrepancies.

**Approach (single PR):**
1. ISSUE-020: Change "webhooks or API polling" → "API polling" in specification.md. Add webhooks to Future Considerations.
2. ISSUE-021: Change "vector database for semantic retrieval" → "keyword matching" in specification.md. Add vector DB to Future Considerations.
3. ISSUE-022: Change "isolated git worktrees or GitHub branches" → "GitHub branches" in specification.md.
4. ISSUE-023: Align task_breakdown.rb prompt wording to match code's soft-warning behavior. Change "Generate between 5 and 20" to "Aim for 5 to 20."
5. ISSUE-024: This requires a code change (add logging) — flag for Agent 1 or Agent 2.
6. ISSUE-025: Document bootstrap task as an "LLM-enforced convention" in the spec rather than a hard constraint.
7. Add `workflow_status_enabled` and `workflow_branch_pattern` to README configuration table (SPEC-CONFIG-007).
8. Document standalone DB location `~/.arnold_pipeline/pipeline.sqlite3` in README (ISSUE-030).

### New: Create CONTRIBUTING.md
**Problem:** No contributor guide. gemspec references a CHANGELOG.md that doesn't exist.

**Approach:**
1. Create `CONTRIBUTING.md` with:
    - Prerequisites (Ruby version, bundler)
    - Setup: `bundle install`, `bundle exec rake test`
    - Test expectations: all changes require tests, run full suite before PR
    - PR process: one logical change per PR, reference issue numbers
    - Code style: follow existing patterns, no new dependencies without discussion
2. Create an empty `CHANGELOG.md` with a header and an "Unreleased" section.

---

## Agent 5: The Inspector — Test & Quality Assurance Engineer

**Persona:** A QA engineer who believes untested code is unfinished code. Writes tests that read like specifications. Tests the boundaries, not just the center. Finds the tests that are missing, not just the tests that are failing.

**Ownership:** Test coverage gaps, integration tests, test quality, CI configuration, dead test removal.

**Approach:**
1. Identify what's untested by reading the traceability map.
2. Write the test description first (the "it should..." statement) — this IS the spec.
3. Write the test body: arrange, act, assert. One assertion per logical concept.
4. For CLI tests: invoke the binary (or Thor dispatch), capture stdout/stderr, check exit code.
5. For integration tests: use real database records, stub only external APIs (LLM, GitHub).
6. Remove dead code: empty test files, commented-out tests, unreachable branches.

**Assigned Issues:**

### ISSUE-017 [Major] — `arnold run` Has Zero Tests
`lib/arnold_pipeline/cli.rb:21-41`

**Problem:** The primary CLI command has no test coverage. All error paths, flag handling, and orchestrator wiring are untested.

**Approach:**
1. Create or extend `test/lib/arnold_pipeline/cli_test.rb` with a `run` command section.
2. Stub `Orchestrator.new.call` to avoid real LLM/GitHub calls.
3. Test:
    - `arnold run "Build an app"` → orchestrator receives correct nl_input, exit code 0
    - `arnold run` (no args) → error message on stderr, exit code non-zero
    - `arnold run ""` → "Description cannot be empty", exit code non-zero (requires ISSUE-004 fix)
    - `arnold run --verbose "test"` → logger set to DEBUG level
    - `arnold run --config path/to/config.yml "test"` → config loaded before orchestrator
    - `arnold run --stop-after spec "test"` → orchestrator receives `stop_after: :spec` (requires ISSUE-003)

### ISSUE-018 [Major] — `--config FILE` Has Zero Tests
`lib/arnold_pipeline/cli.rb:157-188`

**Problem:** Config file loading is implemented but untested. Missing file and malformed YAML produce raw stack traces.

**Approach:**
1. Write tests using temp files:
   ```ruby
   test "loads valid YAML config file" do
     config_file = Tempfile.new(["config", ".yml"])
     config_file.write({ "llm_provider" => "openai", "llm_model" => "gpt-4o" }.to_yaml)
     config_file.close
     # invoke CLI with --config, assert configuration was applied
   end

   test "reports missing config file cleanly" do
     # invoke with --config /nonexistent/path
     # assert stderr contains "File not found"
     # assert exit code 1
   end

   test "reports malformed YAML cleanly" do
     config_file = Tempfile.new(["config", ".yml"])
     config_file.write("invalid: yaml: [broken")
     config_file.close
     # assert stderr contains "Invalid YAML"
     # assert exit code 1
   end
   ```
2. These tests depend on ISSUE-004 (error handling) being fixed first. Coordinate with Agent 2.

### ISSUE-031 [Minor] — Empty Test Placeholder
`test/integration/navigation_test.rb`

**Problem:** Empty test file. Dead code.

**Approach:**
1. Verify the file is truly empty (no pending tests, no comments indicating intent).
2. Delete it.
3. Commit: `chore(test): remove empty navigation_test.rb placeholder`

### New: Add CI Configuration
**Problem:** No `.github/workflows/` configuration. The test suite runs locally but there's no automated check on PRs.

**Approach:**
1. Create `.github/workflows/test.yml`:
   ```yaml
   name: Test
   on: [push, pull_request]
   jobs:
     test:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: ruby/setup-ruby@v1
           with:
             ruby-version: '3.3'
             bundler-cache: true
         - run: bundle exec rake test
   ```
2. Verify it works by running the equivalent commands locally.
3. This is the single most impactful process improvement — every subsequent PR from every agent gets automatic validation.

---

## Execution Order

```
Sprint 1 (Foundation — unblocks everything else):
  Agent 2: ISSUE-001 (exit codes)          ← 1 line, fixes 3 issues
  Agent 5: CI configuration                ← all subsequent work gets automated checks
  Agent 1: ISSUE-006 (MAX_ITERATIONS)      ← correctness fix, low risk

Sprint 2 (Critical CLI — fulfills documented contract):
  Agent 2: ISSUE-004 (error handling)      ← unblocks ISSUE-018 tests
  Agent 2: ISSUE-002 (resume command)
  Agent 2: ISSUE-003 (--stop-after flag)
  Agent 2: ISSUE-013 (--version fix)

Sprint 3 (Critical bugs + test coverage):
  Agent 1: ISSUE-005 (PipelineJob bug)
  Agent 5: ISSUE-017 (run command tests)
  Agent 5: ISSUE-018 (config file tests)
  Agent 1: ISSUE-015 (batch PR fetching)
  Agent 1: ISSUE-016 (narrow rescues)

Sprint 4 (Safety + usability):
  Agent 2: ISSUE-010 (--dry-run)
  Agent 2: ISSUE-012 (--json on list/status)
  Agent 1: ISSUE-032 (auto-validate config)

Sprint 5 (Spec alignment + docs):
  Agent 4: ISSUE-007, 008, 009 (spec cleanup)
  Agent 4: ISSUE-019, 020-025 (spec/code alignment)
  Agent 4: CONTRIBUTING.md + CHANGELOG.md

Sprint 6 (Architecture polish):
  Agent 3: ISSUE-026 (extract TierExecutionEngine)
  Agent 3: ISSUE-027 (iterative gate retry)
  Agent 3: ISSUE-028 (remove default_scope)
  Agent 5: ISSUE-031 (remove dead test)
```

This ordering ensures: (1) CI is live before bulk changes land, (2) critical exit code fix unblocks all CLI testing, (3) error handling fix unblocks config file tests, (4) all Critical issues resolved by end of Sprint 3, (5) refactoring happens last when the test suite is strongest.