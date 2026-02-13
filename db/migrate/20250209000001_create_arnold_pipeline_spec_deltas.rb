class CreateArnoldPipelineSpecDeltas < ActiveRecord::Migration[8.0]
  def change
    create_table :arnold_pipeline_spec_deltas do |t|
      t.references :specification, null: false,
                   foreign_key: { to_table: :arnold_pipeline_specifications }
      t.references :iteration, null: false,
                   foreign_key: { to_table: :arnold_pipeline_iterations }
      t.string  :operation, null: false
      t.string  :section, null: false
      t.string  :requirement
      t.text    :before_content
      t.text    :after_content
      t.text    :rationale
      t.timestamps
    end
  end
end
