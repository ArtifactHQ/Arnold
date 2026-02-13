class CreateArnoldPipelinePipelineEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :arnold_pipeline_pipeline_events do |t|
      t.references :pipeline_run, null: false,
                   foreign_key: { to_table: :arnold_pipeline_pipeline_runs }
      t.integer  :event_type,      null: false
      t.string   :stage,           null: false
      t.json     :summary,         null: false
      t.json     :payload
      t.float    :duration_ms
      t.integer  :iteration_number
      t.integer  :tier_number
      t.timestamps
    end

    add_index :arnold_pipeline_pipeline_events, [:pipeline_run_id, :stage],
              name: "idx_pipeline_events_on_run_and_stage"
    add_index :arnold_pipeline_pipeline_events, [:pipeline_run_id, :created_at],
              name: "idx_pipeline_events_on_run_and_created_at"
  end
end
