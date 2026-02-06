require "yaml"
require_relative "persona"
require_relative "recipe"

module ArnoldPipeline
  module Library
    class Manager
      FALLBACK_PERSONA = "general_analyst"
      FALLBACK_RECIPE = "generic"

      def initialize(library_path: nil)
        @library_path = library_path || default_library_path
        @personas = {}
        @recipes = {}
        load_all
      end

      def find_persona(nl_input)
        best = best_match(@personas.values, nl_input)
        best || @personas[FALLBACK_PERSONA] || @personas.values.first
      end

      def find_recipe(nl_input)
        best = best_match(@recipes.values, nl_input)
        best || @recipes[FALLBACK_RECIPE] || @recipes.values.first
      end

      def all_personas
        @personas.values
      end

      def all_recipes
        @recipes.values
      end

      private

      def default_library_path
        File.expand_path("../../../library", __dir__)
      end

      def load_all
        load_personas
        load_recipes
      end

      def load_personas
        Dir.glob(File.join(@library_path, "personas", "*.yml")).each do |path|
          data = YAML.safe_load_file(path, permitted_classes: [Symbol])
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
          data = YAML.safe_load_file(path, permitted_classes: [Symbol])
          key = File.basename(path, ".yml")
          @recipes[key] = Recipe.new(
            name: data["name"],
            type: data["type"],
            keywords: data["keywords"] || [],
            description: data["description"]&.strip,
            sections: data["sections"] || []
          )
        end
      end

      def best_match(items, nl_input)
        input_words = tokenize(nl_input)
        return nil if input_words.empty?

        scored = items.map do |item|
          score = item.keywords.count { |kw| input_words.include?(kw.downcase) }
          [item, score]
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
