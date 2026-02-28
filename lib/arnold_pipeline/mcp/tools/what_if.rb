require_relative "base"
require "arnold_pipeline/agents/base_agent"

module ArnoldPipeline
  module Mcp
    module Tools
      class WhatIf < Base
        SYSTEM_PROMPT = <<~PROMPT
          You are a product strategist evaluating a hypothetical change to a software product.
          Given the current specification and a "what if" question, analyze the implications
          WITHOUT committing to any changes. This is purely exploratory analysis.

          Respond with a JSON object matching this exact schema:
          {
            "interpretation": "Your understanding of the hypothetical being explored",
            "implications": {
              "new_domains": ["Entirely new product domains that would be needed"],
              "affected_domains": [
                {
                  "domain": "Name of existing domain",
                  "impact": "How this domain would be affected"
                }
              ],
              "new_personas": ["New user types that would be introduced"],
              "affected_personas": [
                {
                  "persona": "Name of existing persona",
                  "impact": "How this persona's experience would change"
                }
              ],
              "complexity_assessment": "Low/Medium/High with brief rationale",
              "dependencies": ["Technical or product dependencies this would introduce"]
            },
            "follow_up_questions": ["Questions to explore further before committing"],
            "ready_to_propose": true or false
          }

          Set ready_to_propose to true only if the hypothetical is specific enough to become
          a concrete change proposal. Vague or open-ended questions should be false.
        PROMPT

        RESPONSE_SCHEMA = {
          name: "what_if_analysis",
          schema: {
            type: "object",
            properties: {
              interpretation: { type: "string" },
              implications: {
                type: "object",
                properties: {
                  new_domains: { type: "array", items: { type: "string" } },
                  affected_domains: {
                    type: "array",
                    items: {
                      type: "object",
                      properties: {
                        domain: { type: "string" },
                        impact: { type: "string" }
                      },
                      required: %w[domain impact]
                    }
                  },
                  new_personas: { type: "array", items: { type: "string" } },
                  affected_personas: {
                    type: "array",
                    items: {
                      type: "object",
                      properties: {
                        persona: { type: "string" },
                        impact: { type: "string" }
                      },
                      required: %w[persona impact]
                    }
                  },
                  complexity_assessment: { type: "string" },
                  dependencies: { type: "array", items: { type: "string" } }
                },
                required: %w[new_domains affected_domains new_personas affected_personas complexity_assessment dependencies]
              },
              follow_up_questions: { type: "array", items: { type: "string" } },
              ready_to_propose: { type: "boolean" }
            },
            required: %w[interpretation implications follow_up_questions ready_to_propose]
          }
        }.freeze

        def self.tool_name
          "what_if"
        end

        def self.description
          "Explore a hypothetical without committing to a change. Arnold evaluates the implications " \
            "of an idea across the spec and returns an assessment. No state changes are made."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              question: {
                type: "string",
                description: "The hypothetical to explore (e.g. 'what if we added group walks?')."
              },
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Defaults to the latest run if not provided."
              }
            },
            required: [ "question" ]
          }
        end

        def self.call(params, context)
          question = params["question"].to_s.strip
          return { error: "question is required" } if question.empty?

          run_id = params["run_id"]
          run = context.pipeline_run(run_id: run_id)
          return { error: "No pipeline run found" } unless run

          spec = run.specification
          return { error: "No specification found for pipeline run ##{run.id}" } unless spec

          analyze_hypothetical(question, spec)
        end

        private_class_method def self.analyze_hypothetical(question, spec)
          llm = Providers::Llm.build
          agent = Agents::BaseAgent.new(llm: llm, logger: Logger.new(File::NULL))

          user_content = build_user_content(question, spec)

          result = agent.send(:chat_json,
            messages: [ { role: "user", content: user_content } ],
            system: SYSTEM_PROMPT,
            schema: RESPONSE_SCHEMA
          )

          normalize_result(result)
        rescue => e
          build_fallback_result(question, spec)
        end

        private_class_method def self.build_user_content(question, spec)
          parts = []
          parts << "## What If Question\n#{question}"
          parts << "\n## Current Specification\n#{spec.content}"

          data = spec.structured_data
          if data.is_a?(Hash)
            domains = data["domains"] || data[:domains] || []
            if domains.any?
              domain_list = domains.map { |d|
                name = d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s
                desc = d.is_a?(Hash) ? (d["description"] || d[:description]).to_s : ""
                "- #{name}: #{desc}"
              }.join("\n")
              parts << "\n## Current Domains\n#{domain_list}"
            end

            personas = data["personas"] || data[:personas] || []
            if personas.any?
              persona_list = personas.map { |p|
                name = p.is_a?(Hash) ? (p["name"] || p[:name]).to_s : p.to_s
                desc = p.is_a?(Hash) ? (p["description"] || p[:description]).to_s : ""
                "- #{name}: #{desc}"
              }.join("\n")
              parts << "\n## Current Personas\n#{persona_list}"
            end
          end

          parts.join("\n")
        end

        private_class_method def self.normalize_result(result)
          implications = result["implications"] || result[:implications] || {}
          {
            interpretation: result["interpretation"] || result[:interpretation] || "",
            implications: {
              new_domains: implications["new_domains"] || implications[:new_domains] || [],
              affected_domains: (implications["affected_domains"] || implications[:affected_domains] || []).map { |d|
                { domain: d["domain"] || d[:domain] || "", impact: d["impact"] || d[:impact] || "" }
              },
              new_personas: implications["new_personas"] || implications[:new_personas] || [],
              affected_personas: (implications["affected_personas"] || implications[:affected_personas] || []).map { |p|
                { persona: p["persona"] || p[:persona] || "", impact: p["impact"] || p[:impact] || "" }
              },
              complexity_assessment: implications["complexity_assessment"] || implications[:complexity_assessment] || "",
              dependencies: implications["dependencies"] || implications[:dependencies] || []
            },
            follow_up_questions: result["follow_up_questions"] || result[:follow_up_questions] || [],
            ready_to_propose: result["ready_to_propose"] || result[:ready_to_propose] || false
          }
        end

        private_class_method def self.build_fallback_result(question, spec)
          data = spec.structured_data || {}
          domains = (data["domains"] || data[:domains] || []).map { |d|
            d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s
          }
          personas = (data["personas"] || data[:personas] || []).map { |p|
            p.is_a?(Hash) ? (p["name"] || p[:name]).to_s : p.to_s
          }

          {
            interpretation: "Evaluating: #{question}",
            implications: {
              new_domains: [],
              affected_domains: domains.map { |d| { domain: d, impact: "Potentially affected" } },
              new_personas: [],
              affected_personas: personas.map { |p| { persona: p, impact: "Potentially affected" } },
              complexity_assessment: "Unable to assess — LLM unavailable",
              dependencies: []
            },
            follow_up_questions: [ "Could you provide more detail about this hypothetical?" ],
            ready_to_propose: false
          }
        end
      end
    end
  end
end
