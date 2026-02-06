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

  create_table "arnold_pipeline_pipeline_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "metadata"
    t.text "nl_input", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
  end

  create_table "arnold_pipeline_specifications", force: :cascade do |t|
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.integer "pipeline_run_id", null: false
    t.json "structured_data"
    t.datetime "updated_at", null: false
    t.integer "version", default: 1, null: false
    t.index ["pipeline_run_id"], name: "index_arnold_pipeline_specifications_on_pipeline_run_id"
  end

  create_table "arnold_pipeline_tasks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "depends_on", default: []
    t.text "description"
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
    t.index ["pipeline_run_id"], name: "index_arnold_pipeline_tasks_on_pipeline_run_id"
  end

  add_foreign_key "arnold_pipeline_iterations", "arnold_pipeline_pipeline_runs", column: "pipeline_run_id"
  add_foreign_key "arnold_pipeline_specifications", "arnold_pipeline_pipeline_runs", column: "pipeline_run_id"
  add_foreign_key "arnold_pipeline_tasks", "arnold_pipeline_pipeline_runs", column: "pipeline_run_id"
end
