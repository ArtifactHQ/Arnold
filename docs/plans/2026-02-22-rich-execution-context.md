# Rich Execution Context Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Inject real project state (schema, routes, Gemfile) and test output into Claude Code task execution so tasks make correct decisions on the first try.

**Architecture:** Enrich CLAUDE.md with project file snapshots at worktree setup time. Thread verification test output through to corrective task descriptions so Claude Code sees exact failures.

**Tech Stack:** Ruby, Minitest, Mocha stubs

---

### Task 1: Add project state reading to ClaudeMdGenerator

**Files:**
- Modify: `lib/arnold_pipeline/services/claude_md_generator.rb`
- Test: `test/lib/arnold_pipeline/services/claude_md_generator_test.rb`

**Step 1: Write the failing tests**

```ruby
# In claude_md_generator_test.rb, add these tests:

test "includes schema section when repo_path has db/schema.rb" do
  Dir.mktmpdir do |dir|
    FileUtils.mkdir_p(File.join(dir, "db"))
    File.write(File.join(dir, "db", "schema.rb"), <<~SCHEMA)
      ActiveRecord::Schema[8.0].define(version: 2026_02_21) do
        enable_extension "plpgsql"

        create_table "users", force: :cascade do |t|
          t.string "email", null: false
          t.string "name"
          t.timestamps
        end

        create_table "posts", force: :cascade do |t|
          t.references "user", null: false
          t.string "title"
          t.timestamps
        end
      end
    SCHEMA

    result = ClaudeMdGenerator.call(
      persona: @persona, recipe: @recipe, domain_type: @domain_type,
      repo_path: dir
    )
    assert_includes result, "## Current Database Schema"
    assert_includes result, "create_table \"users\""
    assert_includes result, "create_table \"posts\""
    refute_includes result, "enable_extension"
    refute_includes result, "ActiveRecord::Schema"
  end
end

test "includes routes section when repo_path has config/routes.rb" do
  Dir.mktmpdir do |dir|
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "routes.rb"), <<~ROUTES)
      Rails.application.routes.draw do
        resources :users
        resources :posts
        root "pages#home"
      end
    ROUTES

    result = ClaudeMdGenerator.call(
      persona: @persona, recipe: @recipe, domain_type: @domain_type,
      repo_path: dir
    )
    assert_includes result, "## Current Routes"
    assert_includes result, "resources :users"
    assert_includes result, "root \"pages#home\""
  end
end

test "includes Gemfile section when repo_path has Gemfile" do
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, "Gemfile"), <<~GEMFILE)
      source "https://rubygems.org"

      # Rails framework
      gem "rails", "~> 8.0"
      gem "sqlite3"

      # Authentication
      gem "bcrypt", "~> 3.1.7"
    GEMFILE

    result = ClaudeMdGenerator.call(
      persona: @persona, recipe: @recipe, domain_type: @domain_type,
      repo_path: dir
    )
    assert_includes result, "## Current Gemfile"
    assert_includes result, 'gem "rails"'
    assert_includes result, 'gem "bcrypt"'
    refute_includes result, "# Rails framework"
    refute_includes result, "# Authentication"
  end
end

test "omits project state sections when repo_path is nil" do
  result = ClaudeMdGenerator.call(
    persona: @persona, recipe: @recipe, domain_type: @domain_type,
    repo_path: nil
  )
  refute_includes result, "Current Database Schema"
  refute_includes result, "Current Routes"
  refute_includes result, "Current Gemfile"
end

test "omits missing files gracefully" do
  Dir.mktmpdir do |dir|
    # Empty dir — no schema, routes, or Gemfile
    result = ClaudeMdGenerator.call(
      persona: @persona, recipe: @recipe, domain_type: @domain_type,
      repo_path: dir
    )
    refute_includes result, "Current Database Schema"
    refute_includes result, "Current Routes"
    refute_includes result, "Current Gemfile"
  end
end

test "schema truncation strips indexes and version info" do
  Dir.mktmpdir do |dir|
    FileUtils.mkdir_p(File.join(dir, "db"))
    File.write(File.join(dir, "db", "schema.rb"), <<~SCHEMA)
      ActiveRecord::Schema[8.0].define(version: 2026_02_21) do
        enable_extension "plpgsql"

        create_table "users", force: :cascade do |t|
          t.string "email"
          t.index ["email"], name: "index_users_on_email", unique: true
          t.timestamps
        end
      end
    SCHEMA

    result = ClaudeMdGenerator.call(
      persona: @persona, recipe: @recipe, domain_type: @domain_type,
      repo_path: dir
    )
    assert_includes result, "create_table \"users\""
    assert_includes result, "t.string \"email\""
    refute_includes result, "t.index"
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/services/claude_md_generator_test.rb`
Expected: FAIL — `ClaudeMdGenerator.call` doesn't accept `repo_path:` keyword

**Step 3: Implement the project state reading**

In `claude_md_generator.rb`:
- Add `repo_path:` as optional keyword (default `nil`) to both `self.call` and `initialize`
- Add three new private methods: `schema_section`, `routes_section`, `gemfile_section`
- `schema_section`: Read `db/schema.rb`, strip lines matching `ActiveRecord::Schema`, `enable_extension`, `end` (outermost), and `t.index`. Keep `create_table` blocks.
- `routes_section`: Read `config/routes.rb` as-is
- `gemfile_section`: Read `Gemfile`, strip comment lines (`#`) and blank lines
- Append these sections in `generate` after the existing sections

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/services/claude_md_generator_test.rb`
Expected: PASS — all existing tests still pass, new tests pass

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/services/claude_md_generator.rb test/lib/arnold_pipeline/services/claude_md_generator_test.rb
git commit -m "feat(claude_md): inject schema, routes, and Gemfile into generated CLAUDE.md [SPEC-PROVIDER-001]"
```

---

### Task 2: Pass worktree_path to ClaudeMdGenerator in the provider

**Files:**
- Modify: `lib/arnold_pipeline/providers/execution/claude_code.rb`
- Test: `test/lib/arnold_pipeline/providers/execution/claude_code_test.rb`

**Step 1: Write the failing test**

```ruby
test "write_claude_md! passes worktree_path to ClaudeMdGenerator" do
  @provider.instance_variable_set(:@library_selections, {
    persona: ArnoldPipeline::Library::Persona.new(
      name: "SA", role: "sa", keywords: [], description: "d", system_prompt: "sp"
    ),
    recipe: ArnoldPipeline::Library::Recipe.new(
      name: "Web App", type: "web_app", keywords: [], description: "d",
      framework: { "primary" => "Rails 8+" }, sections: [], verification: {}
    ),
    domain_type: nil
  })

  worktree_path = Dir.mktmpdir
  FileUtils.mkdir_p(File.join(worktree_path, "config"))
  File.write(File.join(worktree_path, "config", "routes.rb"), "Rails.application.routes.draw do\n  root 'home#index'\nend")

  @provider.send(:write_claude_md!, worktree_path)

  claude_md_path = File.join(worktree_path, "CLAUDE.md")
  content = File.read(claude_md_path)
  assert_includes content, "Current Routes"
  assert_includes content, "root 'home#index'"
ensure
  FileUtils.remove_entry(worktree_path)
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/lib/arnold_pipeline/providers/execution/claude_code_test.rb -n test_write_claude_md!_passes_worktree_path_to_ClaudeMdGenerator`
Expected: FAIL — `write_claude_md!` doesn't pass `repo_path:` to `ClaudeMdGenerator.call`

**Step 3: Modify write_claude_md!**

In `claude_code.rb`, change `write_claude_md!` to pass `repo_path: worktree_path`:

```ruby
def write_claude_md!(worktree_path)
  return unless @library_selections

  content = Services::ClaudeMdGenerator.call(
    persona: @library_selections[:persona],
    recipe: @library_selections[:recipe],
    domain_type: @library_selections[:domain_type],
    repo_path: worktree_path
  )
  # ... rest unchanged
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/providers/execution/claude_code_test.rb`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/providers/execution/claude_code.rb test/lib/arnold_pipeline/providers/execution/claude_code_test.rb
git commit -m "feat(claude_code): pass worktree_path to ClaudeMdGenerator for project state injection [SPEC-PROVIDER-001]"
```

---

### Task 3: Thread verification_results into handle_tier_gate_failure!

**Files:**
- Modify: `lib/arnold_pipeline/tier_execution_engine.rb`
- Test: `test/lib/arnold_pipeline/tier_execution_engine_test.rb`

**Step 1: Write the failing test**

```ruby
test "handle_tier_gate_failure! passes verification output to corrective task descriptions" do
  ArnoldPipeline.configure do |c|
    c.max_iterations = 3
    c.max_tier_retries = 1
    c.tier_gate_enabled = true
    c.llm_api_key = "test"
    c.github_token = "test"
    c.github_repo = "owner/repo"
  end

  pipeline_run = PipelineRun.create!(nl_input: "Build an app")
  pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

  gate_fail = {
    "pass" => false,
    "issues" => ["test failures"],
    "corrective_tasks" => [
      { "title" => "Fix tests", "description" => "fix the test failures" }
    ],
    "context_summary" => "context"
  }
  gate_pass = { "pass" => true, "issues" => [], "context_summary" => "Fixed.", "corrective_tasks" => [] }

  @executor.stubs(:call).returns([])
  @executor.stubs(:await_results).returns(nil)
  @executor.stubs(:merge_results).returns([])
  @tier_gate_check.stubs(:call).returns(gate_pass)

  verification_results = {
    all_passed: false,
    checks: [
      { name: "Test suite", type: :test_suite, success: false, exit_code: 1,
        stdout: "1 runs, 0 assertions, 1 failures, 0 errors\nFAIL UserTest#test_validates_email\nExpected nil to not be nil",
        stderr: "" }
    ]
  }

  @engine.send(:handle_tier_gate_failure!, pipeline_run, 0, [], gate_fail, [],
               verification_results: verification_results)

  corrective = pipeline_run.tasks.where(title: "Fix tests").first
  assert_not_nil corrective
  assert_includes corrective.description, "## Test Output"
  assert_includes corrective.description, "FAIL UserTest#test_validates_email"
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb -n "test_handle_tier_gate_failure!_passes_verification_output_to_corrective_task_descriptions"`
Expected: FAIL — `handle_tier_gate_failure!` doesn't accept `verification_results:` keyword

**Step 3: Implement the plumbing**

Three changes in `tier_execution_engine.rb`:

**3a.** Add `verification_results: nil` keyword to `handle_tier_gate_failure!` signature (line 463).

**3b.** Add `verification_output:` keyword to `build_corrective_description` signature. Extract test suite stdout/stderr from verification_results, truncate to last 3000 chars, pass as the new keyword.

In the corrective task creation loop (around line 488):

```ruby
created_tasks = corrective_tasks.each_with_index.map do |td, i|
  enriched_desc = build_corrective_description(
    base_description: td["description"],
    gate_issues: gate_issues,
    original_tier_tasks: tier_tasks,
    acceptance_criteria_summary: acceptance_criteria_summary,
    verification_output: extract_test_output(verification_results)
  )
  # ... rest unchanged
end
```

**3c.** Add `extract_test_output` private method:

```ruby
def extract_test_output(verification_results)
  return nil unless verification_results

  test_check = verification_results[:checks]&.find { |c| c[:type] == :test_suite }
  return nil unless test_check

  output = [test_check[:stdout], test_check[:stderr]].compact.join("\n")
  return nil if output.strip.empty?

  # Keep last 3000 chars — failure summary is at the bottom
  output.length > 3000 ? output[-3000..] : output
end
```

**3d.** In `build_corrective_description`, append the test output section:

```ruby
if verification_output.present?
  sections << "## Test Output\n```\n#{verification_output}\n```"
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb`
Expected: PASS — all existing tests still pass (they don't pass `verification_results:`, so it defaults to nil)

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/tier_execution_engine.rb test/lib/arnold_pipeline/tier_execution_engine_test.rb
git commit -m "feat(tier_gate): thread verification test output into corrective task descriptions [SPEC-TIER-008]"
```

---

### Task 4: Pass verification_results from execute_tiers! into handle_tier_gate_failure!

**Files:**
- Modify: `lib/arnold_pipeline/tier_execution_engine.rb`
- Test: `test/lib/arnold_pipeline/tier_execution_engine_test.rb`

**Step 1: Write the failing test**

```ruby
test "execute_tiers! passes verification_results to handle_tier_gate_failure!" do
  ArnoldPipeline.configure do |c|
    c.max_iterations = 3
    c.max_tier_retries = 1
    c.tier_gate_enabled = true
    c.context_propagation_enabled = false
    c.llm_api_key = "test"
    c.github_token = "test"
    c.github_repo = "owner/repo"
    c.claude_code_repo_path = "/tmp/test-repo"
    c.verification_checks = [
      { name: "Test suite", command: "echo 'FAIL test_something'", type: "test_suite", required: false }
    ]
  end

  pipeline_run = PipelineRun.create!(nl_input: "Build an app")
  pipeline_run.tasks.create!(
    title: "Setup", position: 0, tier: 0,
    external_id: "cc-1-0", result_diff: '[{"filename":"f.rb","patch":"diff","status":"added"}]'
  )

  # Gate fails with test failures
  verification_results = {
    all_passed: false,
    checks: [
      { name: "Test suite", type: :test_suite, success: false, exit_code: 1,
        stdout: "FAIL test_something\nExpected 1 got 2", stderr: "" }
    ]
  }

  ArnoldPipeline::VerificationRunner.stubs(:call).returns(verification_results)
  ArnoldPipeline::PostMergeHookRunner.stubs(:call).returns([])

  gate_fail = {
    "pass" => false,
    "issues" => ["test failures"],
    "corrective_tasks" => [{ "title" => "Fix it", "description" => "fix" }],
    "context_summary" => "ctx"
  }
  gate_pass = { "pass" => true, "issues" => [], "context_summary" => "OK", "corrective_tasks" => [] }

  # First gate call returns fail (from verification path), second returns pass (retry)
  call_count = 0
  @tier_gate_check.stubs(:call).returns(gate_fail) # won't be called — verification path used

  # Stub the verification-based gate evaluation
  @engine.stubs(:evaluate_with_verification).returns(gate_fail).then.returns(gate_pass)
  @engine.stubs(:has_test_suite_result?).returns(true)

  @executor.stubs(:call).returns([])
  @executor.stubs(:await_results).returns(nil)
  @executor.stubs(:merge_results).returns([])
  @executor.stubs(:fetch_results).returns([])

  @engine.execute_tiers!(pipeline_run)

  # The corrective task should have test output in its description
  corrective = pipeline_run.tasks.where(title: "Fix it").first
  assert_not_nil corrective
  assert_includes corrective.description, "## Test Output"
  assert_includes corrective.description, "FAIL test_something"
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb -n "test_execute_tiers!_passes_verification_results_to_handle_tier_gate_failure!"`
Expected: FAIL

**Step 3: Thread verification_results through execute_tiers!**

In `execute_tiers!`, change the `handle_tier_gate_failure!` call at line 127-128 to pass `verification_results:`:

```ruby
handle_tier_gate_failure!(pipeline_run, tier_num, tier_tasks, gate_result, accumulated_context,
                          acceptance_criteria_summary:,
                          verification_results: verification_results)
```

The `verification_results` variable is already in scope from line 99.

Also update `handle_tier_gate_failure!` to use `retry_verification_results` on subsequent loop iterations. After line 547 (`retry_verification_results = run_verification_checks(tier_num)`), the `verification_results` local should be updated:

```ruby
verification_results = retry_verification_results
```

This ensures each retry's corrective tasks get the latest test output.

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/tier_execution_engine.rb test/lib/arnold_pipeline/tier_execution_engine_test.rb
git commit -m "feat(tier_gate): pass verification_results from execute_tiers! into gate failure handler [SPEC-TIER-008]"
```

---

### Task 5: Run full test suite and verify

**Step 1: Run the full test suite**

Run: `bundle exec rails test`
Expected: 1324+ tests, 0 failures, 0 errors (the known ConfigurationTest failure is pre-existing)

**Step 2: Verify no regressions in existing provider tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/providers/execution/claude_code_test.rb`
Expected: All pass

**Step 3: Verify no regressions in tier execution engine tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb`
Expected: All pass

---

### Task 6: Update MEMORY.md with new patterns

**Files:**
- Modify: `/home/kyle/.claude/projects/-home-kyle-Documents-Projects-artifact-arnold-pipeline/memory/MEMORY.md`

Update the Claude Code Execution Provider section to note:
- `ClaudeMdGenerator` now accepts `repo_path:` to inject schema/routes/Gemfile
- `handle_tier_gate_failure!` accepts `verification_results:` to thread test output into corrective task descriptions
- `extract_test_output` truncates to last 3000 chars
