# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_02_06_165310) do
  create_table "arnold_pipeline_codebase_profiles", force: :cascade do |t|
    t.datetime "analyzed_at"
    t.json "change_surface"
    t.integer "confidence"
    t.json "conventions"
    t.datetime "created_at", null: false
    t.json "documentation_fidelity"
    t.json "feature_inventories"
    t.json "health_baseline"
    t.integer "pipeline_run_id", null: false
    t.string "project_name"
    t.json "recipe_alignment"
    t.json "scan_data"
    t.json "stack_fingerprint"
    t.integer "token_budget_used"
    t.datetime "updated_at", null: false
    t.index ["pipeline_run_id"], name: "index_arnold_pipeline_codebase_profiles_on_pipeline_run_id"
  end

  create_table "arnold_pipeline_drift_findings", force: :cascade do |t|
    t.text "actual_state"
    t.json "affected_tasks", default: []
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.string "domain"
    t.string "drift_type", null: false
    t.json "files_examined", default: []
    t.text "notes"
    t.integer "pipeline_run_id", null: false
    t.string "recommendation"
    t.string "resolution"
    t.datetime "resolved_at"
    t.string "severity", null: false
    t.text "spec_expectation"
    t.integer "spec_revision_id"
    t.datetime "updated_at", null: false
    t.index ["pipeline_run_id", "domain"], name: "idx_on_pipeline_run_id_domain_953a5aab63"
    t.index ["pipeline_run_id", "resolution"], name: "idx_on_pipeline_run_id_resolution_4a120365d1"
    t.index ["pipeline_run_id"], name: "index_arnold_pipeline_drift_findings_on_pipeline_run_id"
    t.index ["spec_revision_id"], name: "index_arnold_pipeline_drift_findings_on_spec_revision_id"
  end

  create_table "arnold_pipeline_iterations", force: :cascade do |t|
    t.integer "confidence"
    t.json "corrective_data"
    t.datetime "created_at", null: false
    t.string "decision"
    t.json "execution_results"
    t.boolean "needs_human_review", default: false
    t.integer "number", null: false
    t.integer "pipeline_run_id", null: false
    t.text "reasoning"
    t.datetime "updated_at", null: false
    t.index ["pipeline_run_id"], name: "index_arnold_pipeline_iterations_on_pipeline_run_id"
  end

  create_table "arnold_pipeline_pipeline_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "duration_ms"
    t.integer "event_type", null: false
    t.integer "iteration_number"
    t.json "payload"
    t.integer "pipeline_run_id", null: false
    t.string "stage", null: false
    t.json "summary", null: false
    t.integer "tier_number"
    t.datetime "updated_at", null: false
    t.index ["pipeline_run_id", "created_at"], name: "idx_pipeline_events_on_run_and_created_at"
    t.index ["pipeline_run_id", "stage"], name: "idx_pipeline_events_on_run_and_stage"
    t.index ["pipeline_run_id"], name: "index_arnold_pipeline_pipeline_events_on_pipeline_run_id"
  end

  create_table "arnold_pipeline_pipeline_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "metadata"
    t.text "nl_input", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
  end

  create_table "arnold_pipeline_spec_deltas", force: :cascade do |t|
    t.text "after_content"
    t.text "before_content"
    t.datetime "created_at", null: false
    t.integer "iteration_id", null: false
    t.string "operation", null: false
    t.text "rationale"
    t.string "requirement"
    t.string "section", null: false
    t.integer "specification_id", null: false
    t.datetime "updated_at", null: false
    t.index ["iteration_id"], name: "index_arnold_pipeline_spec_deltas_on_iteration_id"
    t.index ["specification_id"], name: "index_arnold_pipeline_spec_deltas_on_specification_id"
  end

  create_table "arnold_pipeline_spec_revisions", force: :cascade do |t|
    t.string "change_source"
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.json "delta_summary"
    t.integer "specification_id", null: false
    t.json "structured_data"
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["specification_id", "version"], name: "idx_spec_revisions_on_spec_and_version", unique: true
    t.index ["specification_id"], name: "index_arnold_pipeline_spec_revisions_on_specification_id"
  end

  create_table "arnold_pipeline_specifications", force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.integer "pipeline_run_id", null: false
    t.string "spec_type", default: "target", null: false
    t.json "structured_data"
    t.datetime "updated_at", null: false
    t.integer "version", default: 1, null: false
    t.index ["pipeline_run_id"], name: "index_arnold_pipeline_specifications_on_pipeline_run_id"
  end

  create_table "arnold_pipeline_tasks", force: :cascade do |t|
    t.json "acceptance_criteria", default: []
    t.datetime "created_at", null: false
    t.json "depends_on", default: []
    t.text "description"
    t.json "execution_metadata", default: {}
    t.string "external_id"
    t.string "external_url"
    t.json "labels", default: []
    t.integer "pipeline_run_id", null: false
    t.integer "position", null: false
    t.integer "priority", default: 0
    t.json "result_comments", default: []
    t.text "result_diff"
    t.integer "status", default: 0, null: false
    t.integer "tier"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.boolean "workflow_active", default: false, null: false
    t.index ["pipeline_run_id"], name: "index_arnold_pipeline_tasks_on_pipeline_run_id"
  end

  add_foreign_key "arnold_pipeline_codebase_profiles", "arnold_pipeline_pipeline_runs", column: "pipeline_run_id"
  add_foreign_key "arnold_pipeline_drift_findings", "arnold_pipeline_pipeline_runs", column: "pipeline_run_id"
  add_foreign_key "arnold_pipeline_drift_findings", "arnold_pipeline_spec_revisions", column: "spec_revision_id"
  add_foreign_key "arnold_pipeline_iterations", "arnold_pipeline_pipeline_runs", column: "pipeline_run_id"
  add_foreign_key "arnold_pipeline_pipeline_events", "arnold_pipeline_pipeline_runs", column: "pipeline_run_id"
  add_foreign_key "arnold_pipeline_spec_deltas", "arnold_pipeline_iterations", column: "iteration_id"
  add_foreign_key "arnold_pipeline_spec_deltas", "arnold_pipeline_specifications", column: "specification_id"
  add_foreign_key "arnold_pipeline_spec_revisions", "arnold_pipeline_specifications", column: "specification_id"
  add_foreign_key "arnold_pipeline_specifications", "arnold_pipeline_pipeline_runs", column: "pipeline_run_id"
  add_foreign_key "arnold_pipeline_tasks", "arnold_pipeline_pipeline_runs", column: "pipeline_run_id"
end
