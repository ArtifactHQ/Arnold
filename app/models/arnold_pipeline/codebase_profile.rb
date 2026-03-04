module ArnoldPipeline
  class CodebaseProfile < ApplicationRecord
    belongs_to :pipeline_run

    validates :pipeline_run, presence: true

    def stack_language
      stack_fingerprint&.dig("language")
    end

    def stack_framework
      stack_fingerprint&.dig("framework")
    end

    def concern_status(concern_id)
      recipe_alignment&.dig("concerns", concern_id.to_s, "status")
    end

    def convention(key)
      conventions&.dig(key.to_s)
    end

    def pre_existing_failures
      health_baseline&.dig("checks")&.select { |c| !c["success"] } || []
    end

    def stale?(repo_path)
      return true unless analyzed_at

      latest_mtime = Dir.glob(File.join(repo_path, "**/*"))
                        .select { |f| File.file?(f) }
                        .map { |f| File.mtime(f) }
                        .max

      return false unless latest_mtime
      latest_mtime > analyzed_at
    end
  end
end
