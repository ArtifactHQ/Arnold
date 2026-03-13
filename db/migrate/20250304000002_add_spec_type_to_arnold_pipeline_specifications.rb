class AddSpecTypeToArnoldPipelineSpecifications < ActiveRecord::Migration[8.0]
  def change
    add_column :arnold_pipeline_specifications, :spec_type, :string, default: "target", null: false
  end
end
