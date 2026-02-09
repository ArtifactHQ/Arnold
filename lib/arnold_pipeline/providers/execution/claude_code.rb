require "open3"
require "shellwords"
require_relative "base"

module ArnoldPipeline
  module Providers
    module Execution
      class ClaudeCode < Base
        class MergeError < StandardError; end

        attr_reader :repo_path, :model, :max_turns, :permission_mode

        def initialize(repo_path:, model: "sonnet", max_turns: nil, permission_mode: "auto")
          @repo_path = repo_path
          @model = model
          @max_turns = max_turns
          @permission_mode = permission_mode
          @results = {}
        end

        def async? = false

        def recoverable_errors = [MergeError]

        def self.validate_configuration!(config)
          path = config.claude_code_repo_path

          if path.nil? || path.to_s.strip.empty?
            raise ConfigurationError, "claude_code_repo_path is required when execution_provider is :claude_code"
          end

          unless Dir.exist?(path)
            raise ConfigurationError, "claude_code_repo_path '#{path}' is not a valid directory"
          end

          unless claude_cli_available?
            raise ConfigurationError,
              "claude CLI not found — install Claude Code: npm install -g @anthropic-ai/claude-code"
          end
        end

        def self.build_from_config(config, **options)
          new(
            repo_path: options[:repo_path] || config.claude_code_repo_path,
            model: options[:model] || config.claude_code_model || "sonnet",
            max_turns: options[:max_turns] || config.claude_code_max_turns,
            permission_mode: options[:permission_mode] || config.claude_code_permission_mode || "auto"
          )
        end

        def create_tasks(tasks:, pipeline_run:, prior_context: nil)
          tasks.each_with_index.map do |task, i|
            title = task.respond_to?(:title) ? task.title : task["title"]
            description = task.respond_to?(:description) ? task.description : task["description"]
            labels = task.respond_to?(:labels) ? task.labels : (task["labels"] || [])

            external_id = "cc-#{pipeline_run.id}-#{i}"
            branch_name = "task-#{pipeline_run.id}-#{i}"

            prompt = build_prompt(
              title: title,
              description: description,
              labels: labels,
              prior_context: prior_context
            )

            result = execute_claude_code(
              prompt: prompt,
              branch: branch_name,
              external_id: external_id
            )

            diff = capture_diff(branch: branch_name)

            @results[external_id] = {
              success: result[:success],
              output: result[:output],
              diff: diff,
              branch: branch_name,
              error: result[:error]
            }

            { external_id: external_id, external_url: nil, title: title }
          end
        end

        def fetch_results(pipeline_run:, tasks: nil)
          # Reload tasks to pick up external_id set by Executor#call, which updates
          # via find_by (a separate object). Without reload, stale in-memory objects
          # from TierExecutionEngine's sync path will have nil external_id.
          target_tasks = tasks ? tasks.map(&:reload) : pipeline_run.tasks
          target_tasks.filter_map do |task|
            next unless task.external_id

            stored = @results[task.external_id]
            next unless stored

            {
              task_id: task.id,
              external_id: task.external_id,
              diffs: parse_diff_to_array(stored[:diff] || ""),
              comments: [],
              status: stored[:success] ? :completed : :failed,
              workflow_active: false,
              workflow_details: "claude code execution"
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

            merge_branch(stored[:branch])
          end

          []
        end

        private

        def self.claude_cli_available?
          system("which claude > /dev/null 2>&1")
        end

        def build_prompt(title:, description:, labels:, prior_context:)
          context_section = if prior_context
            prior_context
          else
            "This is the first tier — no prior context."
          end

          <<~PROMPT
            You are implementing a task as part of a larger application build.

            ## Task
            Title: #{title}
            Description: #{description}
            Labels: #{Array(labels).join(', ')}

            ## Prior Context
            #{context_section}

            Implement this task fully. Create or modify all necessary files.
            Do not ask questions — make reasonable decisions and document assumptions in code comments.
          PROMPT
        end

        def execute_claude_code(prompt:, branch:, external_id:)
          worktree_path = setup_worktree(branch)

          cmd = build_cli_command(prompt)

          output, status = Open3.capture2(cmd, chdir: worktree_path)

          if status.success?
            { success: true, output: output, error: nil }
          else
            { success: false, output: output, error: "claude CLI exited with code #{status.exitstatus}" }
          end
        rescue => e
          { success: false, output: "", error: e.message }
        end

        def build_cli_command(prompt)
          cmd_parts = [
            "claude", "--print", "--output-format", "json",
            "--model", model,
            "--permission-mode", permission_mode
          ]

          cmd_parts += ["--max-turns", max_turns.to_s] if max_turns

          cmd_parts += ["--prompt", prompt]

          cmd_parts.shelljoin
        end

        def setup_worktree(branch)
          worktree_path = File.join(repo_path, ".worktrees", branch)

          system("git", "-C", repo_path, "worktree", "add", "-b", branch, worktree_path,
            exception: true)

          worktree_path
        end

        def capture_diff(branch:)
          output, _status = Open3.capture2(
            "git", "-C", repo_path, "diff", "HEAD...#{branch}"
          )
          output
        end

        def merge_branch(branch)
          system("git", "-C", repo_path, "merge", "--no-ff", branch,
            exception: true)
        rescue => e
          raise MergeError, "Failed to merge branch '#{branch}': #{e.message}"
        end

        def cleanup_worktree(branch)
          worktree_path = File.join(repo_path, ".worktrees", branch)
          system("git", "-C", repo_path, "worktree", "remove", worktree_path) if Dir.exist?(worktree_path)
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
              current_patch_lines = [line]
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
