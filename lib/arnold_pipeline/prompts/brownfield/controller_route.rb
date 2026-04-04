module ArnoldPipeline
  module Prompts
    module Brownfield
      module ControllerRoute
        def self.prompt(context:, file_contents:)
          stack = context.stack_fingerprint
          route_table = context.route_table
          stack_hints = stack_instructions(context)

          route_section = if route_table && !route_table.empty?
            "## Route Table\n```\n#{route_table}\n```"
          else
            "## Route Table\n(no route table available)"
          end

          code_lang = stack_hints[:code_language]
          file_sections = file_contents.filter_map { |path, content|
            next unless content

            truncated = content.length > 6000 ? content[0, 6000] + "\n# ... [truncated]" : content
            "### #{path}\n```#{code_lang}\n#{truncated}\n```"
          }.join("\n\n")

          <<~PROMPT
            You are analyzing the #{stack_hints[:layer_name]} of an existing #{stack[:language]}/#{stack[:framework]} codebase.

            ## Task: #{stack_hints[:task_title]}

            #{stack_hints[:task_description]}

            ## What to Analyze Per Endpoint

            1. **verb & path**: #{stack_hints[:verb_path_hint]}
            2. **controller & action**: #{stack_hints[:controller_action_hint]}
            3. **description**: What it does (1-2 sentences based on reading the code)
            4. **access_control**: #{stack_hints[:access_control_hint]}
            5. **side_effects**: #{stack_hints[:side_effects_hint]}
            6. **error_handling**: How errors are handled
            7. **input_params**: #{stack_hints[:input_params_hint]}
            8. **output_format**: #{stack_hints[:output_format_hint]}
            9. **status**: Implementation status:
               - "implemented" — fully working with real logic
               - "partial" — exists but some paths are incomplete
               - "stubbed" — empty or placeholder
            10. **feature_domain**: The product feature this endpoint/screen serves, named
               from the user's perspective (e.g., "Care Plan Management", "Video Consultations",
               "User Onboarding", "Messaging"). Use consistent names — endpoints that serve
               the same product feature MUST share the same feature_domain value. Infer from
               the endpoint's path, controller, and what user action it supports.
               For auth endpoints, use "Authentication". For admin-only endpoints, prefix
               with "Admin: " (e.g., "Admin: User Management").

            ## Stack
            Language: #{stack[:language]}
            Framework: #{stack[:framework]}
            #{stack[:meta] ? "Meta: #{stack[:meta]}" : ""}

            #{route_section}

            ## #{stack_hints[:files_header]}
            #{file_sections.empty? ? "(no files found)" : file_sections}

            ## Instructions
            #{stack_hints[:instructions]}

            Return a JSON object with an "endpoints" array.
          PROMPT
        end

        def self.stack_instructions(context)
          require "arnold_pipeline/brownfield/stack_aware_file_selector"
          family = ArnoldPipeline::Brownfield::StackAwareFileSelector.stack_family(context)

          case family
          when "mobile"
            {
              layer_name: "navigation and API service layer",
              task_title: "Navigation & API Endpoint Analysis",
              task_description: "Examine the React Navigation structure and API service layer to produce a complete inventory of screens the user can navigate to and API endpoints the app calls. For a mobile client, 'endpoints' include both navigation routes (screens) and outbound API calls.",
              code_language: "typescript",
              verb_path_hint: 'HTTP method and URL for API calls (e.g., "GET /api/v1/clients"), or "NAVIGATE" for screen routes',
              controller_action_hint: "The screen component or API service function",
              access_control_hint: 'Auth requirements (e.g., "requires auth token", "public screen", "role-gated")',
              side_effects_hint: "Effects triggered (API calls, state updates, navigation events, push registration, analytics)",
              input_params_hint: "Parameters accepted (route params, query params, request body shape)",
              output_format_hint: 'Response type (JSON from API, screen render, navigation action)',
              files_header: "Navigation & API Service Files",
              instructions: <<~INST
                - Analyze React Navigation navigator definitions to find all screens
                - Examine API service files to find all outbound HTTP calls the app makes
                - For each API call: identify the HTTP verb, path, request params, and response handling
                - For each screen: identify the route name, required params, and what data it displays
                - Check for auth guards in navigation (conditional rendering based on auth state)
                - Identify deep linking configuration — deep link paths reveal externally-reachable
                  screens and the user flows that external links can trigger
                - Look for saga/thunk patterns that orchestrate API calls
                - If backend source exists (backend/, server/, api/), examine backend routes to
                  understand the full API surface the mobile app consumes
                - If feature-organized directories exist (src/features/*/, src/modules/*/), each
                  directory likely maps to a distinct navigation subtree or feature flow
              INST
            }
          when "client_spa"
            {
              layer_name: "routing and API layer",
              task_title: "Route & API Endpoint Analysis",
              task_description: "Examine the file-based routes and API handlers to produce a complete inventory of pages and API endpoints.",
              code_language: "typescript",
              verb_path_hint: "HTTP method and URL pattern from file-based routing",
              controller_action_hint: "The page component or API route handler",
              access_control_hint: 'Auth requirements (e.g., "middleware protected", "public", "role-gated")',
              side_effects_hint: "Effects triggered (database writes, email delivery, cache updates, external API calls)",
              input_params_hint: "Parameters accepted (URL params, search params, request body, form data)",
              output_format_hint: "Response type (HTML page, JSON API, redirect, Server-Sent Events)",
              files_header: "Page & API Route Files",
              instructions: <<~INST
                - Map file-based routes (app/**/page.tsx, app/api/**/route.ts) to URL paths
                - For each API route: identify HTTP methods handled, request validation, response format
                - For each page: identify data fetching (Server Components, fetch calls, Server Actions)
                - Check middleware.ts for auth/access control
                - Identify Server Actions and their form bindings
                - Look for loading.tsx and error.tsx for UX patterns
              INST
            }
          else
            {
              layer_name: "controller and routing layer",
              task_title: "Controller & Route Endpoint Analysis",
              task_description: "Examine every controller file and cross-reference with the route table to produce a complete inventory of HTTP endpoints. For each endpoint, analyze the controller action's BEHAVIOR — not just its existence.",
              code_language: "ruby",
              verb_path_hint: "HTTP method and URL pattern from the route table",
              controller_action_hint: "Controller class name and action method",
              access_control_hint: 'Authentication/authorization requirements (e.g., "requires login", "admin only", "public", "API token required")',
              side_effects_hint: "External effects (email delivery, background jobs, webhook calls, cache invalidation, broadcasts, file uploads)",
              input_params_hint: "Parameters accepted (from strong params, query params, path segments)",
              output_format_hint: "Response format (HTML, JSON, redirect, Turbo Stream, file download)",
              files_header: "Controller Files",
              instructions: <<~INST
                - Cross-reference the route table with controller actions to ensure completeness
                - If a route exists but the controller action is missing, include it with status "stubbed"
                - If a controller action exists but no matching route is found, still include it with a note
                - Look inside before_action filters to determine access_control
                - Check for respond_to blocks to determine output_format
                - Identify callbacks, mailer calls, job enqueues, and broadcasts as side_effects
                - Read strong_params / permit calls to identify input_params
              INST
            }
          end
        end
      end
    end
  end
end
