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
            You are a product analyst synthesizing an as-built product specification from
            technical analysis of an existing codebase. The specification you produce will
            be used to REBUILD this product on a new tech stack — it must capture every
            product requirement without referencing the original implementation.

            ## Project: #{project_name}
            ## Original Stack: #{stack_fingerprint[:language]}/#{stack_fingerprint[:framework]}

            ## Task: Synthesize As-Built Product Specification

            You have received structured analysis from 5 specialized agents that each examined
            a different layer of the codebase. Your job is to synthesize their findings into a
            product specification that describes **what this application does for its users** —
            not how it is built.

            ## Critical Framing Rules

            Think like a PRODUCT MANAGER, not an engineer. Apply these rules:

            1. **Name requirements as product features** — "Care Plan Management", not
               "State Management and Hooks". "Video Consultations", not "WebView Integration".
               Ask: "What would a product manager call this in a roadmap?"

            2. **Infer the product domain** — From screen names, data entities, API endpoints,
               and business logic, determine what this product IS: a healthcare app, an e-commerce
               platform, a project management tool, etc. State this clearly in the Overview.

            3. **Identify user roles** — From auth logic, role constants, conditional rendering,
               and navigation guards, identify the distinct user types (e.g., "caregiver", "admin",
               "patient", "customer").

            4. **Write user-centric requirements** — Each requirement should describe value
               delivered to a user role. Bad: "The system SHALL utilize React Native for
               cross-platform development." Good: "Caregivers SHALL be able to manage daily
               checklists for their assigned clients."

            5. **Construct user flows** — Trace multi-step journeys across screens, API calls,
               and state changes. A login flow touches auth context, login screen, API service,
               and navigation — connect these into one coherent flow, not four separate findings.

            6. **Separate product features from infrastructure** — Technical concerns
               (CI/CD, build tooling, test framework, state management architecture) are NOT
               product requirements. Only document user-facing product features and behaviors.

            ## Stack-Agnostic Requirements

            This specification will be used to rebuild the product on a DIFFERENT tech stack.
            Therefore:
            - NEVER mention specific libraries, frameworks, gems, or packages in requirements
              (no "Devise", "Redux", "Sidekiq", "ActiveRecord")
            - NEVER reference file paths, class names, or module structures
            - NEVER describe data types in implementation terms (use "text", "number", "date",
              "yes/no", not "string", "integer", "datetime", "boolean")
            - DO describe behaviors, rules, and user-visible outcomes in plain language
            - DO name entities in business terms ("Care Plan", "Invoice") not technical terms
              ("CarePlan model", "invoices table")

            ## Epistemic Classification

            Tag every requirement and finding with its confidence level using callout annotations:

            > [!CONFIRMED] — Directly observed in code with multiple corroborating signals
            (e.g., route exists AND controller implements it AND view renders it).

            > [!INFERRED] — Reasonable deduction from partial evidence. State what evidence
            supports the inference and what is assumed.

            > [!GAP] — Expected capability that appears missing or cannot be determined
            from the codebase. These MUST become open questions in the Review section.

            > [!CONFLICT] — Agents disagree on this finding. Document both positions.
            These MUST become conflict entries in the Review section.

            Rules:
            - A requirement is CONFIRMED when 2+ agents provide corroborating evidence
            - A requirement is INFERRED when only 1 agent provides evidence, or evidence
              is indirect (e.g., a translation key exists but no corresponding screen)
            - A requirement is a GAP when a logical expectation is not met (e.g., a
              user role exists in the auth system but no screens are role-gated for them)
            - NEVER silently resolve contradictions — surface them as CONFLICT entries

            ## Feature Domain Analysis

            Each agent has tagged its findings with a `feature_domain` field. USE THESE TAGS
            to trace complete features through the codebase:

            1. **Group by feature_domain first** — Collect all screens, services, endpoints,
               and entities that share the same feature_domain value.

            2. **Trace each feature through all layers** — For each feature domain, identify:
               - What can users accomplish? (the requirement)
               - What do users see and interact with? (Views & Interfaces)
               - What journey do they follow? (User Journeys)
               - What rules and validations apply? (Logic & Calculations)
               - What data is involved? (Entities & Data Model)
               - What happens automatically? (System Behaviors)
               - What external services are involved? (External Connections)

            3. **Cross-reference signals** — If localization, analytics, or feature
               flag files were analyzed, use them to enrich understanding:
               - Translation keys reveal user-facing copy and error states
               - Analytics events reveal which features are instrumented
               - Feature flags reveal capabilities that are toggled or experimental

            4. **Identify gaps in features** — If a feature has screens but no business logic,
               or business logic but no screens, tag as [!GAP] and add an open question.

            5. **Merge similar domains** — Agents may use slightly different names for the same
               feature (e.g., "Care Plans" vs "Care Plan Management"). Normalize to one name.

            ## Organizational Scaffold (Domain Concerns)
            #{concern_scaffold}

            ## Agent Analysis Results
            #{agent_sections}
            #{reference_section}
            ## Document Structure

            Produce a Markdown document with the following structure. Adapt section names
            to fit the domain language, but preserve the purpose and numbering of each section.

            # #{project_name} — As-Built Specification

            ## 1. Overview
            - Application Classification: [inferred domain type, e.g., HEALTHCARE, FINTECH, SAAS]
            - Vision & Description: What this application is and why it exists
            - Target Users: Who uses this and their key characteristics (list each user role)
            - What This Is NOT: Explicit boundaries inferred from what the app does NOT do
            - Assumptions & Constraints: Conditions taken as true from the analysis

            > [!NOTE] Originally built with #{stack_fingerprint[:language]}/#{stack_fingerprint[:framework]}.
            > This specification is stack-agnostic — it describes product requirements only.

            ## 2. Features
            Organized by functional area using OpenSpec-compatible requirement format.

            Each functional area gets a `## [Area Name]` header. Within each area,
            each discrete requirement gets a `### Requirement: [Name] [REQ-{DOMAIN}-{NNN}]` header.

            Requirements use RFC 2119 keywords: SHALL (mandatory), SHOULD (recommended), MAY (optional).

            Each requirement has one or more `#### Scenario: [Name]` blocks using
            GIVEN/WHEN/THEN/AND format.

            Template:
            ```
            ## [Functional Area Name]

            ### Requirement: [Feature Name] [REQ-{DOMAIN}-{NNN}]
            [One-sentence statement using RFC 2119 keywords]

            > [!CONFIRMED] / [!INFERRED] — [brief evidence summary]

            **Context:** [Why this feature exists — what user problem it solves]

            #### Scenario: [Descriptive Name]
            - GIVEN [user state/precondition]
            - WHEN [user action]
            - THEN [observable outcome from user perspective]
            - AND [additional outcome, if any]

            #### Scenario: [Edge Case or Error Name]
            - GIVEN [precondition]
            - WHEN [failure or edge condition]
            - THEN [specific error handling or recovery behavior]
            ```

            Rules:
            - Every functional requirement becomes a `### Requirement:` block
            - Every behavioral spec, corner case, and acceptance criterion becomes a `#### Scenario:` block
            - Scenarios MUST use GIVEN/WHEN/THEN format with dash-prefixed lines
            - Each requirement MUST have at least one scenario
            - Use specific numbers, limits, and concrete details in scenarios
            - Assign a unique ID: [REQ-{DOMAIN}-{NNN}] where DOMAIN is a short uppercase label
              (e.g., AUTH, CARE, USER, PAY) and NNN is zero-padded from 001
            - Requirements with only partial evidence get > [!INFERRED]
            - Requirements that appear stubbed or incomplete move to Section 10

            ## 3. Entities & Data Model
            All persistent objects discovered in the system. Each entity includes:
            - Description and purpose (in business terms)
            - Attributes described in plain language (not SQL/ORM types)
            - Relationships to other entities
            - Lifecycle states (if applicable)
            - Business rules that govern this entity

            ## 4. User Journeys
            End-to-end flows through the system:
            - New user journey (first-time experience)
            - Core repeated journeys (daily/frequent use)
            - Edge case journeys (unusual but valid paths)
            - Recovery journeys (when things go wrong)

            ## 5. Views & Interfaces
            Every screen, page, or interaction surface discovered. Each view includes:
            - Purpose: Why this view exists
            - Information displayed: What the user sees
            - Actions available: What the user can do
            - Navigation: Where users can go from here
            - Role-based variations: How the view changes by user role

            ## 6. System Behaviors
            How the system operates autonomously:
            - Scheduled processes (recurring jobs)
            - Triggered automations (event-driven actions)
            - Background calculations
            - Notification logic and delivery rules

            ## 7. Logic & Calculations
            All formulas, algorithms, and decision trees discovered:
            - Expressed in plain language
            - With concrete worked examples where possible
            - With boundary conditions and limits

            ## 8. External Connections
            Integrations with outside systems:
            - What connects and why
            - What data flows in each direction
            - What happens when connections fail

            ## 9. Security & Privacy
            - Who can access what (roles and permissions)
            - How data is protected
            - Authentication approach (described functionally, not by library)
            - Sensitive data handling

            ## 10. Future Considerations
            Items that appear stubbed, incomplete, or partially implemented:
            - Describe the intended capability
            - Note what evidence suggests it was planned
            - Flag as deferred for PO decision

            ```json
            [JSON METADATA BLOCK — see instructions below]
            ```

            ## 11. Review
            <!-- REVIEW_SECTION_START -->

            ### Open Questions
            Decisions requiring Product Owner input before building.
            Format each as:
            - **[OQ-NNN]** [Question text]
              - Context: [Why this matters]
              - Options: [A, B, C if applicable]
              - Default assumption: [What we'll assume if no answer]
              - Affects: [REQ-IDs or sections impacted]

            ### Conflicts
            Cross-agent contradictions surfaced during analysis.
            Format each as:
            - **[CONFLICT-NNN]** [Description]
              - Agent A says: [finding]
              - Agent B says: [finding]
              - Recommended resolution: [suggestion]

            ### Risk Register
            Potential issues discovered during analysis.
            Format each as:
            - **[RISK-NNN]** [Description] — Severity: [HIGH/MEDIUM/LOW]
              - Evidence: [what signals this risk]
              - Recommended action: [suggestion]

            ### Source Provenance
            For each major feature area, which agents and files contributed to the findings.
            Format as a table:
            | Feature Area | Contributing Agents | Key Files |

            <!-- REVIEW_SECTION_END -->

            ## JSON Metadata Block

            Place the JSON metadata block BETWEEN Section 10 and Section 11, fenced with ```json.

            The metadata MUST use this exact structure for compatibility with the build pipeline:
            ```json
            {
              "application_type": "<inferred domain code: HEALTHCARE, FINTECH, SAAS, ECOMMERCE, SOCIAL, EDUCATION, PRODUCTIVITY, CONTENT, MARKETPLACE, DEVTOOLS, or GENERIC>",
              "features": ["<feature_name_1>", "<feature_name_2>"],
              "tech_stack": {},
              "data_models": [{"name": "<EntityName>", "attributes": ["<attr1>", "<attr2>"]}],
              "recipe_type": "<inferred recipe type or null>",
              "supporting_recipe_types": [],
              "as_built_metadata": {
                "original_stack": #{JSON.generate(stack_fingerprint)},
                "product_domain": "<inferred domain>",
                "user_roles": ["<role1>", "<role2>"],
                "confirmed": "<count of CONFIRMED requirements>",
                "inferred": "<count of INFERRED requirements>",
                "gaps": "<count of GAP items>",
                "open_questions": "<count>",
                "conflicts": "<count>",
                "risks": "<count>"
              }
            }
            ```

            IMPORTANT:
            - `tech_stack` MUST be an empty object `{}` — the new tech stack will be
              determined by the recipe selected at build time, not by the original stack
            - `application_type` should be an uppercase domain code
            - `features` should list each feature area name as a short string
            - `data_models` should list each entity with its plain-language attribute names
            - For `recipe_type`, infer from the product:
              - Web applications with server-rendered pages → "web_app"
              - REST/GraphQL API services → "api_service"
              - Mobile applications → "mobile_app"
              - CLI tools → "cli_tool"
              - If unclear, use null
            - `supporting_recipe_types` should be an empty array unless clearly applicable

            ## Output
            Return the complete Markdown specification document with all 11 sections.
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
              reduced = [ current / 2, 3000 ].max
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
