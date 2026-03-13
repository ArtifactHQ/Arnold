module ArnoldPipeline
  module Brownfield
    module Parsers
      class Ruby
        EMPTY_RESULT = {
          classes: [],
          modules: [],
          methods: [],
          associations: [],
          validations: [],
          callbacks: [],
          scopes: [],
          includes: [],
          constants: []
        }.freeze

        ASSOCIATION_TYPES = %w[has_many has_one belongs_to has_and_belongs_to_many].freeze
        CALLBACK_PREFIXES = %w[before_ after_ around_].freeze
        CALLBACK_HOOKS = %w[
          before_validation after_validation
          before_save after_save around_save
          before_create after_create around_create
          before_update after_update around_update
          before_destroy after_destroy around_destroy
          before_action after_action around_action
          before_commit after_commit after_create_commit after_update_commit after_destroy_commit
          after_rollback after_initialize after_find after_touch
        ].freeze

        def self.call(content:)
          new(content:).call
        end

        def initialize(content:)
          @content = content
          @lines = content.lines
        end

        def call
          {
            classes: extract_classes,
            modules: extract_modules,
            methods: extract_methods,
            associations: extract_associations,
            validations: extract_validations,
            callbacks: extract_callbacks,
            scopes: extract_scopes,
            includes: extract_includes,
            constants: extract_constants
          }
        end

        private

        def extract_classes
          results = []
          @lines.each_with_index do |line, idx|
            if (match = line.match(/^\s*class\s+([A-Z]\w*(?:::[A-Z]\w*)*)(?:\s*<\s*(\S+))?\s*$/))
              results << {
                name: match[1],
                superclass: match[2],
                line: idx + 1
              }
            end
          end
          results
        end

        def extract_modules
          results = []
          @lines.each_with_index do |line, idx|
            if (match = line.match(/^\s*module\s+([A-Z]\w*(?:::[A-Z]\w*)*)\s*$/))
              results << { name: match[1], line: idx + 1 }
            end
          end
          results
        end

        def extract_methods
          results = []
          visibility = "public"

          @lines.each_with_index do |line, idx|
            stripped = line.strip

            case stripped
            when "private"
              visibility = "private"
            when "protected"
              visibility = "protected"
            when "public"
              visibility = "public"
            end

            if (match = line.match(/^\s*def\s+(self\.)?(\w+[\w?!=]*)/))
              method_name = match[1] ? "self.#{match[2]}" : match[2]
              results << {
                name: method_name,
                line: idx + 1,
                visibility: match[1] ? "public" : visibility
              }
            end
          end
          results
        end

        def extract_associations
          results = []
          pattern = /^\s*(#{ASSOCIATION_TYPES.join("|")})\s+:(\w+)(?:,\s*(.+))?\s*$/

          @lines.each do |line|
            if (match = line.match(pattern))
              options = parse_options(match[3])
              results << {
                type: match[1],
                name: match[2],
                options: options
              }
            end
          end
          results
        end

        def extract_validations
          results = []
          @lines.each do |line|
            if (match = line.match(/^\s*validates?\s+:(\w+)(?:,\s*(.+))?\s*$/))
              results << {
                type: line.strip.start_with?("validate ") ? "validate" : "validates",
                field: match[1],
                options: match[2]&.strip || ""
              }
            elsif (match = line.match(/^\s*validate\s+:(\w+)/))
              results << {
                type: "validate",
                field: match[1],
                options: ""
              }
            end
          end
          results
        end

        def extract_callbacks
          results = []
          callback_pattern = /^\s*(#{CALLBACK_HOOKS.join("|")})\s+:(\w+[?!]?)/

          @lines.each do |line|
            if (match = line.match(callback_pattern))
              results << {
                type: match[1],
                method: match[2]
              }
            end
          end
          results
        end

        def extract_scopes
          results = []
          @lines.each_with_index do |line, idx|
            if (match = line.match(/^\s*scope\s+:(\w+)/))
              results << { name: match[1], line: idx + 1 }
            end
          end
          results
        end

        def extract_includes
          results = []
          @lines.each do |line|
            if (match = line.match(/^\s*include\s+(\S+)/))
              results << match[1]
            elsif (match = line.match(/^\s*extend\s+(\S+)/))
              results << match[1]
            end
          end
          results
        end

        def extract_constants
          results = []
          @lines.each_with_index do |line, idx|
            if (match = line.match(/^\s*([A-Z][A-Z0-9_]+)\s*=/))
              results << { name: match[1], line: idx + 1 }
            end
          end
          results
        end

        def parse_options(options_str)
          return {} if options_str.nil? || options_str.strip.empty?

          result = {}
          options_str.scan(/(\w+):\s*(?::(\w+)|"([^"]*)"|(true|false|\d+))/) do |key, sym, str, lit|
            result[key] = sym || str || lit
          end
          result
        end
      end
    end
  end
end
