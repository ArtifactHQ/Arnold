module ArnoldPipeline
  class SpecRevision < ApplicationRecord
    CHANGE_SOURCES = %w[spec_generation iterate_spec user_iterate mcp_confirm drift_resolution].freeze

    belongs_to :specification

    validates :version, presence: true, numericality: { greater_than: 0 }
    validates :content, presence: true
    validates :change_source, inclusion: { in: CHANGE_SOURCES }, allow_nil: true

    scope :ordered, -> { order(:version) }
  end
end
