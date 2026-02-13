module ArnoldPipeline
  class PipelineRun < ApplicationRecord
    enum :status, {
      pending: 0,
      generating_spec: 1,
      breaking_tasks: 2,
      executing: 3,
      analyzing: 4,
      completed: 5,
      max_iterations_reached: 6,
      failed: 7,
      awaiting_results: 8,
      paused: 9
    }

    VALID_TRANSITIONS = {
      "pending" => %w[generating_spec executing failed],
      "generating_spec" => %w[breaking_tasks paused failed],
      "breaking_tasks" => %w[executing paused failed],
      "executing" => %w[awaiting_results analyzing paused failed],
      "awaiting_results" => %w[analyzing executing paused failed max_iterations_reached],
      "analyzing" => %w[completed max_iterations_reached executing breaking_tasks failed],
      "paused" => %w[generating_spec breaking_tasks executing analyzing failed],
      "failed" => %w[generating_spec breaking_tasks executing analyzing],
      "completed" => [],
      "max_iterations_reached" => []
    }.freeze

    has_one :specification, dependent: :destroy
    has_many :tasks, dependent: :destroy
    has_many :iterations, dependent: :destroy
    has_many :pipeline_events, dependent: :destroy

    validates :nl_input, presence: true
    validate :valid_status_transition, on: :update

    private

    def valid_status_transition
      return unless status_changed?

      from = status_was
      to = status
      allowed = VALID_TRANSITIONS[from]

      unless allowed&.include?(to)
        errors.add(:status, "cannot transition from '#{from}' to '#{to}'")
      end
    end
  end
end
