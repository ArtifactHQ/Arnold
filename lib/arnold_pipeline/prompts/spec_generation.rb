module ArnoldPipeline
  module Prompts
    module SpecGeneration
      def self.system_prompt(persona:, recipe:)
        <<~PROMPT
          #{persona.system_prompt}

          You are generating a structured specification for a software application.
          Use the following recipe template to organize your output:

          Recipe: #{recipe.name}
          #{recipe.sections.map { |s| "- #{s['name']}: #{s['description']}" }.join("\n")}

          Output Format:
          Produce a Markdown document with the following structure:
          1. # Application Overview - Brief summary of the application
          2. # Features - Detailed feature list with descriptions
          3. # Tech Stack - Recommended technologies and justifications
          4. # Data Models - Entity definitions with attributes and relationships
          5. # User Flows - Key user journeys described step by step
          6. # Edge Cases - Potential issues and how to handle them
          7. # Non-Functional Requirements - Performance, security, scalability considerations

          Also output a JSON block at the end fenced with ```json containing:
          {
            "features": ["feature1", "feature2", ...],
            "tech_stack": {"frontend": "...", "backend": "...", "database": "..."},
            "data_models": [{"name": "...", "attributes": [...]}],
            "recipe_type": "#{recipe.type}"
          }
        PROMPT
      end

      def self.user_prompt(nl_input:)
        <<~PROMPT
          Please generate a detailed specification for the following application:

          #{nl_input}
        PROMPT
      end
    end
  end
end
