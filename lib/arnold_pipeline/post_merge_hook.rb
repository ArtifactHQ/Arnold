module ArnoldPipeline
  class PostMergeHook
    attr_reader :name, :trigger_paths, :command, :commit_paths, :commit_message

    def initialize(name:, trigger_paths:, command:, commit_paths: [], commit_message: nil)
      @name = name
      @trigger_paths = Array(trigger_paths)
      @command = command
      @commit_paths = Array(commit_paths)
      @commit_message = commit_message || "Post-merge hook: #{name}"
    end

    def triggered_by?(changed_files)
      changed_files.any? do |file|
        @trigger_paths.any? { |pattern| File.fnmatch(pattern, file, File::FNM_PATHNAME) }
      end
    end
  end
end
