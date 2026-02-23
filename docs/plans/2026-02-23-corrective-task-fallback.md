# Corrective Task Fallback Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure the pipeline always generates corrective tasks when tests fail, even when individual failures can't be parsed from the output.

**Architecture:** Three surgical fixes across three files: (1) improve minitest error block regex to capture both `Failure:` and `Error:` formats, (2) add a fallback generic corrective task in CorrectiveTaskGenerator when parsing yields nothing, (3) change silent `return` to `next` in the retry loop so empty corrective tasks consume a retry instead of silently proceeding.

**Tech Stack:** Ruby, Minitest, Mocha for stubs

---

### Task 1: Fix minitest error block extraction in TestResultParser

**Files:**
- Modify: `lib/arnold_pipeline/test_execution/test_result_parser.rb:46-62`
- Test: `test/lib/arnold_pipeline/test_execution/test_result_parser_test.rb`

The current regex at line 53 uses a single pattern that expects `[path:line]:` location format. Minitest errors don't use brackets — they use `TestName#method:` followed by stack traces. Split into two passes.

**Step 1: Write the failing test for error-only output**

Add this test after the existing "parses minitest failing output" test (after line 51):

```ruby
test "parses minitest error-only output with stack traces" do
  stdout = <<~OUTPUT
    Running 14 tests...
    ..........E.E.

      1) Error:
    UsersControllerTest#test_should_get_index:
    NameError: uninitialized constant UsersController
        app/controllers/users_controller.rb:1:in `<main>'
        test/controllers/users_controller_test.rb:4:in `block in <class:UsersControllerTest>'

      2) Error:
    SessionsControllerTest#test_should_create_session:
    NoMethodError: undefined method `authenticate' for nil
        app/controllers/sessions_controller.rb:8:in `create'
        test/controllers/sessions_controller_test.rb:12:in `block in <class:SessionsControllerTest>'

    14 runs, 0 assertions, 0 failures, 2 errors, 0 skips
  OUTPUT

  result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 1)

  refute result.passed
  assert_equal "minitest", result.framework
  assert_equal 2, result.failures.size
  assert_equal "UsersControllerTest#test_should_get_index", result.failures[0][:name]
  assert_includes result.failures[0][:message], "NameError"
  assert_equal "SessionsControllerTest#test_should_create_session", result.failures[1][:name]
  assert_includes result.failures[1][:message], "NoMethodError"
end

test "parses minitest mixed failures and errors" do
  stdout = <<~OUTPUT
      1) Failure:
    AuthTest#test_login [test/auth_test.rb:42]:
    Expected 200, got 401

      2) Error:
    UsersControllerTest#test_should_get_index:
    NameError: uninitialized constant UsersController
        app/controllers/users_controller.rb:1:in `<main>'

    14 runs, 28 assertions, 1 failures, 1 errors, 0 skips
  OUTPUT

  result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 1)

  refute result.passed
  assert_equal 2, result.failures.size
  # Failure block has bracket location
  assert_equal "AuthTest#test_login", result.failures[0][:name]
  assert_equal "test/auth_test.rb:42", result.failures[0][:location]
  # Error block has stack trace location
  assert_equal "UsersControllerTest#test_should_get_index", result.failures[1][:name]
  assert_includes result.failures[1][:message], "NameError"
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/test_execution/test_result_parser_test.rb -v 2>&1 | tail -20`
Expected: 2 failures — the error-only and mixed tests fail because the regex doesn't capture error blocks.

**Step 3: Fix extract_minitest_failures**

Replace lines 46-62 in `lib/arnold_pipeline/test_execution/test_result_parser.rb`:

```ruby
def extract_minitest_failures
  failures = []

  # Pass 1: Failure blocks with bracket location
  #   1) Failure:
  # TestName#test_something [path/to/file.rb:42]:
  # Expected true, got false
  @combined.scan(/\d+\)\s+Failure:\n\s*(.+?)\s+\[(.+?)\]:\n(.+?)(?=\n\n|\n\s*\d+\)|\z)/m).each do |name, location, message|
    failures << {
      name: name.strip,
      message: message.strip.lines.first&.strip || message.strip,
      location: location.strip
    }
  end

  # Pass 2: Error blocks with colon and stack trace
  #   1) Error:
  # TestName#test_something:
  # NameError: uninitialized constant Foo
  #     app/file.rb:1:in `<main>'
  @combined.scan(/\d+\)\s+Error:\n\s*(.+?):\n(.+?)(?=\n\n|\n\s*\d+\)|\z)/m).each do |name, body|
    first_line = body.strip.lines.first&.strip || body.strip
    # Extract location from first stack trace line
    stack_match = body.match(/^\s+(\S+:\d+):in\s/)
    failures << {
      name: name.strip,
      message: first_line,
      location: stack_match&.[](1)
    }
  end

  failures
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/test_execution/test_result_parser_test.rb -v 2>&1 | tail -20`
Expected: All tests pass, including existing ones (regression check).

**Step 5: Commit**

```
git add lib/arnold_pipeline/test_execution/test_result_parser.rb test/lib/arnold_pipeline/test_execution/test_result_parser_test.rb
git commit -m "fix(parser): extract minitest error blocks with stack traces [SPEC-TIER-008]"
```

---

### Task 2: Add has_issues? to TestResult

**Files:**
- Modify: `lib/arnold_pipeline/test_execution/test_result.rb:11-14`
- Test: `test/lib/arnold_pipeline/test_execution/test_result_parser_test.rb`

**Step 1: Write the failing test**

Add at end of test file before the final `end`s:

```ruby
# --- has_issues? ---

test "has_issues? returns false when passed" do
  result = TestResultParser.call(
    stdout: "14 runs, 28 assertions, 0 failures, 0 errors, 0 skips",
    stderr: "", exit_code: 0
  )
  refute result.has_issues?
end

test "has_issues? returns true when failed with parsed failures" do
  stdout = <<~OUTPUT
      1) Failure:
    AuthTest#test_login [test/auth_test.rb:42]:
    Expected 200, got 401

    14 runs, 28 assertions, 1 failures, 0 errors, 0 skips
  OUTPUT
  result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 1)
  assert result.has_issues?
end

test "has_issues? returns true when failed with empty failures array" do
  result = TestExecution::TestResult.new(
    passed: false, exit_code: 1,
    summary: "14 runs, 0 assertions, 0 failures, 14 errors",
    failures: [], framework: "minitest"
  )
  assert result.has_issues?
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/test_execution/test_result_parser_test.rb -n /has_issues/ -v 2>&1 | tail -10`
Expected: `NoMethodError: undefined method 'has_issues?'`

**Step 3: Add has_issues? to TestResult**

Add after line 14 (after the `initialize` method) in `lib/arnold_pipeline/test_execution/test_result.rb`:

```ruby
def has_issues?
  !passed
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/test_execution/test_result_parser_test.rb -v 2>&1 | tail -10`
Expected: All pass.

**Step 5: Commit**

```
git add lib/arnold_pipeline/test_execution/test_result.rb test/lib/arnold_pipeline/test_execution/test_result_parser_test.rb
git commit -m "feat(test_result): add has_issues? for clearer intent checks [SPEC-TIER-008]"
```

---

### Task 3: Add fallback generic corrective task in CorrectiveTaskGenerator

**Files:**
- Modify: `lib/arnold_pipeline/corrective_task_generator.rb:84-93`
- Modify: `test/lib/arnold_pipeline/corrective_task_generator_test.rb:30-41`

**Step 1: Update the existing test and add new test**

The test at line 30-41 ("handles test result with empty failures array") currently asserts `[]` — this is the buggy behavior. Update it and add a new test:

Replace the test at lines 30-41 with:

```ruby
test "generates generic fallback task when failures array is empty but tests failed" do
  test_result = TestExecution::TestResult.new(
    passed: false, exit_code: 1, summary: "14 runs, 0 assertions, 0 failures, 14 errors",
    failures: [], framework: "minitest"
  )

  result = CorrectiveTaskGenerator.call(
    test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
  )

  assert_equal 1, result.size
  task = result.first
  assert_match(/Fix test failures/, task["title"])
  assert_includes task["labels"], "test-fix"
  assert_includes task["description"], "14 runs, 0 assertions, 0 failures, 14 errors"
end

test "generic fallback task includes raw test summary in description" do
  test_result = TestExecution::TestResult.new(
    passed: false, exit_code: 1, summary: "50 runs, 124 assertions, 2 failures, 0 errors",
    failures: [], framework: "minitest"
  )

  result = CorrectiveTaskGenerator.call(
    test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
  )

  assert_equal 1, result.size
  assert_includes result.first["description"], "50 runs, 124 assertions, 2 failures, 0 errors"
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/corrective_task_generator_test.rb -n /generic fallback/ -v 2>&1 | tail -10`
Expected: Failures — current code returns `[]`.

**Step 3: Implement the fallback**

Replace lines 84-93 in `lib/arnold_pipeline/corrective_task_generator.rb`:

```ruby
def call
  return [] if @test_result.passed

  if @test_result.failures.empty?
    @logger.warn { "Test failures detected but no individual failures parsed — generating generic corrective task" }
    return [generic_failure_task]
  end

  grouped = group_failures_by_category(@test_result.failures)
  return [] if grouped.empty?

  grouped.flat_map do |category, failures|
    generate_task_for_category(category, failures)
  end.compact
end
```

Add `generic_failure_task` as a private method after `build_fallback_task` (after line 210):

```ruby
def generic_failure_task
  {
    "title" => "Fix test failures: #{@test_result.summary}",
    "description" => "The test suite failed but individual failure details could not be parsed from the output.\n\n" \
      "## Test Summary\n#{@test_result.summary}\n\n" \
      "## Instructions\nRun the full test suite, identify all failures and errors, and fix them.\n" \
      "Focus on errors first (often missing constants, undefined methods) as these frequently cause cascading failures.",
    "labels" => ["test-fix"]
  }
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/corrective_task_generator_test.rb -v 2>&1 | tail -20`
Expected: All tests pass including the updated and new tests.

**Step 5: Commit**

```
git add lib/arnold_pipeline/corrective_task_generator.rb test/lib/arnold_pipeline/corrective_task_generator_test.rb
git commit -m "fix(corrective): generate fallback task when failure parser returns empty [SPEC-TIER-008]"
```

---

### Task 4: Fix silent return in handle_tier_gate_failure!

**Files:**
- Modify: `lib/arnold_pipeline/tier_execution_engine.rb:563`
- Modify: `test/lib/arnold_pipeline/tier_execution_engine_test.rb`

**Step 1: Write the failing test**

Add a new test in the `handle_tier_gate_failure!` section of the test file:

```ruby
test "handle_tier_gate_failure! consumes retry when corrective_tasks is empty instead of silently returning" do
  ArnoldPipeline.configure do |c|
    c.max_iterations = 3
    c.max_tier_retries = 2
    c.tier_gate_enabled = true
    c.context_propagation_enabled = false
  end

  pipeline_run = PipelineRun.create!(nl_input: "test", status: :executing)

  # Gate fails with zero corrective tasks (the bug scenario)
  gate_fail = {
    "pass" => false,
    "issues" => ["Test suite failed: 14 runs, 0 assertions, 0 failures, 14 errors"],
    "corrective_tasks" => []
  }

  # Gate keeps failing on re-check
  @verification_runner.stubs(:run).returns({ passed: true, checks: [] })
  @tier_gate_check.stubs(:call).returns(gate_fail)

  assert_raises(TierGateError) do
    @engine.send(:handle_tier_gate_failure!, pipeline_run, 0, [], gate_fail, [])
  end

  pipeline_run.reload
  assert_equal "paused", pipeline_run.status
  assert_equal 2, pipeline_run.metadata.dig("tier_retries", "0")
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb -n /consumes retry when corrective_tasks is empty/ -v 2>&1 | tail -10`
Expected: Fails — currently the method silently returns instead of consuming retries and pausing.

**Step 3: Change `return` to `next`**

In `lib/arnold_pipeline/tier_execution_engine.rb`, change line 563:

From:
```ruby
        return if created_tasks.empty?
```

To:
```ruby
        if created_tasks.empty?
          logger.warn { "[Arnold] Tier #{tier_num} gate failed but no corrective tasks generated (retry #{retry_count}/#{max_retries})" }
          next
        end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb -v 2>&1 | tail -20`
Expected: All tests pass. The new test passes because the loop now exhausts retries and raises TierGateError.

**Step 5: Commit**

```
git add lib/arnold_pipeline/tier_execution_engine.rb test/lib/arnold_pipeline/tier_execution_engine_test.rb
git commit -m "fix(tier_engine): consume retry on empty corrective tasks instead of silent return [SPEC-TIER-008]"
```

---

### Task 5: Run full test suite and verify

**Step 1: Run the full test suite**

Run: `bundle exec rails test 2>&1 | tail -5`
Expected: All tests pass (1354+ runs, 0 failures, 0 errors).

**Step 2: Verify no regressions**

Specifically check that existing tier gate tests still pass:
Run: `bundle exec rails test test/lib/arnold_pipeline/tier_execution_engine_test.rb -v 2>&1 | tail -5`

**Step 3: Final commit if any fixups needed**

If any tests needed adjustment, commit the fixes.
