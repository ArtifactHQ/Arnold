module ArnoldPipeline
  class ResumeInferrer
    def self.call(pipeline_run)
      tasks = pipeline_run.tasks

      return :generate_spec unless pipeline_run.specification

      return :break_tasks if tasks.empty?

      return :execute if tasks.any? { |t| t.tier.nil? }

      return :execute if tasks.any? { |t| t.external_id.blank? }

      all_resolved = tasks.select { |t| t.external_id.present? }.all? { |t|
        !t.workflow_active? && ((t.result_diff.present? && t.result_diff != "[]") || t.failed? || t.has_substantive_comments?)
      }

      return :execute unless all_resolved

      :analyze
    end
  end
end
