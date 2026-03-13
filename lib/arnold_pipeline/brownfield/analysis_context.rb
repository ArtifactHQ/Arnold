module ArnoldPipeline
  module Brownfield
    AnalysisContext = Data.define(
      :repo_path,
      :stack_fingerprint,
      :artifacts,
      :overlay,
      :file_manifest,
      :route_table,
      :git_activity,
      :test_names,
      :concerns,
      :reference_materials,
      :change_request
    )
  end
end
