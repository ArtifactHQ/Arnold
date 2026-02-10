module ArnoldPipeline
  class SpecDelta < ApplicationRecord
    self.table_name = "arnold_pipeline_spec_deltas"

    OPERATIONS = %w[added modified removed].freeze

    belongs_to :specification
    belongs_to :iteration

    validates :operation, inclusion: { in: OPERATIONS }
    validates :section, presence: true
    validates :requirement, presence: true, if: -> { operation.in?(%w[modified removed]) }
    validates :after_content, presence: true, unless: -> { operation == "removed" }
    validates :before_content, presence: true, if: -> { operation == "modified" }

    scope :additions, -> { where(operation: "added") }
    scope :modifications, -> { where(operation: "modified") }
    scope :removals, -> { where(operation: "removed") }
    scope :by_section, ->(section) { where(section: section) }
  end
end
