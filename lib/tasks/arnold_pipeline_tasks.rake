namespace :mutant do
  desc "Run full mutation testing"
  task :run do
    sh "bundle exec mutant run --use minitest"
  end

  desc "Run mutation testing on changed files since master"
  task :incremental do
    sh "bundle exec mutant run --use minitest --since master"
  end

  desc "Run mutation testing on a specific class"
  task :class, [:name] do |_t, args|
    abort "Usage: rake mutant:class[ArnoldPipeline::ClassName]" unless args[:name]
    sh "bundle exec mutant run --use minitest '#{args[:name]}'"
  end
end
