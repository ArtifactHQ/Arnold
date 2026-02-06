module ArnoldPipeline
  class Iteration < ApplicationRecord
    DECISIONS = %w[iterate_tasks iterate_spec done].freeze
    MAX_ITERATIONS = 3

    belongs_to :pipeline_run

    validates :number, presence: true,
              numericality: { greater_than: 0, less_than_or_equal_to: MAX_ITERATIONS }
    validates :decision, inclusion: { in: DECISIONS }, allow_nil: true
    validates :confidence, numericality: { in: 0..100 }, allow_nil: true

    before_save :flag_low_confidence

    private

    def flag_low_confidence
      self.needs_human_review = confidence.present? && confidence < 70
      true
    end
  end
end
