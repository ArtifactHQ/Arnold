namespace :arnold do
  desc "Initialize a new project: rake arnold:setup[/path/to/project,'project description']"
  task :setup, [ :path, :description ] do |_t, args|
    require "arnold_pipeline/setup/orchestrator"

    request = ArnoldPipeline::Setup::Request.new(
      project_path: args[:path],
      description: args[:description],
      llm_api_key: ENV["ANTHROPIC_API_KEY"] || ENV["OPENAI_API_KEY"]
    )

    orchestrator = ArnoldPipeline::Setup::Orchestrator.new
    result = orchestrator.call(request)

    case result.status
    when :needs_input
      puts "Missing required fields: #{result.missing_fields.join(', ')}"
      abort "Provide all required arguments: rake arnold:setup[path,description]"
    when :error
      result.errors.each { |e| puts "Error: #{e}" }
      abort "Setup failed"
    when :complete
      puts "Project initialized at #{result.project_path}"
      puts "Config written to #{result.config_path}"
      puts "Run ID: #{result.run_id}"
      puts "Tasks: #{result.task_summary[:total]} across #{result.task_summary[:tiers]} tiers" if result.task_summary
    end
  end
end

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
  task :class, [ :name ] do |_t, args|
    abort "Usage: rake mutant:class[ArnoldPipeline::ClassName]" unless args[:name]
    sh "bundle exec mutant run --use minitest '#{args[:name]}'"
  end
end
