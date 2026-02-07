class AddWorkflowActiveToArnoldPipelineTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :arnold_pipeline_tasks, :workflow_active, :boolean, default: false, null: false
  end
end
