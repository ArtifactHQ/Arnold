module ArnoldPipeline
  module Prompts
    module AsBuiltSpec
      def self.generation_prompt(feature_inventories:, stack_fingerprint:, project_name:, reference_materials: [])
        inventory_text = feature_inventories.map { |inv|
          features = inv["features"]&.map { |f|
            status_tag = "[#{f['status'].upcase}]"
            deps = f["dependencies"]&.any? ? " (depends on: #{f['dependencies'].join(', ')})" : ""
            "  - #{status_tag} #{f['name']}: #{f['description']}#{deps}"
          }&.join("\n") || "  (no features detected)"

          "### #{inv['concern_id']}\n#{features}"
        }.join("\n\n")

        reference_section = format_reference_materials(reference_materials)

        <<~PROMPT
          You are generating an as-built specification for an existing codebase.

          ## Project: #{project_name}
          ## Stack: #{stack_fingerprint[:language]}/#{stack_fingerprint[:framework]}

          ## Task: Generate As-Built Specification

          Based on the feature inventories below, produce a specification document in
          OpenSpec-compatible Markdown format that describes what this codebase currently does.

          ## Feature Inventories
          #{inventory_text}
          #{reference_section}
          ## Format Requirements

          1. Use `[EXISTING]` tag on all requirement IDs to indicate these are discovered
             (not target) requirements.

          2. Use status tags on each requirement:
             - `[IMPLEMENTED]` — fully working
             - `[PARTIAL]` — partially implemented
             - `[STUBBED]` — placeholder only

          3. Use GIVEN/WHEN/THEN scenarios for each requirement.

          4. Follow this structure:

          ```markdown
          # #{project_name} — As-Built Specification

          ## Purpose
          [Inferred purpose based on features]

          ## Requirements

          ### Requirement: [Feature Name] [EXISTING] [REQ-{DOMAIN}-{NNN}]
          [IMPLEMENTED] The system SHALL [description].

          **Context:** [Why this exists based on the implementation]

          #### Scenario: [Name]
          - GIVEN [precondition]
          - WHEN [action]
          - THEN [result]
          ```

          5. Group requirements by concern area (auth, data_layer, api_layer, frontend, etc.)

          6. At the end, include a JSON metadata block:
          ```json
          {
            "project_name": "#{project_name}",
            "stack": #{JSON.generate(stack_fingerprint)},
            "total_features": <count>,
            "implemented": <count>,
            "partial": <count>,
            "stubbed": <count>
          }
          ```

          ## Instructions
          Return the complete Markdown specification document.
        PROMPT
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
          The following reference documents provide additional product context. Use them
          to write a richer, more complete specification that captures features and
          requirements mentioned in documentation but not yet visible in code.

          #{docs}
        SECTION
      end
    end
  end
end
