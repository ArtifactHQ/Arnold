class AddAcceptanceCriteriaToArnoldPipelineTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :arnold_pipeline_tasks, :acceptance_criteria, :json, default: []
  end
end
