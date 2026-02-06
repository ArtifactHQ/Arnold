module ArnoldPipeline
  class Task < ApplicationRecord
    enum :status, {
      pending: 0,
      in_progress: 1,
      completed: 2,
      failed: 3
    }

    belongs_to :pipeline_run

    validates :title, presence: true
    validates :position, presence: true, numericality: { greater_than_or_equal_to: 0 }

    scope :in_tier, ->(tier) { where(tier: tier) }

    default_scope { order(:position) }
  end
end
