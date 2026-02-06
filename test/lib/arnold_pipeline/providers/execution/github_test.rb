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

        test "create_tasks includes issue_mention in body when configured" do
          provider = Github.new(token: "ghp_test", repo: "owner/repo", issue_mention: "@claude")

          stub_request(:post, "https://api.github.com/repos/owner/repo/issues")
            .to_return(
              status: 201,
              headers: { "Content-Type" => "application/json" },
              body: { number: 1, html_url: "https://github.com/owner/repo/issues/1" }.to_json
            )

          tasks = [{ "title" => "Setup DB", "description" => "Create schema", "labels" => ["backend"], "position" => 0, "depends_on" => [] }]
          provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          assert_requested(:post, "https://api.github.com/repos/owner/repo/issues") { |req|
            body = JSON.parse(req.body)
            body["body"].include?("@claude")
          }
        end

        test "create_tasks omits mention when issue_mention is nil" do
          stub_request(:post, "https://api.github.com/repos/owner/repo/issues")
            .to_return(
              status: 201,
              headers: { "Content-Type" => "application/json" },
              body: { number: 1, html_url: "https://github.com/owner/repo/issues/1" }.to_json
            )

          tasks = [{ "title" => "Setup DB", "description" => "Create schema", "labels" => ["backend"], "position" => 0, "depends_on" => [] }]
          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          assert_requested(:post, "https://api.github.com/repos/owner/repo/issues") { |req|
            body = JSON.parse(req.body)
            !body["body"].include?("@")
          }
        end

        test "fetch_results returns comments from issues and PRs" do
          task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { number: 42, state: "open" }.to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [{ user: { login: "copilot" }, body: "I can't do this without a Gemfile", created_at: "2025-02-06T00:00:00Z" }].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [].to_json
            )

          results = @provider.fetch_results(pipeline_run: @pipeline_run)

          assert_equal 1, results.size
          result = results.first
          assert_equal 1, result[:comments].size
          assert_equal "issue", result[:comments].first[:source]
          assert_equal "copilot", result[:comments].first[:author]
          assert_includes result[:comments].first[:body], "Gemfile"
          assert_equal "open", result[:issue_state]
        end

        test "fetch_results returns failed status for closed issue with no PRs" do
          task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { number: 42, state: "closed" }.to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [].to_json
            )

          results = @provider.fetch_results(pipeline_run: @pipeline_run)

          assert_equal :failed, results.first[:status]
        end

        test "fetch_results returns pending status for open issue with no PRs" do
          task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { number: 42, state: "open" }.to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [].to_json
            )

          results = @provider.fetch_results(pipeline_run: @pipeline_run)

          assert_equal :pending, results.first[:status]
        end

        test "fetch_results includes PR review comments" do
          task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { number: 42, state: "open" }.to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [{ number: 10, title: "Fix #42", body: "Closes #42", state: "open", merged_at: nil }].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls/10/files")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [{ filename: "app.rb", patch: "+code", status: "added" }].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls/10/comments")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [{ user: { login: "reviewer" }, body: "Looks good", created_at: "2025-02-06T01:00:00Z" }].to_json
            )

          results = @provider.fetch_results(pipeline_run: @pipeline_run)

          result = results.first
          assert_equal 1, result[:comments].size
          assert_equal "pr_review", result[:comments].first[:source]
          assert_equal "reviewer", result[:comments].first[:author]
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

        test "build factory passes issue_mention from config" do
          ArnoldPipeline.configure do |c|
            c.execution_provider = :github
            c.github_token = "ghp_test"
            c.github_repo = "owner/repo"
            c.github_issue_mention = "@claude"
          end

          provider = Execution.build
          assert_kind_of Github, provider
          # Verify mention is wired by checking instance variable
          assert_equal "@claude", provider.instance_variable_get(:@issue_mention)
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
