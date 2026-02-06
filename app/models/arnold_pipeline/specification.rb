module ArnoldPipeline
  class Specification < ApplicationRecord
    belongs_to :pipeline_run

    validates :content, presence: true
    validates :version, presence: true, numericality: { greater_than: 0 }
  end
end
