module ArnoldPipeline
  class Iteration < ApplicationRecord
    DECISIONS = %w[iterate_tasks iterate_spec done].freeze

    belongs_to :pipeline_run

    validates :number, presence: true, numericality: { greater_than: 0 }
    validates :decision, inclusion: { in: DECISIONS }, allow_nil: true
    validates :confidence, numericality: { in: 0..100 }, allow_nil: true
    validate :number_within_configured_limit

    before_save :flag_low_confidence

    private

    def number_within_configured_limit
      max = ArnoldPipeline.configuration.max_iterations
      if number.present? && number > max
        errors.add(:number, "must be less than or equal to #{max}")
      end
    end

    def flag_low_confidence
      self.needs_human_review = confidence.present? && confidence < 70
      true
    end
  end
end
