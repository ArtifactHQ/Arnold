require_relative "base"
require "arnold_pipeline/agents/base_agent"

module ArnoldPipeline
  module Mcp
    module Tools
      class ExploreArchitecture < Base
        SYSTEM_PROMPT = <<~PROMPT
          You are a software architect analyzing a project's architecture.
          Given the specification and recipe details, provide a structural overview.
          Focus on identifying distinct domains/modules, their components, data models,
          and how they integrate with each other.

          Respond with a JSON object matching this exact schema:
          {
            "architecture": {
              "stack": "Technology stack summary",
              "rationale": "Why this stack was chosen for this project",
              "domains": [
                {
                  "name": "Domain name",
                  "components": "Key components in this domain",
                  "recipes_used": ["Recipe names that inform this domain"],
                  "data_summary": "Key data models and relationships",
                  "integrations": "How this domain connects to others"
                }
              ]
            }
          }
        PROMPT

        RESPONSE_SCHEMA = {
          name: "architecture_overview",
          schema: {
            type: "object",
            properties: {
              architecture: {
                type: "object",
                properties: {
                  stack: { type: "string" },
                  rationale: { type: "string" },
                  domains: {
                    type: "array",
                    items: {
                      type: "object",
                      properties: {
                        name: { type: "string" },
                        components: { type: "string" },
                        recipes_used: {
                          type: "array",
                          items: { type: "string" }
                        },
                        data_summary: { type: "string" },
                        integrations: { type: "string" }
                      },
                      required: %w[name components recipes_used data_summary integrations]
                    }
                  }
                },
                required: %w[stack rationale domains]
              }
            },
            required: %w[architecture]
          }
        }.freeze

        def self.tool_name
          "explore_architecture"
        end

        def self.description
          "Returns a structural view of the system architecture by domain. " \
            "Extracts stack info, recipes used, and domain-level components from the spec."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              domain: {
                type: %w[string null],
                description: "Filter to a specific domain name. Returns all domains if not provided."
              },
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Defaults to the latest run if not provided."
              }
            },
            required: []
          }
        end

        def self.call(params, context)
          domain_filter = params["domain"]
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

          stack = extract_stack(spec, selections, library_manager)
          recipe_names = extract_recipe_names(selections)
          domains = extract_domains_from_spec(spec, recipe_names)

          if domain_filter && !domain_filter.strip.empty?
            domains = domains.select { |d|
              d[:name].downcase.include?(domain_filter.downcase)
            }
          end

          enrich_with_llm(spec, stack, domains, recipe_names, domain_filter)
        rescue => e
          # Fallback: return what we extracted without LLM enrichment
          build_fallback_response(stack, domains, recipe_names)
        end

        private_class_method def self.extract_stack(spec, selections, library_manager)
          # Try structured_data first
          data = spec.structured_data
          if data.is_a?(Hash)
            tech_stack = data["tech_stack"] || data[:tech_stack]
            if tech_stack.is_a?(Hash)
              return tech_stack.map { |k, v| "#{k}: #{v}" }.join(", ")
            end
            if tech_stack.is_a?(String)
              return tech_stack
            end
          end

          # Fall back to recipe framework
          recipe_name = selections["recipe"]
          if recipe_name
            recipe = library_manager.all_recipes.find { |r| r.name.downcase == recipe_name.downcase }
            if recipe&.framework.is_a?(Hash)
              return recipe.framework.map { |k, v| "#{k}: #{v}" }.join(", ")
            end
          end

          # Fall back to parsing spec content
          extract_stack_from_content(spec.content)
        end

        private_class_method def self.extract_stack_from_content(content)
          return "Not specified" unless content

          stack_section = content[/##\s*Tech(?:nology)?\s*Stack\s*\n(.*?)(?=\n##|\z)/mi, 1]
          if stack_section
            stack_section.strip.lines.map(&:strip).reject(&:empty?).first(5).join(", ")
          else
            "Rails 8+ (default)"
          end
        end

        private_class_method def self.extract_recipe_names(selections)
          names = []
          names << selections["recipe"] if selections["recipe"]
          if selections["supporting_recipes"].is_a?(Array)
            names.concat(selections["supporting_recipes"])
          end
          names
        end

        private_class_method def self.extract_domains_from_spec(spec, recipe_names)
          domains = []

          # Try structured_data domains
          data = spec.structured_data
          if data.is_a?(Hash)
            spec_domains = data["domains"] || data[:domains] || []
            spec_domains.each do |d|
              if d.is_a?(Hash)
                domains << {
                  name: (d["name"] || d[:name]).to_s,
                  components: (d["components"] || d[:components] || "").to_s,
                  recipes_used: recipe_names,
                  data_summary: (d["data_summary"] || d[:data_summary] || d["models"] || d[:models] || "").to_s,
                  integrations: (d["integrations"] || d[:integrations] || "").to_s
                }
              else
                domains << {
                  name: d.to_s,
                  components: "",
                  recipes_used: recipe_names,
                  data_summary: "",
                  integrations: ""
                }
              end
            end
          end

          # If no structured domains, try to parse from spec content headings
          if domains.empty?
            domains = extract_domains_from_content(spec.content, recipe_names)
          end

          domains
        end

        private_class_method def self.extract_domains_from_content(content, recipe_names)
          return [] unless content

          domains = []
          # Look for ## Features or ## Requirements sections with sub-items
          feature_section = content[/##\s*(?:Features|Requirements)\s*\n(.*?)(?=\n##|\z)/mi, 1]
          if feature_section
            # Each line starting with - or ### could be a domain
            feature_section.scan(/^(?:###\s+|\-\s+)(.+)$/).flatten.first(10).each do |name|
              domains << {
                name: name.strip.gsub(/[*_`]/, ""),
                components: "",
                recipes_used: recipe_names,
                data_summary: "",
                integrations: ""
              }
            end
          end

          domains
        end

        private_class_method def self.enrich_with_llm(spec, stack, domains, recipe_names, domain_filter)
          llm = Providers::Llm.build
          agent = Agents::BaseAgent.new(llm: llm, logger: Logger.new(File::NULL))

          user_content = build_llm_context(spec, stack, domains, recipe_names, domain_filter)

          result = agent.send(:chat_json,
            messages: [ { role: "user", content: user_content } ],
            system: SYSTEM_PROMPT,
            schema: RESPONSE_SCHEMA
          )

          normalize_response(result)
        end

        private_class_method def self.build_llm_context(spec, stack, domains, recipe_names, domain_filter)
          parts = []
          parts << "## Specification\n#{spec.content}"
          parts << "## Extracted Stack\n#{stack}"
          parts << "## Recipes Used\n#{recipe_names.join(', ')}" if recipe_names.any?

          if domains.any?
            domain_text = domains.map { |d| "- #{d[:name]}" }.join("\n")
            parts << "## Identified Domains\n#{domain_text}"
          end

          if domain_filter
            parts << "## Filter\nFocus on the '#{domain_filter}' domain specifically."
          end

          parts.join("\n\n")
        end

        private_class_method def self.normalize_response(result)
          arch = result["architecture"] || result[:architecture] || {}
          {
            architecture: {
              stack: arch["stack"] || arch[:stack] || "",
              rationale: arch["rationale"] || arch[:rationale] || "",
              domains: (arch["domains"] || arch[:domains] || []).map { |d|
                {
                  name: d["name"] || d[:name] || "",
                  components: d["components"] || d[:components] || "",
                  recipes_used: d["recipes_used"] || d[:recipes_used] || [],
                  data_summary: d["data_summary"] || d[:data_summary] || "",
                  integrations: d["integrations"] || d[:integrations] || ""
                }
              }
            }
          }
        end

        private_class_method def self.build_fallback_response(stack, domains, recipe_names)
          {
            architecture: {
              stack: stack || "Not specified",
              rationale: "Extracted from spec and recipe data (LLM enrichment unavailable)",
              domains: domains || []
            }
          }
        end
      end
    end
  end
end
