class AddExecutionMetadataToArnoldPipelineTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :arnold_pipeline_tasks, :execution_metadata, :json, default: {}
  end
end
