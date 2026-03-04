require "test_helper"

module ArnoldPipeline
  class CodebaseProfileTest < ActiveSupport::TestCase
    setup do
      @pipeline_run = PipelineRun.create!(nl_input: "test app", status: :pending)
      @profile = CodebaseProfile.create!(
        pipeline_run: @pipeline_run,
        project_name: "my_app",
        stack_fingerprint: { "language" => "ruby", "framework" => "rails", "confidence" => 95 },
        recipe_alignment: {
          "concerns" => {
            "auth" => { "status" => "present", "implementation" => "devise" },
            "data_layer" => { "status" => "present", "implementation" => "active_record" },
            "realtime" => { "status" => "absent" }
          }
        },
        conventions: { "naming" => "snake_case", "test_framework" => "minitest" },
        health_baseline: {
          "checks" => [
            { "name" => "git_status", "success" => true },
            { "name" => "test_suite", "success" => false, "exit_code" => 1 }
          ]
        },
        confidence: 85,
        token_budget_used: 12000,
        analyzed_at: Time.current
      )
    end

    test "belongs to pipeline_run" do
      assert_equal @pipeline_run, @profile.pipeline_run
    end

    test "requires pipeline_run" do
      profile = CodebaseProfile.new(project_name: "test")
      assert_not profile.valid?
      assert_includes profile.errors[:pipeline_run], "must exist"
    end

    test "stack_language returns language from fingerprint" do
      assert_equal "ruby", @profile.stack_language
    end

    test "stack_language returns nil when fingerprint is nil" do
      @profile.stack_fingerprint = nil
      assert_nil @profile.stack_language
    end

    test "stack_framework returns framework from fingerprint" do
      assert_equal "rails", @profile.stack_framework
    end

    test "concern_status returns status for a known concern" do
      assert_equal "present", @profile.concern_status(:auth)
      assert_equal "absent", @profile.concern_status(:realtime)
    end

    test "concern_status returns nil for unknown concern" do
      assert_nil @profile.concern_status(:unknown)
    end

    test "convention returns value for a known key" do
      assert_equal "snake_case", @profile.convention(:naming)
    end

    test "convention returns nil for unknown key" do
      assert_nil @profile.convention(:unknown)
    end

    test "pre_existing_failures returns failed checks" do
      failures = @profile.pre_existing_failures
      assert_equal 1, failures.size
      assert_equal "test_suite", failures.first["name"]
    end

    test "pre_existing_failures returns empty array when health_baseline is nil" do
      @profile.health_baseline = nil
      assert_equal [], @profile.pre_existing_failures
    end

    test "stale? returns true when analyzed_at is nil" do
      @profile.analyzed_at = nil
      assert @profile.stale?("/tmp")
    end

    test "stale? returns false when repo has no files newer than analyzed_at" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "test.rb"), "# test")
        # Set analyzed_at to the future so it's definitely after file mtime
        @profile.analyzed_at = Time.current + 1.hour
        assert_not @profile.stale?(dir)
      end
    end

    test "stale? returns true when repo has files newer than analyzed_at" do
      Dir.mktmpdir do |dir|
        @profile.analyzed_at = Time.current - 1.hour
        File.write(File.join(dir, "test.rb"), "# test")
        assert @profile.stale?(dir)
      end
    end

    test "pipeline_run has_one codebase_profile" do
      assert_equal @profile, @pipeline_run.codebase_profile
    end
  end
end
