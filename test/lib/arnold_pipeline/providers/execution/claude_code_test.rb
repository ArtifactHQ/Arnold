require "test_helper"
require "arnold_pipeline/providers/execution/claude_code"
require "arnold_pipeline/library/persona"
require "arnold_pipeline/library/recipe"
require "arnold_pipeline/library/domain_type"
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
          tasks = [ { "title" => "Setup project", "description" => "Initialize the project structure" } ]
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
          tasks = [ { "title" => title, "description" => "Add OAuth2 flow" } ]
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

          results = @provider.create_tasks(tasks: [ task_a, task_b ], pipeline_run: @pipeline_run)

          assert_equal "cc-#{@pipeline_run.id}-#{task_a.id}", results[0][:external_id]
          assert_equal "cc-#{@pipeline_run.id}-#{task_b.id}", results[1][:external_id]
          assert_nil results[0][:external_url]
        end

        test "create_tasks uses random hex for hash-based tasks" do
          tasks = [ { "title" => "Hash Task", "description" => "No DB ID" } ]
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

          results1 = @provider.create_tasks(tasks: [ task_a ], pipeline_run: @pipeline_run)
          results2 = @provider.create_tasks(tasks: [ task_b ], pipeline_run: @pipeline_run)

          refute_equal results1[0][:external_id], results2[0][:external_id],
            "Successive create_tasks calls must produce unique external_ids"
        end

        test "create_tasks handles ActiveRecord task objects" do
          task = @pipeline_run.tasks.create!(title: "AR Task", description: "From DB", position: 0)
          @provider.stubs(:execute_claude_code).returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          results = @provider.create_tasks(tasks: [ task ], pipeline_run: @pipeline_run)
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

          results = @provider.fetch_results(pipeline_run: @pipeline_run, tasks: [ task1 ])
          assert_equal 1, results.size
          assert_equal task1.id, results.first[:task_id]
        end

        test "fetch_results returns empty comments on success" do
          @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "cc-1-0")
          @provider.instance_variable_set(:@results, {
            "cc-1-0" => { success: true, diff: "", output: "Done",
                          parsed: { result: "All done" } }
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

        test "system_prompt includes behavioral instructions" do
          prompt = @provider.send(:system_prompt)
          assert_includes prompt, "automated pipeline"
          assert_includes prompt, "without asking questions"
          assert_includes prompt, "test suite"
          assert_includes prompt, "Commit all changes"
        end

        test "build_prompt contains only task content" do
          prompt = @provider.send(:build_prompt, title: "Setup", description: "Init project", labels: [ "backend" ], prior_context: nil)
          assert_includes prompt, "Setup"
          assert_includes prompt, "Init project"
          assert_includes prompt, "Labels: backend"
          # Should NOT contain behavioral instructions (those are in system_prompt now)
          refute_includes prompt, "Working Directory Rules"
          refute_includes prompt, "git init"
        end

        test "build_prompt includes prior context when provided" do
          prompt = @provider.send(:build_prompt, title: "Auth", description: "Add auth", labels: [], prior_context: "Tier 1 set up the database")
          assert_includes prompt, "Prior Implementation Context"
          assert_includes prompt, "Tier 1 set up the database"
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
          tasks = [ { "title" => "Setup", "description" => "Init project" } ]
          call_sequence = sequence("execution_flow")

          @provider.stubs(:setup_worktree).returns(@repo_path)
          @provider.expects(:execute_claude_code).returns({ success: true, output: "Done", error: nil }).in_sequence(call_sequence)
          @provider.expects(:normalize_worktree).in_sequence(call_sequence)
          @provider.expects(:capture_diff).returns("").in_sequence(call_sequence)

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)
        end

        test "create_tasks skips normalize_worktree when execution fails" do
          tasks = [ { "title" => "Broken", "description" => "Will fail" } ]
          @provider.stubs(:setup_worktree).returns(@repo_path)
          @provider.stubs(:execute_claude_code).returns({ success: false, output: "", error: "CLI failed" })
          @provider.stubs(:capture_diff).returns("")

          @provider.expects(:normalize_worktree).never

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)
        end

        # --- Empty-diff detection tests ---

        test "create_tasks marks successful execution with empty diff as failed" do
          tasks = [ { "title" => "Setup project", "description" => "Initialize" } ]
          @provider.stubs(:execute_claude_code).returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          results = @provider.instance_variable_get(:@results)
          stored = results.values.first
          assert_equal false, stored[:success]
          assert_match(/produced no code changes/, stored[:error])
        end

        test "fetch_results returns :failed for empty-diff task" do
          tasks = [ { "title" => "Setup", "description" => "Init" } ]
          @provider.stubs(:execute_claude_code).returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          created = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)
          ext_id = created.first[:external_id]
          task = @pipeline_run.tasks.create!(title: "Setup", position: 0, external_id: ext_id)

          results = @provider.fetch_results(pipeline_run: @pipeline_run, tasks: [ task ])
          assert_equal :failed, results.first[:status]
        end

        test "create_tasks preserves success when diff is non-empty" do
          tasks = [ { "title" => "Setup project", "description" => "Initialize" } ]
          @provider.stubs(:execute_claude_code).returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("diff --git a/file.rb b/file.rb\n+hello")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          results = @provider.instance_variable_get(:@results)
          stored = results.values.first
          assert_equal true, stored[:success]
          assert_nil stored[:error]
        end

        test "create_tasks preserves original failure when CLI fails" do
          tasks = [ { "title" => "Setup project", "description" => "Initialize" } ]
          @provider.stubs(:execute_claude_code).returns({ success: false, output: "", error: "CLI exited with code 1" })
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          results = @provider.instance_variable_get(:@results)
          stored = results.values.first
          assert_equal false, stored[:success]
          assert_equal "CLI exited with code 1", stored[:error]
        end

        # --- Environment tests ---

        test "execute_claude_code unsets CLAUDECODE env var in child process" do
          branch = "test-env-strip"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          @provider.stubs(:setup_worktree).returns(worktree_path)
          FileUtils.mkdir_p(worktree_path)

          captured_env = nil
          Process.stubs(:spawn).with { |*args|
            captured_env = args.first if args.first.is_a?(Hash)
            true
          }.returns(999)
          Process.stubs(:waitpid2).returns([ 999, stub(success?: true) ])
          IO.stubs(:pipe).returns([ StringIO.new(""), StringIO.new ])

          ENV["CLAUDECODE"] = "1"
          @provider.send(:execute_claude_code, prompt: "test", branch: branch, external_id: "cc-1")

          assert_kind_of Hash, captured_env
          assert captured_env.key?("CLAUDECODE"), "CLAUDECODE key should be present"
          assert_nil captured_env["CLAUDECODE"], "CLAUDECODE should be nil to unset in child"
        ensure
          ENV.delete("CLAUDECODE")
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

        test "validate_configuration! raises when repo_path is not a git repository" do
          non_git_dir = Dir.mktmpdir
          config = ArnoldPipeline::Configuration.new
          config.execution_provider = :claude_code
          config.claude_code_repo_path = non_git_dir

          error = assert_raises(ArnoldPipeline::ConfigurationError) do
            ClaudeCode.validate_configuration!(config)
          end
          assert_match(/is not a git repository/, error.message)
        ensure
          FileUtils.remove_entry(non_git_dir) if non_git_dir && Dir.exist?(non_git_dir)
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

        test "build_from_config respects nil max_turns for unlimited" do
          config = ArnoldPipeline::Configuration.new
          config.claude_code_repo_path = @repo_path
          config.claude_code_max_turns = nil

          provider = ClaudeCode.build_from_config(config)
          assert_nil provider.max_turns
        end

        test "build_from_config respects nil max_budget_usd" do
          config = ArnoldPipeline::Configuration.new
          config.claude_code_repo_path = @repo_path
          config.claude_code_max_budget_usd = nil

          provider = ClaudeCode.build_from_config(config)
          assert_nil provider.max_budget_usd
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

        test "merge_branch uses --no-edit flag" do
          branch = "test-merge-no-edit"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          system("git", "-C", @repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)

          # Add a commit on the branch so there's something to merge
          File.write(File.join(worktree_path, "merged.rb"), "class Merged; end")
          system("git", "-C", worktree_path, "add", "-A", exception: true)
          system("git", "-C", worktree_path, "commit", "-m", "Add merged.rb", exception: true)

          # merge_branch should complete without opening an editor
          @provider.send(:merge_branch, branch)

          # Verify it created a merge commit (--no-ff always creates one)
          log_output, = Open3.capture2("git", "-C", @repo_path, "log", "--oneline", "-1")
          assert_match(/Merge branch/, log_output)
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", worktree_path) if worktree_path && Dir.exist?(worktree_path)
        end

        test "recoverable_errors includes MergeError" do
          assert_includes @provider.recoverable_errors, ClaudeCode::MergeError
        end

        test "create_tasks with prior_context includes it in prompt" do
          tasks = [ { "title" => "Add API", "description" => "REST endpoints" } ]
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
          tasks = [ { "title" => "Setup", "description" => "Init" } ]

          prompt_received = nil
          @provider.stubs(:execute_claude_code).with { |**kwargs|
            prompt_received = kwargs[:prompt]
            true
          }.returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)
          assert_includes prompt_received, "first implementation tier"
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

        # --- Concurrency tests ---

        test "create_tasks executes multiple tasks concurrently" do
          ArnoldPipeline.configure { |c| c.claude_code_max_concurrency = 4 }

          tasks = 3.times.map { |i| { "title" => "Task #{i}", "description" => "Desc #{i}" } }
          mu = Mutex.new
          thread_ids = []

          @provider.stubs(:execute_claude_code).with { |**_kwargs|
            mu.synchronize { thread_ids << Thread.current.object_id }
            sleep 0.05
            true
          }.returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("diff --git a/f.rb b/f.rb\n+x")

          results = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          assert_equal 3, results.size
          assert thread_ids.uniq.size > 1, "Expected multiple threads, got #{thread_ids.uniq.size}"
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "create_tasks with concurrency 1 stays sequential" do
          ArnoldPipeline.configure { |c| c.claude_code_max_concurrency = 1 }

          tasks = 2.times.map { |i| { "title" => "Task #{i}", "description" => "Desc #{i}" } }
          thread_ids = []

          @provider.stubs(:execute_claude_code).with { |**_kwargs|
            thread_ids << Thread.current.object_id
            true
          }.returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("diff --git a/f.rb b/f.rb\n+x")

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          assert_equal 1, thread_ids.uniq.size, "Expected single thread for concurrency=1"
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "create_tasks stores results correctly under concurrent execution" do
          ArnoldPipeline.configure { |c| c.claude_code_max_concurrency = 4 }

          tasks = 5.times.map { |i|
            @pipeline_run.tasks.create!(title: "Task #{i}", description: "Desc #{i}", position: i)
          }

          @provider.stubs(:execute_claude_code).returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("diff --git a/f.rb b/f.rb\n+x")

          results = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          assert_equal 5, results.size
          stored = @provider.instance_variable_get(:@results)
          assert_equal 5, stored.size

          # Verify ordering: results[i] corresponds to tasks[i]
          results.each_with_index do |r, i|
            assert_equal "Task #{i}", r[:title]
            assert_match(/cc-#{@pipeline_run.id}-#{tasks[i].id}/, r[:external_id])
          end
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "create_tasks handles per-thread failures gracefully" do
          ArnoldPipeline.configure { |c| c.claude_code_max_concurrency = 3 }

          tasks = 3.times.map { |i| { "title" => "Task #{i}", "description" => "Desc #{i}" } }
          mu = Mutex.new
          call_count = 0

          @provider.stubs(:execute_claude_code).with { |**_kwargs|
            mu.synchronize { call_count += 1 }
            true
          }.returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("diff --git a/f.rb b/f.rb\n+x")

          results = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          assert_equal 3, results.size
          assert_equal 3, call_count
          results.each do |r|
            assert r.key?(:external_id)
            assert r.key?(:title)
          end
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "create_tasks with single task skips thread pool" do
          tasks = [ { "title" => "Solo Task", "description" => "Only one" } ]

          @provider.stubs(:execute_claude_code).returns({ success: true, output: "Done", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("diff --git a/f.rb b/f.rb\n+x")

          @provider.expects(:execute_parallel).never

          results = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)
          assert_equal 1, results.size
        end

        test "claude_code_max_concurrency defaults to 4" do
          config = ArnoldPipeline::Configuration.new
          assert_equal 4, config.claude_code_max_concurrency
        end

        test "validate_configuration! rejects invalid concurrency values" do
          config = ArnoldPipeline::Configuration.new
          config.execution_provider = :claude_code
          config.claude_code_repo_path = @repo_path
          ClaudeCode.stubs(:claude_cli_available?).returns(true)

          [ 0, -1, 17, 1.5, "4" ].each do |bad_value|
            config.claude_code_max_concurrency = bad_value
            error = assert_raises(ArnoldPipeline::ConfigurationError) do
              ClaudeCode.validate_configuration!(config)
            end
            assert_match(/claude_code_max_concurrency/, error.message)
          end
        end

        test "validate_configuration! accepts valid concurrency values" do
          config = ArnoldPipeline::Configuration.new
          config.execution_provider = :claude_code
          config.claude_code_repo_path = @repo_path
          ClaudeCode.stubs(:claude_cli_available?).returns(true)

          [ 1, 4, 8, 16, nil ].each do |good_value|
            config.claude_code_max_concurrency = good_value
            assert_nothing_raised { ClaudeCode.validate_configuration!(config) }
          end
        end

        # --- Constructor tests ---

        test "constructor sets defaults" do
          provider = ClaudeCode.new(repo_path: @repo_path)
          assert_equal @repo_path, provider.repo_path
          assert_equal "sonnet", provider.model
          assert_equal 25, provider.max_turns
          assert_equal "bypassPermissions", provider.permission_mode
          assert_nil provider.max_budget_usd
        end

        test "constructor accepts all options" do
          provider = ClaudeCode.new(
            repo_path: @repo_path,
            model: "opus",
            max_turns: 10,
            permission_mode: "default",
            max_budget_usd: 5.0
          )
          assert_equal "opus", provider.model
          assert_equal 10, provider.max_turns
          assert_equal "default", provider.permission_mode
          assert_equal 5.0, provider.max_budget_usd
        end

        # --- Tool restriction flags tests ---

        test "tool_restriction_flags returns empty when all nil" do
          assert_equal [], @provider.send(:tool_restriction_flags)
        end

        test "tool_restriction_flags includes --tools when configured" do
          ArnoldPipeline.configure { |c| c.claude_code_tools = [ "Bash", "Edit", "Read" ] }
          flags = @provider.send(:tool_restriction_flags)
          assert_includes flags, "--tools"
          assert_includes flags, "Bash,Edit,Read"
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "tool_restriction_flags includes --allowedTools for each pattern" do
          ArnoldPipeline.configure { |c| c.claude_code_allowed_tools = [ "Bash(git *)", "Read" ] }
          flags = @provider.send(:tool_restriction_flags)
          assert_equal [ "--allowedTools", "Bash(git *)", "--allowedTools", "Read" ], flags
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "tool_restriction_flags includes --disallowedTools for each pattern" do
          ArnoldPipeline.configure { |c| c.claude_code_disallowed_tools = [ "WebSearch" ] }
          flags = @provider.send(:tool_restriction_flags)
          assert_equal [ "--disallowedTools", "WebSearch" ], flags
        ensure
          ArnoldPipeline.reset_configuration!
        end

        # --- build_cli_command tests ---

        test "build_cli_command includes --append-system-prompt" do
          cmd = @provider.send(:build_cli_command, "test prompt")
          assert_includes cmd, "--append-system-prompt"
        end

        test "build_cli_command includes --max-budget-usd when configured" do
          provider = ArnoldPipeline::Providers::Execution::ClaudeCode.new(repo_path: @repo_path, max_budget_usd: 5.0)
          cmd = provider.send(:build_cli_command, "test prompt")
          assert_includes cmd, "--max-budget-usd"
          assert_includes cmd, "5.0"
        end

        test "build_cli_command omits --max-budget-usd when nil" do
          cmd = @provider.send(:build_cli_command, "test prompt")
          refute_includes cmd, "--max-budget-usd"
        end

        test "build_cli_command includes max_turns by default (25)" do
          provider = ArnoldPipeline::Providers::Execution::ClaudeCode.new(repo_path: @repo_path)
          cmd = provider.send(:build_cli_command, "test prompt")
          assert_includes cmd, "--max-turns"
          assert_includes cmd, "25"
        end

        # --- Worktree hygiene tests ---

        test "normalize_worktree excludes tmp/ from staging" do
          branch = "test-normalize-exclude-tmp"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          system("git", "-C", @repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)

          # ensure_gitignore! runs before normalize_worktree in production
          File.write(File.join(worktree_path, ".gitignore"), "tmp/\n")

          # Create a file in tmp/ that should be excluded
          FileUtils.mkdir_p(File.join(worktree_path, "tmp", "cache", "bootsnap"))
          File.write(File.join(worktree_path, "tmp", "cache", "bootsnap", "compiled.bin"), "binary data")

          # Also create a normal file that should be staged
          File.write(File.join(worktree_path, "app.rb"), "class App; end")

          @provider.send(:normalize_worktree, worktree_path: worktree_path, title: "Test exclusions")

          diff = @provider.send(:capture_diff, branch: branch)
          assert_includes diff, "app.rb"
          refute_includes diff, "bootsnap"
          refute_includes diff, "compiled.bin"
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", worktree_path) if worktree_path && Dir.exist?(worktree_path)
        end

        test "normalize_worktree excludes log/ from staging" do
          branch = "test-normalize-exclude-log"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          system("git", "-C", @repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)

          # ensure_gitignore! runs before normalize_worktree in production
          File.write(File.join(worktree_path, ".gitignore"), "log/\n")

          FileUtils.mkdir_p(File.join(worktree_path, "log"))
          File.write(File.join(worktree_path, "log", "development.log"), "log line")
          File.write(File.join(worktree_path, "app.rb"), "class App; end")

          @provider.send(:normalize_worktree, worktree_path: worktree_path, title: "Test log exclusion")

          diff = @provider.send(:capture_diff, branch: branch)
          assert_includes diff, "app.rb"
          refute_includes diff, "development.log"
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", worktree_path) if worktree_path && Dir.exist?(worktree_path)
        end

        test "normalize_worktree excludes node_modules/ from staging" do
          branch = "test-normalize-exclude-node"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          system("git", "-C", @repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)

          # ensure_gitignore! runs before normalize_worktree in production
          File.write(File.join(worktree_path, ".gitignore"), "node_modules/\n")

          FileUtils.mkdir_p(File.join(worktree_path, "node_modules", "express"))
          File.write(File.join(worktree_path, "node_modules", "express", "index.js"), "module.exports = {}")
          File.write(File.join(worktree_path, "index.js"), "console.log('hello')")

          @provider.send(:normalize_worktree, worktree_path: worktree_path, title: "Test node exclusion")

          diff = @provider.send(:capture_diff, branch: branch)
          assert_includes diff, "index.js"
          refute_includes diff, "node_modules/express"
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", worktree_path) if worktree_path && Dir.exist?(worktree_path)
        end

        test "normalize_worktree handles repos with existing .gitignore gracefully" do
          branch = "test-normalize-existing-gitignore"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          system("git", "-C", @repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)

          # Simulate a Rails repo's .gitignore that already excludes log/ and tmp/
          File.write(File.join(worktree_path, ".gitignore"), "log/\ntmp/\n")

          # Create files only in gitignored directories (the trigger scenario)
          FileUtils.mkdir_p(File.join(worktree_path, "log"))
          FileUtils.mkdir_p(File.join(worktree_path, "tmp"))
          File.write(File.join(worktree_path, "log", "development.log"), "log data")
          File.write(File.join(worktree_path, "tmp", "cache.bin"), "cache data")

          # Should NOT raise — this is the bug fix
          @provider.send(:normalize_worktree, worktree_path: worktree_path, title: "Handle gitignore")

          # Verify no commit was made for the title (only gitignored files changed, plus .gitignore itself)
          log_output, = Open3.capture2("git", "-C", worktree_path, "log", "--oneline")
          # The .gitignore change will be committed, but the ignored files won't be
          diff = @provider.send(:capture_diff, branch: branch)
          refute_includes diff, "development.log"
          refute_includes diff, "cache.bin"
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", worktree_path) if worktree_path && Dir.exist?(worktree_path)
        end

        test "normalize_worktree stages non-ignored files when repo has .gitignore" do
          branch = "test-normalize-mixed-gitignore"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          system("git", "-C", @repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)

          File.write(File.join(worktree_path, ".gitignore"), "log/\ntmp/\n")
          FileUtils.mkdir_p(File.join(worktree_path, "log"))
          File.write(File.join(worktree_path, "log", "dev.log"), "log")
          File.write(File.join(worktree_path, "app.rb"), "class App; end")

          @provider.send(:normalize_worktree, worktree_path: worktree_path, title: "Mixed files")

          diff = @provider.send(:capture_diff, branch: branch)
          assert_includes diff, "app.rb"
          refute_includes diff, "dev.log"
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", worktree_path) if worktree_path && Dir.exist?(worktree_path)
        end

        # --- ensure_initial_commit! tests ---

        test "ensure_initial_commit! is a no-op when repo already has commits" do
          # setup already creates an initial commit
          head_before, = Open3.capture2("git", "-C", @repo_path, "rev-parse", "HEAD")

          @provider.send(:ensure_initial_commit!)

          head_after, = Open3.capture2("git", "-C", @repo_path, "rev-parse", "HEAD")
          assert_equal head_before.strip, head_after.strip, "HEAD should not change when commits already exist"
        end

        test "ensure_initial_commit! creates initial commit on empty repo" do
          empty_repo = Dir.mktmpdir
          system("git", "-C", empty_repo, "init", exception: true)
          provider = ClaudeCode.new(repo_path: empty_repo)

          # Verify HEAD is invalid before
          _, status = Open3.capture2("git", "-C", empty_repo, "rev-parse", "HEAD")
          refute status.success?, "Empty repo should not have a valid HEAD"

          provider.send(:ensure_initial_commit!)

          # Now HEAD should be valid
          _, status = Open3.capture2("git", "-C", empty_repo, "rev-parse", "HEAD")
          assert status.success?, "HEAD should be valid after ensure_initial_commit!"

          # And the commit message should be identifiable
          msg, = Open3.capture2("git", "-C", empty_repo, "log", "--format=%s", "-1")
          assert_equal "Initial commit (arnold pipeline)", msg.strip
        ensure
          FileUtils.remove_entry(empty_repo) if empty_repo && Dir.exist?(empty_repo)
        end

        test "ensure_initial_commit! enables worktree and diff on fresh repo" do
          empty_repo = Dir.mktmpdir
          system("git", "-C", empty_repo, "init", exception: true)
          provider = ClaudeCode.new(repo_path: empty_repo)

          provider.send(:ensure_initial_commit!)

          # Worktree creation should now work
          branch = "test-fresh-worktree"
          worktree_path = File.join(empty_repo, ".worktrees", branch)
          system("git", "-C", empty_repo, "worktree", "add", "-B", branch, worktree_path, exception: true)

          # Add a file in the worktree
          File.write(File.join(worktree_path, "hello.rb"), "puts 'hello'\n")
          system("git", "-C", worktree_path, "add", "-A", ".", exception: true)
          system("git", "-C", worktree_path, "commit", "-m", "Add hello", exception: true)

          # diff HEAD...branch should return content
          diff, = Open3.capture2("git", "-C", empty_repo, "diff", "HEAD...#{branch}")
          assert_includes diff, "hello.rb", "diff should detect changes on worktree branch"

          # merge should succeed
          _, status = Open3.capture2e("git", "-C", empty_repo, "merge", "--no-ff", "--no-edit", branch)
          assert status.success?, "merge into main should succeed after initial commit"
        ensure
          system("git", "-C", empty_repo, "worktree", "remove", "--force", worktree_path) if worktree_path && Dir.exist?(worktree_path)
          FileUtils.remove_entry(empty_repo) if empty_repo && Dir.exist?(empty_repo)
        end

        test "setup_worktree creates .gitignore when missing" do
          branch = "test-gitignore-creation"
          worktree_path = @provider.send(:setup_worktree, branch)

          gitignore = File.join(worktree_path, ".gitignore")
          assert File.exist?(gitignore), ".gitignore should be created in worktree"

          content = File.read(gitignore)
          assert_includes content, "tmp/"
          assert_includes content, "log/"
          assert_includes content, "node_modules/"
          assert_includes content, "vendor/bundle/"
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", worktree_path) if worktree_path && Dir.exist?(worktree_path)
        end

        test "setup_worktree preserves existing .gitignore" do
          # First, create a .gitignore on main branch
          File.write(File.join(@repo_path, ".gitignore"), "*.secret\n")
          system("git", "-C", @repo_path, "add", ".gitignore", exception: true)
          system("git", "-C", @repo_path, "commit", "-m", "Add gitignore", exception: true)

          branch = "test-gitignore-preserved"
          worktree_path = @provider.send(:setup_worktree, branch)

          content = File.read(File.join(worktree_path, ".gitignore"))
          assert_equal "*.secret\n", content, "Existing .gitignore should not be overwritten"
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", worktree_path) if worktree_path && Dir.exist?(worktree_path)
        end

        test "setup_worktree recovers from stale branch left by crashed run" do
          branch = "test-stale-branch"
          # Create a worktree + branch, then remove just the worktree dir (simulating a crash)
          worktree_path = @provider.send(:setup_worktree, branch)
          system("git", "-C", @repo_path, "worktree", "remove", "--force", worktree_path)
          # Branch still exists but worktree is gone — this is the crash state
          branches, = Open3.capture2("git", "-C", @repo_path, "branch", "--list", branch)
          assert_includes branches, branch, "Stale branch should still exist"

          # setup_worktree should succeed despite the stale branch (uses -B)
          new_worktree_path = @provider.send(:setup_worktree, branch)
          assert Dir.exist?(new_worktree_path), "Worktree should be recreated"
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", "--force", new_worktree_path) if new_worktree_path && Dir.exist?(new_worktree_path)
        end

        test "cleanup_worktree removes dirty worktrees with --force" do
          branch = "test-dirty-cleanup"
          worktree_path = @provider.send(:setup_worktree, branch)
          # Create an untracked file to make the worktree dirty
          File.write(File.join(worktree_path, "dirty_file.txt"), "uncommitted content")

          # cleanup should succeed despite dirty worktree
          @provider.send(:cleanup_worktree, branch)
          refute Dir.exist?(worktree_path), "Dirty worktree should be force-removed"
        end

        # --- JSON output parsing tests ---

        test "parse_claude_output extracts fields from valid JSON" do
          json = {
            "result" => "Task completed successfully",
            "total_cost_usd" => 0.034,
            "duration_ms" => 28470,
            "num_turns" => 12,
            "session_id" => "abc-123",
            "is_error" => false,
            "subtype" => "success"
          }.to_json

          parsed = @provider.send(:parse_claude_output, json)

          assert_equal "Task completed successfully", parsed[:result]
          assert_equal 0.034, parsed[:cost_usd]
          assert_equal 28470, parsed[:duration_ms]
          assert_equal 12, parsed[:num_turns]
          assert_equal "abc-123", parsed[:session_id]
          assert_equal false, parsed[:is_error]
        end

        test "parse_claude_output handles invalid JSON gracefully" do
          parsed = @provider.send(:parse_claude_output, "not json at all")

          assert_equal "not json at all", parsed[:result]
          assert_nil parsed[:cost_usd]
          assert_nil parsed[:duration_ms]
          assert_nil parsed[:num_turns]
        end

        test "parse_claude_output handles empty string" do
          parsed = @provider.send(:parse_claude_output, "")
          assert_equal "", parsed[:result]
        end

        # --- Execution metadata in fetch_results ---

        test "fetch_results populates execution_metadata from parsed output" do
          task = @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "cc-1-0")
          @provider.instance_variable_set(:@results, {
            "cc-1-0" => {
              success: true, diff: "diff --git a/f.rb b/f.rb\n+x", output: "Done",
              parsed: { cost_usd: 0.034, duration_ms: 28470, num_turns: 12, session_id: "abc" }
            }
          })

          results = @provider.fetch_results(pipeline_run: @pipeline_run)
          meta = results.first[:execution_metadata]

          assert_kind_of Hash, meta
          assert_equal 0.034, meta["cost_usd"]
          assert_equal 28470, meta["duration_ms"]
          assert_equal 12, meta["num_turns"]
        end

        test "fetch_results returns empty execution_metadata when no parsed data" do
          task = @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "cc-1-0")
          @provider.instance_variable_set(:@results, {
            "cc-1-0" => { success: true, diff: "", output: "Done" }
          })

          results = @provider.fetch_results(pipeline_run: @pipeline_run)
          meta = results.first[:execution_metadata]

          assert_kind_of Hash, meta
        end

        # --- Failure comments ---

        test "fetch_results includes failure comment with Claude's message on failure" do
          task = @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "cc-1-0")
          @provider.instance_variable_set(:@results, {
            "cc-1-0" => {
              success: false, diff: "", error: "CLI exited with code 1",
              parsed: { result: "I couldn't complete this because the database wasn't configured" }
            }
          })

          results = @provider.fetch_results(pipeline_run: @pipeline_run)
          comments = results.first[:comments]

          assert_equal 1, comments.size
          assert_equal "claude_code", comments.first["source"]
          assert_equal "claude", comments.first["author"]
          assert_includes comments.first["body"], "database wasn't configured"
        end

        test "fetch_results returns empty comments for successful task with parsed data" do
          task = @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "cc-1-0")
          @provider.instance_variable_set(:@results, {
            "cc-1-0" => {
              success: true, diff: "diff --git a/f.rb b/f.rb\n+x", output: "Done",
              parsed: { result: "All done" }
            }
          })

          results = @provider.fetch_results(pipeline_run: @pipeline_run)
          assert_equal [], results.first[:comments]
        end

        test "fetch_results truncates long failure comments" do
          task = @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "cc-1-0")
          long_message = "x" * 5000
          @provider.instance_variable_set(:@results, {
            "cc-1-0" => {
              success: false, diff: "", error: "CLI exited with code 1",
              parsed: { result: long_message }
            }
          })

          results = @provider.fetch_results(pipeline_run: @pipeline_run)
          body = results.first[:comments].first["body"]
          assert body.length < 3100, "Failure comment should be truncated"
          assert_includes body, "(truncated)"
        end

        test "execute_work_item marks task failed when is_error is true despite exit 0" do
          @provider.stubs(:execute_claude_code).returns({ success: true, output: { "result" => "Hit max turns", "is_error" => true, "subtype" => "max_turns", "total_cost_usd" => 0.5, "duration_ms" => 1000, "num_turns" => 25, "session_id" => "s1" }.to_json, error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("diff --git a/f.rb b/f.rb\n+x")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          item = { prompt: "do stuff", branch_name: "test-branch", external_id: "cc-1-0", title: "Task", index: 0 }
          @provider.send(:execute_work_item, item)

          stored = @provider.instance_variable_get(:@results)["cc-1-0"]
          refute stored[:success], "Task should be marked failed when is_error is true"
          assert_includes stored[:error], "Claude reported error"
        end

        # --- CLAUDE.md generation tests ---

        test "create_tasks resolves library_selections from pipeline_run metadata" do
          @pipeline_run.update!(metadata: {
            "library_selections" => {
              "persona" => "Software Architect",
              "recipe" => "Web App",
              "domain_type" => "GAME"
            }
          })

          tasks = [ { "title" => "Setup", "description" => "Init" } ]
          @provider.stubs(:execute_claude_code).returns({ success: true, output: "{}", error: nil })
          @provider.stubs(:normalize_worktree)
          @provider.stubs(:capture_diff).returns("diff --git a/f.rb b/f.rb\n+x")
          @provider.stubs(:setup_worktree).returns(@repo_path)

          @provider.create_tasks(tasks: tasks, pipeline_run: @pipeline_run)

          selections = @provider.instance_variable_get(:@library_selections)
          assert_not_nil selections
          assert_not_nil selections[:recipe]
          assert_equal "Web App", selections[:recipe].name
        end

        test "write_claude_md! writes CLAUDE.md when repo has none" do
          @provider.instance_variable_set(:@library_selections, {
            persona: ArnoldPipeline::Library::Persona.new(
              name: "SA", role: "sa", keywords: [], description: "d", system_prompt: "sp"
            ),
            recipe: ArnoldPipeline::Library::Recipe.new(
              name: "Web App", type: "web_app", keywords: [], description: "d",
              framework: { "primary" => "Rails 8+" }, sections: [], verification: {}
            ),
            domain_type: ArnoldPipeline::Library::DomainType.new(
              code: "GAME", name: "Game", keywords: [], description: "d",
              primary_value: "Fun", emphasis: [], document_focus: [], watch_for: [], terminology: {}
            )
          })

          worktree_path = Dir.mktmpdir
          @provider.send(:write_claude_md!, worktree_path)

          claude_md_path = File.join(worktree_path, "CLAUDE.md")
          assert File.exist?(claude_md_path)
          content = File.read(claude_md_path)
          assert_includes content, "Rails 8+"
        ensure
          FileUtils.remove_entry(worktree_path)
        end

        test "write_claude_md! writes to .claude/CLAUDE.md when repo has existing CLAUDE.md" do
          @provider.instance_variable_set(:@library_selections, {
            persona: nil,
            recipe: ArnoldPipeline::Library::Recipe.new(
              name: "Web App", type: "web_app", keywords: [], description: "d",
              framework: { "primary" => "Rails 8+" }, sections: [], verification: {}
            ),
            domain_type: nil
          })

          worktree_path = Dir.mktmpdir
          File.write(File.join(worktree_path, "CLAUDE.md"), "# Existing project instructions")

          @provider.send(:write_claude_md!, worktree_path)

          # Original untouched
          assert_equal "# Existing project instructions", File.read(File.join(worktree_path, "CLAUDE.md"))
          # Generated in subdirectory
          generated = File.join(worktree_path, ".claude", "CLAUDE.md")
          assert File.exist?(generated)
          assert_includes File.read(generated), "Rails 8+"
        ensure
          FileUtils.remove_entry(worktree_path)
        end

        test "write_claude_md! is no-op when library_selections is nil" do
          @provider.instance_variable_set(:@library_selections, nil)

          worktree_path = Dir.mktmpdir
          @provider.send(:write_claude_md!, worktree_path)

          refute File.exist?(File.join(worktree_path, "CLAUDE.md"))
          refute File.exist?(File.join(worktree_path, ".claude", "CLAUDE.md"))
        ensure
          FileUtils.remove_entry(worktree_path)
        end

        test "write_claude_md! passes worktree_path to ClaudeMdGenerator for project state" do
          @provider.instance_variable_set(:@library_selections, {
            persona: ArnoldPipeline::Library::Persona.new(
              name: "SA", role: "sa", keywords: [], description: "d", system_prompt: "sp"
            ),
            recipe: ArnoldPipeline::Library::Recipe.new(
              name: "Web App", type: "web_app", keywords: [], description: "d",
              framework: { "primary" => "Rails 8+" }, sections: [], verification: {}
            ),
            domain_type: nil
          })

          worktree_path = Dir.mktmpdir
          FileUtils.mkdir_p(File.join(worktree_path, "config"))
          File.write(File.join(worktree_path, "config", "routes.rb"), "Rails.application.routes.draw do\n  root 'home#index'\nend")

          @provider.send(:write_claude_md!, worktree_path)

          claude_md_path = File.join(worktree_path, "CLAUDE.md")
          assert File.exist?(claude_md_path), "CLAUDE.md should exist"
          content = File.read(claude_md_path)
          assert_includes content, "Current Routes"
          assert_includes content, "root 'home#index'"
        ensure
          FileUtils.remove_entry(worktree_path) if worktree_path
        end

        # --- Merge conflict resolution tests ---

        # Helper: create a conflict scenario.
        # Creates branch_a and branch_b that both modify the same file.
        # Merges branch_a into main, leaving branch_b ready to conflict.
        def create_conflict_scenario(file: "routes.rb", content_a: "get '/leads'\n", content_b: "root 'landing#index'\n")
          # Create a base file and commit
          File.write(File.join(@repo_path, file), "# Routes\n")
          system("git", "-C", @repo_path, "add", file, exception: true)
          system("git", "-C", @repo_path, "commit", "-m", "Add base #{file}", exception: true)

          # Branch A: modify the file
          system("git", "-C", @repo_path, "checkout", "-b", "branch-a", exception: true)
          File.write(File.join(@repo_path, file), "# Routes\n#{content_a}")
          system("git", "-C", @repo_path, "add", file, exception: true)
          system("git", "-C", @repo_path, "commit", "-m", "Branch A changes", exception: true)

          # Back to main, merge branch A
          system("git", "-C", @repo_path, "checkout", "-", exception: true)
          system("git", "-C", @repo_path, "merge", "--no-ff", "--no-edit", "branch-a", exception: true)

          # Branch B from pre-merge main (the parent of the merge commit)
          base_sha, = Open3.capture2("git", "-C", @repo_path, "rev-parse", "HEAD~1")
          system("git", "-C", @repo_path, "branch", "branch-b", base_sha.strip, exception: true)
          system("git", "-C", @repo_path, "checkout", "branch-b", exception: true)
          File.write(File.join(@repo_path, file), "# Routes\n#{content_b}")
          system("git", "-C", @repo_path, "add", file, exception: true)
          system("git", "-C", @repo_path, "commit", "-m", "Branch B changes", exception: true)

          # Back to main — merging branch-b will conflict
          system("git", "-C", @repo_path, "checkout", "-", exception: true)

          "branch-b"
        end

        test "merge_branch detects conflict and resolves via Claude CLI" do
          ArnoldPipeline.configure { |c| c.merge_conflict_resolution_enabled = true }

          branch = create_conflict_scenario
          task = @pipeline_run.tasks.create!(title: "Landing page", description: "Add landing page routes", position: 0)

          # Write a resolver script that the CLI command will execute
          resolve_script_path = File.join(@repo_path, "_resolve.rb")
          routes_path = File.join(@repo_path, "routes.rb")
          File.write(resolve_script_path, <<~RUBY)
            File.write(#{routes_path.inspect}, "# Routes\\nget '/leads'\\nroot 'landing#index'\\n")
          RUBY

          @provider.stubs(:build_cli_command).returns("ruby #{resolve_script_path.shellescape}")

          @provider.send(:merge_branch, branch, task: task)

          # Verify both changes are present
          content = File.read(routes_path)
          assert_includes content, "get '/leads'"
          assert_includes content, "root 'landing#index'"

          # Verify no conflict markers remain
          refute_includes content, "<<<<<<<"
          refute_includes content, ">>>>>>>"
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "merge_branch raises MergeError when resolution is disabled" do
          ArnoldPipeline.configure { |c| c.merge_conflict_resolution_enabled = false }

          branch = create_conflict_scenario
          task = @pipeline_run.tasks.create!(title: "Landing page", description: "Add routes", position: 0)

          error = assert_raises(ClaudeCode::MergeError) do
            @provider.send(:merge_branch, branch, task: task)
          end
          assert_match(/Failed to merge branch/, error.message)

          # Verify merge was aborted (no MERGE_HEAD left)
          merge_head = File.join(@repo_path, ".git", "MERGE_HEAD")
          refute File.exist?(merge_head), "MERGE_HEAD should be cleaned up after abort"
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "merge_branch raises MergeError when too many conflicted files" do
          ArnoldPipeline.configure do |c|
            c.merge_conflict_resolution_enabled = true
            c.merge_conflict_max_files = 1
          end

          # Create conflicts in two files
          File.write(File.join(@repo_path, "file1.rb"), "base1\n")
          File.write(File.join(@repo_path, "file2.rb"), "base2\n")
          system("git", "-C", @repo_path, "add", ".", exception: true)
          system("git", "-C", @repo_path, "commit", "-m", "Add base files", exception: true)

          # Branch A
          system("git", "-C", @repo_path, "checkout", "-b", "branch-a2", exception: true)
          File.write(File.join(@repo_path, "file1.rb"), "branch-a-change1\n")
          File.write(File.join(@repo_path, "file2.rb"), "branch-a-change2\n")
          system("git", "-C", @repo_path, "add", ".", exception: true)
          system("git", "-C", @repo_path, "commit", "-m", "A changes", exception: true)

          system("git", "-C", @repo_path, "checkout", "-", exception: true)
          system("git", "-C", @repo_path, "merge", "--no-ff", "--no-edit", "branch-a2", exception: true)

          # Branch B from pre-merge
          base_sha, = Open3.capture2("git", "-C", @repo_path, "rev-parse", "HEAD~1")
          system("git", "-C", @repo_path, "branch", "branch-b2", base_sha.strip, exception: true)
          system("git", "-C", @repo_path, "checkout", "branch-b2", exception: true)
          File.write(File.join(@repo_path, "file1.rb"), "branch-b-change1\n")
          File.write(File.join(@repo_path, "file2.rb"), "branch-b-change2\n")
          system("git", "-C", @repo_path, "add", ".", exception: true)
          system("git", "-C", @repo_path, "commit", "-m", "B changes", exception: true)

          system("git", "-C", @repo_path, "checkout", "-", exception: true)

          task = @pipeline_run.tasks.create!(title: "Task", description: "Desc", position: 0)

          error = assert_raises(ClaudeCode::MergeError) do
            @provider.send(:merge_branch, "branch-b2", task: task)
          end
          assert_match(/Too many conflicted files/, error.message)

          merge_head = File.join(@repo_path, ".git", "MERGE_HEAD")
          refute File.exist?(merge_head), "MERGE_HEAD should be cleaned up"
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "merge_branch raises MergeError when CLI fails" do
          ArnoldPipeline.configure { |c| c.merge_conflict_resolution_enabled = true }

          branch = create_conflict_scenario
          task = @pipeline_run.tasks.create!(title: "Task", description: "Desc", position: 0)

          @provider.stubs(:build_cli_command).returns("false") # exits with code 1

          error = assert_raises(ClaudeCode::MergeError) do
            @provider.send(:merge_branch, branch, task: task)
          end
          assert_match(/Claude CLI failed to resolve/, error.message)

          merge_head = File.join(@repo_path, ".git", "MERGE_HEAD")
          refute File.exist?(merge_head), "MERGE_HEAD should be cleaned up after CLI failure"
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "merge_branch raises MergeError when conflict markers remain after resolution" do
          ArnoldPipeline.configure { |c| c.merge_conflict_resolution_enabled = true }

          branch = create_conflict_scenario
          task = @pipeline_run.tasks.create!(title: "Task", description: "Desc", position: 0)

          # CLI "succeeds" but doesn't actually fix the markers
          @provider.stubs(:build_cli_command).returns("true") # no-op, leaves markers

          error = assert_raises(ClaudeCode::MergeError) do
            @provider.send(:merge_branch, branch, task: task)
          end
          assert_match(/Conflict markers remain/, error.message)

          merge_head = File.join(@repo_path, ".git", "MERGE_HEAD")
          refute File.exist?(merge_head), "MERGE_HEAD should be cleaned up"
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "build_conflict_resolution_prompt includes task context and file contents" do
          task = @pipeline_run.tasks.create!(
            title: "Add landing page",
            description: "Create a landing page with hero section",
            position: 0
          )

          # Create a fake conflicted file
          File.write(File.join(@repo_path, "routes.rb"), <<~CONTENT)
            <<<<<<< HEAD
            get '/leads'
            =======
            root 'landing#index'
            >>>>>>> branch-b
          CONTENT

          prompt = @provider.send(:build_conflict_resolution_prompt,
            branch: "branch-b",
            task: task,
            conflicted_files: [ "routes.rb" ]
          )

          assert_includes prompt, "branch-b"
          assert_includes prompt, "Add landing page"
          assert_includes prompt, "Create a landing page with hero section"
          assert_includes prompt, "routes.rb"
          assert_includes prompt, "<<<<<<< HEAD"
          assert_includes prompt, "Remove ALL conflict markers"
        end

        test "merge_results passes task to merge_branch" do
          task = @pipeline_run.tasks.create!(title: "My Task", description: "Desc", position: 0, external_id: "cc-1-1")
          @provider.instance_variable_set(:@results, {
            "cc-1-1" => { success: true, branch: "task-branch" }
          })

          @provider.expects(:merge_branch).with("task-branch", task: task)
          @provider.merge_results(pipeline_run: @pipeline_run, tasks: [ task ])
        end

        test "fatal git error (exit 128) skips resolution" do
          ArnoldPipeline.configure { |c| c.merge_conflict_resolution_enabled = true }

          # A non-existent branch produces exit code 128 (fatal)
          task = @pipeline_run.tasks.create!(title: "Task", description: "Desc", position: 0)

          error = assert_raises(ClaudeCode::MergeError) do
            @provider.send(:merge_branch, "nonexistent-branch-xyz", task: task)
          end
          assert_match(/Failed to merge branch/, error.message)
        ensure
          ArnoldPipeline.reset_configuration!
        end

        # --- Task timeout tests ---

        test "claude_code_task_timeout defaults to 30" do
          config = ArnoldPipeline::Configuration.new
          assert_equal 30, config.claude_code_task_timeout
        end

        test "claude_code_task_timeout is configurable" do
          ArnoldPipeline.configure { |c| c.claude_code_task_timeout = 60 }
          assert_equal 60, ArnoldPipeline.configuration.claude_code_task_timeout
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "claude_code_task_timeout nil disables timeout" do
          ArnoldPipeline.configure { |c| c.claude_code_task_timeout = nil }
          assert_nil ArnoldPipeline.configuration.claude_code_task_timeout
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "validate_configuration! rejects invalid task timeout values" do
          config = ArnoldPipeline::Configuration.new
          config.execution_provider = :claude_code
          config.claude_code_repo_path = @repo_path
          ClaudeCode.stubs(:claude_cli_available?).returns(true)

          [ 0, -5, "30" ].each do |bad_value|
            config.claude_code_task_timeout = bad_value
            error = assert_raises(ArnoldPipeline::ConfigurationError) do
              ClaudeCode.validate_configuration!(config)
            end
            assert_match(/claude_code_task_timeout/, error.message)
          end
        end

        test "validate_configuration! accepts valid task timeout values" do
          config = ArnoldPipeline::Configuration.new
          config.execution_provider = :claude_code
          config.claude_code_repo_path = @repo_path
          ClaudeCode.stubs(:claude_cli_available?).returns(true)

          [ 1, 30, 60, 0.5, nil ].each do |good_value|
            config.claude_code_task_timeout = good_value
            assert_nothing_raised { ClaudeCode.validate_configuration!(config) }
          end
        end

        test "spawn_with_timeout returns output and status on normal completion" do
          worktree_path = @repo_path

          output, status = @provider.send(
            :spawn_with_timeout, "echo hello",
            worktree_path: worktree_path, timeout_minutes: 1
          )

          assert_equal "hello\n", output
          assert status.success?
        end

        test "spawn_with_timeout returns nil status on timeout" do
          worktree_path = @repo_path

          # Use a very short timeout with a long-running command
          output, status = @provider.send(
            :spawn_with_timeout, "sleep 60",
            worktree_path: worktree_path, timeout_minutes: 0.01 # 0.6 seconds
          )

          assert_nil status, "Status should be nil when timed out"
        end

        test "spawn_with_timeout with nil timeout_minutes runs without deadline" do
          worktree_path = @repo_path

          output, status = @provider.send(
            :spawn_with_timeout, "echo no-timeout",
            worktree_path: worktree_path, timeout_minutes: nil
          )

          assert_equal "no-timeout\n", output
          assert status.success?
        end

        test "spawn_with_timeout closes pipes when Process.spawn raises" do
          Process.stubs(:spawn).raises(Errno::ENOENT, "No such file or directory")

          assert_raises(Errno::ENOENT) do
            @provider.send(
              :spawn_with_timeout, "nonexistent_command",
              worktree_path: "/nonexistent/path", timeout_minutes: 1
            )
          end
        end

        test "drain_pipe returns immediately when pipe has no writers" do
          r, w = IO.pipe
          w.write("buffered data")
          w.close

          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          output = @provider.send(:drain_pipe, r, timeout_seconds: 5)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

          assert_equal "buffered data", output
          assert elapsed < 1, "drain_pipe should return immediately when pipe is closed, took #{elapsed}s"
        ensure
          r&.close unless r&.closed?
        end

        test "execute_claude_code marks task as failed with execution_timeout on timeout" do
          ArnoldPipeline.configure { |c| c.claude_code_task_timeout = 0.01 }

          branch = "test-timeout-branch"
          @provider.stubs(:setup_worktree).returns(@repo_path)
          @provider.stubs(:spawn_with_timeout).returns([ "partial output", nil ])
          @provider.stubs(:cleanup_worktree)

          result = @provider.send(:execute_claude_code, prompt: "test", branch: branch, external_id: "cc-timeout")

          assert_equal false, result[:success]
          assert_match(/execution_timeout/, result[:error])
          assert_match(/0\.01 minute limit/, result[:error])
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "execute_claude_code cleans up worktree on timeout" do
          ArnoldPipeline.configure { |c| c.claude_code_task_timeout = 0.01 }

          branch = "test-timeout-cleanup"
          @provider.stubs(:setup_worktree).returns(@repo_path)
          @provider.stubs(:spawn_with_timeout).returns([ "", nil ])
          @provider.expects(:cleanup_worktree).with(branch)

          @provider.send(:execute_claude_code, prompt: "test", branch: branch, external_id: "cc-cleanup")
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "create_tasks stores timeout failure in results" do
          ArnoldPipeline.configure { |c| c.claude_code_task_timeout = 0.01 }

          tasks = [ { "title" => "Slow task", "description" => "Will timeout" } ]
          @provider.stubs(:setup_worktree).returns(@repo_path)
          @provider.stubs(:spawn_with_timeout).returns([ "", nil ])
          @provider.stubs(:cleanup_worktree)
          @provider.stubs(:capture_diff).returns("")

          @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

          results = @provider.instance_variable_get(:@results)
          stored = results.values.first
          assert_equal false, stored[:success]
          assert_match(/execution_timeout/, stored[:error])
        ensure
          ArnoldPipeline.reset_configuration!
        end

        test "fetch_results returns :failed for timed-out task" do
          tasks = [ { "title" => "Timeout task", "description" => "Timed out" } ]
          @provider.stubs(:setup_worktree).returns(@repo_path)
          @provider.stubs(:spawn_with_timeout).returns([ "", nil ])
          @provider.stubs(:cleanup_worktree)
          @provider.stubs(:capture_diff).returns("")

          created = @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)
          ext_id = created.first[:external_id]
          task = @pipeline_run.tasks.create!(title: "Timeout task", position: 0, external_id: ext_id)

          results = @provider.fetch_results(pipeline_run: @pipeline_run, tasks: [ task ])
          assert_equal :failed, results.first[:status]
        end

        test "execute_claude_code succeeds normally within timeout" do
          ArnoldPipeline.configure { |c| c.claude_code_task_timeout = 30 }

          branch = "test-normal-timeout"
          @provider.stubs(:setup_worktree).returns(@repo_path)
          @provider.stubs(:spawn_with_timeout).returns([ "Done", stub(success?: true) ])

          result = @provider.send(:execute_claude_code, prompt: "test", branch: branch, external_id: "cc-ok")

          assert_equal true, result[:success]
          assert_equal "Done", result[:output]
          assert_nil result[:error]
        ensure
          ArnoldPipeline.reset_configuration!
        end

        # --- Bug A: strip_binary_noise! tests ---

        test "strip_binary_noise! removes sqlite3 files from branch before merge" do
          branch = "test-sqlite-noise"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          system("git", "-C", @repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)

          # Simulate rails test creating storage/test.sqlite3 in the worktree
          FileUtils.mkdir_p(File.join(worktree_path, "storage"))
          File.write(File.join(worktree_path, "storage", "test.sqlite3"), "binary data")
          File.write(File.join(worktree_path, "app.rb"), "class App; end")
          system("git", "-C", worktree_path, "add", "-A", exception: true)
          system("git", "-C", worktree_path, "commit", "-m", "Add files with sqlite noise", exception: true)

          # Remove the worktree (production flow: worktrees are temporary during execution)
          system("git", "-C", @repo_path, "worktree", "remove", "--force", worktree_path, exception: true)

          @provider.send(:strip_binary_noise!, branch)

          # Verify sqlite3 file is no longer tracked on the branch
          tracked, = Open3.capture2("git", "-C", @repo_path, "ls-tree", "-r", "--name-only", branch, "storage/")
          refute_match(/\.sqlite3/, tracked)

          # Verify app.rb is still tracked
          all_tracked, = Open3.capture2("git", "-C", @repo_path, "ls-tree", "-r", "--name-only", branch)
          assert_includes all_tracked, "app.rb"
        ensure
          cleanup = File.join(@repo_path, ".worktrees", "cleanup-#{branch}")
          system("git", "-C", @repo_path, "worktree", "remove", "--force", cleanup) if Dir.exist?(cleanup)
        end

        test "strip_binary_noise! is no-op when branch has no storage/ files" do
          branch = "test-no-storage"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          system("git", "-C", @repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)

          File.write(File.join(worktree_path, "app.rb"), "class App; end")
          system("git", "-C", worktree_path, "add", "-A", exception: true)
          system("git", "-C", worktree_path, "commit", "-m", "Add app.rb", exception: true)

          # Remove worktree so strip_binary_noise! can operate
          system("git", "-C", @repo_path, "worktree", "remove", "--force", worktree_path, exception: true)

          commit_before, = Open3.capture2("git", "-C", @repo_path, "rev-parse", branch)

          @provider.send(:strip_binary_noise!, branch)

          commit_after, = Open3.capture2("git", "-C", @repo_path, "rev-parse", branch)
          assert_equal commit_before.strip, commit_after.strip, "No commit should be created when no noise files exist"
        end

        test "strip_binary_noise! is called before merge in merge_branch" do
          branch = "test-strip-order"
          call_order = sequence("merge_flow")

          @provider.expects(:strip_binary_noise!).with(branch).in_sequence(call_order)
          Open3.expects(:capture2e).with("git", "-C", @repo_path, "merge", "--no-ff", "--no-edit", branch)
            .returns([ "", stub(success?: true) ]).in_sequence(call_order)

          @provider.send(:merge_branch, branch)
        end

        test "merge_branch succeeds after strip_binary_noise! removes conflicting sqlite files" do
          branch = "test-sqlite-merge"
          worktree_path = File.join(@repo_path, ".worktrees", branch)
          system("git", "-C", @repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)

          FileUtils.mkdir_p(File.join(worktree_path, "storage"))
          File.write(File.join(worktree_path, "storage", "test.sqlite3"), "branch binary data")
          File.write(File.join(worktree_path, "new_feature.rb"), "class Feature; end")
          system("git", "-C", worktree_path, "add", "-A", exception: true)
          system("git", "-C", worktree_path, "commit", "-m", "Add feature with sqlite noise", exception: true)

          # Remove the worktree (production flow: worktrees are temporary during execution)
          system("git", "-C", @repo_path, "worktree", "remove", "--force", worktree_path, exception: true)

          # Create conflicting sqlite on main
          FileUtils.mkdir_p(File.join(@repo_path, "storage"))
          File.write(File.join(@repo_path, "storage", "test.sqlite3"), "main binary data (different)")
          system("git", "-C", @repo_path, "add", "storage/test.sqlite3", exception: true)
          system("git", "-C", @repo_path, "commit", "-m", "Add conflicting sqlite on main", exception: true)

          # Without strip_binary_noise!, this would conflict
          assert_nothing_raised { @provider.send(:merge_branch, branch) }
          assert File.exist?(File.join(@repo_path, "new_feature.rb"))
        ensure
          cleanup = File.join(@repo_path, ".worktrees", "cleanup-#{branch}")
          system("git", "-C", @repo_path, "worktree", "remove", "--force", cleanup) if Dir.exist?(cleanup)
        end

        test "ensure_gitignore! includes storage/ in auto-generated gitignore" do
          branch = "test-gitignore-storage"
          worktree_path = @provider.send(:setup_worktree, branch)

          content = File.read(File.join(worktree_path, ".gitignore"))
          assert_includes content, "storage/"
        ensure
          system("git", "-C", @repo_path, "worktree", "remove", worktree_path) if worktree_path && Dir.exist?(worktree_path)
        end

        # --- Bug B: merge failure handling in merge_results ---

        test "merge_results catches MergeError per task and continues to next task" do
          task1 = @pipeline_run.tasks.create!(title: "Task 1", description: "Desc 1", position: 0, external_id: "cc-1-a")
          task2 = @pipeline_run.tasks.create!(title: "Task 2", description: "Desc 2", position: 1, external_id: "cc-1-b")

          @provider.instance_variable_set(:@results, {
            "cc-1-a" => { success: true, branch: "branch-a" },
            "cc-1-b" => { success: true, branch: "branch-b" }
          })

          # First call raises MergeError, second succeeds
          call_seq = sequence("merge_calls")
          @provider.expects(:merge_branch).with("branch-a", task: task1).in_sequence(call_seq)
            .raises(ClaudeCode::MergeError, "conflict")
          @provider.expects(:merge_branch).with("branch-b", task: task2).in_sequence(call_seq)

          @provider.merge_results(pipeline_run: @pipeline_run, tasks: [ task1, task2 ])

          # Task 1 should be failed, Task 2 should be untouched
          task1.reload
          assert_equal "failed", task1.status
        end

        test "merge_results clears result_diff on merge failure" do
          task = @pipeline_run.tasks.create!(
            title: "Task 1", description: "Desc", position: 0,
            external_id: "cc-1-a",
            result_diff: '[{"filename":"feature.rb","patch":"+code","status":"added"}]'
          )

          @provider.instance_variable_set(:@results, {
            "cc-1-a" => { success: true, branch: "branch-a" }
          })
          @provider.stubs(:merge_branch).raises(ClaudeCode::MergeError, "sqlite conflict")

          @provider.merge_results(pipeline_run: @pipeline_run, tasks: [ task ])

          task.reload
          assert_equal "[]", task.result_diff
          assert_equal "failed", task.status
          assert task.result_comments.any? { |c| c["body"]&.include?("Merge failed") }
        end

        test "merge_results marks merge_failed in internal results" do
          task = @pipeline_run.tasks.create!(title: "Task 1", description: "Desc", position: 0, external_id: "cc-1-a")
          stored = { success: true, branch: "branch-a" }
          @provider.instance_variable_set(:@results, { "cc-1-a" => stored })
          @provider.stubs(:merge_branch).raises(ClaudeCode::MergeError, "conflict")

          @provider.merge_results(pipeline_run: @pipeline_run, tasks: [ task ])

          assert stored[:merge_failed]
        end

        test "merge_results does not swallow non-MergeError exceptions" do
          task = @pipeline_run.tasks.create!(title: "Task 1", description: "Desc", position: 0, external_id: "cc-1-a")
          @provider.instance_variable_set(:@results, {
            "cc-1-a" => { success: true, branch: "branch-a" }
          })
          @provider.stubs(:merge_branch).raises(RuntimeError, "unexpected error")

          assert_raises(RuntimeError) do
            @provider.merge_results(pipeline_run: @pipeline_run, tasks: [ task ])
          end
        end
      end
    end
  end
end
