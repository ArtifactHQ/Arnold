require_relative "base"

module ArnoldPipeline
  module Mcp
    module Tools
      class ExplainRecipe < Base
        def self.tool_name
          "explain_recipe"
        end

        def self.description
          "Deep dive into a specific recipe from the library. Returns its purpose, what it provides, " \
            "framework configuration, trade-offs compared to alternatives, and selection rationale."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              recipe: {
                type: "string",
                description: "Recipe name to look up (e.g. 'Web App', 'API Service')."
              },
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Used to explain why this recipe was selected. Defaults to the latest run."
              }
            },
            required: %w[recipe]
          }
        end

        def self.call(params, context)
          recipe_name = params["recipe"]
          return { error: "recipe is required" } if recipe_name.nil? || recipe_name.strip.empty?

          run_id = params["run_id"]
          library_manager = context.library_manager

          # Exact match first, then fuzzy
          recipe = library_manager.all_recipes.find { |r|
            r.name.downcase == recipe_name.downcase
          }

          unless recipe
            fuzzy = library_manager.find_recipe(recipe_name)
            # find_recipe always returns a fallback (Generic). Only accept it if
            # the fuzzy result has keyword overlap with the input, or if the input
            # matches the recipe name. Otherwise, treat as not found.
            if fuzzy && keyword_match?(fuzzy, recipe_name)
              recipe = fuzzy
            else
              available = library_manager.all_recipes.map(&:name).join(", ")
              return {
                error: "Recipe '#{recipe_name}' not found. Available recipes: #{available}"
              }
            end
          end

          # Build response from recipe data
          purpose = recipe.description.to_s.strip
          provides = extract_provides(recipe)
          configuration = extract_configuration(recipe)
          trade_offs = build_trade_offs(recipe, library_manager)
          rationale = build_rationale(recipe, context, run_id)

          {
            recipe: recipe.name,
            purpose: purpose,
            provides: provides,
            rationale: rationale,
            trade_offs: trade_offs,
            configuration: configuration
          }
        end

        private_class_method def self.keyword_match?(recipe, input)
          input_words = input.downcase.scan(/[a-z0-9]+/)
          recipe.keywords.any? { |kw| input_words.include?(kw.downcase) }
        end

        private_class_method def self.extract_provides(recipe)
          provides = []

          if recipe.sections.is_a?(Array)
            recipe.sections.each do |section|
              if section.is_a?(Hash)
                name = section["name"] || section[:name]
                desc = section["description"] || section[:description]
                phase = section["phase"] || section[:phase]
                if name
                  entry = name.to_s
                  entry += " (#{phase})" if phase && phase.to_s != "pipeline"
                  provides << entry
                end
              else
                provides << section.to_s
              end
            end
          end

          provides
        end

        private_class_method def self.extract_configuration(recipe)
          config = {}

          if recipe.framework.is_a?(Hash)
            recipe.framework.each do |key, value|
              config[key.to_s] = value.to_s
            end
          end

          if recipe.verification.is_a?(Hash)
            recipe.verification.each do |key, value|
              config["verification_#{key}"] = value.is_a?(Array) ? value.join(", ") : value.to_s
            end
          end

          config
        end

        private_class_method def self.build_trade_offs(recipe, library_manager)
          trade_offs = []
          all_recipes = library_manager.all_recipes

          all_recipes.each do |other|
            next if other.name == recipe.name
            next if other.name == "Generic" || other.type == "generic"

            unique_self = (recipe.keywords - other.keywords).first(3)
            unique_other = (other.keywords - recipe.keywords).first(3)

            self_focus = unique_self.any? ? unique_self.join(", ") : recipe.keywords.first(3).join(", ")
            other_focus = unique_other.any? ? unique_other.join(", ") : other.keywords.first(3).join(", ")

            trade_offs << "vs #{other.name}: #{recipe.name} is preferred when the focus is on " \
                         "#{self_focus} features; " \
                         "#{other.name} is better for #{other_focus}"
          end

          trade_offs
        end

        private_class_method def self.build_rationale(recipe, context, run_id)
          run = context.pipeline_run(run_id: run_id)
          return "No pipeline run available for selection context." unless run

          selections = run.metadata&.dig("library_selections") || {}
          selected_recipe = selections["recipe"]
          supporting = selections["supporting_recipes"] || []

          if selected_recipe&.downcase == recipe.name.downcase
            "Selected as the primary recipe for this pipeline run based on natural language input: '#{run.nl_input.to_s.truncate(100)}'."
          elsif supporting.any? { |s| s.downcase == recipe.name.downcase }
            "Selected as a supporting recipe for this pipeline run. Primary recipe: #{selected_recipe}."
          else
            "This recipe was not selected for pipeline run ##{run.id}. " \
              "The selected recipe was '#{selected_recipe || 'none'}'."
          end
        end
      end
    end
  end
end
