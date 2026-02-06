class AddResultCommentsToArnoldPipelineTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :arnold_pipeline_tasks, :result_comments, :json, default: []
  end
end
