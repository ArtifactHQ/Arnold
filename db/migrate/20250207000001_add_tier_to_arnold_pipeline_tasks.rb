class AddTierToArnoldPipelineTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :arnold_pipeline_tasks, :tier, :integer
  end
end
