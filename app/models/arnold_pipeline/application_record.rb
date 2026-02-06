module ArnoldPipeline
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
    self.table_name_prefix = "arnold_pipeline_"
  end
end
