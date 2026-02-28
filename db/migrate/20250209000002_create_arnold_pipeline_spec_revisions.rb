class CreateArnoldPipelineSpecRevisions < ActiveRecord::Migration[8.0]
  def change
    create_table :arnold_pipeline_spec_revisions do |t|
      t.references :specification, null: false,
                   foreign_key: { to_table: :arnold_pipeline_specifications }
      t.integer :version, null: false
      t.text    :content, null: false
      t.json    :structured_data
      t.string  :change_source
      t.json    :delta_summary
      t.timestamps
    end

    add_index :arnold_pipeline_spec_revisions,
              [ :specification_id, :version ], unique: true,
              name: "idx_spec_revisions_on_spec_and_version"
  end
end
