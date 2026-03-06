require "yaml"
require "logger"
require_relative "persona"
require_relative "recipe"
require_relative "domain_type"

module ArnoldPipeline
  module Library
    class Manager
      FALLBACK_PERSONA = "general_analyst"
      FALLBACK_RECIPE = "generic"
      FALLBACK_DOMAIN_TYPE = "generic"

      def initialize(library_path: nil, logger: nil)
        @library_path = library_path || default_library_path
        @logger = logger || Logger.new($stdout, level: Logger::WARN)
        @personas = {}
        @recipes = {}
        @domain_types = {}
        load_all
      end

      def find_persona(nl_input)
        best = best_match(@personas.values, nl_input)
        unless best
          @logger.warn { "Library: No persona matched input '#{nl_input.truncate(50)}', falling back to generic" }
        end
        best || @personas[FALLBACK_PERSONA] || @personas.values.first
      end

      def find_recipe(nl_input)
        best = best_match(@recipes.values, nl_input)
        unless best
          @logger.warn { "Library: No recipe matched input '#{nl_input.truncate(50)}', falling back to generic" }
        end
        best || fallback_recipe
      end

      def find_recipes(nl_input)
        input_words = tokenize(nl_input)
        return { primary: fallback_recipe, supporting: [] } if input_words.empty?

        scored = @recipes.values.map do |recipe|
          score = recipe.keywords.count { |kw| input_words.include?(kw.downcase) }
          [ recipe, score ]
        end.select { |_, score| score > 0 }
          .sort_by { |_, score| -score }

        return { primary: fallback_recipe, supporting: [] } if scored.empty?

        primary = scored.first.first
        threshold = (scored.first.last / 2.0).ceil
        supporting = scored[1..].select { |_, score| score >= threshold }.map(&:first)

        { primary:, supporting: }
      end

      def find_domain_type(nl_input)
        best = best_match(@domain_types.values, nl_input)
        unless best
          @logger.warn { "Library: No domain type matched input '#{nl_input.truncate(50)}', falling back to generic" }
        end
        best || @domain_types[FALLBACK_DOMAIN_TYPE] || @domain_types.values.first
      end

      def all_personas
        @personas.values
      end

      def all_recipes
        @recipes.values
      end

      def all_domain_types
        @domain_types.values
      end

      private

      def default_library_path
        File.expand_path("../../../library", __dir__)
      end

      def load_all
        load_personas
        load_recipes
        load_domain_types
      end

      def load_personas
        Dir.glob(File.join(@library_path, "personas", "*.yml")).each do |path|
          data = YAML.safe_load_file(path, permitted_classes: [ Symbol ])
          key = File.basename(path, ".yml")
          @personas[key] = Persona.new(
            name: data["name"],
            role: data["role"],
            keywords: data["keywords"] || [],
            description: data["description"]&.strip,
            system_prompt: data["system_prompt"]&.strip
          )
        end
      end

      def load_recipes
        Dir.glob(File.join(@library_path, "recipes", "*.yml")).each do |path|
          data = YAML.safe_load_file(path, permitted_classes: [ Symbol ])
          key = File.basename(path, ".yml")
          @recipes[key] = Recipe.new(
            name: data["name"],
            type: data["type"],
            keywords: data["keywords"] || [],
            description: data["description"]&.strip,
            framework: data["framework"] || {},
            sections: data["sections"] || [],
            verification: data["verification"] || {},
            finalization: data["finalization"] || {}
          )
        end
      end

      def load_domain_types
        Dir.glob(File.join(@library_path, "domain_types", "*.yml")).each do |path|
          data = YAML.safe_load_file(path, permitted_classes: [ Symbol ])
          key = File.basename(path, ".yml")
          @domain_types[key] = DomainType.new(
            code: data["code"],
            name: data["name"],
            keywords: data["keywords"] || [],
            description: data["description"]&.strip,
            primary_value: data["primary_value"]&.strip,
            emphasis: data["emphasis"] || [],
            document_focus: data["document_focus"] || [],
            watch_for: data["watch_for"] || [],
            terminology: data["terminology"] || {}
          )
        end
      end

      def fallback_recipe
        @recipes[FALLBACK_RECIPE] || @recipes.values.first
      end

      def best_match(items, nl_input)
        input_words = tokenize(nl_input)
        return nil if input_words.empty?

        scored = items.map do |item|
          score = item.keywords.count { |kw| input_words.include?(kw.downcase) }
          [ item, score ]
        end

        best = scored.max_by(&:last)
        best && best.last > 0 ? best.first : nil
      end

      def tokenize(text)
        text.downcase.scan(/[a-z0-9]+/)
      end
    end
  end
end
