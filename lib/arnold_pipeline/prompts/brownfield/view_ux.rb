module ArnoldPipeline
  module Prompts
    module Brownfield
      module ViewUx
        def self.prompt(context:, file_contents:)
          stack = context.stack_fingerprint

          view_sections = []
          helper_sections = []
          js_sections = []
          component_sections = []

          file_contents.each do |path, content|
            next unless content

            truncated = content.length > 4000 ? content[0, 4000] + "\n<!-- ... [truncated] -->" : content

            case path
            when /\Aapp\/views\//
              view_sections << "### #{path}\n```\n#{truncated}\n```"
            when /\Aapp\/helpers\//
              helper_sections << "### #{path}\n```ruby\n#{truncated}\n```"
            when /\Aapp\/javascript\/controllers\//
              js_sections << "### #{path}\n```javascript\n#{truncated}\n```"
            when /\Aapp\/components\//
              component_sections << "### #{path}\n```\n#{truncated}\n```"
            end
          end

          <<~PROMPT
            You are analyzing the view and user experience layer of an existing #{stack[:language]}/#{stack[:framework]} codebase.

            ## Task: View & UX Page Analysis

            Examine every view template, helper, JavaScript controller, and component to produce
            a complete inventory of user-facing pages and their capabilities. For each page,
            analyze WHAT THE USER SEES AND CAN DO — not just the template structure.

            ## What to Analyze Per Page

            1. **name**: Human-readable page name (e.g., "User Dashboard", "Login Form", "Product List")
            2. **path**: View template path (e.g., "app/views/users/index.html.erb")
            3. **description**: What the page shows and its purpose (1-2 sentences)
            4. **data_displayed**: What data is rendered on the page (e.g., "user profile info",
               "list of orders with status badges", "chart of monthly revenue")
            5. **actions**: User interactions available on the page (e.g., "submit login form",
               "click edit button", "filter by date range", "drag to reorder")
            6. **role_adaptations**: How the page changes based on user role or state (e.g.,
               "admin sees delete button", "logged-out users see signup CTA",
               "empty state when no records")
            7. **layout**: Which layout wraps this page (e.g., "application", "admin", "devise")
            8. **javascript_controllers**: Stimulus/Turbo/JS controllers attached to elements
               on this page
            9. **status**: Implementation status:
               - "implemented" — fully rendered page with real content
               - "partial" — page exists but some sections are incomplete or placeholder
               - "stubbed" — empty template or minimal placeholder content

            ## Stack
            Language: #{stack[:language]}
            Framework: #{stack[:framework]}
            #{stack[:meta] ? "Meta: #{stack[:meta]}" : ""}

            ## View Templates
            #{view_sections.empty? ? "(no view templates found)" : view_sections.join("\n\n")}

            ## Helper Files
            #{helper_sections.empty? ? "(no helper files found)" : helper_sections.join("\n\n")}

            ## JavaScript Controllers (Stimulus/Turbo)
            #{js_sections.empty? ? "(no JavaScript controllers found)" : js_sections.join("\n\n")}

            ## Components (ViewComponent / Phlex / Partials)
            #{component_sections.empty? ? "(no component files found)" : component_sections.join("\n\n")}

            ## Instructions

            - Group related templates into logical PAGES (e.g., index + _item partial = one "List" page)
            - Partials (_partial.html.erb) should be associated with the parent page, not listed separately
              unless they are shared across multiple pages
            - Look for `render` calls to identify which partials belong to which pages
            - Examine helpers for view logic that affects data presentation
            - Check Stimulus controller `connect()`, `targets`, and action methods to identify interactivity
            - Look for `turbo_frame_tag`, `turbo_stream`, and `data-turbo-*` attributes for Turbo integration
            - Identify conditional rendering (`if current_user.admin?`, `policy().show?`) for role_adaptations
            - Check `content_for :layout` or `layout` declarations for layout information

            Return a JSON object with a "pages" array.
          PROMPT
        end
      end
    end
  end
end
