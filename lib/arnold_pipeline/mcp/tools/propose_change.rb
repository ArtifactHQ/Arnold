require "securerandom"
require "arnold_pipeline/providers/llm/base"
require "arnold_pipeline/agents/spec_iterator"
require_relative "base"

module ArnoldPipeline
  module Mcp
    module Tools
      class ProposeChange < Base
        # In-memory store for proposals keyed by change_id
        @@proposals = {}

        def self.tool_name
          "propose_change"
        end

        def self.description
          "Evaluates a change request against the spec without applying it. " \
            "Returns an impact analysis with affected domains, personas, and capabilities. " \
            "Use confirm_change with the returned change_id to apply."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              description: {
                type: "string",
                description: "Description of the proposed change to the specification."
              },
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Defaults to the latest run if not provided."
              }
            },
            required: ["description"]
          }
        end

        def self.call(params, context)
          change_description = params["description"].to_s.strip
          run_id = params["run_id"]

          if change_description.empty?
            return { error: "Change description is required" }
          end

          run = context.pipeline_run(run_id: run_id)
          unless run
            return { error: "No pipeline run found" }
          end

          spec = run.specification
          unless spec
            return { error: "No specification found for pipeline run ##{run.id}" }
          end

          # Use the SpecIterator agent to analyze the change (dry run)
          analysis = analyze_change(spec, change_description)

          change_id = SecureRandom.uuid

          # Store proposal for later confirmation
          @@proposals[change_id] = {
            change_id: change_id,
            run_id: run.id,
            description: change_description,
            analysis: analysis,
            created_at: Time.current
          }

          build_response(change_id, analysis, spec, run)
        end

        def self.proposals
          @@proposals
        end

        def self.clear_proposals!
          @@proposals.clear
        end

        private_class_method def self.analyze_change(spec, change_description)
          llm = ArnoldPipeline::Providers::Llm.build
          iterator = ArnoldPipeline::Agents::SpecIterator.new(
            llm: llm,
            logger: Logger.new(File::NULL)
          )
          iterator.call(
            spec_content: spec.content,
            change_request: change_description
          )
        rescue => e
          # Return a minimal analysis on LLM failure
          {
            "summary" => "Unable to perform full analysis: #{e.message}",
            "deltas" => []
          }
        end

        private_class_method def self.build_response(change_id, analysis, spec, run)
          deltas = analysis["deltas"] || []
          summary = analysis["summary"] || "Change analysis complete"

          domains_affected = extract_affected_domains(deltas, spec)
          personas_affected = extract_affected_personas(deltas, spec)

          new_capabilities = deltas
            .select { |d| d["operation"] == "added" }
            .map { |d| d["requirement"] || d["section"] }

          modified_capabilities = deltas
            .select { |d| d["operation"] == "modified" }
            .map { |d| d["requirement"] }

          removed_capabilities = deltas
            .select { |d| d["operation"] == "removed" }
            .map { |d| d["requirement"] }

          questions = generate_questions(deltas, analysis)

          confidence = determine_confidence(deltas, questions)

          {
            change_id: change_id,
            summary: summary,
            impact: {
              domains_affected: domains_affected,
              personas_affected: personas_affected,
              new_capabilities: new_capabilities.compact,
              modified_capabilities: modified_capabilities.compact,
              removed_capabilities: removed_capabilities.compact
            },
            questions: questions,
            confidence: confidence
          }
        end

        private_class_method def self.extract_affected_domains(deltas, spec)
          sections = deltas.map { |d| d["section"] }.compact.uniq

          data = spec.structured_data
          known_domains = if data.is_a?(Hash)
            (data["domains"] || data[:domains] || []).map { |d|
              d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s
            }
          else
            []
          end

          sections.map { |section|
            matched_domain = known_domains.find { |d|
              d.downcase.include?(section.downcase) || section.downcase.include?(d.downcase)
            }

            domain_name = matched_domain || section
            section_deltas = deltas.select { |d| d["section"] == section }
            changes = section_deltas.map { |d| "#{d['operation']}: #{d['requirement'] || 'new'}" }.join("; ")

            { domain: domain_name, changes: changes }
          }
        end

        private_class_method def self.extract_affected_personas(deltas, spec)
          data = spec.structured_data
          return [] unless data.is_a?(Hash)

          personas = data["personas"] || data[:personas] || []
          return [] if personas.empty?

          # Check which personas are affected by the changed sections
          changed_sections = deltas.map { |d| d["section"] }.compact.uniq
          content_changes = deltas.map { |d|
            [d["content"], d["after_content"], d["requirement"]].compact.join(" ")
          }.join(" ").downcase

          personas.select { |p|
            p_name = (p.is_a?(Hash) ? (p["name"] || p[:name]).to_s : p.to_s).downcase
            content_changes.include?(p_name)
          }.map { |p|
            name = p.is_a?(Hash) ? (p["name"] || p[:name]).to_s : p.to_s
            { persona: name, changes: "Affected by changes in: #{changed_sections.join(', ')}" }
          }
        end

        private_class_method def self.generate_questions(deltas, analysis)
          questions = []

          # Flag removed capabilities
          removed = deltas.select { |d| d["operation"] == "removed" }
          removed.each do |d|
            questions << "Removing '#{d['requirement']}' may affect dependent features. Is this intended?"
          end

          # Flag large changes
          if deltas.size > 5
            questions << "This change affects #{deltas.size} requirements. Have you considered the scope of this change?"
          end

          # Flag if no deltas were generated (LLM might not understand the change)
          if deltas.empty?
            questions << "No specific changes were identified. Could you clarify the change request?"
          end

          questions
        end

        private_class_method def self.determine_confidence(deltas, questions)
          return "low" if deltas.empty?
          return "low" if questions.size > 3
          return "medium" if questions.any?

          "high"
        end
      end
    end
  end
end
