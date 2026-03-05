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

          <<~PROMPT
            You are analyzing an existing #{stack[:language]}/#{stack[:framework]} codebase to understand its data model layer.

            ## Task: Data Model Analysis

            Examine the model files, database schema, migrations, and model concerns to produce a comprehensive data model inventory.

            ### Part 1: Entities
            For each model/entity discovered, extract:
            1. **name**: The class name (e.g., "User", "Post")
            2. **table**: The database table name (e.g., "users", "posts")
            3. **file**: The file path where the model is defined
            4. **attributes**: Array of column/attribute definitions with name and type (from schema.rb or migrations)
            5. **associations**: Array of ActiveRecord associations (has_many, belongs_to, has_one, has_and_belongs_to_many) with type and name
            6. **validations**: Array of validation declarations as strings (e.g., "validates :email, presence: true, uniqueness: true")
            7. **callbacks**: Array of callback declarations as strings (e.g., "before_save :normalize_email")
            8. **scopes**: Array of named scopes as strings (e.g., "scope :active, -> { where(active: true) }")
            9. **business_methods**: Array of significant instance/class methods with name and a short description of what they do
            10. **status**: "implemented" (fully functional model with migrations), "partial" (model exists but incomplete), or "stubbed" (placeholder)

            ### Part 2: Relationships
            Identify all relationships between entities:
            1. **from**: Source entity name
            2. **to**: Target entity name
            3. **type**: Relationship type (has_many, belongs_to, has_one, has_many_through, has_and_belongs_to_many)
            4. **through**: Join model/table name if it's a through relationship, or null

            ## What to Look For
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

        def self.select_files(context)
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
