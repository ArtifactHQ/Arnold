module ArnoldPipeline
  module Prompts
    module Brownfield
      module ControllerRoute
        def self.prompt(context:, file_contents:)
          stack = context.stack_fingerprint
          route_table = context.route_table

          route_section = if route_table && !route_table.empty?
            "## Route Table\n```\n#{route_table}\n```"
          else
            "## Route Table\n(no route table available)"
          end

          controller_sections = file_contents.filter_map { |path, content|
            next unless content

            truncated = content.length > 6000 ? content[0, 6000] + "\n# ... [truncated]" : content
            "### #{path}\n```ruby\n#{truncated}\n```"
          }.join("\n\n")

          <<~PROMPT
            You are analyzing the controller and routing layer of an existing #{stack[:language]}/#{stack[:framework]} codebase.

            ## Task: Controller & Route Endpoint Analysis

            Examine every controller file and cross-reference with the route table to produce
            a complete inventory of HTTP endpoints. For each endpoint, analyze the controller
            action's BEHAVIOR — not just its existence.

            ## What to Analyze Per Endpoint

            1. **verb & path**: HTTP method and URL pattern from the route table
            2. **controller & action**: Controller class name and action method
            3. **description**: What the action does (1-2 sentences based on reading the code)
            4. **access_control**: Authentication/authorization requirements (e.g., "requires login",
               "admin only", "public", "API token required")
            5. **side_effects**: External effects triggered by this action (email delivery, background
               jobs, webhook calls, cache invalidation, broadcasts, file uploads)
            6. **error_handling**: How errors are handled (rescue blocks, error responses, redirects)
            7. **input_params**: Parameters accepted (from strong params, query params, path segments)
            8. **output_format**: Response format (HTML, JSON, redirect, Turbo Stream, file download)
            9. **status**: Implementation status:
               - "implemented" — fully working action with real logic
               - "partial" — action exists but some paths are incomplete
               - "stubbed" — empty action or placeholder (raise NotImplementedError, render nothing)

            ## Stack
            Language: #{stack[:language]}
            Framework: #{stack[:framework]}
            #{stack[:meta] ? "Meta: #{stack[:meta]}" : ""}

            #{route_section}

            ## Controller Files
            #{controller_sections.empty? ? "(no controller files found)" : controller_sections}

            ## Instructions

            - Cross-reference the route table with controller actions to ensure completeness
            - If a route exists but the controller action is missing, include it with status "stubbed"
            - If a controller action exists but no matching route is found, still include it with a note
            - Look inside before_action filters to determine access_control
            - Check for respond_to blocks to determine output_format
            - Identify callbacks, mailer calls, job enqueues, and broadcasts as side_effects
            - Read strong_params / permit calls to identify input_params

            Return a JSON object with an "endpoints" array.
          PROMPT
        end
      end
    end
  end
end
