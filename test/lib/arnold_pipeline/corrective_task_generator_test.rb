require "test_helper"
require "arnold_pipeline/corrective_task_generator"
require "arnold_pipeline/test_execution/test_result"

module ArnoldPipeline
  class CorrectiveTaskGeneratorTest < ActiveSupport::TestCase
    setup do
      @llm = stub("llm")
      @diffs = "diff --git a/app/models/user.rb\n+class User\n+end"
      @task_summaries = "- Create User model\n- Add authentication"
    end

    # -- Empty / passing results --

    test "returns empty array when test result has no failures" do
      test_result = TestExecution::TestResult.new(
        passed: true, exit_code: 0, summary: "5 runs, 10 assertions, 0 failures, 0 errors",
        failures: [], framework: "minitest"
      )

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      assert_equal [], result
    end

    test "handles test result with empty failures array" do
      test_result = TestExecution::TestResult.new(
        passed: false, exit_code: 1, summary: "5 runs, 10 assertions, 1 failures, 0 errors",
        failures: [], framework: "minitest"
      )

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      assert_equal [], result
    end

    # -- Categorization --

    test "categorizes view failures correctly" do
      test_result = build_test_result([
        { name: "test_index_page", message: "Expected element matching 'h1'", location: "test/views/users_test.rb:12" }
      ])

      stub_llm_response(@llm, "view-fix")

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      assert_equal 1, result.size
      assert_includes result.first["labels"], "view-fix"
    end

    test "categorizes view failures by location" do
      test_result = build_test_result([
        { name: "test_index", message: "assertion failed", location: "test/views/posts_test.rb:5" }
      ])

      stub_llm_response(@llm, "view-fix")

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      assert_equal 1, result.size
      assert_includes result.first["labels"], "view-fix"
    end

    test "categorizes unit expectation failures correctly" do
      test_result = build_test_result([
        { name: "test_calculation", message: "Expected 5 but was 3", location: "test/models/calc_test.rb:22" }
      ])

      stub_llm_response(@llm, "unit-fix")

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      assert_equal 1, result.size
      assert_includes result.first["labels"], "unit-fix"
    end

    test "categorizes integration failures correctly" do
      test_result = build_test_result([
        { name: "test_user_flow", message: "Expected 200 got 404", location: "test/integration/users_test.rb:33" }
      ])

      stub_llm_response(@llm, "integration-fix")

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      assert_equal 1, result.size
      assert_includes result.first["labels"], "integration-fix"
    end

    test "categorizes missing reference failures correctly" do
      test_result = build_test_result([
        { name: "test_user_creation", message: "NameError: uninitialized constant User", location: "test/models/user_test.rb:5" }
      ])

      stub_llm_response(@llm, "missing-ref")

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      assert_equal 1, result.size
      assert_includes result.first["labels"], "missing-ref"
    end

    test "categorizes routing failures correctly" do
      test_result = build_test_result([
        { name: "test_routes", message: "No route matches [GET] /users", location: "test/routing/routes_test.rb:8" }
      ])

      stub_llm_response(@llm, "routing-fix")

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      assert_equal 1, result.size
      assert_includes result.first["labels"], "routing-fix"
    end

    test "categorizes unmatched failures as general" do
      test_result = build_test_result([
        { name: "test_something", message: "timeout error", location: "test/misc_test.rb:1" }
      ])

      stub_llm_response(@llm, "bugfix")

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      assert_equal 1, result.size
      assert_includes result.first["labels"], "bugfix"
    end

    # -- Grouping and task generation --

    test "groups failures by category" do
      test_result = build_test_result([
        { name: "test_view_1", message: "Expected element matching 'div'", location: "test/views/a_test.rb:1" },
        { name: "test_view_2", message: "Expected element matching 'span'", location: "test/views/b_test.rb:2" },
        { name: "test_calc", message: "Expected 5 but was 3", location: "test/models/calc_test.rb:10" }
      ])

      # Two categories: view_markup (2 failures) and unit_expectation (1 failure)
      @llm.stubs(:chat_json).returns({
        "tasks" => [{ "title" => "Fix test", "description" => "details", "labels" => ["view-fix"] }]
      })

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      assert_equal 2, result.size
    end

    test "generates one task per failure category" do
      test_result = build_test_result([
        { name: "test_a", message: "No route matches", location: "test/routing_test.rb:1" },
        { name: "test_b", message: "No route matches /foo", location: "test/routing_test.rb:5" },
        { name: "test_c", message: "NameError: undefined local", location: "test/models/foo_test.rb:3" }
      ])

      @llm.stubs(:chat_json).returns({
        "tasks" => [{ "title" => "Fix issue", "description" => "details", "labels" => ["fix"] }]
      })

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      # routing (2 failures) + missing_reference (1 failure) = 2 tasks
      assert_equal 2, result.size
    end

    test "includes file and line references in LLM prompt" do
      test_result = build_test_result([
        { name: "test_page", message: "Expected element matching 'h1'", location: "test/views/home_test.rb:42" }
      ])

      @llm.expects(:chat_json).with { |params|
        user_msg = params[:messages].first[:content]
        user_msg.include?("test/views/home_test.rb:42") &&
          user_msg.include?("Expected element matching 'h1'")
      }.returns({
        "tasks" => [{ "title" => "Fix view", "description" => "Fix at test/views/home_test.rb:42", "labels" => ["view-fix"] }]
      })

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      assert_equal 1, result.size
    end

    test "limits failure details to first 5 per category" do
      failures = (1..8).map do |i|
        { name: "test_#{i}", message: "Expected element matching 'div#{i}'", location: "test/views/test#{i}.rb:#{i}" }
      end
      test_result = build_test_result(failures)

      @llm.expects(:chat_json).with { |params|
        user_msg = params[:messages].first[:content]
        # Should include first 5 failures
        user_msg.include?("test_1") &&
          user_msg.include?("test_5") &&
          !user_msg.include?("test_6")
      }.returns({
        "tasks" => [{ "title" => "Fix views", "description" => "Fix view tests", "labels" => ["view-fix"] }]
      })

      CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )
    end

    # -- Fallback behavior --

    test "falls back to direct task when LLM call fails" do
      test_result = build_test_result([
        { name: "test_calc", message: "Expected 5 but was 3", location: "test/models/calc_test.rb:22" }
      ])

      @llm.expects(:chat_json).raises(StandardError.new("API timeout"))

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm,
        logger: Logger.new(File::NULL)
      )

      assert_equal 1, result.size
      task = result.first
      assert_match(/unit expectation failures/, task["title"])
      assert_includes task["labels"], "unit-fix"
      assert_match(/test\/models\/calc_test\.rb:22/, task["description"])
    end

    test "fallback task includes failure count in title" do
      test_result = build_test_result([
        { name: "test_a", message: "Expected 1 got 2", location: "test/models/a_test.rb:1" },
        { name: "test_b", message: "Expected 3 got 4", location: "test/models/b_test.rb:2" }
      ])

      @llm.stubs(:chat_json).raises(StandardError.new("fail"))

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm,
        logger: Logger.new(File::NULL)
      )

      assert_equal 1, result.size
      assert_match(/2 tests/, result.first["title"])
    end

    test "fallback task uses singular when only one failure" do
      test_result = build_test_result([
        { name: "test_a", message: "Expected 1 got 2", location: "test/models/a_test.rb:1" }
      ])

      @llm.stubs(:chat_json).raises(StandardError.new("fail"))

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm,
        logger: Logger.new(File::NULL)
      )

      assert_equal 1, result.size
      assert_match(/1 test\)/, result.first["title"])
      refute_match(/1 tests/, result.first["title"])
    end

    test "falls back when LLM returns empty tasks array" do
      test_result = build_test_result([
        { name: "test_a", message: "Expected 1 got 2", location: "test/models/a_test.rb:1" }
      ])

      @llm.stubs(:chat_json).returns({ "tasks" => [] })

      result = CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )

      assert_equal 1, result.size
      assert_includes result.first["labels"], "unit-fix"
    end

    # -- Repo context --

    test "includes repo context in LLM prompt when provided" do
      test_result = build_test_result([
        { name: "test_a", message: "Expected 1 got 2", location: "test/models/a_test.rb:1" }
      ])

      @llm.expects(:chat_json).with { |params|
        user_msg = params[:messages].first[:content]
        user_msg.include?("### Repository Context") &&
          user_msg.include?("app/models/user.rb")
      }.returns({
        "tasks" => [{ "title" => "Fix", "description" => "d", "labels" => ["unit-fix"] }]
      })

      CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries,
        llm_client: @llm, repo_context: "app/models/user.rb"
      )
    end

    test "omits repo context section when not provided" do
      test_result = build_test_result([
        { name: "test_a", message: "Expected 1 got 2", location: "test/models/a_test.rb:1" }
      ])

      @llm.expects(:chat_json).with { |params|
        user_msg = params[:messages].first[:content]
        !user_msg.include?("Repository Context")
      }.returns({
        "tasks" => [{ "title" => "Fix", "description" => "d", "labels" => ["unit-fix"] }]
      })

      CorrectiveTaskGenerator.call(
        test_result:, diffs: @diffs, task_summaries: @task_summaries, llm_client: @llm
      )
    end

    private

    def build_test_result(failures)
      TestExecution::TestResult.new(
        passed: false,
        exit_code: 1,
        summary: "#{failures.size} failures",
        failures: failures,
        framework: "minitest"
      )
    end

    def stub_llm_response(llm, label)
      llm.stubs(:chat_json).returns({
        "tasks" => [{ "title" => "Fix #{label} issue", "description" => "Fix the failing tests", "labels" => [label] }]
      })
    end
  end
end
