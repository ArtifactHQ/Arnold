require "test_helper"
require "arnold_pipeline/providers/execution/claude_code"
require_relative "shared_provider_tests"

module ArnoldPipeline
  module Providers
    module Execution
      class ClaudeCodeTest < ActiveSupport::TestCase
        include SharedProviderTests

        def provider_instance = @provider

        setup do
          @repo_path = Dir.mktmpdir
          system("git", "-C", @repo_path, "init", exception: true)
          system("git", "-C", @repo_path, "commit", "--allow-empty", "-m", "init", exception: true)
          @provider = ClaudeCode.new(repo_path: @repo_path)
          @pipeline_run = ArnoldPipeline::PipelineRun.create!(nl_input: "Build a test app")
        end

        teardown do
          FileUtils.remove_entry(@repo_path) if @repo_path && Dir.exist?(@repo_path)
        end

        # --- Shared tests run automatically via include ---

        # --- Contract shape tests ---

        test "create_tasks returns correct shape" do
          tasks = [{ "title" => "Setup project", "description" => "Initialize the project structure" }]
          @provider.stubs(:execute_claude_code).returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          results = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          assert_equal 1, results.size
          result = results.first
          assert result.key?(:external_id)
          assert result.key?(:external_url)
          assert result.key?(:title)
          assert_equal "Setup project", result[:title]
        end

        test "create_tasks title matches input exactly" do
          title = "Implement user authentication with OAuth2"
          tasks = [{ "title" => title, "description" => "Add OAuth2 flow" }]
          @provider.stubs(:execute_claude_code).returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          results = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)
          assert_equal title, results.first[:title]
        end

        test "create_tasks uses task.id for external_ids with AR records" do
          task_a = @pipeline_run.tasks.create!(title: "Task A", description: "First", position: 0)
          task_b = @pipeline_run.tasks.create!(title: "Task B", description: "Second", position: 1)
          @provider.stubs(:execute_claude_code).returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          results = @provider.create_tasks(tasks: [task_a, task_b], pipeline_run: @pipeline_run)

          assert_equal "cc-#{@pipeline_run.id}-#{task_a.id}", results[0][:external_id]
          assert_equal "cc-#{@pipeline_run.id}-#{task_b.id}", results[1][:external_id]
          assert_nil results[0][:external_url]
        end

        test "create_tasks uses random hex for hash-based tasks" do
          tasks = [{ "title" => "Hash Task", "description" => "No DB ID" }]
          @provider.stubs(:execute_claude_code).returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          results = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          assert_match(/\Acc-#{@pipeline_run.id}-[0-9a-f]{8}\z/, results[0][:external_id])
        end

        test "create_tasks branch names are unique across successive calls" do
          task_a = @pipeline_run.tasks.create!(title: "Original", description: "First", position: 0)
          task_b = @pipeline_run.tasks.create!(title: "Corrective", description: "Retry", position: 1)
          @provider.stubs(:execute_claude_code).returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          results1 = @provider.create_tasks(tasks: [task_a], pipeline_run: @pipeline_run)
          results2 = @provider.create_tasks(tasks: [task_b], pipeline_run: @pipeline_run)

          refute_equal results1[0][:external_id], results2[0][:external_id],
            "Successive create_tasks calls must produce unique external_ids"
        end

        test "create_tasks handles ActiveRecord task objects" do
          task = @pipeline_run.tasks.create!(title: "AR Task", description: "From DB", position: 0)
          @provider.stubs(:execute_claude_code).returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          results = @provider.create_tasks(tasks: [task], pipeline_run: @pipeline_run)
          assert_equal "AR Task", results.first[:title]
        end

        test "fetch_results returns correct shape" do
          task = @pipeline_run.tasks.create!(title: "Setup", position: 0, external_id: "cc-1-0")
          @provider.instance_variable_set(:@results, {
            "cc-1-0" => { success: true, diff: "diff --git a/file.rb b/file.rb\n+hello", output: "Done" }
          })

          results = @provider.fetch_results(pipeline_run: @pipeline_run)

          assert_equal 1, results.size
          r = results.first
          assert_equal task.id, r[:task_id]
          assert_equal "cc-1-0", r[:external_id]
          assert_kind_of Array, r[:diffs]
          assert_equal :completed, r[:status]
          assert_equal false, r[:workflow_active]
          assert_equal "claude code execution", r[:workflow_details]
        end

        test "fetch_results skips tasks without external_id" do
          @pipeline_run.tasks.create!(title: "Unpublished", position: 0, external_id: nil)

          results = @provider.fetch_results(pipeline_run: @pipeline_run)
          assert_empty results
        end

        test "fetch_results skips tasks without stored results" do
          @pipeline_run.tasks.create!(title: "Missing", position: 0, external_id: "cc-orphan")

          results = @provider.fetch_results(pipeline_run: @pipeline_run)
          assert_empty results
        end

        test "fetch_results returns :failed for failed tasks" do
          @pipeline_run.tasks.create!(title: "Broken", position: 0, external_id: "cc-1-0")
          @provider.instance_variable_set(:@results, {
            "cc-1-0" => { success: false, diff: "", error: "CLI exited with code 1" }
          })

          results = @provider.fetch_results(pipeline_run: @pipeline_run)
          assert_equal :failed, results.first[:status]
        end

        test "fetch_results scopes to provided tasks array" do
          task1 = @pipeline_run.tasks.create!(title: "Task 1", position: 0, external_id: "cc-1-0")
          task2 = @pipeline_run.tasks.create!(title: "Task 2", position: 1, external_id: "cc-1-1")

          @provider.instance_variable_set(:@results, {
            "cc-1-0" => { success: true, diff: "", output: "Done" },
            "cc-1-1" => { success: true, diff: "", output: "Done" }
          })

          results = @provider.fetch_results(pipeline_run: @pipeline_run, tasks: [task1])
          assert_equal 1, results.size
          assert_equal task1.id, results.first[:task_id]
        end

        test "fetch_results always returns empty comments" do
          @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "cc-1-0")
          @provider.instance_variable_set(:@results, {
            "cc-1-0" => { success: true, diff: "", output: "Done" }
          })

          results = @provider.fetch_results(pipeline_run: @pipeline_run)
          assert_equal [], results.first[:comments]
        end

        test "merge_results returns empty array" do
          assert_equal [], @provider.merge_results(pipeline_run: @pipeline_run)
        end

        # --- Diff parsing tests ---

        test "diffs array elements have correct shape" do
          @pipeline_run.tasks.create!(title: "Add file", position: 0, external_id: "cc-1-0")
          diff_text = <<~DIFF
            diff --git a/app/models/user.rb b/app/models/user.rb
            new file mode 100644
            --- /dev/null
            +++ b/app/models/user.rb
            @@ -0,0 +1,3 @@
            +class User
            +  # model
            +end
          DIFF
          @provider.instance_variable_set(:@results, {
            "cc-1-0" => { success: true, diff: diff_text }
          })

          results = @provider.fetch_results(pipeline_run: @pipeline_run)
          diff_element = results.first[:diffs].first

          assert diff_element.key?(:filename), "Diff element must have :filename key"
          assert diff_element.key?(:patch), "Diff element must have :patch key"
          assert diff_element.key?(:status), "Diff element must have :status key"
          assert_equal "added", diff_element[:status]
        end

        test "parse_diff_to_array handles multiple files" do
          diff_text = <<~DIFF
            diff --git a/file1.rb b/file1.rb
            --- a/file1.rb
            +++ b/file1.rb
            @@ -1 +1 @@
            -old
            +new
            diff --git a/file2.rb b/file2.rb
            new file mode 100644
            --- /dev/null
            +++ b/file2.rb
            @@ -0,0 +1 @@
            +added
          DIFF

          diffs = @provider.send(:parse_diff_to_array, diff_text)
          assert_equal 2, diffs.size
          assert_equal "file1.rb", diffs[0][:filename]
          assert_equal "modified", diffs[0][:status]
          assert_equal "file2.rb", diffs[1][:filename]
          assert_equal "added", diffs[1][:status]
        end

        test "parse_diff_to_array handles deleted files" do
          diff_text = <<~DIFF
            diff --git a/old.rb b/old.rb
            deleted file mode 100644
            --- a/old.rb
            +++ /dev/null
            @@ -1 +0,0 @@
            -removed
          DIFF

          diffs = @provider.send(:parse_diff_to_array, diff_text)
          assert_equal 1, diffs.size
          assert_equal "deleted", diffs.first[:status]
        end

        test "parse_diff_to_array returns empty for blank input" do
          assert_equal [], @provider.send(:parse_diff_to_array, "")
          assert_equal [], @provider.send(:parse_diff_to_array, nil)
        end

        test "diffs serialize to JSON without error" do
          @pipeline_run.tasks.create!(title: "Add file", position: 0, external_id: "cc-1-0")
          @provider.instance_variable_set(:@results, {
            "cc-1-0" => { success: true, diff: "diff --git a/f.rb b/f.rb\n+x" }
          })

          results = @provider.fetch_results(pipeline_run: @pipeline_run)
          assert_nothing_raised { results.first[:diffs].to_json }
        end

        # --- Prompt tests ---

        test "build_prompt includes working directory rules" do
          prompt = @provider.send(:build_prompt,
            title: "Setup Rails",
            description: "Create project",
            labels: ["setup"],
            prior_context: nil
          )

          assert_includes prompt, "Working Directory Rules"
          assert_includes prompt, "do NOT create a project subdirectory"
          assert_includes prompt, "Do NOT run `git init`"
          assert_includes prompt, "rails new . --force"
          assert_includes prompt, "Commit all changes"
        end

        # --- normalize_worktree tests ---

        test "normalize_worktree removes nested .git directories" do
          # Create a real worktree
          branch = "test-normalize-nested"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          system("git", "-C", @repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)

          # Simulate a nested git repo (e.g. from `rails new app_name`)
          nested_dir = File.join(worktree_path, "myapp", ".git")
          FileUtils.mkdir_p(nested_dir)
          File.write(File.join(nested_dir, "HEAD"), "ref: refs/heads/main\n")

          assert File.directory?(nested_dir), "Nested .git dir should exist before normalize"

          @provider.send(:normalize_worktree, worktree_path: worktree_path, title: "Test task")

          refute File.directory?(nested_dir), "Nested .git dir should be removed after normalize"
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", worktree_path) if worktree_path && Dir.exist?(worktree_path)
        end

        test "normalize_worktree commits uncommitted files" do
          branch = "test-normalize-commit"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          system("git", "-C", @repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)

          # Create an uncommitted file in the worktree
          File.write(File.join(worktree_path, "new_file.rb"), "class Foo; end")

          @provider.send(:normalize_worktree, worktree_path: worktree_path, title: "Add Foo")

          # The file should now be visible via capture_diff
          diff = @provider.send(:capture_diff, branch: branch)
          assert_includes diff, "new_file.rb"
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", worktree_path) if worktree_path && Dir.exist?(worktree_path)
        end

        test "normalize_worktree is no-op when changes already committed" do
          branch = "test-normalize-noop"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          system("git", "-C", @repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)

          # Commit a file manually
          File.write(File.join(worktree_path, "existing.rb"), "class Bar; end")
          system("git", "-C", worktree_path, "add", "-A", exception: true)
          system("git", "-C", worktree_path, "commit", "-m", "Already committed", exception: true)

          commit_count_before, = Open3.capture2("git", "-C", worktree_path, "rev-list", "--count", "HEAD")

          @provider.send(:normalize_worktree, worktree_path: worktree_path, title: "No-op")

          commit_count_after, = Open3.capture2("git", "-C", worktree_path, "rev-list", "--count", "HEAD")
          assert_equal commit_count_before.strip, commit_count_after.strip, "No new commit should be created"
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", worktree_path) if worktree_path && Dir.exist?(worktree_path)
        end

        test "create_tasks calls normalize_worktree after execution and before capture_diff" do
          tasks = [{ "title" => "Setup", "description" => "Init project" }]
          call_sequence = sequence("execution_flow")

          @provider.stubs(:setup_worktree).returns(@repo_path)
          @provider.expects(:execute_claude_code).returns({ success: true, output: "Done", error: nil }).in_sequence(call_sequence)
          @provider.expects(:normalize_worktree).in_sequence(call_sequence)
          @provider.expects(:capture_diff).returns("").in_sequence(call_sequence)

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)
        end

        test "create_tasks skips normalize_worktree when execution fails" do
          tasks = [{ "title" => "Broken", "description" => "Will fail" }]
          @provider.stubs(:setup_worktree).returns(@repo_path)
          @provider.stubs(:execute_claude_code).returns({ success: false, output: "", error: "CLI failed" })
          @provider.stubs(:capture_diff).returns("")

          @provider.expects(:normalize_worktree).never

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)
        end

        # --- Configuration tests ---

        test "validate_configuration! raises when repo_path blank" do
          config = ArnoldPipeline::Configuration.new
          config.execution_provider = :claude_code
          config.claude_code_repo_path = nil

          error = assert_raises(ArnoldPipeline::ConfigurationError) do
            ClaudeCode.validate_configuration!(config)
          end
          assert_match(/claude_code_repo_path is required/, error.message)
        end

        test "validate_configuration! raises when repo_path not a directory" do
          config = ArnoldPipeline::Configuration.new
          config.execution_provider = :claude_code
          config.claude_code_repo_path = "/nonexistent/path/to/nowhere"

          error = assert_raises(ArnoldPipeline::ConfigurationError) do
            ClaudeCode.validate_configuration!(config)
          end
          assert_match(/is not a valid directory/, error.message)
        end

        test "validate_configuration! raises when claude CLI not available" do
          config = ArnoldPipeline::Configuration.new
          config.execution_provider = :claude_code
          config.claude_code_repo_path = @repo_path

          ClaudeCode.stubs(:claude_cli_available?).returns(false)

          error = assert_raises(ArnoldPipeline::ConfigurationError) do
            ClaudeCode.validate_configuration!(config)
          end
          assert_match(/claude CLI not found/, error.message)
        end

        test "validate_configuration! passes with valid config" do
          config = ArnoldPipeline::Configuration.new
          config.execution_provider = :claude_code
          config.claude_code_repo_path = @repo_path

          ClaudeCode.stubs(:claude_cli_available?).returns(true)
          assert_nothing_raised { ClaudeCode.validate_configuration!(config) }
        end

        test "build_from_config creates instance from config" do
          config = ArnoldPipeline::Configuration.new
          config.claude_code_repo_path = @repo_path
          config.claude_code_model = "opus"

          provider = ClaudeCode.build_from_config(config)
          assert_kind_of ClaudeCode, provider
          assert_equal @repo_path, provider.repo_path
          assert_equal "opus", provider.model
        end

        test "build_from_config uses defaults when config values nil" do
          config = ArnoldPipeline::Configuration.new
          config.claude_code_repo_path = @repo_path
          config.claude_code_model = nil

          provider = ClaudeCode.build_from_config(config)
          assert_equal "sonnet", provider.model
          assert_equal "bypassPermissions", provider.permission_mode
        end

        test "build_from_config options override config" do
          config = ArnoldPipeline::Configuration.new
          config.claude_code_repo_path = @repo_path
          config.claude_code_model = "sonnet"

          provider = ClaudeCode.build_from_config(config, model: "haiku")
          assert_equal "haiku", provider.model
        end

        test "Execution.build resolves :claude_code" do
          ArnoldPipeline.configure do |c|
            c.execution_provider = :claude_code
            c.claude_code_repo_path = @repo_path
          end

          provider = Execution.build
          assert_kind_of ClaudeCode, provider
        ensure
          ArnoldPipeline.reset_configuration!
        end

        # --- Sync behavior tests ---

        test "async? returns false" do
          assert_equal false, @provider.async?
        end

        test "recoverable_errors includes MergeError" do
          assert_includes @provider.recoverable_errors, ClaudeCode::MergeError
        end

        test "create_tasks with prior_context includes it in prompt" do
          tasks = [{ "title" => "Add API", "description" => "REST endpoints" }]
          context = "## Prior Implementation Context\n\n**Tier 0 completed:** project setup"

          prompt_received = nil
          @provider.stubs(:execute_claude_code).with { |**kwargs|
            prompt_received = kwargs[:prompt]
            true
          }.returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run, prior_context: context)
          assert_includes prompt_received, "Tier 0 completed"
        end

        test "create_tasks without prior_context uses default message" do
          tasks = [{ "title" => "Setup", "description" => "Init" }]

          prompt_received = nil
          @provider.stubs(:execute_claude_code).with { |**kwargs|
            prompt_received = kwargs[:prompt]
            true
          }.returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)
          assert_includes prompt_received, "first tier"
        end

        test "validate_configuration! raises for invalid permission_mode" do
          config = ArnoldPipeline::Configuration.new
          config.execution_provider = :claude_code
          config.claude_code_repo_path = @repo_path
          config.claude_code_permission_mode = "auto"

          ClaudeCode.stubs(:claude_cli_available?).returns(true)

          error = assert_raises(ArnoldPipeline::ConfigurationError) do
            ClaudeCode.validate_configuration!(config)
          end
          assert_match(/Invalid claude_code_permission_mode/, error.message)
        end

        test "validate_configuration! accepts all valid permission modes" do
          config = ArnoldPipeline::Configuration.new
          config.execution_provider = :claude_code
          config.claude_code_repo_path = @repo_path

          ClaudeCode.stubs(:claude_cli_available?).returns(true)

          ClaudeCode::VALID_PERMISSION_MODES.each do |mode|
            config.claude_code_permission_mode = mode
            assert_nothing_raised { ClaudeCode.validate_configuration!(config) }
          end
        end

        # --- Constructor tests ---

        test "constructor sets defaults" do
          provider = ClaudeCode.new(repo_path: @repo_path)
          assert_equal @repo_path, provider.repo_path
          assert_equal "sonnet", provider.model
          assert_nil provider.max_turns
          assert_equal "bypassPermissions", provider.permission_mode
        end

        test "constructor accepts all options" do
          provider = ClaudeCode.new(
            repo_path: @repo_path,
            model: "opus",
            max_turns: 10,
            permission_mode: "default"
          )
          assert_equal "opus", provider.model
          assert_equal 10, provider.max_turns
          assert_equal "default", provider.permission_mode
        end
      end
    end
  end
end
