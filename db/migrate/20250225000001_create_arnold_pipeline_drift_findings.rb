class CreateArnoldPipelineDriftFindings < ActiveRecord::Migration[8.0]
  def change
    create_table :arnold_pipeline_drift_findings do |t|
      t.references :pipeline_run, null: false, foreign_key: { to_table: :arnold_pipeline_pipeline_runs }
      t.references :spec_revision, foreign_key: { to_table: :arnold_pipeline_spec_revisions }
      t.string :domain
      t.string :drift_type, null: false
      t.string :severity, null: false
      t.text :description, null: false
      t.text :spec_expectation
      t.text :actual_state
      t.json :files_examined, default: []
      t.json :affected_tasks, default: []
      t.string :recommendation
      t.string :resolution
      t.datetime :resolved_at
      t.text :notes
      t.timestamps
    end

    add_index :arnold_pipeline_drift_findings, [:pipeline_run_id, :domain]
    add_index :arnold_pipeline_drift_findings, [:pipeline_run_id, :resolution]
  end
end
