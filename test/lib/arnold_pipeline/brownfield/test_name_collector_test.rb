require "test_helper"
require "arnold_pipeline/brownfield/test_name_collector"

module ArnoldPipeline
  module Brownfield
    class TestNameCollectorTest < ActiveSupport::TestCase
      setup do
        @repo_path = Dir.mktmpdir("test_collector_")
        @rails_fingerprint = { language: "ruby", framework: "rails" }
        @nextjs_fingerprint = { language: "typescript", framework: "nextjs" }
        @python_fingerprint = { language: "python", framework: "django" }
        @rust_fingerprint = { language: "rust", framework: "actix" }
      end

      teardown do
        FileUtils.rm_rf(@repo_path)
      end

      test "detects rails_minitest framework for ruby stack" do
        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)
        assert_equal "rails_minitest", collector.send(:detect_test_framework)
      end

      test "detects rspec framework when .rspec file exists" do
        File.write(File.join(@repo_path, ".rspec"), "--require spec_helper")

        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)
        assert_equal "rspec", collector.send(:detect_test_framework)
      end

      test "detects rspec framework when spec directory exists" do
        FileUtils.mkdir_p(File.join(@repo_path, "spec"))

        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)
        assert_equal "rspec", collector.send(:detect_test_framework)
      end

      test "detects jest for typescript stack" do
        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: @nextjs_fingerprint)
        assert_equal "jest", collector.send(:detect_test_framework)
      end

      test "detects pytest for python stack" do
        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: @python_fingerprint)
        assert_equal "pytest", collector.send(:detect_test_framework)
      end

      test "detects cargo for rust stack" do
        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: @rust_fingerprint)
        assert_equal "cargo", collector.send(:detect_test_framework)
      end

      test "returns nil framework for unknown language" do
        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: { language: "cobol" })
        assert_nil collector.send(:detect_test_framework)
      end

      test "parses minitest dry-run output" do
        output = <<~OUTPUT
          UserTest#test_email_must_be_unique = 0.00 s = .
          UserTest#test_password_minimum_length = 0.00 s = .
          SessionTest#test_login_creates_session = 0.00 s = .
        OUTPUT

        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)
        names = collector.send(:parse_minitest, output)

        assert_equal 3, names.size
        assert_includes names, "UserTest#test_email_must_be_unique"
        assert_includes names, "SessionTest#test_login_creates_session"
      end

      test "parses rspec documentation output" do
        output = <<~OUTPUT
          User
            validations
              validates email presence
              validates password length
          Session
            #create
              creates a new session
        OUTPUT

        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)
        names = collector.send(:parse_rspec, output)

        assert names.any? { |n| n.include?("validates email presence") }
        assert names.any? { |n| n.include?("creates a new session") }
      end

      test "parses jest test list output" do
        output = <<~OUTPUT
          /project/src/auth/__tests__/login.test.ts
          /project/src/api/__tests__/users.test.ts
          /project/src/components/__tests__/Header.spec.tsx
        OUTPUT

        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: @nextjs_fingerprint)
        names = collector.send(:parse_jest, output)

        assert_equal 3, names.size
        assert names.any? { |n| n.include?("login.test.ts") }
      end

      test "parses pytest collect-only output" do
        output = <<~OUTPUT
          tests/test_auth.py::test_user_login
          tests/test_auth.py::test_password_reset
          tests/test_models.py::test_create_user
          === 3 tests collected ===
        OUTPUT

        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: @python_fingerprint)
        names = collector.send(:parse_pytest, output)

        assert_equal 3, names.size
        assert names.any? { |n| n.include?("test_user_login") }
      end

      test "parses cargo test list output" do
        output = <<~OUTPUT
          auth::test_login: test
          auth::test_logout: test
          models::test_create_user: test
        OUTPUT

        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: @rust_fingerprint)
        names = collector.send(:parse_cargo, output)

        assert_equal 3, names.size
        assert_includes names, "auth::test_login"
        assert_includes names, "models::test_create_user"
      end

      test "groups test names by concern using keywords" do
        test_names = [
          "UserTest#test_password_validation",
          "UserTest#test_login_flow",
          "PostControllerTest#test_create_post",
          "SurveyJobTest#test_enqueue_job",
          "SomeRandomTest#test_something"
        ]

        collector = TestNameCollector.new(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)
        grouped = collector.send(:group_by_concern, test_names)

        assert_includes grouped["auth"], "UserTest#test_password_validation"
        assert_includes grouped["auth"], "UserTest#test_login_flow"
        assert_includes grouped["api_layer"], "PostControllerTest#test_create_post"
        assert_includes grouped["background_jobs"], "SurveyJobTest#test_enqueue_job"
        assert_includes grouped["uncategorized"], "SomeRandomTest#test_something"
      end

      test "returns empty result on command failure" do
        Open3.stubs(:capture3).raises(Errno::ENOENT)

        result = TestNameCollector.call(
          repo_path: @repo_path,
          stack_fingerprint: @rails_fingerprint
        )

        assert_equal [], result[:test_names]
        assert_equal({}, result[:grouped_by_concern])
        assert_nil result[:framework]
      end

      test "returns empty result for unknown language" do
        result = TestNameCollector.call(
          repo_path: @repo_path,
          stack_fingerprint: { language: "cobol" }
        )

        assert_equal [], result[:test_names]
        assert_nil result[:framework]
      end

      test "returns empty result when command output is empty" do
        Open3.stubs(:capture3).returns([ "", "", stub(success?: true) ])

        result = TestNameCollector.call(
          repo_path: @repo_path,
          stack_fingerprint: @rails_fingerprint
        )

        assert_equal [], result[:test_names]
      end

      test "handles string keys in stack_fingerprint" do
        collector = TestNameCollector.new(
          repo_path: @repo_path,
          stack_fingerprint: { "language" => "ruby", "framework" => "rails" }
        )

        assert_equal "rails_minitest", collector.send(:detect_test_framework)
      end
    end
  end
end
