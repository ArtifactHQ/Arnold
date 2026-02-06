require "rails/generators"
require "rails/generators/active_record"

module ArnoldPipeline
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Install Arnold Pipeline: copy migrations, create initializer, mount engine"

      def copy_migrations
        rake "arnold_pipeline:install:migrations"
      end

      def create_initializer
        template "initializer.rb", "config/initializers/arnold_pipeline.rb"
      end

      def mount_engine
        route 'mount ArnoldPipeline::Engine => "/arnold"'
      end

      def print_next_steps
        say ""
        say "Arnold Pipeline installed!", :green
        say ""
        say "Next steps:", :yellow
        say "  1. Run migrations:     rails db:migrate"
        say "  2. Set environment variables:"
        say "       ANTHROPIC_API_KEY=your-key"
        say "       GITHUB_TOKEN=your-token"
        say "  3. Update config/initializers/arnold_pipeline.rb"
        say "  4. Start using: ArnoldPipeline::Orchestrator.new.call(nl_input: 'Build a todo app')"
        say ""
      end
    end
  end
end
