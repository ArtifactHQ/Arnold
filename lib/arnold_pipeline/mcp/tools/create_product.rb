require_relative "base"
require "arnold_pipeline/orchestrator"

module ArnoldPipeline
  module Mcp
    module Tools
      class CreateProduct < Base
        def self.tool_name
          "create_product"
        end

        def self.description
          "Start a new pipeline from a natural language idea. Arnold runs its full spec generation " \
            "pipeline — persona matching, recipe selection, domain identification — and returns a " \
            "product-level overview. This is the conversational entry point for new products."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              description: {
                type: "string",
                description: "Natural language description of the product to create " \
                  "(e.g. 'a dog walking app where walkers find clients nearby')."
              }
            },
            required: ["description"]
          }
        end

        def self.call(params, context)
          description = params["description"].to_s.strip
          return { error: "description is required" } if description.empty?
          if description.length < 10
            return { error: "Please provide a more detailed description (at least 10 characters)" }
          end

          orchestrator = ArnoldPipeline::Orchestrator.new(logger: Logger.new(File::NULL))
          pipeline_run = orchestrator.call(nl_input: description, stop_after: :spec)

          spec = pipeline_run.specification
          build_response(pipeline_run, spec)
        rescue => e
          { error: "Failed to create product: #{e.message}" }
        end

        private_class_method def self.build_response(pipeline_run, spec)
          data = spec&.structured_data || {}

          {
            run_id: pipeline_run.id.to_s,
            product_name: extract_product_name(data, spec, pipeline_run),
            summary: extract_summary(data, spec, pipeline_run),
            personas: extract_personas(data),
            domains: extract_domains(data),
            recipes_selected: extract_recipes(pipeline_run),
            revision: spec&.version.to_s,
            open_questions: extract_open_questions(data)
          }
        end

        private_class_method def self.extract_product_name(data, spec, run)
          name = data["product_name"] || data[:product_name] ||
                 data["name"] || data[:name] ||
                 data["title"] || data[:title]
          return name.to_s if name.present?

          first_heading = spec&.content.to_s.lines.find { |l| l.match?(/^#\s/) }
          if first_heading
            first_heading.sub(/^#+\s*/, "").strip
          else
            run.nl_input.to_s.truncate(80)
          end
        end

        private_class_method def self.extract_summary(data, spec, run)
          summary = data["summary"] || data[:summary] ||
                    data["description"] || data[:description]
          return summary.to_s if summary.present?

          content = spec&.content.to_s
          purpose_match = content.match(/##\s*Purpose\s*\n(.*?)(?=\n##|\z)/m)
          if purpose_match
            purpose_match[1].strip.truncate(500)
          else
            "Product based on: #{run.nl_input.to_s.truncate(200)}"
          end
        end

        private_class_method def self.extract_personas(data)
          personas = data["personas"] || data[:personas] || []
          personas.map { |p|
            if p.is_a?(Hash)
              {
                name: (p["name"] || p[:name]).to_s,
                description: (p["description"] || p[:description] || p["role"] || p[:role]).to_s
              }
            else
              { name: p.to_s, description: "" }
            end
          }
        end

        private_class_method def self.extract_domains(data)
          domains = data["domains"] || data[:domains] || []
          domains.map { |d|
            if d.is_a?(Hash)
              {
                name: (d["name"] || d[:name]).to_s,
                description: (d["description"] || d[:description]).to_s
              }
            else
              { name: d.to_s, description: "" }
            end
          }
        end

        private_class_method def self.extract_recipes(pipeline_run)
          selections = pipeline_run.metadata&.dig("library_selections") || {}
          recipes = []

          if selections["recipe"]
            recipes << { name: selections["recipe"], purpose: "Primary recipe" }
          end

          Array(selections["supporting_recipes"]).each do |name|
            recipes << { name: name, purpose: "Supporting recipe" }
          end

          recipes
        end

        private_class_method def self.extract_open_questions(data)
          questions = data["open_questions"] || data[:open_questions]
          return Array(questions) if questions.present?

          # Check for ambiguities or unknowns flagged in the spec
          ambiguities = data["ambiguities"] || data[:ambiguities] || []
          Array(ambiguities)
        end
      end
    end
  end
end
