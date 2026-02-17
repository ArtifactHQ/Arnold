require "open3"

module ArnoldPipeline
  class PostMergeHookRunner
    MAX_OUTPUT_CHARS = 2000

    def self.call(repo_path:, changed_files:, hooks:, logger: nil)
      new(repo_path: repo_path, changed_files: changed_files, hooks: hooks, logger: logger).call
    end

    def initialize(repo_path:, changed_files:, hooks:, logger: nil)
      @repo_path = repo_path
      @changed_files = changed_files
      @hooks = hooks
      @logger = logger
    end

    def call
      @hooks.map { |hook| run_hook(hook) }
    end

    private

    def run_hook(hook)
      unless hook.triggered_by?(@changed_files)
        return { name: hook.name, triggered: false, success: nil, stdout: nil, stderr: nil, exit_code: nil }
      end

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

      if status.success? && hook.commit_paths.any?
        commit_derived_files(hook)
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

    def truncate(str)
      return str if str.nil? || str.length <= MAX_OUTPUT_CHARS

      str[0, MAX_OUTPUT_CHARS]
    end
  end
end
