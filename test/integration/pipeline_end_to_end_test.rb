require "test_helper"
require "webmock/minitest"
require "arnold_pipeline/orchestrator"

module ArnoldPipeline
  class PipelineEndToEndTest < ActiveSupport::TestCase
    setup do
      ArnoldPipeline.configure do |c|
        c.llm_provider = :anthropic
        c.llm_api_key = "sk-test-key"
        c.llm_model = "claude-sonnet-4-20250514"
        c.execution_provider = :github
        c.github_token = "ghp_test"
        c.github_repo = "testowner/testrepo"
        c.max_iterations = 3
        c.polling_interval = 0.01
        c.polling_timeout = 0.05
        c.polling_max_interval = 0.02
        c.tier_gate_enabled = false
        c.context_propagation_enabled = false
      end

      stub_anthropic_api!
      stub_github_api!
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    test "full pipeline from NL input to completion" do
      orchestrator = Orchestrator.new(logger: Logger.new(File::NULL))

      result = orchestrator.call(nl_input: "Build a todo list app with user authentication")

      assert_equal "completed", result.status

      # Spec was generated
      assert_not_nil result.specification
      assert_includes result.specification.content, "Todo App Spec"

      # Tasks were created
      assert result.tasks.count >= 5

      # Analysis produced a done decision
      assert_equal 1, result.iterations.count
      iteration = result.iterations.first
      assert_equal "done", iteration.decision
      assert_equal 92, iteration.confidence
      assert_not iteration.needs_human_review
    end

    test "full pipeline with iterate_tasks path" do
      # Override the analysis stub to first return iterate_tasks, then done
      @analysis_call_count = 0
      stub_anthropic_with_sequential_analysis!

      orchestrator = Orchestrator.new(logger: Logger.new(File::NULL))
      result = orchestrator.call(nl_input: "Build a todo list app with user authentication")

      assert_equal "completed", result.status
      assert_equal 2, result.iterations.count
      assert_equal "iterate_tasks", result.iterations.order(:number).first.decision
      assert_equal "done", result.iterations.order(:number).last.decision
    end

    private

    def stub_anthropic_api!
      spec_response = {
        content: [{ type: "text", text: spec_llm_response }],
        role: "assistant"
      }

      task_response = {
        content: [{ type: "text", text: task_llm_response }],
        role: "assistant"
      }

      analysis_response = {
        content: [{ type: "text", text: analysis_done_response }],
        role: "assistant"
      }

      # Use a counter to return different responses based on the prompt content
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return do |request|
          body = JSON.parse(request.body)
          user_msg = body["messages"]&.last&.dig("content") || ""

          response_body = if user_msg.include?("generate a detailed specification")
            spec_response
          elsif user_msg.include?("Break down the following specification")
            task_response
          else
            analysis_response
          end

          { status: 200, headers: { "Content-Type" => "application/json" }, body: response_body.to_json }
        end
    end

    def stub_anthropic_with_sequential_analysis!
      WebMock.reset!

      spec_response = { content: [{ type: "text", text: spec_llm_response }], role: "assistant" }
      task_response = { content: [{ type: "text", text: task_llm_response }], role: "assistant" }

      @analysis_call_count = 0
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return do |request|
          body = JSON.parse(request.body)
          user_msg = body["messages"]&.last&.dig("content") || ""

          response_body = if user_msg.include?("generate a detailed specification")
            spec_response
          elsif user_msg.include?("Break down the following specification")
            task_response
          else
            @analysis_call_count += 1
            if @analysis_call_count == 1
              { content: [{ type: "text", text: analysis_iterate_tasks_response }], role: "assistant" }
            else
              { content: [{ type: "text", text: analysis_done_response }], role: "assistant" }
            end
          end

          { status: 200, headers: { "Content-Type" => "application/json" }, body: response_body.to_json }
        end

      stub_github_api!
    end

    def stub_github_api!
      # Issue creation
      stub_request(:post, %r{https://api.github.com/repos/testowner/testrepo/issues})
        .to_return do |_|
          issue_num = rand(100..999)
          {
            status: 201,
            headers: { "Content-Type" => "application/json" },
            body: { number: issue_num, html_url: "https://github.com/testowner/testrepo/issues/#{issue_num}" }.to_json
          }
        end

      # Issue fetching (for fetch_results)
      stub_request(:get, %r{https://api.github.com/repos/testowner/testrepo/issues/\d+\z})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { number: 1, state: "open" }.to_json
        )

      # Issue comments — registered after issue stub so it takes priority (WebMock matches last-registered first)
      stub_request(:get, %r{https://api.github.com/repos/testowner/testrepo/issues/\d+/comments})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      # PR listing (empty — no PRs to fetch)
      stub_request(:get, %r{https://api.github.com/repos/testowner/testrepo/pulls})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [].to_json
        )

      # Merge (no-op for empty)
      stub_request(:put, %r{https://api.github.com/repos/testowner/testrepo/pulls/\d+/merge})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { merged: true }.to_json)
    end

    def spec_llm_response
      <<~RESPONSE
        # Todo App Spec

        ## Features
        - User authentication (signup, login, logout)
        - CRUD operations for todo items
        - Real-time updates

        ## Tech Stack
        - Backend: Rails 8
        - Database: PostgreSQL
        - Frontend: Hotwire/Turbo

        ```json
        {
          "application_type": "PRODUCTIVITY",
          "features": ["authentication", "crud_todos", "real_time"],
          "tech_stack": {"backend": "Rails 8", "database": "PostgreSQL", "frontend": "Hotwire"},
          "data_models": [{"name": "User", "attributes": ["email", "password"]}, {"name": "Todo", "attributes": ["title", "completed"]}],
          "recipe_type": "web_app"
        }
        ```
      RESPONSE
    end

    def task_llm_response
      tasks = [
        { "title" => "Setup Rails project", "description" => "Initialize Rails 8 project with PostgreSQL", "priority" => 0, "labels" => ["setup"], "position" => 0, "depends_on" => [] },
        { "title" => "Create User model", "description" => "Generate User model with authentication", "priority" => 0, "labels" => ["backend", "database"], "position" => 1, "depends_on" => [0] },
        { "title" => "Create Todo model", "description" => "Generate Todo model with associations", "priority" => 0, "labels" => ["backend", "database"], "position" => 2, "depends_on" => [1] },
        { "title" => "Build authentication", "description" => "Implement signup/login/logout", "priority" => 1, "labels" => ["backend", "frontend"], "position" => 3, "depends_on" => [1] },
        { "title" => "Build Todo CRUD", "description" => "Implement create/read/update/delete for todos", "priority" => 1, "labels" => ["backend", "frontend"], "position" => 4, "depends_on" => [2, 3] },
        { "title" => "Add real-time updates", "description" => "Implement Turbo Streams for live updates", "priority" => 2, "labels" => ["frontend"], "position" => 5, "depends_on" => [4] },
        { "title" => "Write tests", "description" => "System and unit tests", "priority" => 2, "labels" => ["testing"], "position" => 6, "depends_on" => [4, 5] }
      ]
      "```json\n#{JSON.generate(tasks)}\n```"
    end

    def analysis_done_response
      analysis = {
        "decision" => "done",
        "confidence" => 92,
        "reasoning" => "All features implemented correctly. Authentication, CRUD operations, and real-time updates are present.",
        "corrective_data" => {}
      }
      "```json\n#{JSON.generate(analysis)}\n```"
    end

    def analysis_iterate_tasks_response
      analysis = {
        "decision" => "iterate_tasks",
        "confidence" => 72,
        "reasoning" => "Missing error handling in authentication flow",
        "corrective_data" => {
          "tasks" => [
            { "title" => "Fix auth error handling", "description" => "Add proper error messages", "priority" => 0, "labels" => ["backend"], "position" => 0, "depends_on" => [] },
            { "title" => "Add input validation", "description" => "Validate todo inputs", "priority" => 0, "labels" => ["backend"], "position" => 1, "depends_on" => [0] },
            { "title" => "Fix test coverage", "description" => "Add missing test cases", "priority" => 1, "labels" => ["testing"], "position" => 2, "depends_on" => [0, 1] },
            { "title" => "Update error pages", "description" => "Custom error pages", "priority" => 1, "labels" => ["frontend"], "position" => 3, "depends_on" => [0] },
            { "title" => "Integration tests", "description" => "End-to-end flow tests", "priority" => 2, "labels" => ["testing"], "position" => 4, "depends_on" => [2, 3] }
          ]
        }
      }
      "```json\n#{JSON.generate(analysis)}\n```"
    end
  end
end
