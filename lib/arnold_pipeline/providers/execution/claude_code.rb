require "bundler"
require "fileutils"
require "json"
require "open3"
require "shellwords"
require_relative "base"
require "arnold_pipeline/library/manager"
require "arnold_pipeline/services/claude_md_generator"

module ArnoldPipeline
  module Providers
    module Execution
      class ClaudeCode < Base
        class MergeError < StandardError; end

        VALID_PERMISSION_MODES = %w[acceptEdits bypassPermissions default delegate dontAsk plan].freeze

        attr_reader :repo_path, :model, :max_turns, :permission_mode, :max_budget_usd

        def initialize(repo_path:, model: "sonnet", max_turns: 25, permission_mode: "bypassPermissions", max_budget_usd: nil)
          @repo_path = repo_path
          @model = model
          @max_turns = max_turns
          @permission_mode = permission_mode
          @max_budget_usd = max_budget_usd
          @results = {}
          @results_mutex = Mutex.new
          @worktree_mutex = Mutex.new
        end

        def async? = false

        def recoverable_errors = [ MergeError ]

        def self.validate_configuration!(config)
          path = config.claude_code_repo_path

          if path.nil? || path.to_s.strip.empty?
            raise ConfigurationError, "claude_code_repo_path is required when execution_provider is :claude_code"
          end

          unless Dir.exist?(path)
            raise ConfigurationError, "claude_code_repo_path '#{path}' is not a valid directory"
          end

          unless system("git", "-C", path, "rev-parse", "--git-dir", out: File::NULL, err: File::NULL)
            raise ConfigurationError, "claude_code_repo_path '#{path}' is not a git repository"
          end

          unless claude_cli_available?
            raise ConfigurationError,
              "claude CLI not found — install Claude Code: npm install -g @anthropic-ai/claude-code"
          end

          mode = config.claude_code_permission_mode || "bypassPermissions"
          unless VALID_PERMISSION_MODES.include?(mode)
            raise ConfigurationError,
              "Invalid claude_code_permission_mode '#{mode}'. Must be one of: #{VALID_PERMISSION_MODES.join(', ')}"
          end

          concurrency = config.claude_code_max_concurrency
          if concurrency && !(concurrency.is_a?(Integer) && concurrency.between?(1, 16))
            raise ConfigurationError,
              "claude_code_max_concurrency must be an integer between 1 and 16"
          end

          timeout = config.claude_code_task_timeout
          if timeout && !(timeout.is_a?(Numeric) && timeout > 0)
            raise ConfigurationError,
              "claude_code_task_timeout must be nil or a positive number (minutes)"
          end
        end

        def self.build_from_config(config, **options)
          new(
            repo_path: options[:repo_path] || config.claude_code_repo_path,
            model: options[:model] || config.claude_code_model || "sonnet",
            max_turns: options.key?(:max_turns) ? options[:max_turns] : config.claude_code_max_turns,
            permission_mode: options[:permission_mode] || config.claude_code_permission_mode || "bypassPermissions",
            max_budget_usd: options.key?(:max_budget_usd) ? options[:max_budget_usd] : config.claude_code_max_budget_usd
          )
        end

        def create_tasks(tasks:, pipeline_run:, prior_context: nil)
          @library_selections = resolve_library_selections(pipeline_run)
          ensure_initial_commit!

          work_items = tasks.each_with_index.map do |task, index|
            title = task.respond_to?(:title) ? task.title : task["title"]
            description = task.respond_to?(:description) ? task.description : task["description"]
            labels = task.respond_to?(:labels) ? task.labels : (task["labels"] || [])

            task_key = task.respond_to?(:id) && task.id ? task.id : SecureRandom.hex(4)
            external_id = "cc-#{pipeline_run.id}-#{task_key}"
            branch_name = "task-#{pipeline_run.id}-#{task_key}"

            prompt = build_prompt(
              title: title,
              description: description,
              labels: labels,
              prior_context: prior_context
            )

            {
              index: index,
              title: title,
              external_id: external_id,
              branch_name: branch_name,
              prompt: prompt
            }
          end

          if work_items.size <= 1 || max_concurrency <= 1
            work_items.map { |item| execute_work_item(item) }
          else
            execute_parallel(work_items)
          end
        end

        def fetch_results(pipeline_run:, tasks: nil)
          (tasks || pipeline_run.tasks).filter_map do |task|
            next unless task.external_id

            stored = @results[task.external_id]
            next unless stored

            parsed = stored[:parsed] || {}

            comments = if !stored[:success] && parsed[:result]
              body = "Task failed: #{parsed[:result]}"
              body = body[0..3000] + "\n\n(truncated)" if body.length > 3000
              [ { "source" => "claude_code", "author" => "claude", "body" => body } ]
            else
              []
            end

            metadata = {
              "cost_usd" => parsed[:cost_usd],
              "duration_ms" => parsed[:duration_ms],
              "num_turns" => parsed[:num_turns],
              "model" => model,
              "session_id" => parsed[:session_id]
            }.compact

            {
              task_id: task.id,
              external_id: task.external_id,
              diffs: parse_diff_to_array(stored[:diff] || ""),
              comments: comments,
              status: stored[:success] ? :completed : :failed,
              workflow_active: false,
              workflow_details: "claude code execution",
              execution_metadata: metadata
            }
          end
        end

        def merge_results(pipeline_run:, tasks: nil)
          target_tasks = tasks || pipeline_run.tasks
          target_tasks.each do |task|
            next unless task.external_id

            stored = @results[task.external_id]
            next unless stored
            next unless stored[:success]

            begin
              merge_branch(stored[:branch], task: task)
            rescue MergeError => e
              Rails.logger.warn { "[Arnold] Merge failed for task '#{task.title}' (#{task.external_id}): #{e.message}" } if defined?(Rails)
              @results_mutex.synchronize { stored[:merge_failed] = true }
              task.update!(
                status: :failed,
                result_diff: "[]",
                result_comments: [ { "source" => "arnold", "author" => "system", "body" => "Merge failed: #{e.message}" } ]
              )
            end
          end

          []
        end

        private

        def self.claude_cli_available?
          system("which claude > /dev/null 2>&1")
        end

        def parse_claude_output(raw_output)
          parsed = JSON.parse(raw_output)
          {
            result: parsed["result"],
            cost_usd: parsed["total_cost_usd"],
            duration_ms: parsed["duration_ms"],
            num_turns: parsed["num_turns"],
            session_id: parsed["session_id"],
            is_error: parsed["is_error"],
            subtype: parsed["subtype"]
          }
        rescue JSON::ParserError
          { result: raw_output, cost_usd: nil, duration_ms: nil, num_turns: nil,
            session_id: nil, is_error: nil, subtype: nil }
        end

        def build_prompt(title:, description:, labels:, prior_context:)
          context_section = if prior_context
            <<~CTX
              ## Prior Implementation Context
              Previous tiers have already implemented and merged code into this repository.
              You can see their work in the existing files. Here is a summary:

              #{prior_context}

              Build on top of existing code. Do not rewrite or duplicate what already exists.
            CTX
          else
            "This is the first implementation tier. Start from the project's current state."
          end

          <<~PROMPT
            ## Task
            **#{title}**
            #{description}
            #{"Labels: #{Array(labels).join(', ')}" if Array(labels).any?}

            #{context_section}
          PROMPT
        end

        def execute_work_item(item)
          result = execute_claude_code(
            prompt: item[:prompt],
            branch: item[:branch_name],
            external_id: item[:external_id]
          )

          if result[:success]
            worktree_path = File.join(repo_path, ".worktrees", item[:branch_name])
            normalize_worktree(worktree_path: worktree_path, title: item[:title])
          end

          diff = capture_diff(branch: item[:branch_name])

          if result[:success] && diff.strip.empty?
            result = result.merge(
              success: false,
              error: "Task completed with exit code 0 but produced no code changes"
            )
          end

          parsed = parse_claude_output(result[:output] || "")

          if result[:success] && parsed[:is_error]
            result = result.merge(
              success: false,
              error: "Claude reported error: #{parsed[:subtype] || "unknown"}"
            )
          end

          @results_mutex.synchronize do
            @results[item[:external_id]] = {
              success: result[:success],
              output: result[:output],
              diff: diff,
              branch: item[:branch_name],
              error: result[:error],
              parsed: parsed
            }
          end

          { external_id: item[:external_id], external_url: nil, title: item[:title] }
        end

        def execute_parallel(work_items)
          queue = Thread::Queue.new
          work_items.each { |item| queue << item }

          output = Array.new(work_items.size)
          num_workers = [ max_concurrency, work_items.size ].min

          workers = num_workers.times.map do
            Thread.new do
              loop do
                item = begin; queue.pop(true); rescue ThreadError; break; end
                output[item[:index]] = execute_work_item(item)
              end
            end
          end

          workers.each(&:join)
          output
        end

        def max_concurrency
          ArnoldPipeline.configuration.claude_code_max_concurrency || 4
        end

        def task_timeout
          ArnoldPipeline.configuration.claude_code_task_timeout
        end

        def merge_conflict_timeout
          ArnoldPipeline.configuration.claude_code_merge_timeout || 10
        end

        def agent_subprocess_env
          { "CLAUDECODE" => nil, "CI" => "true", "ARNOLD_NONINTERACTIVE" => "1" }
        end

        # Spawns a shell command in its own process group with an optional timeout.
        # Returns [output_string, Process::Status] on normal completion, or
        # [output_string, nil] when the process is killed due to timeout.
        def spawn_with_timeout(cmd, worktree_path:, timeout_minutes:)
          stdout_r, stdout_w = IO.pipe

          pid = Process.spawn(
            agent_subprocess_env,
            cmd,
            chdir: worktree_path,
            pgroup: true,
            in: "/dev/null",
            out: stdout_w,
            err: [ :child, :out ]
          )
          stdout_w.close

          deadline = timeout_minutes ? Process.clock_gettime(Process::CLOCK_MONOTONIC) + (timeout_minutes * 60) : nil
          status = nil
          timed_out = false

          # Poll for process completion with 5-second intervals
          loop do
            result = Process.waitpid2(pid, Process::WNOHANG)
            if result
              _, status = result
              break
            end

            if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              timed_out = true
              kill_process_group(pid)
              break
            end

            sleep 5
          end

          output = if timed_out
            drain_pipe(stdout_r, timeout_seconds: 5)
          else
            stdout_r.read
          end

          timed_out ? [ output, nil ] : [ output, status ]
        ensure
          stdout_r&.close unless stdout_r&.closed?
          stdout_w&.close unless stdout_w&.closed?
        end

        # Reads remaining data from a pipe with a bounded timeout.
        # Returns immediately when all writers have closed; caps at timeout_seconds
        # if a grandchild process still holds the write end open.
        def drain_pipe(io, timeout_seconds:)
          output = +""
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
          loop do
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0
            break unless IO.select([ io ], nil, nil, [ remaining, 1 ].min)
            chunk = io.read_nonblock(65536, exception: false)
            break if chunk.nil? || chunk == :wait_readable
            output << chunk
          end
          output
        end

        def kill_process_group(pid)
          pgid = Process.getpgid(pid)

          # Graceful shutdown
          Process.kill("-TERM", pgid)
          # Wait up to 10 seconds for graceful exit
          10.times do
            break if Process.waitpid2(pid, Process::WNOHANG)
            sleep 1
          end

          # Force kill if still alive
          Process.kill("-KILL", pgid) if Process.waitpid2(pid, Process::WNOHANG).nil?
          Process.waitpid2(pid, 0) # Reap the zombie
        rescue Errno::ESRCH, Errno::ECHILD
          # Process already exited — nothing to do
        end

        def execute_claude_code(prompt:, branch:, external_id:)
          worktree_path = @worktree_mutex.synchronize { setup_worktree(branch) }

          cmd = build_cli_command(prompt)
          timeout_minutes = task_timeout

          # Clear Bundler env so the child process uses its own Gemfile (not arnold_pipeline's).
          # Unset CLAUDECODE so child claude processes don't refuse to start nested sessions.
          output, status = Bundler.with_unbundled_env do
            spawn_with_timeout(cmd, worktree_path: worktree_path, timeout_minutes: timeout_minutes)
          end

          if status.nil?
            # Timed out — process was killed
            cleanup_worktree(branch)
            { success: false, output: output, error: "execution_timeout: task exceeded #{timeout_minutes} minute limit" }
          elsif status.success?
            { success: true, output: output, error: nil }
          else
            { success: false, output: output, error: "claude CLI exited with code #{status.exitstatus}" }
          end
        rescue => e
          { success: false, output: "", error: e.message }
        end

        def system_prompt
          base = <<~SYSTEM.strip
            You are an implementation agent in an automated pipeline.
            Complete the task fully without asking questions.
            Make reasonable decisions and document assumptions in code comments.
            Run the project's test suite after implementing changes. If tests fail, fix them.
            Only commit once tests pass.
            Do not create project subdirectories — work in the current directory.
            Do not run `git init` — this directory is already tracked by git.
            If scaffolding a Rails app, use `rails new . --force` (dot = current dir).
            Commit all changes when finished.
          SYSTEM

          base + "\n" + pipeline_safety_instructions
        end

        def pipeline_safety_instructions
          recipe = @library_selections&.dig(:recipe)
          verification = recipe&.verification || {}
          test_cmd = verification["test_command"]
          boot_cmd = verification["boot_command"]

          parts = []
          parts << "To verify changes, run: `#{test_cmd}`" if test_cmd
          parts << "NEVER run commands that start long-lived server processes. These block the pipeline indefinitely and will be killed."

          if boot_cmd
            parts << "Specifically, do NOT run: bin/setup (starts a server), bin/dev, #{boot_cmd.split.first(2).join(' ')}, puma, foreman start, overmind start, or any command that listens on a port."
          else
            parts << "Do NOT run: bin/setup, bin/dev, puma, foreman start, overmind start, npm start, or any command that listens on a port."
          end

          parts.join("\n")
        end

        def tool_restriction_flags
          flags = []
          if (tools = ArnoldPipeline.configuration.claude_code_tools)
            flags += [ "--tools", Array(tools).join(",") ]
          end
          if (allowed = ArnoldPipeline.configuration.claude_code_allowed_tools)
            Array(allowed).each { |t| flags += [ "--allowedTools", t ] }
          end
          if (disallowed = ArnoldPipeline.configuration.claude_code_disallowed_tools)
            Array(disallowed).each { |t| flags += [ "--disallowedTools", t ] }
          end
          flags
        end

        def build_cli_command(prompt)
          cmd_parts = [
            "claude", "--print", "--output-format", "json",
            "--model", model,
            "--permission-mode", permission_mode,
            "--append-system-prompt", system_prompt
          ]
          cmd_parts += [ "--max-turns", max_turns.to_s ] if max_turns
          cmd_parts += [ "--max-budget-usd", max_budget_usd.to_s ] if max_budget_usd
          cmd_parts += tool_restriction_flags
          cmd_parts << prompt
          cmd_parts.shelljoin
        end

        # Ensure the target repo has at least one commit so that HEAD is valid.
        # Without this, git worktree, diff HEAD..., and merge all fail on a
        # freshly-initialized repo with no commits.
        # Safe to call multiple times; no-ops if HEAD already resolves.
        def ensure_initial_commit!
          _, status = Open3.capture2e("git", "-C", repo_path, "rev-parse", "HEAD")
          return if status.success?

          system("git", "-C", repo_path,
            "-c", "user.name=Arnold Pipeline",
            "-c", "user.email=arnold@pipeline.local",
            "commit", "--allow-empty",
            "-m", "Initial commit (arnold pipeline)", exception: true)
        end

        def setup_worktree(branch)
          worktree_path = File.join(repo_path, ".worktrees", branch)

          cleanup_worktree(branch)

          system("git", "-C", repo_path, "worktree", "add", "-B", branch, worktree_path,
            exception: true)

          ensure_gitignore!(worktree_path)
          write_claude_md!(worktree_path)

          worktree_path
        end

        def resolve_library_selections(pipeline_run)
          selections = pipeline_run.metadata&.dig("library_selections")
          return nil unless selections

          manager = Library::Manager.new
          {
            persona: manager.all_personas.find { |p| p.name == selections["persona"] },
            recipe: manager.all_recipes.find { |r| r.name == selections["recipe"] },
            domain_type: manager.all_domain_types.find { |d| d.code == selections["domain_type"] }
          }
        end

        def write_claude_md!(worktree_path)
          return unless @library_selections

          content = Services::ClaudeMdGenerator.call(
            persona: @library_selections[:persona],
            recipe: @library_selections[:recipe],
            domain_type: @library_selections[:domain_type],
            repo_path: worktree_path
          )

          if File.exist?(File.join(worktree_path, "CLAUDE.md"))
            FileUtils.mkdir_p(File.join(worktree_path, ".claude"))
            File.write(File.join(worktree_path, ".claude", "CLAUDE.md"), content)
          else
            File.write(File.join(worktree_path, "CLAUDE.md"), content)
          end
        end

        def ensure_gitignore!(worktree_path)
          gitignore_path = File.join(worktree_path, ".gitignore")
          return if File.exist?(gitignore_path)

          File.write(gitignore_path, <<~GITIGNORE)
            # Auto-generated by Arnold Pipeline
            tmp/
            log/
            storage/
            node_modules/
            .bundle/
            vendor/bundle/
          GITIGNORE
        end

        def capture_diff(branch:)
          output, _status = Open3.capture2(
            "git", "-C", repo_path, "diff", "HEAD...#{branch}"
          )
          output
        end

        def merge_branch(branch, task: nil)
          strip_binary_noise!(branch)
          output, status = Open3.capture2e("git", "-C", repo_path, "merge", "--no-ff", "--no-edit", branch)
          return if status.success?

          if merge_conflict?(status) && conflict_resolution_enabled?
            resolve_merge_conflicts(branch: branch, task: task)
          else
            abort_merge_if_needed
            raise MergeError, "Failed to merge branch '#{branch}': #{output}"
          end
        rescue MergeError
          raise
        rescue => e
          abort_merge_if_needed
          raise MergeError, "Failed to merge branch '#{branch}': #{e.message}"
        end

        def merge_conflict?(status)
          return false unless status.exitstatus == 1

          conflicted = list_conflicted_files
          conflicted.any?
        end

        def abort_merge_if_needed
          merge_head = File.join(repo_path, ".git", "MERGE_HEAD")
          return unless File.exist?(merge_head)

          system("git", "-C", repo_path, "merge", "--abort")
        end

        def resolve_merge_conflicts(branch:, task:)
          conflicted_files = list_conflicted_files

          if conflicted_files.size > ArnoldPipeline.configuration.merge_conflict_max_files
            abort_merge_if_needed
            raise MergeError,
              "Too many conflicted files (#{conflicted_files.size}) merging '#{branch}' — skipping resolution"
          end

          prompt = build_conflict_resolution_prompt(
            branch: branch,
            task: task,
            conflicted_files: conflicted_files
          )

          cmd = build_cli_command(prompt)
          _output, status = Bundler.with_unbundled_env do
            spawn_with_timeout(cmd, worktree_path: repo_path, timeout_minutes: merge_conflict_timeout)
          end

          if status.nil?
            abort_merge_if_needed
            raise MergeError, "Merge conflict resolution timed out after #{merge_conflict_timeout} minutes for '#{branch}'"
          end

          unless status.success?
            abort_merge_if_needed
            raise MergeError, "Claude CLI failed to resolve merge conflicts for '#{branch}'"
          end

          # Verify all conflict markers are gone
          remaining = conflicted_files.select { |f| file_has_conflict_markers?(f) }
          if remaining.any?
            abort_merge_if_needed
            raise MergeError,
              "Conflict markers remain after resolution in: #{remaining.join(', ')}"
          end

          complete_merge_after_resolution(conflicted_files, branch)
        end

        def list_conflicted_files
          output, _status = Open3.capture2(
            "git", "-C", repo_path, "diff", "--name-only", "--diff-filter=U"
          )
          output.strip.split("\n").reject(&:empty?)
        end

        def file_has_conflict_markers?(relative_path)
          full_path = File.join(repo_path, relative_path)
          return false unless File.exist?(full_path)

          content = File.read(full_path)
          content.include?("<<<<<<<") && content.include?(">>>>>>>")
        end

        def complete_merge_after_resolution(files, branch)
          files.each do |f|
            system("git", "-C", repo_path, "add", f, exception: true)
          end
          system("git", "-C", repo_path, "commit", "--no-edit", exception: true)
        end

        def conflict_resolution_enabled?
          ArnoldPipeline.configuration.merge_conflict_resolution_enabled
        end

        def build_conflict_resolution_prompt(branch:, task:, conflicted_files:)
          file_sections = conflicted_files.map do |file_path|
            full_path = File.join(repo_path, file_path)
            content = File.exist?(full_path) ? File.read(full_path) : "(file not found)"
            "### #{file_path}\n```\n#{content}\n```"
          end.join("\n\n")

          task_title = task.respond_to?(:title) ? task.title : (task&.dig("title") || "unknown")
          task_desc = task.respond_to?(:description) ? task.description : (task&.dig("description") || "")

          <<~PROMPT
            You are resolving git merge conflicts. The branch '#{branch}' is being merged.

            ## Branch Context
            - Task: #{task_title}
            - Description: #{task_desc}

            ## Conflicted Files
            #{file_sections}

            ## Rules
            - Edit ONLY the conflicted files listed above
            - Remove ALL conflict markers (<<<<<<< ======= >>>>>>>)
            - Preserve the intent of BOTH sides
            - For config files (routes, Gemfile, etc.), combine entries from both sides
            - Do NOT create new files or modify non-conflicted files
          PROMPT
        end

        def normalize_worktree(worktree_path:, title:)
          # Remove nested .git directories that frameworks like Rails create.
          # The worktree's own .git is a *file* (not a directory), so it's naturally excluded.
          Dir.glob("**/.git", base: worktree_path).each do |nested_git|
            full_path = File.join(worktree_path, nested_git)
            FileUtils.rm_rf(full_path) if File.directory?(full_path)
          end

          # Stage any unstaged/untracked files.
          # Noise directories are handled by .gitignore (either the repo's own or one
          # created by ensure_gitignore!), so no pathspec exclusions are needed here.
          output, status = Open3.capture2e("git", "-C", worktree_path, "add", "-A", ".")
          unless status.success?
            Rails.logger.warn { "[Arnold] git add exited #{status.exitstatus}: #{output.strip}" } if defined?(Rails)
          end

          # Commit only if there are staged changes (exit 1 = changes exist)
          _output, status = Open3.capture2("git", "-C", worktree_path, "diff", "--cached", "--quiet")
          unless status.success?
            system("git", "-C", worktree_path, "commit", "-m", "Implement: #{title}", exception: true)
          end
        end

        def cleanup_worktree(branch)
          worktree_path = File.join(repo_path, ".worktrees", branch)
          system("git", "-C", repo_path, "worktree", "remove", "--force", worktree_path) if Dir.exist?(worktree_path)
        end

        # Remove binary noise files (storage/*.sqlite3, etc.) from the branch
        # commit before merging. These files are created by `rails test` in
        # worktrees and cause merge conflicts that silently drop entire branches.
        BINARY_NOISE_PATTERNS = %w[storage/*.sqlite3 storage/*.sqlite3-*].freeze

        def strip_binary_noise!(branch)
          # Check if the branch has any noise files tracked under storage/
          tracked, status = Open3.capture2(
            "git", "-C", repo_path, "ls-tree", "-r", "--name-only", branch, "storage/"
          )
          return unless status.success? && tracked.strip.length > 0

          noise_files = tracked.strip.split("\n").select { |f| f.match?(/\.sqlite3/) }
          return if noise_files.empty?

          # Remove noise files from the branch via a temporary worktree
          cleanup_path = File.join(repo_path, ".worktrees", "cleanup-#{branch}")
          begin
            system("git", "-C", repo_path, "worktree", "add", cleanup_path, branch, exception: true)

            noise_files.each do |file|
              system("git", "-C", cleanup_path, "rm", "--cached", "-f", "--ignore-unmatch", file)
            end

            # Commit only if something was actually removed
            _output, diff_status = Open3.capture2("git", "-C", cleanup_path, "diff", "--cached", "--quiet")
            unless diff_status.success?
              system("git", "-C", cleanup_path, "commit", "-m",
                "Remove binary noise files (storage/*.sqlite3)", exception: true)
            end
          ensure
            system("git", "-C", repo_path, "worktree", "remove", "--force", cleanup_path) if Dir.exist?(cleanup_path)
          end
        rescue => e
          Rails.logger.warn { "[Arnold] strip_binary_noise! failed (non-fatal): #{e.message}" } if defined?(Rails)
        end

        def parse_diff_to_array(diff_string)
          return [] if diff_string.nil? || diff_string.strip.empty?

          diffs = []
          current_file = nil
          current_patch_lines = []

          diff_string.each_line do |line|
            if line.start_with?("diff --git")
              # Save previous file's diff
              if current_file
                diffs << build_diff_entry(current_file, current_patch_lines)
              end

              # Extract filename from "diff --git a/path b/path"
              match = line.match(%r{diff --git a/.+ b/(.+)})
              current_file = match ? match[1].strip : "unknown"
              current_patch_lines = [ line ]
            elsif current_file
              current_patch_lines << line
            end
          end

          # Don't forget the last file
          if current_file
            diffs << build_diff_entry(current_file, current_patch_lines)
          end

          diffs
        end

        def build_diff_entry(filename, patch_lines)
          patch = patch_lines.join

          status = if patch.include?("new file mode")
            "added"
          elsif patch.include?("deleted file mode")
            "deleted"
          else
            "modified"
          end

          { filename: filename, patch: patch, status: status }
        end
      end

      register(:claude_code, ClaudeCode)
    end
  end
end
