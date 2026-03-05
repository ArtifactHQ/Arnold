module ArnoldPipeline
  module Prompts
    module FeatureExtraction
      def self.extraction_prompt(concern_id:, concern_name:, implementation_files:, stack_fingerprint:, reference_materials: [])
        file_contents = implementation_files.filter_map { |path, content|
          next unless content
          "### #{path}\n```\n#{content[0, 4000]}\n```"
        }.join("\n\n")

        reference_section = format_reference_materials(reference_materials)

        <<~PROMPT
          You are analyzing an existing #{stack_fingerprint[:language]}/#{stack_fingerprint[:framework]} codebase.

          ## Task: Feature Extraction for "#{concern_name}" (#{concern_id})

          Examine the implementation files below and enumerate every discrete feature
          or capability provided by this concern area.

          For each feature, identify:
          1. **name**: Short descriptive name
          2. **description**: What it does in 1-2 sentences
          3. **status**: "implemented" (working), "partial" (incomplete), "stubbed" (placeholder)
          4. **files**: Key files that implement this feature
          5. **dependencies**: Other features or concerns this depends on

          ## Implementation Files
          #{file_contents}
          #{reference_section}
          ## Instructions
          Return a JSON object:
          ```json
          {
            "concern_id": "#{concern_id}",
            "features": [
              {
                "name": "string",
                "description": "string",
                "status": "implemented|partial|stubbed",
                "files": ["path1"],
                "dependencies": ["feature_name or concern_id"]
              }
            ]
          }
          ```
        PROMPT
      end

      def self.scoped_extraction_prompt(concern_id:, concern_name:, implementation_files:, stack_fingerprint:, change_request:, reference_materials: [])
        base = extraction_prompt(
          concern_id:,
          concern_name:,
          implementation_files:,
          stack_fingerprint:,
          reference_materials:
        )

        <<~PROMPT
          #{base}

          ## Additional Context: Change Request Scoping

          A change has been requested: "#{change_request}"

          Focus your feature extraction on features that are relevant to or would be
          affected by this change request. Still enumerate all features, but flag those
          relevant to the change with `"change_relevant": true`.
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
          The following reference documents provide additional context about the project's
          features and architecture. Use them to discover features that may not be obvious
          from code structure alone.

          #{docs}
        SECTION
      end
    end
  end
end
