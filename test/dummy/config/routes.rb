Rails.application.routes.draw do
  mount ArnoldPipeline::Engine => "/arnold_pipeline"
end
