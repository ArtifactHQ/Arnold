# Eager-load all ArnoldPipeline classes so mutant can discover them as subjects.
# Rails eager_load! covers app/ (models, jobs), but lib/ classes use explicit require.
Rails.application.eager_load!

Dir[File.expand_path("../lib/arnold_pipeline/**/*.rb", __dir__)].each do |file|
  require file
end
