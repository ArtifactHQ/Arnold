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
          ArnoldPipeline.configure do |c|
            c.workflow_status_enabled = false
            c.github_token = "ghp_test"
            c.github_repo = "owner/repo"
          end
        end

        teardown do
          ArnoldPipeline.reset_configuration!
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

        test "create_tasks with prior_context includes it in issue body" do
          stub_request(:post, "https://api.github.com/repos/owner/repo/issues")
            .to_return(
              status: 201,
              headers: { "Content-Type" => "application/json" },
              body: { number: 1, html_url: "https://github.com/owner/repo/issues/1" }.to_json
            )

          tasks = [{ "title" => "Build API", "description" => "Create endpoints", "labels" => ["backend"], "position" => 0, "depends_on" => [] }]
          prior_context = "## Prior Implementation Context\n\n**Tier 0 completed:** Set up Rails project."

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run, prior_context:)

          assert_requested(:post, "https://api.github.com/repos/owner/repo/issues") { |req|
            body = JSON.parse(req.body)
            body["body"].include?("Prior Implementation Context") &&
              body["body"].include?("Tier 0 completed")
          }
        end

        test "create_tasks without prior_context omits context section" do
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
            !body["body"].include?("Prior Implementation Context")
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

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments").with(query: { per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [{ user: { login: "copilot" }, body: "I can't do this without a Gemfile", created_at: "2025-02-06T00:00:00Z" }].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all", per_page: "100" })
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

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments").with(query: { per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all", per_page: "100" })
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

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments").with(query: { per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all", per_page: "100" })
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

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments").with(query: { per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all", per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [{ number: 10, title: "Fix #42", body: "Closes #42", state: "open", merged_at: nil }].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls/10/files").with(query: { per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [{ filename: "app.rb", patch: "+code", status: "added" }].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls/10/comments").with(query: { per_page: "100" })
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

        test "fetch_results with tasks: parameter scopes to given tasks" do
          task1 = @pipeline_run.tasks.create!(title: "Task 1", position: 0, external_id: "42")
          task2 = @pipeline_run.tasks.create!(title: "Task 2", position: 1, external_id: "43")

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { number: 42, state: "open" }.to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments").with(query: { per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all", per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [].to_json
            )

          # Only fetch results for task1
          results = @provider.fetch_results(pipeline_run: @pipeline_run, tasks: [task1])

          assert_equal 1, results.size
          assert_equal task1.id, results.first[:task_id]
        end

        test "merge_results with tasks: parameter scopes to given tasks" do
          task1 = @pipeline_run.tasks.create!(title: "Task 1", position: 0, external_id: "42")
          task2 = @pipeline_run.tasks.create!(title: "Task 2", position: 1, external_id: "43")

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "open", per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [{ number: 10, title: "Fix #42", body: "Closes #42", state: "open", merged_at: nil }].to_json
            )

          stub_request(:put, "https://api.github.com/repos/owner/repo/pulls/10/merge")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { merged: true }.to_json
            )

          # Only merge for task1
          results = @provider.merge_results(pipeline_run: @pipeline_run, tasks: [task1])

          assert_equal 1, results.size
          assert_equal task1.id, results.first[:task_id]
        end

        # --- workflow checking tests ---

        test "fetch_results returns workflow_active true when PR check runs are in progress" do
          ArnoldPipeline.configure do |c|
            c.workflow_status_enabled = true
            c.github_token = "ghp_test"
            c.github_repo = "owner/repo"
          end

          task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { number: 42, state: "open" }.to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments").with(query: { per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all", per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [{
                number: 10, title: "Fix #42", body: "Closes #42", state: "open", merged_at: nil,
                head: { sha: "abc123" }
              }].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls/10/files").with(query: { per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls/10/comments").with(query: { per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          stub_request(:get, "https://api.github.com/repos/owner/repo/commits/abc123/check-runs").with(query: { per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { check_runs: [{ name: "CI", status: "in_progress", conclusion: nil }] }.to_json
            )

          results = @provider.fetch_results(pipeline_run: @pipeline_run)

          assert results.first[:workflow_active], "Should detect active workflow from PR check runs"
          assert_includes results.first[:workflow_details], "PR #10 check runs: CI(in_progress)"
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "fetch_results returns workflow_active false when all checks are completed" do
          ArnoldPipeline.configure do |c|
            c.workflow_status_enabled = true
            c.github_token = "ghp_test"
            c.github_repo = "owner/repo"
          end

          task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { number: 42, state: "open" }.to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments").with(query: { per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all", per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: [{
                number: 10, title: "Fix #42", body: "Closes #42", state: "open", merged_at: nil,
                head: { sha: "abc123" }
              }].to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls/10/files").with(query: { per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls/10/comments").with(query: { per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          stub_request(:get, "https://api.github.com/repos/owner/repo/commits/abc123/check-runs").with(query: { per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { check_runs: [{ name: "CI", status: "completed", conclusion: "success" }] }.to_json
            )

          # No active workflow runs by branch either
          stub_request(:get, "https://api.github.com/repos/owner/repo/actions/runs")
            .with(query: { status: "in_progress", per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { workflow_runs: [] }.to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/actions/runs")
            .with(query: { status: "queued", per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { workflow_runs: [] }.to_json
            )

          results = @provider.fetch_results(pipeline_run: @pipeline_run)

          refute results.first[:workflow_active], "Should not detect active workflow when all checks complete"
          assert_equal "no active workflows", results.first[:workflow_details]
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "fetch_results returns workflow_active true when branch workflow run matches issue" do
          ArnoldPipeline.configure do |c|
            c.workflow_status_enabled = true
            c.github_token = "ghp_test"
            c.github_repo = "owner/repo"
          end

          task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { number: 42, state: "open" }.to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments").with(query: { per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          # No PRs — fall through to branch-based check
          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all", per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          stub_request(:get, "https://api.github.com/repos/owner/repo/actions/runs")
            .with(query: { status: "in_progress", per_page: "100" })
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { workflow_runs: [{ head_branch: "claude/issue-42-setup-db" }] }.to_json
            )

          results = @provider.fetch_results(pipeline_run: @pipeline_run)

          assert results.first[:workflow_active], "Should detect active workflow from branch name matching issue number"
          assert_includes results.first[:workflow_details], "branch workflow runs:"
          assert_includes results.first[:workflow_details], "claude/issue-42-setup-db"
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "fetch_results returns workflow_active false on API error (graceful degradation)" do
          ArnoldPipeline.configure do |c|
            c.workflow_status_enabled = true
            c.github_token = "ghp_test"
            c.github_repo = "owner/repo"
          end

          task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { number: 42, state: "open" }.to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments").with(query: { per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all", per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          # Workflow runs API returns an error
          stub_request(:get, "https://api.github.com/repos/owner/repo/actions/runs")
            .with(query: { status: "in_progress", per_page: "100" })
            .to_return(status: 500, headers: { "Content-Type" => "application/json" }, body: { message: "Internal Server Error" }.to_json)

          results = @provider.fetch_results(pipeline_run: @pipeline_run)

          refute results.first[:workflow_active], "Should return false on API error"
          assert_match(/error:/, results.first[:workflow_details])
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "fetch_results returns workflow_active false when workflow_status_enabled is false" do
          ArnoldPipeline.configure do |c|
            c.workflow_status_enabled = false
            c.github_token = "ghp_test"
            c.github_repo = "owner/repo"
          end

          task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { number: 42, state: "open" }.to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments").with(query: { per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all", per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          results = @provider.fetch_results(pipeline_run: @pipeline_run)

          refute results.first[:workflow_active], "Should skip workflow check when disabled"
          assert_equal "disabled", results.first[:workflow_details]
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "check_workflows_active? lets unexpected exceptions bubble up" do
          ArnoldPipeline.configure do |c|
            c.workflow_status_enabled = true
            c.github_token = "ghp_test"
            c.github_repo = "owner/repo"
          end

          task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42")
            .to_return(
              status: 200,
              headers: { "Content-Type" => "application/json" },
              body: { number: 42, state: "open" }.to_json
            )

          stub_request(:get, "https://api.github.com/repos/owner/repo/issues/42/comments").with(query: { per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          stub_request(:get, "https://api.github.com/repos/owner/repo/pulls")
            .with(query: { state: "all", per_page: "100" })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: [].to_json)

          # Stub the workflow runs call to raise a programming error
          @provider.instance_variable_get(:@client).stubs(:repository_workflow_runs).raises(NoMethodError, "undefined method 'foo'")

          assert_raises(NoMethodError) do
            @provider.fetch_results(pipeline_run: @pipeline_run)
          end
        ensure
          ArnoldPipeline.reset_configuration!
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
          assert_raises(NotImplementedError) { base.fetch_results(pipeline_run: nil, tasks: nil) }
          assert_raises(NotImplementedError) { base.merge_results(pipeline_run: nil, tasks: nil) }
        end

        test "client has auto_paginate enabled" do
          provider = Github.new(token: "test-token", repo: "owner/repo")
          client = provider.instance_variable_get(:@client)
          assert client.auto_paginate
        end
      end
    end
  end
end
