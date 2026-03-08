require "test_helper"
require "arnold_pipeline/post_merge_hook"
require "arnold_pipeline/post_merge_hook_runner"
require "tmpdir"

module ArnoldPipeline
  class PostMergeHookRunnerTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::PostMergeHookRunner*"

    setup do
      @tmpdir = Dir.mktmpdir("post_merge_hook_runner_test")
      system("git", "init", @tmpdir, out: File::NULL, err: File::NULL)
      system("git", "-C", @tmpdir, "config", "user.email", "test@example.com")
      system("git", "-C", @tmpdir, "config", "user.name", "Test")
      # Create an initial commit so HEAD exists
      File.write(File.join(@tmpdir, "README.md"), "# Test\n")
      system("git", "-C", @tmpdir, "add", ".")
      system("git", "-C", @tmpdir, "commit", "-m", "initial", "--no-verify", out: File::NULL, err: File::NULL)
    end

    teardown do
      FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
    end

    test "runs hooks that match changed files" do
      hook = PostMergeHook.new(
        name: "bundler",
        trigger_paths: [ "Gemfile" ],
        command: "echo hook_ran"
      )

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "Gemfile" ],
        hooks: [ hook ]
      )

      assert_equal 1, results.size
      result = results.first
      assert_equal "bundler", result[:name]
      assert result[:triggered]
      assert result[:success]
      assert_includes result[:stdout], "hook_ran"
      assert_equal 0, result[:exit_code]
    end

    test "skips hooks that don't match changed files" do
      hook = PostMergeHook.new(
        name: "bundler",
        trigger_paths: [ "Gemfile" ],
        command: "echo should_not_run"
      )

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app/models/user.rb" ],
        hooks: [ hook ]
      )

      result = results.first
      assert_equal "bundler", result[:name]
      refute result[:triggered]
      assert_nil result[:success]
      assert_nil result[:stdout]
    end

    test "commits derived files when command succeeds and commit_paths present" do
      # Create a script that generates a derived file and commit it so working tree is clean
      script_path = File.join(@tmpdir, "generate.sh")
      File.write(script_path, "#!/bin/sh\necho 'generated content' > derived.txt\n")
      File.chmod(0o755, script_path)
      system("git", "-C", @tmpdir, "add", "generate.sh")
      system("git", "-C", @tmpdir, "commit", "-m", "add script", "--no-verify", out: File::NULL, err: File::NULL)

      hook = PostMergeHook.new(
        name: "generate",
        trigger_paths: [ "*.rb" ],
        command: "./generate.sh",
        commit_paths: [ "derived.txt" ],
        commit_message: "chore: update derived file"
      )

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app.rb" ],
        hooks: [ hook ]
      )

      assert results.first[:success]

      # Verify the file was committed
      log_output, = Open3.capture3("git", "log", "--oneline", "-1", chdir: @tmpdir)
      assert_includes log_output, "chore: update derived file"

      # Verify working tree is clean
      status_output, = Open3.capture3("git", "status", "--porcelain", chdir: @tmpdir)
      assert_empty status_output.strip
    end

    test "does not commit when command succeeds but no staged changes" do
      hook = PostMergeHook.new(
        name: "noop",
        trigger_paths: [ "*.rb" ],
        command: "echo noop",
        commit_paths: [ "nonexistent.txt" ]
      )

      # Get commit count before
      before_log, = Open3.capture3("git", "rev-list", "--count", "HEAD", chdir: @tmpdir)

      PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app.rb" ],
        hooks: [ hook ]
      )

      # Commit count should be the same
      after_log, = Open3.capture3("git", "rev-list", "--count", "HEAD", chdir: @tmpdir)
      assert_equal before_log.strip, after_log.strip
    end

    test "captures stdout/stderr on failure" do
      hook = PostMergeHook.new(
        name: "failing",
        trigger_paths: [ "*.rb" ],
        command: "echo 'error output' >&2 && exit 1"
      )

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app.rb" ],
        hooks: [ hook ]
      )

      result = results.first
      assert result[:triggered]
      refute result[:success]
      assert_includes result[:stderr], "error output"
      assert_equal 1, result[:exit_code]
    end

    test "returns success: false on non-zero exit" do
      hook = PostMergeHook.new(
        name: "bad_exit",
        trigger_paths: [ "*.rb" ],
        command: "exit 42"
      )

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app.rb" ],
        hooks: [ hook ]
      )

      result = results.first
      refute result[:success]
      assert_equal 42, result[:exit_code]
    end

    test "rescues exceptions and returns error result" do
      hook = PostMergeHook.new(
        name: "broken",
        trigger_paths: [ "*.rb" ],
        command: "echo test"
      )

      # Stub Open3.capture3 to raise an exception
      Open3.stubs(:capture3).raises(Errno::ENOENT, "No such file or directory")

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app.rb" ],
        hooks: [ hook ]
      )

      result = results.first
      assert_equal "broken", result[:name]
      assert result[:triggered]
      refute result[:success]
      assert_includes result[:error], "No such file or directory"
    end

    test "runs multiple hooks in order" do
      hook1 = PostMergeHook.new(
        name: "first",
        trigger_paths: [ "*.rb" ],
        command: "echo first"
      )
      hook2 = PostMergeHook.new(
        name: "second",
        trigger_paths: [ "*.rb" ],
        command: "echo second"
      )
      hook3 = PostMergeHook.new(
        name: "skipped",
        trigger_paths: [ "*.py" ],
        command: "echo skipped"
      )

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app.rb" ],
        hooks: [ hook1, hook2, hook3 ]
      )

      assert_equal 3, results.size
      assert_equal "first", results[0][:name]
      assert results[0][:triggered]
      assert_includes results[0][:stdout], "first"

      assert_equal "second", results[1][:name]
      assert results[1][:triggered]
      assert_includes results[1][:stdout], "second"

      assert_equal "skipped", results[2][:name]
      refute results[2][:triggered]
    end

    test "caps stdout/stderr at 2000 chars" do
      long_output = "x" * 3000
      hook = PostMergeHook.new(
        name: "verbose",
        trigger_paths: [ "*.rb" ],
        command: "printf '#{long_output}'"
      )

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app.rb" ],
        hooks: [ hook ]
      )

      result = results.first
      assert result[:success]
      assert_equal 2000, result[:stdout].length
    end

    test "auto-commits files dirtied by hook but not listed in commit_paths" do
      script_path = File.join(@tmpdir, "generate.sh")
      File.write(script_path, "#!/bin/sh\necho 'listed' > listed.txt\necho 'unlisted' > unlisted.txt\n")
      File.chmod(0o755, script_path)
      system("git", "-C", @tmpdir, "add", "generate.sh")
      system("git", "-C", @tmpdir, "commit", "-m", "add script", "--no-verify", out: File::NULL, err: File::NULL)

      hook = PostMergeHook.new(
        name: "generate",
        trigger_paths: [ "*.rb" ],
        command: "./generate.sh",
        commit_paths: [ "listed.txt" ],
        commit_message: "chore: update listed file"
      )

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app.rb" ],
        hooks: [ hook ]
      )

      assert results.first[:success]

      status_output, = Open3.capture3("git", "status", "--porcelain", chdir: @tmpdir)
      assert_empty status_output.strip, "Expected clean working tree but found: #{status_output}"

      assert File.exist?(File.join(@tmpdir, "unlisted.txt"))
      log_output, = Open3.capture3("git", "log", "--oneline", "-1", chdir: @tmpdir)
      assert_includes log_output, "Auto-commit"
    end

    test "auto-commit result includes list of unexpected files" do
      script_path = File.join(@tmpdir, "generate.sh")
      File.write(script_path, "#!/bin/sh\necho 'a' > extra_a.txt\necho 'b' > extra_b.txt\n")
      File.chmod(0o755, script_path)
      system("git", "-C", @tmpdir, "add", "generate.sh")
      system("git", "-C", @tmpdir, "commit", "-m", "add script", "--no-verify", out: File::NULL, err: File::NULL)

      hook = PostMergeHook.new(
        name: "generate",
        trigger_paths: [ "*.rb" ],
        command: "./generate.sh"
      )

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app.rb" ],
        hooks: [ hook ]
      )

      assert results.first[:success]
      assert_includes results.first[:auto_committed], "extra_a.txt"
      assert_includes results.first[:auto_committed], "extra_b.txt"
    end

    test "does not auto-commit files that were already dirty before hook ran" do
      File.write(File.join(@tmpdir, "preexisting.txt"), "dirty before hook")

      script_path = File.join(@tmpdir, "generate.sh")
      File.write(script_path, "#!/bin/sh\necho 'new' > hook_output.txt\n")
      File.chmod(0o755, script_path)
      system("git", "-C", @tmpdir, "add", "generate.sh")
      system("git", "-C", @tmpdir, "commit", "-m", "add script", "--no-verify", out: File::NULL, err: File::NULL)

      hook = PostMergeHook.new(
        name: "generate",
        trigger_paths: [ "*.rb" ],
        command: "./generate.sh"
      )

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app.rb" ],
        hooks: [ hook ]
      )

      assert results.first[:success]
      assert_includes results.first[:auto_committed], "hook_output.txt"

      status_output, = Open3.capture3("git", "status", "--porcelain", chdir: @tmpdir)
      assert_includes status_output, "preexisting.txt"
    end

    test "force_all: true triggers hooks regardless of changed_files" do
      hook = PostMergeHook.new(
        name: "schema",
        trigger_paths: [ "db/migrate/**" ],
        command: "echo force_triggered"
      )

      # changed_files don't match trigger_paths, but force_all overrides
      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app/models/user.rb" ],
        hooks: [ hook ],
        force_all: true
      )

      result = results.first
      assert_equal "schema", result[:name]
      assert result[:triggered], "Hook should be triggered with force_all: true"
      assert result[:success]
      assert_includes result[:stdout], "force_triggered"
    end

    test "force_all: false respects trigger_paths (default behavior)" do
      hook = PostMergeHook.new(
        name: "schema",
        trigger_paths: [ "db/migrate/**" ],
        command: "echo should_not_run"
      )

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app/models/user.rb" ],
        hooks: [ hook ],
        force_all: false
      )

      result = results.first
      refute result[:triggered], "Hook should not be triggered when force_all is false and paths don't match"
    end

    test "no auto-commit when hook leaves no new dirty files" do
      hook = PostMergeHook.new(
        name: "clean",
        trigger_paths: [ "*.rb" ],
        command: "echo clean"
      )

      before_log, = Open3.capture3("git", "rev-list", "--count", "HEAD", chdir: @tmpdir)

      results = PostMergeHookRunner.call(
        repo_path: @tmpdir,
        changed_files: [ "app.rb" ],
        hooks: [ hook ]
      )

      after_log, = Open3.capture3("git", "rev-list", "--count", "HEAD", chdir: @tmpdir)
      assert_equal before_log.strip, after_log.strip
      assert_empty results.first[:auto_committed] || []
    end
  end
end
