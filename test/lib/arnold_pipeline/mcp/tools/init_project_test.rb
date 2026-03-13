require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/init_project"
require "arnold_pipeline/orchestrator"
require "tmpdir"

module ArnoldPipeline
  module Mcp
    module Tools
      class InitProjectTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::InitProject*"

        setup do
          @context = Context.new
          @tmp_dir = Dir.mktmpdir("init_project_test")
          @project_path = File.join(@tmp_dir, "my_app")

          # Redirect config path for tests
          @test_arnold_home = File.join(@tmp_dir, ".arnold_pipeline")
          @test_config_path = File.join(@test_arnold_home, "config.yml")
          Setup::Orchestrator.send(:remove_const, :CONFIG_PATH)
          Setup::Orchestrator.const_set(:CONFIG_PATH, @test_config_path)
          Setup::Orchestrator.send(:remove_const, :ARNOLD_HOME)
          Setup::Orchestrator.const_set(:ARNOLD_HOME, @test_arnold_home)

          # Build mock pipeline run
          @pipeline_run = PipelineRun.create!(
            nl_input: "a simple todo app",
            status: :paused,
            metadata: { "paused_at" => "tasks" }
          )
          Specification.create!(
            pipeline_run: @pipeline_run,
            content: "# Todo App\n\n## Purpose\nA todo app.",
            version: 1,
            structured_data: { "product_name" => "Todo App" }
          )
          @pipeline_run.tasks.create!(
            title: "Setup DB", description: "Create schema",
            priority: 1, position: 1, tier: 0, labels: [], depends_on: []
          )

          @orchestrator_stub = stub("orchestrator")
          @orchestrator_stub.stubs(:call).returns(@pipeline_run)
          ArnoldPipeline::Orchestrator.stubs(:new).returns(@orchestrator_stub)

          @original_anthropic_key = ENV["ANTHROPIC_API_KEY"]
          @original_openai_key = ENV["OPENAI_API_KEY"]
        end

        teardown do
          FileUtils.rm_rf(@tmp_dir)
          Setup::Orchestrator.send(:remove_const, :CONFIG_PATH)
          Setup::Orchestrator.const_set(:CONFIG_PATH, File.join(File.expand_path("~/.arnold_pipeline"), "config.yml"))
          Setup::Orchestrator.send(:remove_const, :ARNOLD_HOME)
          Setup::Orchestrator.const_set(:ARNOLD_HOME, File.expand_path("~/.arnold_pipeline"))

          if @original_anthropic_key
            ENV["ANTHROPIC_API_KEY"] = @original_anthropic_key
          else
            ENV.delete("ANTHROPIC_API_KEY")
          end
          if @original_openai_key
            ENV["OPENAI_API_KEY"] = @original_openai_key
          else
            ENV.delete("OPENAI_API_KEY")
          end

          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns init_project" do
          assert_equal "init_project", InitProject.tool_name
        end

        test "description is present and non-empty" do
          assert_kind_of String, InitProject.description
          refute_empty InitProject.description
        end

        test "input_schema has expected properties" do
          schema = InitProject.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:project_path)
          assert schema[:properties].key?(:description)
          assert schema[:properties].key?(:llm_provider)
          assert schema[:properties].key?(:execution_provider)
          assert_equal [], schema[:required]
        end

        test "needs_input returns status and missing fields" do
          ENV.delete("ANTHROPIC_API_KEY")
          ENV.delete("OPENAI_API_KEY")

          result = InitProject.call({}, @context)

          assert_equal "needs_input", result[:status]
          assert_includes result[:missing_fields], "project_path"
          assert_includes result[:missing_fields], "description"
          assert_includes result[:missing_fields], "llm_api_key"
        end

        test "needs_input includes field hints" do
          ENV.delete("ANTHROPIC_API_KEY")
          ENV.delete("OPENAI_API_KEY")

          result = InitProject.call({}, @context)

          assert result[:field_hints].key?("project_path")
          assert result[:field_hints].key?("description")
        end

        test "complete returns status and next_actions" do
          result = InitProject.call({
            "project_path" => @project_path,
            "description" => "a simple todo app with auth",
            "llm_api_key" => "sk-test"
          }, @context)

          assert_equal "complete", result[:status]
          assert_equal @project_path, result[:project_path]
          assert_equal @pipeline_run.id.to_s, result[:run_id]
          assert result[:next_actions].is_a?(Array)
          assert result[:next_actions].any? { |a| a.include?("arnold run") }
        end

        test "complete includes spec and task summaries" do
          result = InitProject.call({
            "project_path" => @project_path,
            "description" => "a simple todo app with auth",
            "llm_api_key" => "sk-test"
          }, @context)

          assert result[:spec_summary].is_a?(Hash)
          assert result[:task_summary].is_a?(Hash)
        end

        test "error returns status and errors" do
          result = InitProject.call({
            "project_path" => @project_path,
            "description" => "short",
            "llm_api_key" => "sk-test"
          }, @context)

          assert_equal "error", result[:status]
          assert result[:errors].is_a?(Array)
        end

        test "handles orchestrator exception gracefully" do
          @orchestrator_stub.stubs(:call).raises(StandardError.new("LLM down"))

          result = InitProject.call({
            "project_path" => @project_path,
            "description" => "a simple todo app with auth",
            "llm_api_key" => "sk-test"
          }, @context)

          # The error is caught at Setup::Orchestrator level and returned as Result.error,
          # so it comes through as status: "error" from the MCP tool
          assert %w[error].include?(result[:status]) || result.key?(:error)
        end

        test "strips whitespace from string params" do
          ENV["ANTHROPIC_API_KEY"] = "sk-test"

          result = InitProject.call({
            "project_path" => "  #{@project_path}  ",
            "description" => "  a simple todo app with auth  "
          }, @context)

          assert_equal "complete", result[:status]
        end
      end
    end
  end
end
