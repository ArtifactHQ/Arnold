require_relative "lib/arnold_pipeline/version"

Gem::Specification.new do |spec|
  spec.name        = "arnold_pipeline"
  spec.version     = ArnoldPipeline::VERSION
  spec.authors     = [ "Arnold Pipeline Contributors" ]
  spec.email       = [ "arnold@example.com" ]
  spec.homepage    = "https://github.com/ArtifactHQ/Arnold"
  spec.summary     = "Agentic workflow system that transforms natural language into executable code"
  spec.description = "A Rails 8 mountable engine that orchestrates AI agents to generate specs, break down tasks, execute via GitHub, and iteratively refine code from natural language descriptions."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,exe,lib,library}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.bindir = "exe"
  spec.executables = [ "arnold" ]

  spec.required_ruby_version = ">= 4.0"

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "thor", "~> 1.3"
  spec.add_dependency "ruby-anthropic", "~> 0.4"
  spec.add_dependency "ruby-openai", "~> 7.0"
  spec.add_dependency "octokit", "~> 9.0"
  spec.add_dependency "faraday-retry", "~> 2.0"
  spec.add_dependency "tty-prompt", "~> 0.23"
end
