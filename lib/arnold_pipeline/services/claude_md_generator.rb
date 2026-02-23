module ArnoldPipeline
  module Services
    class ClaudeMdGenerator
      def self.call(persona:, recipe:, domain_type:, repo_path: nil)
        new(persona:, recipe:, domain_type:, repo_path:).generate
      end

      def initialize(persona:, recipe:, domain_type:, repo_path: nil)
        @persona = persona
        @recipe = recipe
        @domain_type = domain_type
        @repo_path = repo_path
      end

      def generate
        sections = []
        sections << "# Project Instructions"
        sections << tech_stack_section
        sections << conventions_section
        sections << testing_section
        sections << domain_context_section
        sections << terminology_section
        sections << watch_for_section
        sections << schema_section
        sections << routes_section
        sections << gemfile_section

        sections.compact.join("\n\n")
      end

      private

      def tech_stack_section
        framework = @recipe&.framework
        return nil if framework.nil? || framework.empty?

        lines = framework.map { |key, value| "- **#{key.capitalize}:** #{value}" }
        "## Tech Stack\n\n#{lines.join("\n")}"
      end

      def conventions_section
        return nil unless @recipe&.sections&.any?

        guidance_items = @recipe.sections
          .select { |s| s["phase"] == "pipeline" }
          .flat_map { |s| s["guidance"] || [] }
          .compact

        return nil if guidance_items.empty?

        lines = guidance_items.map { |g| "- #{g}" }
        "## Conventions\n\n#{lines.join("\n")}"
      end

      def testing_section
        verification = @recipe&.verification
        return nil if verification.nil? || verification.empty?

        lines = []
        lines << "- **Test command:** #{verification["test_command"]}" if verification["test_command"]

        if (setup = verification["setup_commands"])&.any?
          lines << "- **Setup:** #{setup.join(", ")}"
        end

        lines << "- **Boot command:** #{verification["boot_command"]}" if verification["boot_command"]

        if (checks = verification["health_checks"])&.any?
          checks.each do |check|
            lines << "- **Health check:** GET #{check["url"]} → #{check["expected_status"]}"
          end
        end

        return nil if lines.empty?

        "## Testing\n\n#{lines.join("\n")}"
      end

      def domain_context_section
        return nil unless @domain_type

        lines = []
        lines << "- **Domain:** #{@domain_type.name}"
        lines << "- **Primary value:** #{@domain_type.primary_value}" if @domain_type.primary_value&.present?

        if @domain_type.emphasis&.any?
          lines << "- **Priorities:**"
          @domain_type.emphasis.each { |e| lines << "  - #{e}" }
        end

        "## Domain Context\n\n#{lines.join("\n")}"
      end

      def terminology_section
        return nil unless @domain_type&.terminology&.any?

        lines = @domain_type.terminology.map { |from, to| "- #{from} → #{to}" }
        "## Terminology\n\n#{lines.join("\n")}"
      end

      def watch_for_section
        return nil unless @domain_type&.watch_for&.any?

        lines = @domain_type.watch_for.map { |w| "- #{w}" }
        "## Watch For\n\n#{lines.join("\n")}"
      end

      def schema_section
        return nil unless @repo_path

        path = File.join(@repo_path, "db", "schema.rb")
        return nil unless File.exist?(path)

        content = File.read(path)
        lines = content.lines.reject do |line|
          line.match?(/\A\s*(ActiveRecord::Schema|enable_extension|#)/) ||
            line.match?(/\bt\.index\b/) ||
            line.match?(/\A\s{0,2}end\s*\z/)
        end
        cleaned = lines.join.strip
        return nil if cleaned.empty?

        "## Current Database Schema\n\n```ruby\n#{cleaned}\n```"
      end

      def routes_section
        return nil unless @repo_path

        path = File.join(@repo_path, "config", "routes.rb")
        return nil unless File.exist?(path)

        content = File.read(path).strip
        return nil if content.empty?

        "## Current Routes\n\n```ruby\n#{content}\n```"
      end

      def gemfile_section
        return nil unless @repo_path

        path = File.join(@repo_path, "Gemfile")
        return nil unless File.exist?(path)

        lines = File.readlines(path).reject { |l| l.strip.start_with?("#") || l.strip.empty? }
        cleaned = lines.join.strip
        return nil if cleaned.empty?

        "## Current Gemfile\n\n```ruby\n#{cleaned}\n```"
      end
    end
  end
end
