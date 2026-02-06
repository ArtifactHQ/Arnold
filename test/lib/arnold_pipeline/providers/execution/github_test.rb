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
