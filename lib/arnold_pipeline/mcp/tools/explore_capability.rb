require_relative "base"
require "arnold_pipeline/agents/base_agent"

module ArnoldPipeline
  module Mcp
    module Tools
      class ExploreCapability < Base
        SYSTEM_PROMPT = <<~PROMPT
          You are a product analyst examining a software product specification.
          Given a capability reference and the full spec, identify the matching capability
          and generate a detailed exploration.

          Respond with a JSON object matching this exact schema:
          {
            "capability": "The canonical name of the matched capability",
            "domain": "Which product domain this belongs to",
            "description": "Detailed product-level description of this capability",
            "user_flow": "Step-by-step flow from the user's perspective",
            "personas_involved": ["Names of personas who use this capability"],
            "depends_on": ["Other capabilities this requires"],
            "enables": ["Other capabilities this unlocks"],
            "open_questions": ["Ambiguities or undefined aspects"]
          }
        PROMPT

        RESPONSE_SCHEMA = {
          name: "capability_exploration",
          schema: {
            type: "object",
            properties: {
              capability: { type: "string" },
              domain: { type: "string" },
              description: { type: "string" },
              user_flow: { type: "string" },
              personas_involved: {
                type: "array",
                items: { type: "string" }
              },
              depends_on: {
                type: "array",
                items: { type: "string" }
              },
              enables: {
                type: "array",
                items: { type: "string" }
              },
              open_questions: {
                type: "array",
                items: { type: "string" }
              }
            },
            required: %w[capability domain description user_flow personas_involved depends_on enables open_questions]
          }
        }.freeze

        def self.tool_name
          "explore_capability"
        end

        def self.description
          "Drill into a specific capability within a domain. Returns a detailed product-level " \
            "description, user flow, dependencies, and open questions."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              capability: {
                type: "string",
                description: "Natural language reference to a capability (e.g. 'walker matching', 'booking system')."
              },
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Defaults to the latest run if not provided."
              }
            },
            required: ["capability"]
          }
        end

        def self.call(params, context)
          capability_query = params["capability"].to_s.strip
          return { error: "capability is required" } if capability_query.empty?

          run_id = params["run_id"]
          run = context.pipeline_run(run_id: run_id)
          return { error: "No pipeline run found" } unless run

          spec = run.specification
          return { error: "No specification found for pipeline run ##{run.id}" } unless spec

          explore_with_llm(capability_query, spec)
        end

        private_class_method def self.explore_with_llm(capability_query, spec)
          llm = Providers::Llm.build
          agent = Agents::BaseAgent.new(llm: llm, logger: Logger.new(File::NULL))

          user_content = "## Capability Query\n#{capability_query}\n\n## Full Specification\n#{spec.content}"

          if spec.structured_data.is_a?(Hash)
            data = spec.structured_data
            if (domains = data["domains"] || data[:domains])
              user_content += "\n\n## Known Domains\n#{domains.map { |d| d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s }.join(', ')}"
            end
            if (personas = data["personas"] || data[:personas])
              user_content += "\n\n## Known Personas\n#{personas.map { |p| p.is_a?(Hash) ? (p["name"] || p[:name]).to_s : p.to_s }.join(', ')}"
            end
          end

          result = agent.send(:chat_json,
            messages: [{ role: "user", content: user_content }],
            system: SYSTEM_PROMPT,
            schema: RESPONSE_SCHEMA
          )

          normalize_result(result)
        rescue => e
          # Fallback: attempt keyword matching
          build_fallback_result(capability_query, spec)
        end

        private_class_method def self.normalize_result(result)
          {
            capability: result["capability"] || result[:capability] || "",
            domain: result["domain"] || result[:domain] || "",
            description: result["description"] || result[:description] || "",
            user_flow: result["user_flow"] || result[:user_flow] || "",
            personas_involved: result["personas_involved"] || result[:personas_involved] || [],
            depends_on: result["depends_on"] || result[:depends_on] || [],
            enables: result["enables"] || result[:enables] || [],
            open_questions: result["open_questions"] || result[:open_questions] || []
          }
        end

        private_class_method def self.build_fallback_result(capability_query, spec)
          query_lower = capability_query.downcase
          data = spec.structured_data || {}
          domains = data["domains"] || data[:domains] || []
          personas = data["personas"] || data[:personas] || []

          # Find the domain that best matches
          matched_domain = domains.find { |d|
            name = d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s
            desc = d.is_a?(Hash) ? (d["description"] || d[:description]).to_s : ""
            name.downcase.include?(query_lower) || query_lower.include?(name.downcase) ||
              desc.downcase.include?(query_lower)
          }

          domain_name = if matched_domain.is_a?(Hash)
            (matched_domain["name"] || matched_domain[:name]).to_s
          else
            matched_domain.to_s
          end

          persona_names = personas.map { |p| p.is_a?(Hash) ? (p["name"] || p[:name]).to_s : p.to_s }

          if domain_name.present?
            {
              capability: capability_query,
              domain: domain_name,
              description: "Capability related to #{domain_name}",
              user_flow: "",
              personas_involved: persona_names,
              depends_on: [],
              enables: [],
              open_questions: ["Detailed capability analysis unavailable — LLM fallback"]
            }
          else
            { error: "Could not find capability matching '#{capability_query}'" }
          end
        end
      end
    end
  end
end
