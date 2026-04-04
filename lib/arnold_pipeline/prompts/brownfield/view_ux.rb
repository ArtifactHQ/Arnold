module ArnoldPipeline
  module Prompts
    module Brownfield
      module ViewUx
        def self.prompt(context:, file_contents:)
          stack = context.stack_fingerprint
          stack_hints = stack_instructions(context)

          file_groups = categorize_files(file_contents, stack_hints[:file_categories])

          file_sections_text = file_groups.map { |group_name, entries|
            next if entries.empty?
            "## #{group_name}\n#{entries.join("\n\n")}"
          }.compact.join("\n\n")

          if file_sections_text.empty?
            file_sections_text = "(no view/component files found)"
          end

          <<~PROMPT
            You are analyzing the view and user experience layer of an existing #{stack[:language]}/#{stack[:framework]} codebase.

            ## Task: #{stack_hints[:task_title]}

            #{stack_hints[:task_description]}

            ## What to Analyze Per Page

            Think from the USER'S perspective — what can they accomplish here?

            1. **name**: Human-readable page name (e.g., #{stack_hints[:page_examples]})
            2. **path**: #{stack_hints[:path_hint]}
            3. **description**: What the user can ACCOMPLISH on this page — the product value, not just
               the template structure (e.g., "Allows caregivers to review and update daily checklists
               for their assigned clients" not "Renders a list component with checkboxes")
            4. **data_displayed**: What information the user sees, described in domain terms
               (e.g., "client name, care plan items with completion status, upcoming appointments"
               not "array of objects rendered in FlatList")
            5. **actions**: What the user can DO — described as user actions, not code events
               (e.g., "add a new checklist item", "start a video call", "mark task complete"
               not "dispatch ADD_ITEM action", "call onPress handler")
            6. **role_adaptations**: How the page changes based on user role or state
            7. **layout**: #{stack_hints[:layout_hint]}
            8. **javascript_controllers**: #{stack_hints[:js_controllers_hint]}
            9. **status**: Implementation status:
               - "implemented" — fully rendered page with real content
               - "partial" — page exists but some sections are incomplete or placeholder
               - "stubbed" — empty template or minimal placeholder content
            10. **feature_domain**: The product feature this screen belongs to, named from the
               user's perspective (e.g., "Care Plan Management", "Video Consultations",
               "User Onboarding", "Messaging"). Use consistent names — screens that are part
               of the same product feature MUST share the same feature_domain value.
               Infer from screen name, data displayed, and user actions.
               If the screen is a shared/utility screen (e.g., Settings, Profile), use
               a general domain like "Account Management" or "App Settings".

            ## Stack
            Language: #{stack[:language]}
            Framework: #{stack[:framework]}
            #{stack[:meta] ? "Meta: #{stack[:meta]}" : ""}

            #{file_sections_text}

            ## Instructions
            #{stack_hints[:instructions]}

            Return a JSON object with a "pages" array.
          PROMPT
        end

        def self.categorize_files(file_contents, categories)
          groups = categories.transform_values { [] }
          fallback_key = categories.keys.last

          file_contents.each do |path, content|
            next unless content
            truncated = content.length > 4000 ? content[0, 4000] + "\n// ... [truncated]" : content

            matched = false
            categories.each do |group_name, patterns|
              next unless patterns.is_a?(Array)
              if patterns.any? { |pat| path.match?(pat) }
                groups[group_name] << "### #{path}\n```\n#{truncated}\n```"
                matched = true
                break
              end
            end
            groups[fallback_key] << "### #{path}\n```\n#{truncated}\n```" unless matched
          end
          groups
        end

        def self.stack_instructions(context)
          require "arnold_pipeline/brownfield/stack_aware_file_selector"
          family = ArnoldPipeline::Brownfield::StackAwareFileSelector.stack_family(context)

          case family
          when "mobile"
            {
              task_title: "Screen & Component Analysis",
              task_description: "Examine every screen, component, and layout element to produce a complete inventory of user-facing screens and their capabilities. For each screen, analyze WHAT THE USER SEES AND CAN DO.",
              page_examples: '"Client Dashboard", "Login Screen", "Care Plan View"',
              path_hint: "Screen component file path (e.g., src/pages/client/ClientDashboard.tsx)",
              layout_hint: 'Which layout or navigator wraps this screen (e.g., "AuthenticatedLayout", "BottomTabNavigator", "DrawerNavigator")',
              js_controllers_hint: "Custom hooks, gesture handlers, or native module integrations used on this screen",
              file_categories: {
                "Screen Components" => [ /\Asrc\/(?:pages|screens)\// ],
                "Shared UI Components" => [ /\Asrc\/components\/ui\//, /\Asrc\/components\/layout\// ],
                "Feature Components" => [ /\Asrc\/components\// ],
                "Theme & Styling" => [ /\Asrc\/theme\// ]
              },
              instructions: <<~INST
                - Group related components into logical SCREENS (e.g., a page + its tab components = one screen)
                - Identify which navigator each screen belongs to (stack, tab, drawer)
                - Look for useNavigation/useRoute hooks to understand navigation patterns
                - Examine data fetching: Redux selectors, API hooks, context consumers
                - Identify form components and their validation (Formik, Yup)
                - Check for conditional rendering based on user role or auth state
                - Note accessibility props (accessibilityLabel, accessibilityRole)
                - Identify gesture handlers (swipe, long press, pull to refresh)
                - Look for platform-specific code (Platform.OS checks, .ios/.android suffixes)
                - If localization/i18n files are present, use translation keys to identify ALL user-facing
                  labels, buttons, error messages, and copy — these reveal product features even if the
                  screen code is hard to parse
                - If feature-organized directories exist (src/features/*/, src/modules/*/), treat each
                  directory as a likely product feature domain
              INST
            }
          when "client_spa"
            {
              task_title: "Page & Component Analysis",
              task_description: "Examine every page, layout, and component to produce a complete inventory of user-facing pages and their capabilities. For each page, analyze WHAT THE USER SEES AND CAN DO.",
              page_examples: '"Dashboard", "Login Page", "Settings"',
              path_hint: "Page file path (e.g., app/dashboard/page.tsx)",
              layout_hint: 'Which layout wraps this page (e.g., "RootLayout", "DashboardLayout")',
              js_controllers_hint: "Client-side hooks, event handlers, or third-party widget integrations used on this page",
              file_categories: {
                "Pages" => [ /page\.tsx\z/, /\/pages\// ],
                "Layouts" => [ /layout\.tsx\z/ ],
                "Components" => [ /\/components\// ],
                "Hooks" => [ /\/hooks\// ]
              },
              instructions: <<~INST
                - Group related components into logical PAGES
                - Identify Server vs Client Components (look for "use client" directive)
                - Check loading.tsx and error.tsx for loading/error UX patterns
                - Examine data fetching patterns (fetch in Server Components, useQuery in Client Components)
                - Look for form actions (Server Actions, form handlers)
                - Identify responsive design patterns (media queries, responsive props)
                - Check for conditional rendering based on auth state or user role
              INST
            }
          else
            {
              task_title: "View & UX Page Analysis",
              task_description: "Examine every view template, helper, JavaScript controller, and component to produce a complete inventory of user-facing pages and their capabilities. For each page, analyze WHAT THE USER SEES AND CAN DO — not just the template structure.",
              page_examples: '"User Dashboard", "Login Form", "Product List"',
              path_hint: 'View template path (e.g., "app/views/users/index.html.erb")',
              layout_hint: 'Which layout wraps this page (e.g., "application", "admin", "devise")',
              js_controllers_hint: "Stimulus/Turbo/JS controllers attached to elements on this page",
              file_categories: {
                "View Templates" => [ /\Aapp\/views\// ],
                "Helper Files" => [ /\Aapp\/helpers\// ],
                "JavaScript Controllers (Stimulus/Turbo)" => [ /\Aapp\/javascript\/controllers\// ],
                "Components (ViewComponent / Phlex / Partials)" => [ /\Aapp\/components\// ]
              },
              instructions: <<~INST
                - Group related templates into logical PAGES (e.g., index + _item partial = one "List" page)
                - Partials (_partial.html.erb) should be associated with the parent page, not listed separately
                  unless they are shared across multiple pages
                - Look for `render` calls to identify which partials belong to which pages
                - Examine helpers for view logic that affects data presentation
                - Check Stimulus controller `connect()`, `targets`, and action methods to identify interactivity
                - Look for `turbo_frame_tag`, `turbo_stream`, and `data-turbo-*` attributes for Turbo integration
                - Identify conditional rendering (`if current_user.admin?`, `policy().show?`) for role_adaptations
                - Check `content_for :layout` or `layout` declarations for layout information
              INST
            }
          end
        end
      end
    end
  end
end
