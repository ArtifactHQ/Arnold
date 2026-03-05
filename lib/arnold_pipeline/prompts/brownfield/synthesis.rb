module ArnoldPipeline
  module Prompts
    module Brownfield
      module Synthesis
        MAX_AGENT_OUTPUT_CHARS = 15_000
        TRUNCATION_ORDER = %w[view_ux business_logic controller_route data_model infrastructure].freeze

        def self.prompt(agent_results:, concerns:, stack_fingerprint:, project_name:, reference_materials: [])
          concern_scaffold = format_concerns(concerns)
          agent_sections = format_agent_results(agent_results)
          reference_section = format_reference_materials(reference_materials)

          <<~PROMPT
            You are synthesizing a complete as-built specification for an existing codebase.

            ## Project: #{project_name}
            ## Stack: #{stack_fingerprint[:language]}/#{stack_fingerprint[:framework]}

            ## Task: Synthesize As-Built Specification

            You have received structured analysis from 5 specialized agents that each examined
            a different layer of the codebase. Your job is to synthesize their findings into a
            single, coherent specification document organized by DOMAIN CONCERN — not by
            technical layer.

            ## Organizational Scaffold (Domain Concerns)
            #{concern_scaffold}

            ## Agent Analysis Results
            #{agent_sections}
            #{reference_section}
            ## Synthesis Instructions

            1. **Reorganize by concern**: Group findings from ALL agents under the appropriate
               domain concern. A single concern (e.g., "Authentication") may have findings from
               Infrastructure (config), DataModel (User entity), BusinessLogic (auth service),
               ControllerRoute (sessions endpoint), and ViewUx (login page).

            2. **Resolve contradictions**: If agents disagree on status or implementation details,
               prefer the agent with direct evidence (e.g., DataModel for entity details,
               ControllerRoute for endpoint behavior).

            3. **Status tags**: Mark each requirement with:
               - `[IMPLEMENTED]` — fully working, confirmed by multiple agents
               - `[PARTIAL]` — partially implemented, some aspects missing
               - `[STUBBED]` — placeholder only, minimal implementation

            4. **GIVEN/WHEN/THEN scenarios**: Write behavioral scenarios for each requirement.
               Use test names from agent data as evidence for scenario content.

            5. **Format**: Use OpenSpec-compatible Markdown:

            ```markdown
            # #{project_name} — As-Built Specification

            ## Purpose
            [Inferred purpose based on all agent findings]

            ## Requirements

            ### Requirement: [Feature Name] [EXISTING] [REQ-{DOMAIN}-{NNN}]
            [IMPLEMENTED] The system SHALL [description].

            **Context:** [Why this exists based on the implementation]

            #### Scenario: [Name]
            - GIVEN [precondition]
            - WHEN [action]
            - THEN [result]
            ```

            6. **JSON metadata block** at the end:
            ```json
            {
              "project_name": "#{project_name}",
              "stack": #{JSON.generate(stack_fingerprint)},
              "total_features": <count>,
              "implemented": <count>,
              "partial": <count>,
              "stubbed": <count>,
              "agents_contributing": <count of non-null agent results>
            }
            ```

            ## Output
            Return the complete Markdown specification document.
          PROMPT
        end

        def self.format_concerns(concerns)
          return "(no concerns provided)" if concerns.nil? || concerns.empty?

          concerns.map { |id, data|
            status = data["status"] || data[:status] || "unknown"
            impl = data["implementation"] || data[:implementation]
            "- **#{id}** [#{status}]: #{impl || 'not detected'}"
          }.join("\n")
        end

        def self.format_agent_results(agent_results)
          budget = total_budget(agent_results)
          sections = []

          agent_results.each do |result|
            next unless result.output

            name = result.agent_name
            max_chars = budget[name] || MAX_AGENT_OUTPUT_CHARS
            json_text = JSON.pretty_generate(result.output)

            if json_text.length > max_chars
              json_text = json_text[0, max_chars] + "\n... [truncated]"
            end

            sections << "### #{format_agent_name(name)} (#{result.duration_ms}ms, ~#{result.tokens_used} tokens)\n```json\n#{json_text}\n```"
          end

          sections.join("\n\n")
        end

        def self.total_budget(agent_results)
          available = agent_results.select(&:output)
          return {} if available.empty?

          per_agent = MAX_AGENT_OUTPUT_CHARS
          budget = {}

          available.each { |r| budget[r.agent_name] = per_agent }

          total_chars = available.sum { |r| JSON.pretty_generate(r.output).length rescue 0 }
          max_total = MAX_AGENT_OUTPUT_CHARS * 5

          if total_chars > max_total
            TRUNCATION_ORDER.each do |name|
              break if total_chars <= max_total

              result = available.find { |r| r.agent_name == name }
              next unless result

              current = JSON.pretty_generate(result.output).length rescue 0
              reduced = [current / 2, 3000].max
              budget[name] = reduced
              total_chars -= (current - reduced)
            end
          end

          budget
        end

        def self.format_agent_name(name)
          name.to_s.split("_").map(&:capitalize).join(" ")
        end

        def self.format_reference_materials(materials)
          return "" if materials.nil? || materials.empty?

          docs = materials.filter_map { |mat|
            path = mat[:path] || mat["path"]
            content = mat[:content] || mat["content"]
            next unless path && content

            truncated = content.length > 3000 ? content[0, 3000] + "\n...[truncated]..." : content
            "### #{File.basename(path)}\n```\n#{truncated}\n```"
          }.join("\n\n")

          return "" if docs.empty?

          <<~SECTION

            ## Reference Documentation
            #{docs}
          SECTION
        end
      end
    end
  end
end
