module ArnoldPipeline
  module Prompts
    module FeatureExtraction
      def self.extraction_prompt(concern_id:, concern_name:, implementation_files:, stack_fingerprint:)
        file_contents = implementation_files.filter_map { |path, content|
          next unless content
          "### #{path}\n```\n#{content[0, 4000]}\n```"
        }.join("\n\n")

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

      def self.scoped_extraction_prompt(concern_id:, concern_name:, implementation_files:, stack_fingerprint:, change_request:)
        base = extraction_prompt(
          concern_id:,
          concern_name:,
          implementation_files:,
          stack_fingerprint:
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
    end
  end
end
