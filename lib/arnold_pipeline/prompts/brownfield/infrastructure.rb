module ArnoldPipeline
  module Prompts
    module Brownfield
      module Infrastructure
        FILE_PATTERNS = %w[
          config/**
          Procfile
          Dockerfile*
          .github/**
          .gitlab-ci.yml
          app/views/layouts/**
          app/javascript/controllers/**
          app/assets/**
        ].freeze

        def self.prompt(context:, file_contents:)
          stack = context.stack_fingerprint
          overlay = context.overlay || {}
          artifacts = context.artifacts || []
          concerns = context.concerns || {}

          artifact_summary = artifacts.select { |a| a[:path] }.map { |a|
            content_preview = a[:content] ? a[:content][0, 3000] : nil
            if content_preview
              "### #{a[:role]} (#{a[:path]})\n```\n#{content_preview}\n```"
            else
              "- #{a[:role]}: #{a[:path]} (#{a[:format]})"
            end
          }.join("\n\n")

          file_section = file_contents.filter_map { |path, content|
            next unless content
            "### #{path}\n```\n#{content[0, 4000]}\n```"
          }.join("\n\n")

          overlay_text = overlay.map { |concern_id, data|
            locations = data["expected_locations"]&.join(", ") || "unknown"
            implementations = data["typical_implementations"]&.join(", ") || "unknown"
            "- #{concern_id}: locations=[#{locations}], implementations=[#{implementations}]"
          }.join("\n")

          concern_list = concerns.map { |id, c|
            desc = c.is_a?(Hash) ? c["description"] || c[:description] : c.to_s
            name = c.is_a?(Hash) ? c["name"] || c[:name] || id : id
            "- #{id}: #{name} -- #{desc}"
          }.join("\n")

          stack_hints = stack_instructions(context)

          <<~PROMPT
            You are analyzing an existing #{stack[:language]}/#{stack[:framework]} codebase to understand its infrastructure, conventions, and cross-cutting concerns.

            ## Task: Infrastructure & Convention Analysis

            Analyze the configuration files, CI/CD setup, and build tooling to produce a comprehensive infrastructure profile.

            ### Part 1: Conventions
            Examine the codebase artifacts and file contents to identify:
            1. **naming_conventions**: Variable, method, class, and file naming patterns observed in the code
            2. **architecture_pattern**: MVC, hexagonal, clean architecture, service-oriented, etc.
            3. **test_framework**: minitest, rspec, jest, etc. (look at Gemfile, package.json, CI config)
            4. **code_style**: Formatting tools, linting rules (rubocop, eslint, prettier), indentation style
            5. **dependency_management**: How dependencies are managed (Bundler, npm/yarn), version pinning strategy
            6. **error_handling**: Common error handling patterns (rescue blocks, error classes, exception notification)
            7. **configuration_approach**: Environment variables, Rails credentials, config files, dotenv, etc.

            ### Part 2: Infrastructure
            Identify the infrastructure components and their configuration status.
            #{stack_hints[:infrastructure_areas]}

            For each infrastructure area, report:
            - **area**: Name of the infrastructure component
            - **description**: How it is configured and what it provides
            - **status**: "configured" (fully set up), "partial" (some config exists), or "missing" (not found)
            - **files**: Files that define or configure this area

            ### Part 3: Concerns
            Map each abstract concern to its presence in the codebase. For each concern, determine:
            - **concern_id**: The concern identifier
            - **status**: "present" (clearly implemented), "partial" (some evidence), or "absent" (not found)
            - **implementation**: The specific library or pattern that implements it (e.g., "devise", "has_secure_password"), or null if absent
            - **files**: Key files related to this concern
            - **notes**: Brief observations about the implementation approach or quality

            ## Stack Fingerprint
            - Language: #{stack[:language]}
            - Framework: #{stack[:framework]}
            - Version: #{stack[:version] || "unknown"}

            ## Framework Overlay (expected patterns for this stack)
            #{overlay_text.empty? ? "(none)" : overlay_text}

            ## Known Concerns
            #{concern_list.empty? ? "(none provided)" : concern_list}

            ## Discovered Artifacts
            #{artifact_summary.empty? ? "(none)" : artifact_summary}

            ## File Contents
            #{file_section.empty? ? "(no infrastructure files found)" : file_section}

            ## Instructions
            Return a JSON object with three top-level keys: "conventions", "infrastructure", and "concerns".
          PROMPT
        end

        def self.stack_instructions(context)
          require "arnold_pipeline/brownfield/stack_aware_file_selector"
          family = ArnoldPipeline::Brownfield::StackAwareFileSelector.stack_family(context)

          case family
          when "mobile"
            {
              infrastructure_areas: <<~AREAS
                Look for these mobile infrastructure areas:
                - Build tooling (Metro bundler, Babel, TypeScript config)
                - Native build configuration (Xcode/iOS plist, Gradle/Android manifest)
                - CI/CD pipeline (GitHub Actions, Fastlane, EAS Build)
                - Environment management (.env files, config modules)
                - Push notification setup (Firebase, APNs)
                - Navigation framework (React Navigation, Expo Router)
                - State management infrastructure (Redux store setup, middleware)
                - Native module integrations (camera, video, permissions)
                - Code signing and app distribution
                - Monitoring/crash reporting (Sentry, Crashlytics)
              AREAS
            }
          when "client_spa"
            {
              infrastructure_areas: <<~AREAS
                Look for these SPA infrastructure areas:
                - Build tooling (Next.js config, webpack, Vite, TypeScript)
                - CI/CD pipeline (GitHub Actions, Vercel)
                - Environment management (.env files)
                - API layer configuration (base URLs, auth headers)
                - State management infrastructure (store setup, providers)
                - Styling framework (Tailwind, CSS Modules, styled-components)
                - Middleware (Next.js middleware, auth guards)
                - Monitoring/error tracking (Sentry, LogRocket)
                - SSR/SSG configuration
              AREAS
            }
          else
            {
              infrastructure_areas: <<~AREAS
                Look for these infrastructure areas:
                - CI/CD pipeline (GitHub Actions, GitLab CI, etc.)
                - Deployment configuration (Procfile, Dockerfile, Kamal, Heroku)
                - Asset pipeline (Propshaft, Sprockets, esbuild, Vite)
                - JavaScript framework (Stimulus, Turbo, React, etc.)
                - Background jobs (Solid Queue, Sidekiq, etc.)
                - Caching (Solid Cache, Redis, Memcached)
                - Email delivery (Action Mailer config)
                - Database configuration (database.yml, multi-db setup)
                - Monitoring/logging (exception tracking, APM)
              AREAS
            }
          end
        end

        def self.select_files(context)
          require "arnold_pipeline/brownfield/stack_aware_file_selector"
          ArnoldPipeline::Brownfield::StackAwareFileSelector.select_files(context, "infrastructure") ||
            legacy_select_files(context)
        end

        def self.legacy_select_files(context)
          manifest = context.file_manifest || {}
          manifest.keys.select { |path| matches_patterns?(path) }
        end

        def self.matches_patterns?(path)
          FILE_PATTERNS.any? { |pattern| glob_match?(pattern, path) }
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
