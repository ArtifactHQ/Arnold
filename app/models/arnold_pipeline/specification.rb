module ArnoldPipeline
  class Specification < ApplicationRecord
    belongs_to :pipeline_run
    has_many :spec_deltas, dependent: :destroy
    has_many :spec_revisions, dependent: :destroy

    validates :content, presence: true
    validates :version, presence: true, numericality: { greater_than: 0 }

    scope :target, -> { where(spec_type: "target") }
    scope :as_built, -> { where(spec_type: "as_built") }
  end
end
