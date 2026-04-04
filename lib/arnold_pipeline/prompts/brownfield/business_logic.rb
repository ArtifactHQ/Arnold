module ArnoldPipeline
  module Prompts
    module Brownfield
      module BusinessLogic
        FILE_PATTERNS = %w[
          app/services/**/*.rb
          app/jobs/**/*.rb
          app/mailers/**/*.rb
          lib/**/*.rb
        ].freeze

        EXCLUDED_PATTERNS = %w[
          lib/tasks/**
          lib/generators/**
        ].freeze

        def self.prompt(context:, file_contents:)
          stack = context.stack_fingerprint

          file_section = file_contents.filter_map { |path, content|
            next unless content
            "### #{path}\n```\n#{content[0, 5000]}\n```"
          }.join("\n\n")

          git_activity = context.git_activity
          git_section = if git_activity && !git_activity.empty?
            entries = git_activity.first(30).map { |entry|
              path = entry.is_a?(Hash) ? (entry[:path] || entry["path"]) : entry.to_s
              commits = entry.is_a?(Hash) ? (entry[:commits] || entry["commits"] || entry[:count] || entry["count"]) : nil
              commits ? "- #{path} (#{commits} commits)" : "- #{path}"
            }.join("\n")
            "## Git Activity (most active files)\n#{entries}"
          else
            ""
          end

          test_names = context.test_names
          test_section = if test_names && !test_names.empty?
            names = if test_names.is_a?(Hash)
              test_names.flat_map { |concern, names_list|
                Array(names_list).map { |n| "- [#{concern}] #{n}" }
              }
            else
              Array(test_names).map { |n| "- #{n}" }
            end
            "## Behavioral Signals (Test Names)\nThe following test names indicate implemented behaviors:\n#{names.first(50).join("\n")}"
          else
            ""
          end

          stack_hints = stack_instructions(context)

          <<~PROMPT
            You are analyzing an existing #{stack[:language]}/#{stack[:framework]} codebase to understand its business logic layer.

            ## Task: Business Logic Analysis

            #{stack_hints[:task_description]}

            For each service/component discovered, extract:
            1. **name**: The class, module, or function name
            2. **file**: The file path where it is defined
            3. **purpose**: What this component does from the USER'S perspective in 1-2 sentences
               (e.g., "Allows caregivers to assign tasks to clients" not "Dispatches ASSIGN_TASK action to Redux store")
            4. **rules**: Array of business rules enforced by this code (validations, constraints, conditional logic, permission checks)
            5. **state_transitions**: Array of state changes this component triggers
            6. **side_effects**: Array of external interactions (#{stack_hints[:side_effect_examples]})
            7. **error_handling**: How errors are handled (#{stack_hints[:error_handling_examples]})
            8. **dependencies**: Array of other services, models, or external systems this depends on
            9. **status**: "implemented" (fully functional), "partial" (incomplete implementation), or "stubbed" (placeholder/TODO)
            10. **feature_domain**: The product feature this service/component supports, named
               from the user's perspective (e.g., "Care Plan Management", "Video Consultations",
               "User Onboarding", "Messaging"). Use consistent names — services that support
               the same product feature MUST share the same feature_domain value. Infer from
               the service's purpose, the data it operates on, and what user capability it enables.
               If the service is cross-cutting infrastructure (e.g., error reporter, API client),
               use "Platform Infrastructure".

            ## What to Look For
            #{stack_hints[:look_for]}

            ## Stack Fingerprint
            - Language: #{stack[:language]}
            - Framework: #{stack[:framework]}

            ## Business Logic Files
            #{file_section.empty? ? "(no business logic files found)" : file_section}

            #{git_section}

            #{test_section}

            ## Instructions
            Return a JSON object with a single top-level key: "services".
            - "services" is an array of service/component objects
            Include ALL discovered services, jobs, mailers, and significant library modules.
            If a file contains multiple classes, create separate entries for each.
          PROMPT
        end

        def self.stack_instructions(context)
          require "arnold_pipeline/brownfield/stack_aware_file_selector"
          family = ArnoldPipeline::Brownfield::StackAwareFileSelector.stack_family(context)

          case family
          when "mobile"
            {
              task_description: "Examine the Redux sagas/thunks, custom hooks, utility modules, and service layers to produce a comprehensive inventory of business logic components. In a mobile client, business logic lives in state management side effects, custom hooks, and service modules.",
              side_effect_examples: "API calls, push notification triggers, analytics events, navigation actions, AsyncStorage writes",
              error_handling_examples: "try/catch blocks, saga error boundaries, error state dispatches, toast/snackbar notifications",
              look_for: <<~LOOK
                - Redux sagas (src/redux/sagas/) — async workflows, API call sequences, retry logic
                - Redux thunks — async dispatch chains
                - Custom hooks (src/hooks/) — reusable business logic encapsulated as hooks
                - Utility modules (src/utils/, src/helpers/) — shared business logic, formatters, validators
                - Service modules (src/services/) — API wrappers, platform integrations
                - Form validation logic (Yup schemas, Formik validators)
                - Navigation-driven workflows (multi-step forms, onboarding flows)
                - Push notification handlers (foreground/background behavior)
                - Offline/sync logic (queue actions while offline, retry on reconnect)
                - Analytics/tracking modules (src/analytics/, src/tracking/) — event names reveal which
                  product features are instrumented and what user actions matter to the business
                - Feature flag evaluation logic — conditional code paths gated by flags reveal
                  planned/toggled product capabilities
                - If feature-organized directories exist (src/features/*/, src/modules/*/), each
                  directory likely contains the business logic for one product feature
              LOOK
            }
          when "client_spa"
            {
              task_description: "Examine the server actions, API routes, service modules, and utility code to produce a comprehensive inventory of business logic components.",
              side_effect_examples: "API calls, database writes, email delivery, webhook calls, cache invalidation, file uploads",
              error_handling_examples: "try/catch blocks, error boundaries, error responses, redirects",
              look_for: <<~LOOK
                - Server Actions (app/**/actions.ts) — form processing, data mutations
                - API route handlers (app/api/**/route.ts) — REST endpoint logic
                - Service modules (lib/services/) — shared business logic
                - Utility code (lib/utils/) — helpers, formatters, validators
                - tRPC routers — typed API procedures
                - Middleware — request/response processing
                - Zod schemas — runtime validation
              LOOK
            }
          else
            {
              task_description: "Examine the service objects, background jobs, mailers, and library code to produce a comprehensive inventory of business logic components.",
              side_effect_examples: "email delivery, webhook calls, cache invalidation, file uploads, API calls, broadcasts",
              error_handling_examples: "rescue blocks, error classes, retry logic, fallbacks",
              look_for: <<~LOOK
                - Service objects (app/services/) — command/query pattern, interactors, form objects
                - Background jobs (app/jobs/) — async processing, scheduled tasks, queue configuration
                - Mailers (app/mailers/) — email templates, delivery triggers, preview support
                - Library code (lib/) — shared utilities, adapters, integrations, domain logic
                - Command patterns (call, execute, perform methods)
                - Transaction blocks and rollback handling
                - External API integrations
                - Event publishing/subscribing
                - Rate limiting and throttling
                - Retry and idempotency patterns
              LOOK
            }
          end
        end

        def self.select_files(context)
          require "arnold_pipeline/brownfield/stack_aware_file_selector"
          ArnoldPipeline::Brownfield::StackAwareFileSelector.select_files(context, "business_logic") ||
            legacy_select_files(context)
        end

        def self.legacy_select_files(context)
          manifest = context.file_manifest || {}
          manifest.keys.select { |path| matches_patterns?(path) && !excluded?(path) }
        end

        def self.matches_patterns?(path)
          FILE_PATTERNS.any? { |pattern| glob_match?(pattern, path) }
        end

        def self.excluded?(path)
          EXCLUDED_PATTERNS.any? { |pattern| glob_match?(pattern, path) }
        end

        def self.glob_match?(pattern, path)
          s = pattern.gsub(".", "\\.")
          s = s.gsub("**/", "\x01").gsub("**", "\x02")
          s = s.gsub("*", "[^/]*")
          s = s.gsub("\x01", "(.*/)?").gsub("\x02", ".*")
          Regexp.new("\\A#{s}\\z").match?(path)
        end
      end
    end
  end
end
