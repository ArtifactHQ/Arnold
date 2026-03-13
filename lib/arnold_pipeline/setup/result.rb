module ArnoldPipeline
  module Setup
    class Result
      STATUSES = %i[complete needs_input error].freeze

      attr_reader :status, :missing_fields, :errors, :project_path, :config_path,
                  :spec_summary, :task_summary, :run_id

      def initialize(status:, missing_fields: [], errors: [], project_path: nil,
                     config_path: nil, spec_summary: nil, task_summary: nil, run_id: nil)
        raise ArgumentError, "Invalid status: #{status}" unless STATUSES.include?(status)

        @status = status
        @missing_fields = missing_fields.freeze
        @errors = errors.freeze
        @project_path = project_path
        @config_path = config_path
        @spec_summary = spec_summary
        @task_summary = task_summary
        @run_id = run_id
        freeze
      end

      def complete? = status == :complete
      def needs_input? = status == :needs_input
      def error? = status == :error

      def self.complete(project_path:, config_path:, spec_summary:, task_summary:, run_id:)
        new(
          status: :complete,
          project_path:, config_path:, spec_summary:, task_summary:, run_id:
        )
      end

      def self.needs_input(missing_fields)
        new(status: :needs_input, missing_fields:)
      end

      def self.error(errors)
        errors = Array(errors)
        new(status: :error, errors:)
      end
    end
  end
end
