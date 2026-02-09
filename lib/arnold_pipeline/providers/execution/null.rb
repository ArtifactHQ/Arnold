require_relative "base"

module ArnoldPipeline
  module Providers
    module Execution
      class Null < Base
        def async? = false
        def recoverable_errors = []
        def self.validate_configuration!(config) = nil

        def create_tasks(tasks:, pipeline_run:, prior_context: nil)
          tasks.each_with_index.map do |task, i|
            title = task.respond_to?(:title) ? task.title : task["title"]
            { external_id: "null-#{i}", external_url: nil, title: title }
          end
        end

        def fetch_results(pipeline_run:, tasks: nil)
          (tasks || pipeline_run.tasks).filter_map do |task|
            next unless task.external_id
            { task_id: task.id, external_id: task.external_id, diffs: [],
              comments: [], issue_state: "closed", status: :completed,
              workflow_active: false, workflow_details: "null provider" }
          end
        end

        def merge_results(pipeline_run:, tasks: nil) = []
      end

      register(:null, Null)
    end
  end
end
