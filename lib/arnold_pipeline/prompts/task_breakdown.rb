module ArnoldPipeline
  module Prompts
    module TaskBreakdown
      def self.system_prompt(recipe: nil, supporting_recipes: [])
        <<~PROMPT
          You are a technical project manager breaking down a software specification into
          granular, actionable tasks for AI coding agents.

          # Expected Spec Structure

          The specification follows a 10-section structure:
          1. Overview (classification, vision, goals, target users, boundaries, assumptions)
          2. Features (with per-feature context, user stories, requirements, behaviors, corner cases, acceptance criteria)
          3. Entities & Data Model (attributes, relationships, lifecycle states, business rules)
          4. User Journeys (new user, core, edge case, recovery flows)
          5. Views & Interfaces (screens, actions, navigation, responsive variations)
          6. System Behaviors (scheduled processes, automations, notifications)
          7. Logic & Calculations (formulas, algorithms, boundary conditions)
          8. External Connections (integrations, data flows, failure handling)
          9. Security & Privacy (roles, permissions, data protection, compliance)
          10. Future Considerations (deferred items — do NOT create tasks for these)

          #{technology_context(recipe, supporting_recipes)}

          # Rules

          - Aim for 5 to 20 tasks
          - Each task must be independently executable by a coding agent
          - Tasks MUST be ordered by dependencies (e.g., database setup before API endpoints)
          - Each task should have clear acceptance criteria in its description
          - Use per-feature acceptance criteria from the spec directly in task descriptions
          - Assign appropriate labels (e.g., "backend", "frontend", "database", "testing")
          - Set priority: 0 = highest priority, higher numbers = lower priority
          - The FIRST task (position 0) MUST be a project bootstrap task that sets up the
            foundational structure (project skeleton, dependencies, database configuration).
            ALL other tasks MUST depend on position 0, either directly or transitively
            through other dependencies. This ensures a single foundation task runs first.
          - Task descriptions MUST reference specific tools, gems, generators, and commands
            from the spec and recipe context. Be prescriptive, not generic.
            WRONG: "Set up the project with a database and CSS framework"
            RIGHT: "Run `rails new` with PostgreSQL (`--database=postgresql`), install Tailwind CSS via `tailwindcss-rails`, configure Propshaft asset pipeline"
            WRONG: "Implement authentication"
            RIGHT: "Implement authentication using Rails 8 authentication generator (`bin/rails generate authentication`), configure `has_secure_password`, add `bcrypt` gem"
          - The bootstrap task (position 0) MUST name the specific framework, database,
            CSS framework, and asset pipeline from the recipe context
          - For each spec section, name the specific tools and libraries that apply to
            that section's tasks (e.g., ActiveRecord for models, Turbo Streams for real-time)

          # Output Format

          Return a JSON array fenced with ```json, where each element has:
          {
            "title": "Short descriptive title",
            "description": "Detailed description with acceptance criteria",
            "priority": 0,
            "labels": ["backend", "database"],
            "position": 0,
            "depends_on": [],
            "section_ref": "Features > Authentication"
          }

          The "position" field determines execution order (0-indexed).
          The "depends_on" field lists positions of tasks that must complete first.
          The "section_ref" field references which spec section this task implements (optional but recommended for traceability).
        PROMPT
      end

      def self.user_prompt(spec_content:)
        <<~PROMPT
          Break down the following specification into tasks:

          #{spec_content}
        PROMPT
      end

      def self.technology_context(recipe, supporting_recipes)
        return "" if recipe.nil?

        parts = ["# Technology Context"]
        parts << ""
        parts << "Recipe: #{recipe.name} (#{recipe.type})"
        parts << recipe.description.strip if recipe.description

        fw = framework_section(recipe)
        parts << "" << fw unless fw.empty?

        sd = sections_detail(recipe)
        parts << "" << sd unless sd.empty?

        sr = supporting_recipes_brief(supporting_recipes)
        parts << "" << sr unless sr.empty?

        parts << ""
        parts << "Use these tools, gems, generators, and framework patterns when writing task descriptions."
        parts.join("\n")
      end

      def self.framework_section(recipe)
        return "" if recipe.framework.nil? || recipe.framework.empty?

        items = recipe.framework.map { |key, value| "- #{key}: #{value}" }.join("\n")
        <<~SECTION.strip
          Framework stack:
          #{items}
        SECTION
      end

      def self.sections_detail(recipe)
        return "" if recipe.sections.empty?

        recipe.sections.map { |s| format_section(s) }.join("\n\n")
      end

      def self.format_section(section)
        parts = ["### #{section['name']}"]
        parts << section["description"].strip if section["description"]

        tools = section["rails_tools"] || section["tools"]
        if tools && !tools.empty?
          parts << ""
          parts << "Tools:"
          tools.each { |t| parts << "- #{t}" }
        end

        guidance = section["guidance"]
        if guidance && !guidance.empty?
          parts << ""
          parts << "Implementation guidance:"
          guidance.each { |g| parts << "- #{g}" }
        end

        parts.join("\n")
      end

      def self.supporting_recipes_brief(recipes)
        return "" if recipes.nil? || recipes.empty?

        parts = ["## Supporting recipes"]
        parts << "Consider these additional recipe concerns when creating tasks:"

        recipes.each do |r|
          section_names = r.sections.map { |s| s["name"] }.join(", ")
          parts << ""
          parts << "**#{r.name}** — #{r.description&.strip}"
          parts << "Sections: #{section_names}"
        end

        parts.join("\n")
      end

      private_class_method :technology_context, :framework_section, :sections_detail, :format_section, :supporting_recipes_brief
    end
  end
end
