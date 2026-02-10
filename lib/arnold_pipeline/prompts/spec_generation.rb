module ArnoldPipeline
  module Prompts
    module SpecGeneration
      def self.system_prompt(persona:, recipe:, supporting_recipes: [], domain_type:)
        <<~PROMPT
          #{persona.system_prompt}

          # Core Philosophy

          You follow three foundational principles:

          1. THE DOCUMENT IS THE PRODUCT — The specification is the authoritative source of truth.
             Code is merely an artifact of this document. If the document is incomplete, the code
             will be incomplete. If it is ambiguous, the code will guess wrong.

          2. PRECISION WITHOUT JARGON — Write in plain language a non-technical person can understand,
             but never sacrifice precision for simplicity. Every behavior, limit, and condition must
             be explicitly stated. No "works as expected" or "standard flow" shortcuts.

          3. IDEAS ARE NOT SHORTCUTS — Every concept in the document either gets full treatment
             (worked through all implications, connections, specifications) or gets explicitly
             flagged as incomplete with a callout annotation. You may NOT mention an idea casually
             and move on.

          # Domain Type Lens

          This application is classified as: #{domain_type.code} — #{domain_type.name}
          Primary value: #{domain_type.primary_value}

          Apply this domain-specific lens throughout the specification:

          Emphasize:
          #{domain_type.emphasis.map { |e| "- #{e}" }.join("\n")}

          Document thoroughly:
          #{domain_type.document_focus.map { |d| "- #{d}" }.join("\n")}

          Watch for:
          #{domain_type.watch_for.map { |w| "- #{w}" }.join("\n")}

          #{terminology_section(domain_type)}

          # Recipe Scaffold

          Recipe: #{recipe.name}
          #{recipe.description}

          #{framework_section(recipe)}

          #{sections_detail(recipe)}

          #{supporting_recipes_section(supporting_recipes)}

          Use the recipe's framework, tools, and guidance to inform your technology choices
          and implementation approach. Reflect these in the tech_stack of your JSON metadata.

          # Document Structure

          Produce a Markdown document with the following 10-section structure. Adapt section names
          to fit the domain language, but preserve the purpose of each section:

          1. # Overview
             - Application Classification: #{domain_type.code} — #{domain_type.name}
             - Vision & Description: What this application is and why it exists
             - Objectives & Goals: Measurable success criteria
             - Target Users: Who uses this and their key characteristics
             - What This Is NOT: Explicit boundaries and out-of-scope items
             - Assumptions & Constraints: Taken-as-true conditions and known limitations

          2. # Features
             Organized by functional area, using OpenSpec-compatible requirement format.

             Each functional area gets a `## [Area Name]` header. Within each area,
             each discrete requirement gets a `### Requirement: [Name]` header.

             Requirements use RFC 2119 keywords: SHALL (mandatory), MUST (mandatory),
             SHOULD (recommended), MAY (optional).

             Each requirement has one or more `#### Scenario: [Name]` blocks using
             GIVEN/WHEN/THEN/AND format.

             Corner cases and acceptance criteria are expressed AS scenarios, not as
             separate sections. Every testable condition becomes a scenario.

             Example structure:
             ```
             ## Authentication

             ### Requirement: User Registration
             Users SHALL be able to create a new account using email and password.

             **Context:** Registration is the entry point for all new users.

             #### Scenario: Successful Registration
             - GIVEN a user on the registration page
             - WHEN they submit a valid email and password (8+ characters)
             - THEN a new account is created
             - AND the user is redirected to the dashboard

             #### Scenario: Duplicate Email
             - GIVEN a user on the registration page
             - WHEN they submit an email that is already registered
             - THEN an error message "email already taken" is displayed
             ```

          3. # Entities & Data Model
             All persistent objects in the system. Each entity includes:
             - Description and purpose
             - Attributes described in plain language (not SQL types)
             - Relationships to other entities
             - Lifecycle states (if applicable)
             - Business rules that govern this entity

          4. # User Journeys
             End-to-end flows through the system:
             - New user journey (first-time experience)
             - Core repeated journeys (daily/frequent use)
             - Edge case journeys (unusual but valid paths)
             - Recovery journeys (when things go wrong)

          5. # Views & Interfaces
             Every screen, page, or interaction surface. Each view includes:
             - Purpose: Why this view exists
             - Information displayed: What the user sees
             - Actions available: What the user can do
             - Navigation: Where users can go from here
             - Responsive/platform variations

          6. # System Behaviors
             How the system operates autonomously:
             - Scheduled processes (cron-like jobs)
             - Triggered automations (event-driven actions)
             - Background calculations
             - Notification logic and delivery rules

          7. # Logic & Calculations
             All formulas, algorithms, and decision trees:
             - Expressed in plain language
             - With concrete worked examples
             - With boundary conditions and limits

          8. # External Connections
             Integrations with outside systems:
             - What connects and why
             - What data flows in each direction
             - What happens when connections fail

          9. # Security & Privacy
             - Who can access what (roles and permissions)
             - How data is protected
             - Compliance requirements
             - Sensitive data handling

          10. # Future Considerations
              Explicitly flagged items deferred for later:
              - Deferred features with integration notes
              - Where each deferred item would insert into the spec
              - Dependencies on current features

          # Per-Feature Template

          When documenting each functional area in Section 2, follow this template strictly:

          ## [Functional Area Name]

          ### Requirement: [Requirement Name] [REQ-{DOMAIN}-{NNN}]
          [One-sentence statement using RFC 2119 keywords (SHALL/MUST/SHOULD/MAY)
           describing what the system does.]

          **Context:** [Why this requirement exists and what problem it solves]

          #### Scenario: [Descriptive Name]
          - GIVEN [precondition]
          - WHEN [action or event]
          - THEN [expected outcome]
          - AND [additional outcome, if any]

          #### Scenario: [Edge Case or Error Name]
          - GIVEN [precondition]
          - WHEN [failure or edge condition]
          - THEN [specific error handling or recovery behavior]

          Rules:
          - Every functional requirement becomes a `### Requirement:` block
          - Every behavioral spec, corner case, and acceptance criterion becomes a `#### Scenario:` block
          - Scenarios MUST use GIVEN/WHEN/THEN format with dash-prefixed lines
          - Each requirement MUST have at least one scenario
          - Use specific numbers, limits, and concrete details in scenarios
          - Assign a unique ID to each requirement: [REQ-{DOMAIN}-{NNN}] where DOMAIN
            is a short uppercase label for the functional area (e.g., AUTH, PAY, USER)
            and NNN is a zero-padded sequence number starting from 001

          # Callout Annotations

          Use these callout annotations throughout the document to annotate your thinking:

          > [!NOTE] — Supplementary clarification
          > [!IMPORTANT] — Critical information the reader must not miss
          > [!WARNING] — Potential problems or risks
          > [!QUESTION] — Open questions requiring future resolution (include who should answer)
          > [!IDEA] — Suggested enhancements with integration notes (must assess scope)
          > [!ASSUMPTION] — Something taken as true that may need validation
          > [!PLACEHOLDER] — Temporary values that need refinement
          > [!DEPENDENCY] — Relies on another section, decision, or external factor

          # Anti-Pattern Warnings

          Avoid these documentation anti-patterns:

          - LAZY IDEA DROP: Mentioning an idea without developing it or explicitly deferring it
          - ASSUMED UNDERSTANDING: "Works like you'd expect" or "standard flow" — nothing is assumed
          - TECHNICAL LEAK: Describing HOW data is stored/transmitted instead of WHAT data exists
          - VAGUE QUANTITY: "Earns more points" or "appears higher" without specific numbers/formulas
          - ORPHANED REFERENCE: Referencing a concept (e.g., "Trust Score") that is never defined
          - CONTRADICTORY SPECIFICATION: Conflicting numbers or rules in different sections
          - MISSING NEGATIVE: Describing what CAN happen without specifying what CAN'T (limits, restrictions, error states)

          # JSON Metadata Block

          At the end of the document, output a JSON block fenced with ```json containing:
          {
            "application_type": "#{domain_type.code}",
            "features": ["feature1", "feature2", ...],
            "tech_stack": {"frontend": "...", "backend": "...", "database": "..."},
            "data_models": [{"name": "...", "attributes": [...]}],
            "recipe_type": "#{recipe.type}",
            "supporting_recipe_types": #{supporting_recipes.map(&:type).inspect}
          }
        PROMPT
      end

      def self.user_prompt(nl_input:)
        <<~PROMPT
          Please generate a detailed specification for the following application:

          #{nl_input}
        PROMPT
      end

      def self.terminology_section(domain_type)
        return "" if domain_type.terminology.empty?

        terms = domain_type.terminology.map { |generic, specific| "- Use \"#{specific}\" instead of generic \"#{generic}\" where appropriate" }.join("\n")
        <<~SECTION
          Domain terminology (prefer these terms in the specification):
          #{terms}
        SECTION
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

      def self.supporting_recipes_section(recipes)
        return "" if recipes.nil? || recipes.empty?

        parts = ["## Supporting recipes"]
        parts << "These additional recipes may be relevant. Consider their section concerns where applicable:"

        recipes.each do |r|
          section_names = r.sections.map { |s| s["name"] }.join(", ")
          parts << ""
          parts << "**#{r.name}** — #{r.description&.strip}"
          parts << "Sections: #{section_names}"
        end

        parts.join("\n")
      end

      private_class_method :terminology_section, :framework_section, :sections_detail, :format_section, :supporting_recipes_section
    end
  end
end
