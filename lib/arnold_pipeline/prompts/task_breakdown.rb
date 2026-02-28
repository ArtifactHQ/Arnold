module ArnoldPipeline
  module Prompts
    module TaskBreakdown
      def self.system_prompt(recipe: nil, supporting_recipes: [], deltas: nil)
        <<~PROMPT
          You are a technical project manager breaking down a software specification into
          granular, actionable tasks for AI coding agents.

          # Expected Spec Structure

          The specification follows a 10-section structure:
          1. Overview (classification, vision, goals, target users, boundaries, assumptions)
          2. Features — organized by functional area using `## [Area Name]` headers.
             Each area contains `### Requirement: [Name]` blocks with `#### Scenario:` blocks
             in GIVEN/WHEN/THEN format. Map tasks to specific requirements by name.
          3. Entities & Data Model (attributes, relationships, lifecycle states, business rules)
          4. User Journeys (new user, core, edge case, recovery flows)
          5. Views & Interfaces (screens, actions, navigation, responsive variations)
          6. System Behaviors (scheduled processes, automations, notifications)
          7. Logic & Calculations (formulas, algorithms, boundary conditions)
          8. External Connections (integrations, data flows, failure handling)
          9. Security & Privacy (roles, permissions, data protection, compliance)
          10. Future Considerations (deferred items — do NOT create tasks for these)

          #{technology_context(recipe, supporting_recipes)}

          #{rules_section(deltas)}

          # Local Execution Requirements

          The generated project MUST be immediately runnable after setup:
          - The bootstrap task MUST produce a working `bin/setup` that installs all
            dependencies and prepares the database in one command
          - Use SQLite for the development database (Rails 8 default) — zero external dependencies
          - Use Solid Queue, Solid Cache, Solid Cable — no Redis or Memcached
          - All external integrations MUST work without configuration in development
            (use test/mock modes or graceful degradation)

          # Acceptance Criteria

          Each task MUST include an `acceptance_criteria` array — structured, machine-readable
          assertions derived from the spec's GIVEN/WHEN/THEN scenarios. These are used by
          automated checkers and tier gate evaluation to verify implementation correctness.

          Acceptance criteria types:

          - `file_exists`: A file or glob pattern must exist.
            Fields: `pattern` (glob string, e.g. "app/models/user.rb")
          - `test_exists`: Test files matching a pattern must exist with a minimum assertion count.
            Fields: `pattern` (glob string, e.g. "test/**/*user*"), `min_assertions` (integer, default 1)
          - `model_has`: An ActiveRecord model must have specific columns or associations.
            Fields: `model` (string, e.g. "User"), `columns` (array of strings, optional),
            `associations` (array of strings like "has_many :posts", optional)
          - `route_exists`: A route must be defined for a given method + path.
            Fields: `method` (string, e.g. "POST"), `path` (string, e.g. "/api/sessions")
          - `http`: An endpoint must respond with expected status/body (verified at runtime).
            Fields: `method`, `path`, `input` (hash, optional), `expected_status` (integer),
            `expected_body_contains` (array of strings, optional)
          - `command_exits`: A CLI command must exit with an expected code (verified at runtime).
            Fields: `command` (string), `expected_exit_code` (integer, default 0)

          Derive criteria from the spec's GIVEN/WHEN/THEN scenarios. For each scenario, create
          at least one criterion. Use `file_exists`, `test_exists`, `model_has`, and `route_exists`
          wherever possible — these are verified programmatically without LLM involvement.
          Use `http` and `command_exits` for behavioral requirements that need runtime verification.

          # Output Format

          Your response will be validated against a JSON schema. Return valid JSON matching this structure:
          {
            "tasks": [
              {
                "title": "Short descriptive title",
                "description": "Detailed description with acceptance criteria",
                "priority": 0,
                "labels": ["backend", "database"],
                "position": 0,
                "depends_on": [],
                "section_ref": "Features > Authentication",
                "acceptance_criteria": [
                  {
                    "type": "file_exists",
                    "description": "User model exists",
                    "params": "{\"pattern\": \"app/models/user.rb\"}"
                  },
                  {
                    "type": "route_exists",
                    "description": "Login endpoint is routed",
                    "params": "{\"method\": \"POST\", \"path\": \"/api/sessions\"}"
                  },
                  {
                    "type": "test_exists",
                    "description": "Session tests exist",
                    "params": "{\"pattern\": \"test/**/*session*\", \"min_assertions\": 2}"
                  }
                ]
              }
            ]
          }

          The "position" field determines execution order (0-indexed).
          The "depends_on" field lists positions of tasks that must complete first.
          The "section_ref" field references which spec section and requirement this task
          implements (e.g., "Authentication > User Registration"). Use the format
          "[Area Name] > [Requirement Name]" for Features section tasks. This enables
          traceability between tasks and specific requirements.
          The "acceptance_criteria" array contains structured assertions for automated verification.
          Every task MUST have at least one acceptance criterion.
          IMPORTANT: The "params" field must be a JSON-encoded STRING, not a raw object.
          Example: "params": "{\"pattern\": \"app/models/user.rb\"}" (not "params": {"pattern": "..."})
        PROMPT
      end

      def self.user_prompt(spec_content:, deltas: nil)
        if deltas.present?
          <<~PROMPT
            The application described by the following specification is already built and working.
            Generate tasks ONLY for the deltas described in the system prompt — do not regenerate
            tasks for existing functionality.

            #{spec_content}
          PROMPT
        else
          <<~PROMPT
            Break down the following specification into tasks:

            #{spec_content}
          PROMPT
        end
      end

      def self.technology_context(recipe, supporting_recipes)
        return "" if recipe.nil?

        parts = [ "# Technology Context" ]
        parts << ""
        parts << "Recipe: #{recipe.name} (#{recipe.type})"
        parts << recipe.description.strip if recipe.description

        fw = framework_section(recipe)
        parts << "" << fw unless fw.empty?

        sd = sections_detail(recipe)
        parts << "" << sd unless sd.empty?

        sr = supporting_recipes_brief(supporting_recipes)
        parts << "" << sr unless sr.empty?

        vc = verification_context(recipe)
        parts << "" << vc unless vc.empty?

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

        pipeline_sections = recipe.sections.reject { |s| s["phase"] == "post_pipeline" }
        pipeline_sections.map { |s| format_section(s) }.join("\n\n")
      end

      def self.format_section(section)
        parts = [ "### #{section['name']}" ]
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

        if section["tier_placement"]
          parts << ""
          parts << "Tier placement: #{section['tier_placement']} (tasks from this section should be placed in the #{section['tier_placement']} execution tier)"
        end

        parts.join("\n")
      end

      def self.supporting_recipes_brief(recipes)
        return "" if recipes.nil? || recipes.empty?

        parts = [ "## Supporting recipes" ]
        parts << "Consider these additional recipe concerns when creating tasks:"

        recipes.each do |r|
          section_names = r.sections.map { |s| s["name"] }.join(", ")
          parts << ""
          parts << "**#{r.name}** — #{r.description&.strip}"
          parts << "Sections: #{section_names}"
        end

        parts.join("\n")
      end

      def self.verification_context(recipe)
        return "" if recipe.verification.nil? || recipe.verification.empty?

        parts = [ "## Verification" ]
        parts << "After all tasks complete, the project should be verifiable with:"

        if recipe.verification["setup_commands"]&.any?
          recipe.verification["setup_commands"].each { |cmd| parts << "- Setup: `#{cmd}`" }
        end

        parts << "- Boot: `#{recipe.verification['boot_command']}`" if recipe.verification["boot_command"]

        if recipe.verification["health_checks"]&.any?
          recipe.verification["health_checks"].each do |check|
            parts << "- Health check: `#{check['url']}` (expected #{check['expected_status'] || 200})"
          end
        end

        parts << "- Test: `#{recipe.verification['test_command']}`" if recipe.verification["test_command"]
        parts << "- Cleanup: `#{recipe.verification['cleanup_command']}`" if recipe.verification["cleanup_command"]

        parts << ""
        parts << "Ensure the bootstrap task produces a project that passes these verification steps."
        parts.join("\n")
      end

      def self.rules_section(deltas)
        if deltas.present?
          <<~RULES
            # Delta Scope

            This is a FORKED pipeline run. The application already exists and is fully built.
            You are generating tasks ONLY for the following spec deltas:

            #{delta_scoping_context(deltas)}

            # Rules (Delta-Scoped)

            - Generate ONLY tasks that implement the deltas above — no bootstrap, no existing features
            - There is NO minimum task count — 1 task for 1 delta is perfectly fine
            - Do NOT include a project bootstrap/setup task — the project already exists
            - Tasks may depend on existing code (models, routes, etc.) — assume they exist
            - Each task must be independently executable by a coding agent
            - Tasks MUST be ordered by dependencies
            - Each task should have clear acceptance criteria in its description
            - Assign appropriate labels (e.g., "backend", "frontend", "database", "testing")
            - Set priority: 0 = highest priority, higher numbers = lower priority
            - Task descriptions MUST reference specific tools, gems, generators, and commands
            - Position numbering starts at 0
          RULES
        else
          <<~RULES
            # Rules

            - Aim for 5 to 20 tasks
            - Each task must be independently executable by a coding agent
            - Tasks MUST be ordered by dependencies (e.g., database setup before API endpoints)

            # Parallel Execution & Resource Conflicts

            Tasks at the same dependency tier execute IN PARALLEL in isolated git worktrees.
            Each parallel task branches from master independently — they CANNOT see each other's
            migrations, model changes, or schema modifications.

            This means: if two tasks both create or modify the same database table, they WILL
            produce conflicting migrations when merged. You MUST add a `depends_on` relationship
            between them to force sequential execution.

            Serialization rules:
            - If two tasks both CREATE migrations for the same table → add depends_on
            - If two tasks both ADD COLUMNS to the same model → add depends_on
            - If two tasks both define ASSOCIATIONS on the same model → add depends_on
            - If a task creates a table that another task references (foreign key) → add depends_on
            - When unsure whether tasks conflict, add depends_on — unnecessary serialization
              only slows execution, but conflicting parallel tasks break the pipeline

            Example: "Session Notes" needs a `recommendations` association, and "Recommendations"
            creates the `recommendations` table. These MUST be serialized via depends_on, even
            though they are separate features.
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
              RIGHT: "Run `rails new . --force` with SQLite (`--database=sqlite3`), install Tailwind CSS via `tailwindcss-rails`, configure Propshaft asset pipeline"
            - IMPORTANT: The bootstrap task MUST use `rails new . --force` (dot = current directory)
              to initialize in the working directory. NEVER use `rails new app_name` — that creates
              a subdirectory which breaks the execution provider's diff capture.
              WRONG: "Implement authentication"
              RIGHT: "Implement authentication using Rails 8 authentication generator (`bin/rails generate authentication`), configure `has_secure_password`, add `bcrypt` gem"
            - The bootstrap task (position 0) MUST name the specific framework, database,
              CSS framework, and asset pipeline from the recipe context
            - For each spec section, name the specific tools and libraries that apply to
              that section's tasks (e.g., ActiveRecord for models, Turbo Streams for real-time)
          RULES
        end
      end

      def self.delta_scoping_context(deltas)
        deltas.map.with_index(1) do |delta, i|
          parts = [ "## Delta #{i}: #{delta['operation']&.upcase || 'CHANGED'}" ]
          parts << "Section: #{delta['section']}" if delta["section"]
          parts << "Requirement: #{delta['requirement']}" if delta["requirement"]
          parts << "" << delta["content"] if delta["content"]
          parts << "" << "Rationale: #{delta['rationale']}" if delta["rationale"]
          parts.join("\n")
        end.join("\n\n")
      end

      private_class_method :technology_context, :framework_section, :sections_detail, :format_section, :supporting_recipes_brief, :verification_context, :rules_section, :delta_scoping_context
    end
  end
end
