class CreateArnoldPipelineTables < ActiveRecord::Migration[8.0]
  def change
    create_table :arnold_pipeline_pipeline_runs do |t|
      t.text    :nl_input,  null: false
      t.integer :status,    null: false, default: 0
      t.json    :metadata
      t.timestamps
    end

    create_table :arnold_pipeline_specifications do |t|
      t.references :pipeline_run, null: false, foreign_key: { to_table: :arnold_pipeline_pipeline_runs }
      t.text    :content,         null: false
      t.json    :structured_data
      t.integer :version,         null: false, default: 1
      t.timestamps
    end

    create_table :arnold_pipeline_tasks do |t|
      t.references :pipeline_run, null: false, foreign_key: { to_table: :arnold_pipeline_pipeline_runs }
      t.string  :title,       null: false
      t.text    :description
      t.integer :priority,    default: 0
      t.json    :labels,      default: []
      t.integer :position,    null: false
      t.json    :depends_on,  default: []
      t.integer :status,      null: false, default: 0
      t.string  :external_id
      t.string  :external_url
      t.text    :result_diff
      t.timestamps
    end

    create_table :arnold_pipeline_iterations do |t|
      t.references :pipeline_run, null: false, foreign_key: { to_table: :arnold_pipeline_pipeline_runs }
      t.integer :number,             null: false
      t.string  :decision
      t.integer :confidence
      t.boolean :needs_human_review, default: false
      t.text    :reasoning
      t.json    :execution_results
      t.json    :corrective_data
      t.timestamps
    end
  end
end
