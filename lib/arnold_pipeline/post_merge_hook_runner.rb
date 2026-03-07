require "bundler"
require "open3"

module ArnoldPipeline
  class PostMergeHookRunner
    MAX_OUTPUT_CHARS = 2000

    def self.call(repo_path:, changed_files:, hooks:, logger: nil, force_all: false)
      new(repo_path: repo_path, changed_files: changed_files, hooks: hooks, logger: logger, force_all: force_all).call
    end

    def initialize(repo_path:, changed_files:, hooks:, logger: nil, force_all: false)
      @repo_path = repo_path
      @changed_files = changed_files
      @hooks = hooks
      @logger = logger
      @force_all = force_all
    end

    def call
      @hooks.map { |hook| run_hook(hook) }
    end

    private

    def run_hook(hook)
      unless @force_all || hook.triggered_by?(@changed_files)
        return { name: hook.name, triggered: false, success: nil, stdout: nil, stderr: nil, exit_code: nil }
      end

      pre_hook_dirty = current_dirty_files

      stdout, stderr, status = Bundler.with_unbundled_env do
        Open3.capture3(hook.command, chdir: @repo_path)
      end

      result = {
        name: hook.name,
        triggered: true,
        success: status.success?,
        stdout: truncate(stdout),
        stderr: truncate(stderr),
        exit_code: status.exitstatus
      }

      if status.success?
        commit_derived_files(hook) if hook.commit_paths.any?
        result[:auto_committed] = auto_commit_remaining!(hook, pre_hook_dirty)
      end

      result
    rescue => e
      @logger&.error("PostMergeHookRunner: hook '#{hook.name}' raised #{e.class}: #{e.message}")
      { name: hook.name, triggered: true, success: false, error: e.message }
    end

    def commit_derived_files(hook)
      hook.commit_paths.each do |path|
        system("git", "add", path, chdir: @repo_path)
      end

      # Only commit if there are staged changes
      _, _, diff_status = Open3.capture3("git", "diff", "--cached", "--quiet", chdir: @repo_path)
      return if diff_status.success?

      system("git", "commit", "-m", hook.commit_message, "--no-verify", chdir: @repo_path)
    end

    def auto_commit_remaining!(hook, pre_hook_dirty)
      post_hook_dirty = current_dirty_files
      newly_dirty = post_hook_dirty - pre_hook_dirty
      return [] if newly_dirty.empty?

      @logger&.warn("[Arnold] Hook '#{hook.name}' modified files not in commit_paths: #{newly_dirty.join(', ')}. Auto-committing.")

      newly_dirty.each do |path|
        system("git", "add", path, chdir: @repo_path)
      end

      system("git", "commit", "-m", "Auto-commit files modified by hook '#{hook.name}'", "--no-verify", chdir: @repo_path)
      newly_dirty
    end

    def current_dirty_files
      output, = Open3.capture3("git", "status", "--porcelain", chdir: @repo_path)
      output.lines.map { |line| line[3..].strip }.reject(&:empty?)
    end

    def truncate(str)
      return str if str.nil? || str.length <= MAX_OUTPUT_CHARS

      str[0, MAX_OUTPUT_CHARS]
    end
  end
end
