module ArnoldPipeline
  module Prompts
    module SpecTestGeneration
      def self.system_prompt(persona:, recipe: nil)
        framework_hint = if recipe&.framework.is_a?(Hash)
          lang = recipe.framework["language"] || "Ruby"
          fw = recipe.framework["name"] || "Rails"
          "The target project uses #{lang} with #{fw}."
        else
          "Detect the appropriate test framework from the specification context."
        end

        <<~PROMPT
          #{persona.system_prompt}

          You are generating integration tests from a behavioral specification.
          These tests will be committed to the repository BEFORE implementation begins.
          They are expected to FAIL initially — that is correct behavior. As implementation
          tiers complete, more tests should pass.

          #{framework_hint}

          ## Rules

          1. Generate complete, runnable test files — not stubs or pseudo-code.
          2. Organize tests by requirement ID ([REQ-{DOMAIN}-{NNN}]).
          3. Each test maps to one GIVEN/WHEN/THEN scenario from the spec.
          4. Tests exercise the public API or endpoints, not internal implementation.
          5. Include proper setup/teardown for test isolation.
          6. Use descriptive test names that reference the scenario.
          7. Comment each test with the original GIVEN/WHEN/THEN it derives from.
          8. File naming: one file per requirement or logical group of requirements.
          9. Files go in the configured test directory (provided in the user prompt).

          ## Output Format

          Return a JSON object with a "test_files" array. Each entry has:
          - "path": relative file path (e.g., "test/spec_integration/req_auth_001_test.rb")
          - "content": the complete file content as a string
          - "requirement_ids": array of requirement IDs covered by this file

          Example:
          {
            "test_files": [
              {
                "path": "test/spec_integration/req_auth_001_test.rb",
                "content": "require \\"test_helper\\"\\n\\nclass ReqAuth001Test < ...",
                "requirement_ids": ["REQ-AUTH-001"]
              }
            ]
          }
        PROMPT
      end

      def self.user_prompt(spec_content:, test_directory:)
        <<~PROMPT
          ## Specification

          #{spec_content}

          ## Instructions

          Generate integration test files for ALL requirements with GIVEN/WHEN/THEN
          scenarios found in the specification above.

          Place test files in: #{test_directory}/

          Generate complete, runnable tests. Every scenario in the spec should have
          a corresponding test method.
        PROMPT
      end
    end
  end
end
