module ArnoldPipeline
  module Prompts
    module BrownfieldAnalysis
      def self.concern_mapping_prompt(concerns:, overlay:, artifacts:, stack_fingerprint:)
        artifact_summary = artifacts.select { |a| a[:path] }.map { |a|
          "- #{a[:role]}: #{a[:path]} (#{a[:format]})"
        }.join("\n")

        overlay_text = overlay.map { |concern_id, data|
          locations = data["expected_locations"]&.join(", ") || "unknown"
          implementations = data["typical_implementations"]&.join(", ") || "unknown"
          "- #{concern_id}: locations=[#{locations}], implementations=[#{implementations}]"
        }.join("\n")

        <<~PROMPT
          You are analyzing an existing #{stack_fingerprint[:language]}/#{stack_fingerprint[:framework]} codebase.

          ## Task: Concern Mapping

          Map each abstract concern to its status in this codebase. For each concern, determine:
          1. **status**: "present", "partial", or "absent"
          2. **implementation**: What specific library/pattern implements it (e.g., "devise", "has_secure_password")
          3. **files**: Key files related to this concern
          4. **notes**: Brief observations about the implementation quality or approach

          ## Abstract Concerns
          #{concerns.map { |id, c| "- #{id}: #{c['name']} — #{c['description']}" }.join("\n")}

          ## Framework Overlay (expected patterns for this stack)
          #{overlay_text}

          ## Discovered Artifacts
          #{artifact_summary}

          ## Instructions
          Return a JSON object with this structure:
          ```json
          {
            "concerns": {
              "<concern_id>": {
                "status": "present|partial|absent",
                "implementation": "string or null",
                "files": ["path1", "path2"],
                "notes": "string"
              }
            }
          }
          ```
        PROMPT
      end

      def self.convention_extraction_prompt(artifacts:, stack_fingerprint:, overlay:)
        artifact_contents = artifacts.select { |a| a[:content] }.map { |a|
          "### #{a[:role]} (#{a[:path]})\n```\n#{a[:content][0, 3000]}\n```"
        }.join("\n\n")

        <<~PROMPT
          You are analyzing an existing #{stack_fingerprint[:language]}/#{stack_fingerprint[:framework]} codebase.

          ## Task: Convention Extraction

          Identify the conventions used in this codebase by examining its artifacts.
          Extract:

          1. **naming_conventions**: Variable, method, class, file naming patterns
          2. **architecture_pattern**: MVC, hexagonal, clean architecture, etc.
          3. **test_framework**: minitest, rspec, jest, etc.
          4. **code_style**: Formatting, linting rules, indentation
          5. **dependency_management**: How dependencies are managed, version pinning strategy
          6. **error_handling**: Common error handling patterns
          7. **configuration_approach**: Env vars, config files, Rails credentials, etc.

          ## Artifacts
          #{artifact_contents}

          ## Instructions
          Return a JSON object:
          ```json
          {
            "naming_conventions": "string describing naming patterns",
            "architecture_pattern": "string",
            "test_framework": "string",
            "code_style": "string",
            "dependency_management": "string",
            "error_handling": "string",
            "configuration_approach": "string",
            "additional": {}
          }
          ```
        PROMPT
      end

      def self.doc_fidelity_prompt(reference_materials:, artifacts:)
        ref_contents = reference_materials.map { |path|
          content = File.read(path, encoding: "utf-8")[0, 5000] rescue "[could not read #{path}]"
          "### #{File.basename(path)}\n```\n#{content}\n```"
        }.join("\n\n")

        artifact_summary = artifacts.select { |a| a[:path] }.map { |a|
          "- #{a[:role]}: #{a[:path]}"
        }.join("\n")

        <<~PROMPT
          ## Task: Documentation Fidelity Check

          Compare the reference documentation against the actual codebase artifacts.
          Identify discrepancies, missing features, and outdated documentation.

          ## Reference Documentation
          #{ref_contents}

          ## Codebase Artifacts
          #{artifact_summary}

          ## Instructions
          Return a JSON object:
          ```json
          {
            "alignment_score": 0-100,
            "discrepancies": [
              {"type": "missing_in_code|missing_in_docs|contradicts", "description": "string", "severity": "high|medium|low"}
            ],
            "summary": "string"
          }
          ```
        PROMPT
      end

      def self.change_surface_prompt(recipe_alignment:, conventions:, change_request:)
        <<~PROMPT
          ## Task: Change Surface Analysis

          Given a proposed change request and the current codebase profile, identify
          which areas of the codebase would need to be modified.

          ## Change Request
          #{change_request}

          ## Current Codebase Profile
          Concerns: #{JSON.pretty_generate(recipe_alignment["concerns"])}
          Conventions: #{JSON.pretty_generate(conventions)}

          ## Instructions
          Return a JSON object:
          ```json
          {
            "affected_concerns": ["concern_id1", "concern_id2"],
            "new_concerns": ["concern_id"],
            "estimated_files": ["path1", "path2"],
            "risk_areas": [{"area": "string", "risk": "high|medium|low", "reason": "string"}],
            "summary": "string"
          }
          ```
        PROMPT
      end
    end
  end
end
