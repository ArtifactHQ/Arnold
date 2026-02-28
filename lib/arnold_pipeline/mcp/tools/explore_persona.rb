require_relative "base"
require "arnold_pipeline/agents/base_agent"

module ArnoldPipeline
  module Mcp
    module Tools
      class ExplorePersona < Base
        SYSTEM_PROMPT = <<~PROMPT
          You are a product analyst examining a software product specification.
          Given a persona and the full spec, generate a detailed persona exploration.

          Respond with a JSON object matching this exact schema:
          {
            "journey": "A narrative description of this persona's experience with the product, from first encounter through regular use",
            "capabilities": [
              {
                "description": "What the persona can do",
                "domain": "Which product domain this capability belongs to",
                "status": "defined"
              }
            ],
            "pain_points": ["Problems this persona has that the product solves"]
          }
        PROMPT

        RESPONSE_SCHEMA = {
          name: "persona_exploration",
          schema: {
            type: "object",
            properties: {
              journey: { type: "string" },
              capabilities: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    description: { type: "string" },
                    domain: { type: "string" },
                    status: { type: "string" }
                  },
                  required: %w[description domain status]
                }
              },
              pain_points: {
                type: "array",
                items: { type: "string" }
              }
            },
            required: %w[journey capabilities pain_points]
          }
        }.freeze

        def self.tool_name
          "explore_persona"
        end

        def self.description
          "Drill into a specific persona's experience. Returns their journey, capabilities, " \
            "pain points, and which domains they touch."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              persona: {
                type: "string",
                description: "Persona name or natural language reference (e.g. 'Dog Walker')."
              },
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Defaults to the latest run if not provided."
              }
            },
            required: [ "persona" ]
          }
        end

        def self.call(params, context)
          persona_query = params["persona"].to_s.strip
          return { error: "persona is required" } if persona_query.empty?

          run_id = params["run_id"]
          run = context.pipeline_run(run_id: run_id)
          return { error: "No pipeline run found" } unless run

          spec = run.specification
          return { error: "No specification found for pipeline run ##{run.id}" } unless spec

          persona_info = find_persona(persona_query, spec)
          unless persona_info
            available = list_available_personas(spec)
            return {
              error: "Persona '#{persona_query}' not found",
              available_personas: available
            }
          end

          domains_involved = find_domains_for_persona(persona_info, spec)
          llm_result = explore_with_llm(persona_info, spec, domains_involved)

          {
            persona: persona_info[:name],
            description: persona_info[:description],
            journey: llm_result[:journey],
            capabilities: llm_result[:capabilities],
            pain_points: llm_result[:pain_points],
            domains_involved: domains_involved
          }
        end

        private_class_method def self.find_persona(query, spec)
          query_lower = query.downcase
          data = spec.structured_data
          return nil unless data.is_a?(Hash)

          personas = data["personas"] || data[:personas] || []

          # Exact match
          exact = personas.find { |p| name_of(p).downcase == query_lower }
          return persona_hash(exact) if exact

          # Partial match
          partial = personas.find { |p|
            name_of(p).downcase.include?(query_lower) || query_lower.include?(name_of(p).downcase)
          }
          return persona_hash(partial) if partial

          nil
        end

        private_class_method def self.name_of(persona)
          if persona.is_a?(Hash)
            (persona["name"] || persona[:name]).to_s
          else
            persona.to_s
          end
        end

        private_class_method def self.persona_hash(persona)
          return nil unless persona

          if persona.is_a?(Hash)
            {
              name: (persona["name"] || persona[:name]).to_s,
              description: (persona["description"] || persona[:description] || persona["role"] || persona[:role]).to_s,
              capabilities: Array(persona["capabilities"] || persona[:capabilities] || []),
              domains: Array(persona["domains"] || persona[:domains] || [])
            }
          else
            { name: persona.to_s, description: "", capabilities: [], domains: [] }
          end
        end

        private_class_method def self.list_available_personas(spec)
          data = spec.structured_data
          return [] unless data.is_a?(Hash)

          (data["personas"] || data[:personas] || []).map { |p| name_of(p) }
        end

        private_class_method def self.find_domains_for_persona(persona_info, spec)
          # First check explicit domain associations
          return persona_info[:domains] if persona_info[:domains].any?

          data = spec.structured_data || {}
          domains = data["domains"] || data[:domains] || []

          # If no explicit associations, check spec content for co-references
          persona_lower = persona_info[:name].downcase
          content = spec.content.to_s.downcase

          matching = domains.select { |d|
            domain_name = d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s
            # Check if persona and domain appear in same paragraph
            paragraphs = content.split(/\n\n+/)
            paragraphs.any? { |p| p.include?(persona_lower) && p.include?(domain_name.downcase) }
          }

          if matching.any?
            matching.map { |d| d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s }
          else
            # Return all domain names as a fallback
            domains.map { |d| d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s }
          end
        end

        private_class_method def self.explore_with_llm(persona_info, spec, domains_involved)
          llm = Providers::Llm.build
          agent = Agents::BaseAgent.new(llm: llm, logger: Logger.new(File::NULL))

          user_content = build_user_content(persona_info, spec, domains_involved)

          result = agent.send(:chat_json,
            messages: [ { role: "user", content: user_content } ],
            system: SYSTEM_PROMPT,
            schema: RESPONSE_SCHEMA
          )

          normalize_llm_result(result)
        rescue => e
          # Fallback: return basic info without LLM narrative
          build_fallback_result(persona_info, domains_involved)
        end

        private_class_method def self.build_user_content(persona_info, spec, domains_involved)
          parts = []
          parts << "## Persona: #{persona_info[:name]}"
          parts << "Description: #{persona_info[:description]}" if persona_info[:description].present?
          parts << "Known capabilities: #{persona_info[:capabilities].join(', ')}" if persona_info[:capabilities].any?
          parts << "Domains involved: #{domains_involved.join(', ')}" if domains_involved.any?
          parts << "\n## Full Specification\n#{spec.content}"
          parts.join("\n")
        end

        private_class_method def self.normalize_llm_result(result)
          {
            journey: result["journey"] || result[:journey] || "",
            capabilities: (result["capabilities"] || result[:capabilities] || []).map { |c|
              {
                description: c["description"] || c[:description] || "",
                domain: c["domain"] || c[:domain] || "",
                status: c["status"] || c[:status] || "defined"
              }
            },
            pain_points: result["pain_points"] || result[:pain_points] || []
          }
        end

        private_class_method def self.build_fallback_result(persona_info, domains_involved)
          capabilities = persona_info[:capabilities].map { |cap|
            { description: cap, domain: domains_involved.first.to_s, status: "defined" }
          }

          {
            journey: "#{persona_info[:name]} uses the product to #{persona_info[:capabilities].first || 'interact with the system'}.",
            capabilities: capabilities,
            pain_points: []
          }
        end
      end
    end
  end
end
