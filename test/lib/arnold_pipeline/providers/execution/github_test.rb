require "test_helper"
require "webmock/minitest"
require "arnold_pipeline/providers/execution/github"

module ArnoldPipeline
  module Providers
    module Execution
      class GithubTest < ActiveSupport::TestCase
        setup do
          @provider = Github.new(token: "ghp_test", repo: "owner/repo")
          @pipeline_run = ArnoldPipeline::PipelineRun.create!(nl_input: "Build an app")
        end

        test "create_tasks creates GitHub issues" do
          stub_request(:post, "https://api.github.com/repos/owner/repo/issues")
            .to_return(
              status: 201,
              headers: { "Content-Type" => "application/json" },
              body: { number: 42, html_url: "https://github.com/owner/repo/issues/42" }.to_json
            )

          tasks = [{ "title" => "Setup DB", "description" => "Create schema", "labels" => ["backend"] }]
          results = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          assert_equal 1, results.size
          assert_equal "42", results.first[:external_id]
          assert_equal "https://github.com/owner/repo/issues/42", results.first[:external_url]
        end

        test "create_tasks includes dependency references in issue body" do
          issue_counter = 0
          stub_request(:post, "https://api.github.com/repos/owner/repo/issues")
            .to_return do |request|
              issue_counter += 1
              {
                status: 201,
                headers: { "Content-Type" => "application/json" },
                body: { number: issue_counter, html_url: "https://github.com/owner/repo/issues/#{issue_counter}" }.to_json
              }
            end

          tasks = [
            { "title" => "Setup DB", "description" => "Create schema", "labels" => ["backend"], "position" => 0, "depends_on" => [] },
            { "title" => "Build API", "description" => "Create endpoints", "labels" => ["backend"], "position" => 1, "depends_on" => [0] },
            { "title" => "Add auth", "description" => "Secure endpoints", "labels" => ["backend"], "position" => 2, "depends_on" => [0, 1] }
          ]

          results = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          assert_equal 3, results.size

          # Verify the request bodies
          assert_requested(:post, "https://api.github.com/repos/owner/repo/issues", times: 3)

          # First task (no dependencies)
          assert_requested(:post, "https://api.github.com/repos/owner/repo/issues") { |req|
            body = JSON.parse(req.body)
            body["title"] == "Setup DB" && !body["body"].include?("Depends on")
          }

          # Second task depends on first (issue #1)
          assert_requested(:post, "https://api.github.com/repos/owner/repo/issues") { |req|
            body = JSON.parse(req.body)
            body["title"] == "Build API" && body["body"].include?("**Depends on:** #1")
          }

          # Third task depends on first and second (issues #1, #2)
          assert_requested(:post, "https://api.github.com/repos/owner/repo/issues") { |req|
            body = JSON.parse(req.body)
            body["title"] == "Add auth" && body["body"].include?("**Depends on:** #1, #2")
          }
        end

        test "build factory creates Github provider" do
          ArnoldPipeline.configure do |c|
            c.execution_provider = :github
            c.github_token = "ghp_test"
            c.github_repo = "owner/repo"
          end

          provider = Execution.build
          assert_kind_of Github, provider
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "build factory raises on unknown provider" do
          assert_raises(ConfigurationError) do
            Execution.build(provider: :unknown)
          end
        end

        test "base class raises NotImplementedError" do
          base = Base.new
          assert_raises(NotImplementedError) { base.create_tasks(tasks: [], pipeline_run: nil) }
          assert_raises(NotImplementedError) { base.fetch_results(pipeline_run: nil) }
          assert_raises(NotImplementedError) { base.merge_results(pipeline_run: nil) }
        end
      end
    end
  end
end
