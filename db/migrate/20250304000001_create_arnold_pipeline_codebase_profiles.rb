class CreateArnoldPipelineCodebaseProfiles < ActiveRecord::Migration[8.0]
  def change
    create_table :arnold_pipeline_codebase_profiles do |t|
      t.references :pipeline_run, null: false, foreign_key: { to_table: :arnold_pipeline_pipeline_runs }
      t.string :project_name
      t.json :stack_fingerprint
      t.json :recipe_alignment
      t.json :conventions
      t.json :documentation_fidelity
      t.json :health_baseline
      t.json :change_surface
      t.json :scan_data
      t.json :feature_inventories
      t.integer :confidence
      t.integer :token_budget_used
      t.datetime :analyzed_at

      t.timestamps
    end
  end
end
