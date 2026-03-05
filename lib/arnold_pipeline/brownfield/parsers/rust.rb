module ArnoldPipeline
  module Brownfield
    module Parsers
      class Rust
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

        def self.call(content:)
          new(content:).call
        end

        def initialize(content:)
          @content = content
          @lines = content.lines
        end

        def call
          {
            classes: extract_structs_and_enums,
            modules: extract_modules,
            methods: extract_functions,
            associations: [],
            validations: [],
            callbacks: extract_derive_macros,
            scopes: [],
            includes: extract_use_statements,
            constants: extract_constants
          }
        end

        private

        def extract_structs_and_enums
          results = []
          @lines.each_with_index do |line, idx|
            # pub struct Foo { or struct Foo;
            if (match = line.match(/^\s*(?:pub(?:\([^)]*\))?\s+)?struct\s+(\w+)/))
              results << { name: match[1], superclass: nil, line: idx + 1 }
            end
            # pub enum Foo { or enum Foo {
            if (match = line.match(/^\s*(?:pub(?:\([^)]*\))?\s+)?enum\s+(\w+)/))
              results << { name: match[1], superclass: nil, line: idx + 1 }
            end
          end
          results
        end

        def extract_modules
          results = []
          @lines.each_with_index do |line, idx|
            if (match = line.match(/^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)/))
              results << { name: match[1], line: idx + 1 }
            end
          end
          results
        end

        def extract_functions
          results = []
          in_impl_block = nil

          @lines.each_with_index do |line, idx|
            # Track impl blocks for context
            if (match = line.match(/^\s*impl(?:<[^>]*>)?\s+(\w+)/))
              in_impl_block = match[1]
            end

            # fn declarations
            if (match = line.match(/^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?(?:const\s+)?fn\s+(\w+)/))
              visibility = line.match?(/^\s*pub/) ? "public" : "private"
              results << { name: match[1], line: idx + 1, visibility: visibility }
            end
          end
          results
        end

        def extract_derive_macros
          results = []
          @lines.each_with_index do |line, idx|
            # #[derive(Debug, Clone, Serialize)]
            if (match = line.match(/#\[derive\(([^)]+)\)\]/))
              derives = match[1].split(",").map(&:strip)
              # Look ahead for the struct/enum name
              target = nil
              ((idx + 1)...@lines.length).each do |next_idx|
                next_line = @lines[next_idx]
                next if next_line.strip.start_with?("#[") # skip other attributes
                if (t_match = next_line.match(/(?:struct|enum)\s+(\w+)/))
                  target = t_match[1]
                end
                break
              end
              derives.each do |d|
                results << { type: "derive", method: "#{d}(#{target || 'unknown'})" }
              end
            end
            # Other attributes: #[test], #[cfg(...)], #[serde(...)]
            if (match = line.match(/#\[(\w+)(?:\(|\])/))
              next if match[1] == "derive"
              target = nil
              ((idx + 1)...@lines.length).each do |next_idx|
                next_line = @lines[next_idx]
                next if next_line.strip.start_with?("#[")
                if (t_match = next_line.match(/(?:fn|struct|enum|impl|mod)\s+(\w+)/))
                  target = t_match[1]
                end
                break
              end
              results << { type: match[1], method: target || "unknown" }
            end
          end
          results
        end

        def extract_use_statements
          results = []
          @lines.each do |line|
            if (match = line.match(/^\s*use\s+([^;]+);/))
              results << match[1].strip
            end
          end
          results
        end

        def extract_constants
          results = []
          @lines.each_with_index do |line, idx|
            # const FOO: Type = value;
            if (match = line.match(/^\s*(?:pub(?:\([^)]*\))?\s+)?const\s+([A-Z][A-Z0-9_]+)\s*:/))
              results << { name: match[1], line: idx + 1 }
            end
            # static FOO: Type = value;
            if (match = line.match(/^\s*(?:pub(?:\([^)]*\))?\s+)?static\s+(?:mut\s+)?([A-Z][A-Z0-9_]+)\s*:/))
              results << { name: match[1], line: idx + 1 }
            end
          end
          results
        end
      end
    end
  end
end
