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
      awaiting_results: 8
    }

    has_one :specification, dependent: :destroy
    has_many :tasks, dependent: :destroy
    has_many :iterations, dependent: :destroy

    validates :nl_input, presence: true
  end
end
