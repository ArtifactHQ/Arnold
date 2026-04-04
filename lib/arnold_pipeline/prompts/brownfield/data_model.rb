module ArnoldPipeline
  module Prompts
    module Brownfield
      module DataModel
        FILE_PATTERNS = %w[
          app/models/**/*.rb
          db/schema.rb
          db/migrate/**
          app/models/concerns/**
        ].freeze

        def self.prompt(context:, file_contents:)
          stack = context.stack_fingerprint

          file_section = file_contents.filter_map { |path, content|
            next unless content
            "### #{path}\n```\n#{content[0, 6000]}\n```"
          }.join("\n\n")

          # Include schema artifact if available and not already in file_contents
          schema_artifact = (context.artifacts || []).find { |a| a[:role] == "schema" || a[:path] == "db/schema.rb" }
          schema_section = if schema_artifact && schema_artifact[:content] && !file_contents.key?("db/schema.rb")
            "### db/schema.rb (from artifacts)\n```\n#{schema_artifact[:content][0, 8000]}\n```"
          else
            ""
          end

          route_table = context.route_table
          route_section = if route_table && !route_table.empty?
            "## Route Table (for context on resource naming)\n```\n#{route_table[0, 3000]}\n```"
          else
            ""
          end

          stack_hints = stack_instructions(context)

          <<~PROMPT
            You are analyzing an existing #{stack[:language]}/#{stack[:framework]} codebase to understand its data model layer.

            ## Task: Data Model Analysis

            #{stack_hints[:task_description]}

            ### Part 1: Entities
            For each #{stack_hints[:entity_term]} discovered, extract:
            1. **name**: The #{stack_hints[:entity_name_hint]} (e.g., #{stack_hints[:entity_examples]})
            2. **table**: #{stack_hints[:table_hint]}
            3. **file**: The file path where it is defined
            4. **attributes**: #{stack_hints[:attributes_hint]}
            5. **associations**: #{stack_hints[:associations_hint]}
            6. **validations**: Array of validation or constraint declarations as strings
            7. **callbacks**: Array of lifecycle hook or side-effect declarations as strings
            8. **scopes**: Array of query helpers, selectors, or computed derivations as strings
            9. **business_methods**: Array of significant methods with name and a short description of what they do
            10. **status**: "implemented" (fully functional), "partial" (exists but incomplete), or "stubbed" (placeholder)
            11. **feature_domain**: The primary product feature this entity supports, named
               from the user's perspective (e.g., "Care Plan Management", "Video Consultations",
               "User Onboarding", "Messaging"). Use consistent names — entities that support
               the same product feature MUST share the same feature_domain value. Infer from
               the entity name, its relationships, and what user-facing data it represents.
               If the entity is shared across many features (e.g., User, Organization), use
               the most central feature or "Core Data".

            ### Part 2: Relationships
            Identify all relationships between entities:
            1. **from**: Source entity name
            2. **to**: Target entity name
            3. **type**: Relationship type (#{stack_hints[:relationship_types]})
            4. **through**: #{stack_hints[:through_hint]}

            ## What to Look For
            #{stack_hints[:look_for]}

            ## Stack Fingerprint
            - Language: #{stack[:language]}
            - Framework: #{stack[:framework]}

            #{schema_section}

            #{route_section}

            ## Model & Migration Files
            #{file_section.empty? ? "(no model files found)" : file_section}

            ## Instructions
            Return a JSON object with two top-level keys: "entities" and "relationships".
            - "entities" is an array of entity objects
            - "relationships" is an array of relationship objects
            Ensure every entity discovered in the schema or model files is included.
          PROMPT
        end

        def self.stack_instructions(context)
          require "arnold_pipeline/brownfield/stack_aware_file_selector"
          family = ArnoldPipeline::Brownfield::StackAwareFileSelector.stack_family(context)

          case family
          when "mobile"
            {
              task_description: "Examine the Redux store, state slices, API service layer, TypeScript types, and context providers to produce a comprehensive data model inventory. In a mobile client app, the 'data model' is the shape of client-side state and the API contracts it consumes.",
              entity_term: "state slice or data entity",
              entity_name_hint: "slice or type name",
              entity_examples: '"User", "Client", "AuthState"',
              table_hint: 'The Redux slice key or API resource name (e.g., "auth", "clients", "todos")',
              attributes_hint: "Array of state properties or TypeScript type fields with name and type",
              associations_hint: "Array of relationships between state slices (e.g., a client has many todos) with type and name",
              relationship_types: "has_many, belongs_to, references, nested_in",
              through_hint: "Intermediate entity if applicable, or null",
              look_for: <<~LOOK
                - Redux reducer/slice files (state shape definitions)
                - Redux store configuration (which slices exist)
                - TypeScript interfaces and types (API response shapes)
                - Context providers (AuthContext, ThemeContext, etc.)
                - API service files (the shape of data sent/received)
                - AsyncStorage keys (persisted state)
                - Selector functions (derived data relationships)
                - Initial state declarations (default values and structure)
                - GraphQL queries, mutations, and fragments (*.graphql files, src/graphql/) — these
                  define the exact data contract between client and server
                - API contract files (openapi.*, swagger.*) — define all available endpoints and
                  their request/response shapes
                - If backend source exists (backend/, server/, api/), examine server-side models
                  and schema to understand the canonical data model the app consumes
                - If feature-organized directories exist (src/features/*/, src/modules/*/), examine
                  per-feature types, models, and API files
              LOOK
            }
          when "client_spa"
            {
              task_description: "Examine the data layer — database schema (Prisma/Drizzle), API routes, TypeScript types, and state management — to produce a comprehensive data model inventory.",
              entity_term: "model or entity",
              entity_name_hint: "model or type name",
              entity_examples: '"User", "Post", "Comment"',
              table_hint: 'The database table name or API resource name',
              attributes_hint: "Array of field definitions with name and type (from schema or TypeScript types)",
              associations_hint: "Array of relationships with type and name",
              relationship_types: "has_many, belongs_to, has_one, many_to_many",
              through_hint: "Join table or intermediate model if applicable, or null",
              look_for: <<~LOOK
                - Prisma or Drizzle schema definitions
                - TypeScript types and interfaces for data models
                - API route handlers that reveal data structure
                - Server Actions that interact with the data layer
                - Database migration files
                - Zod or Yup validation schemas
              LOOK
            }
          else
            {
              task_description: "Examine the model files, database schema, migrations, and model concerns to produce a comprehensive data model inventory.",
              entity_term: "model/entity",
              entity_name_hint: "class name",
              entity_examples: '"User", "Post"',
              table_hint: 'The database table name (e.g., "users", "posts")',
              attributes_hint: "Array of column/attribute definitions with name and type (from schema.rb or migrations)",
              associations_hint: "Array of ActiveRecord associations (has_many, belongs_to, has_one, has_and_belongs_to_many) with type and name",
              relationship_types: "has_many, belongs_to, has_one, has_many_through, has_and_belongs_to_many",
              through_hint: "Join model/table name if it's a through relationship, or null",
              look_for: <<~LOOK
                - ActiveRecord model files in app/models/
                - Schema definitions in db/schema.rb (definitive column/type source)
                - Migration files in db/migrate/ (for understanding schema evolution)
                - Model concerns in app/models/concerns/ (shared behavior modules)
                - STI (Single Table Inheritance) patterns
                - Polymorphic associations
                - Enum declarations
                - Delegated types
                - Counter caches
                - Touch declarations on associations
              LOOK
            }
          end
        end

        def self.select_files(context)
          require "arnold_pipeline/brownfield/stack_aware_file_selector"
          ArnoldPipeline::Brownfield::StackAwareFileSelector.select_files(context, "data_model") ||
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
