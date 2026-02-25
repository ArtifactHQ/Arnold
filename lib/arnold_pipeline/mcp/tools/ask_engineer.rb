require_relative "base"
require "arnold_pipeline/agents/base_agent"

module ArnoldPipeline
  module Mcp
    module Tools
      class AskEngineer < Base
        SYSTEM_PROMPT = <<~PROMPT
          You are an opinionated senior software architect reviewing a project specification.
          You give direct, confident answers grounded in the spec and recipe details provided.
          When answering questions:
          - Reference specific recipes and their guidance when relevant
          - Explain the rationale behind architectural decisions
          - Discuss trade-offs honestly — mention what was considered and rejected
          - Cite constraints from the spec (tech stack, framework choices, etc.)
          - If the spec doesn't cover something, say so and give your best recommendation

          Respond with a JSON object matching this exact schema:
          {
            "answer": "Your detailed answer to the question",
            "recipes_referenced": [{"name": "Recipe Name", "relevance": "Why this recipe matters here"}],
            "constraints": ["Constraint from spec or recipe that applies"],
            "alternatives_considered": [{"approach": "Alternative approach", "reason_rejected": "Why it was not chosen"}]
          }
        PROMPT

        RESPONSE_SCHEMA = {
          name: "engineer_answer",
          schema: {
            type: "object",
            properties: {
              answer: { type: "string" },
              recipes_referenced: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    name: { type: "string" },
                    relevance: { type: "string" }
                  },
                  required: %w[name relevance]
                }
              },
              constraints: {
                type: "array",
                items: { type: "string" }
              },
              alternatives_considered: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    approach: { type: "string" },
                    reason_rejected: { type: "string" }
                  },
                  required: %w[approach reason_rejected]
                }
              }
            },
            required: %w[answer recipes_referenced constraints alternatives_considered]
          }
        }.freeze

        def self.tool_name
          "ask_engineer"
        end

        def self.description
          "Ask a technical question about the project as if consulting an opinionated architect. " \
            "Returns an answer grounded in the spec, recipes, and architectural constraints."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              question: {
                type: "string",
                description: "The technical question to ask the architect."
              },
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Defaults to the latest run if not provided."
              }
            },
            required: %w[question]
          }
        end

        def self.call(params, context)
          question = params["question"]
          return { error: "question is required" } if question.nil? || question.strip.empty?

          run_id = params["run_id"]
          run = context.pipeline_run(run_id: run_id)
          unless run
            return { error: "No pipeline run found" }
          end

          spec = run.specification
          unless spec
            return { error: "No specification found for pipeline run ##{run.id}" }
          end

          library_manager = context.library_manager
          selections = run.metadata&.dig("library_selections") || {}

          recipe = resolve_recipe(library_manager, selections["recipe"])
          supporting_recipes = resolve_supporting_recipes(library_manager, selections["supporting_recipes"])
          persona = resolve_persona(library_manager, selections["persona"])

          user_context = build_user_context(question, spec, recipe, supporting_recipes, persona)

          ask_llm(user_context, spec, recipe, supporting_recipes)
        rescue => e
          # Best-effort fallback when LLM is unavailable
          build_fallback_response(question, spec, recipe, supporting_recipes)
        end

        private_class_method def self.resolve_recipe(library_manager, recipe_name)
          return nil unless recipe_name

          library_manager.all_recipes.find { |r| r.name.downcase == recipe_name.downcase } ||
            library_manager.find_recipe(recipe_name)
        end

        private_class_method def self.resolve_supporting_recipes(library_manager, recipe_names)
          return [] unless recipe_names.is_a?(Array)

          all = library_manager.all_recipes
          recipe_names.filter_map { |name|
            all.find { |r| r.name.downcase == name.downcase }
          }
        end

        private_class_method def self.resolve_persona(library_manager, persona_name)
          return nil unless persona_name

          library_manager.all_personas.find { |p| p.name.downcase == persona_name.downcase }
        end

        private_class_method def self.build_user_context(question, spec, recipe, supporting_recipes, persona)
          parts = []
          parts << "## Question\n#{question}"
          parts << "## Specification\n#{spec.content}"

          if recipe
            parts << "## Primary Recipe: #{recipe.name}\n#{recipe.description}"
            if recipe.framework.is_a?(Hash) && recipe.framework.any?
              parts << "### Framework\n#{recipe.framework.map { |k, v| "- #{k}: #{v}" }.join("\n")}"
            end
            if recipe.sections.is_a?(Array) && recipe.sections.any?
              section_list = recipe.sections.map { |s|
                name = s.is_a?(Hash) ? (s["name"] || s[:name]) : s.to_s
                desc = s.is_a?(Hash) ? (s["description"] || s[:description]) : nil
                desc ? "- #{name}: #{desc}" : "- #{name}"
              }.join("\n")
              parts << "### Recipe Sections\n#{section_list}"
            end
          end

          supporting_recipes.each do |sr|
            parts << "## Supporting Recipe: #{sr.name}\n#{sr.description}"
          end

          if persona
            parts << "## Persona: #{persona.name} (#{persona.role})\n#{persona.description}"
          end

          parts.join("\n\n")
        end

        private_class_method def self.ask_llm(user_context, spec, recipe, supporting_recipes)
          llm = Providers::Llm.build
          agent = Agents::BaseAgent.new(llm: llm, logger: Logger.new(File::NULL))

          result = agent.send(:chat_json,
            messages: [{ role: "user", content: user_context }],
            system: SYSTEM_PROMPT,
            schema: RESPONSE_SCHEMA
          )

          normalize_response(result)
        end

        private_class_method def self.normalize_response(result)
          {
            answer: result["answer"] || result[:answer] || "",
            recipes_referenced: (result["recipes_referenced"] || result[:recipes_referenced] || []).map { |r|
              { name: r["name"] || r[:name] || "", relevance: r["relevance"] || r[:relevance] || "" }
            },
            constraints: result["constraints"] || result[:constraints] || [],
            alternatives_considered: (result["alternatives_considered"] || result[:alternatives_considered] || []).map { |a|
              { approach: a["approach"] || a[:approach] || "", reason_rejected: a["reason_rejected"] || a[:reason_rejected] || "" }
            }
          }
        end

        private_class_method def self.build_fallback_response(question, spec, recipe, supporting_recipes)
          recipes_referenced = []
          constraints = []

          if recipe
            recipes_referenced << { name: recipe.name, relevance: "Primary recipe for this project" }
            if recipe.framework.is_a?(Hash)
              recipe.framework.each { |k, v| constraints << "#{k}: #{v}" }
            end
          end

          supporting_recipes&.each do |sr|
            recipes_referenced << { name: sr.name, relevance: "Supporting recipe" }
          end

          # Extract tech stack constraints from structured_data
          if spec&.structured_data.is_a?(Hash)
            tech_stack = spec.structured_data["tech_stack"] || spec.structured_data[:tech_stack]
            if tech_stack.is_a?(Hash)
              tech_stack.each { |k, v| constraints << "#{k}: #{v}" }
            end
          end

          {
            answer: "Based on the spec and recipe data: the project uses #{recipe&.name || 'no specific recipe'}. " \
                    "Refer to the specification for detailed requirements.",
            recipes_referenced: recipes_referenced,
            constraints: constraints,
            alternatives_considered: []
          }
        end
      end
    end
  end
end
