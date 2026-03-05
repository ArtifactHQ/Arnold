module ArnoldPipeline
  module Brownfield
    module Parsers
      class Python
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
            classes: extract_classes,
            modules: [],
            methods: extract_methods,
            associations: [],
            validations: [],
            callbacks: extract_decorators,
            scopes: [],
            includes: extract_imports,
            constants: extract_constants
          }
        end

        private

        def extract_classes
          results = []
          @lines.each_with_index do |line, idx|
            if (match = line.match(/^\s*class\s+(\w+)(?:\(([^)]*)\))?\s*:/))
              superclass = match[2]&.strip
              superclass = nil if superclass&.empty?
              # Handle multiple inheritance — take the first base class
              if superclass&.include?(",")
                superclass = superclass.split(",").first.strip
              end
              results << {
                name: match[1],
                superclass: superclass,
                line: idx + 1
              }
            end
          end
          results
        end

        def extract_methods
          results = []
          @lines.each_with_index do |line, idx|
            if (match = line.match(/^(\s*)def\s+(\w+)\s*\(/))
              indent = match[1].length
              name = match[2]
              visibility = if name.start_with?("__") && name.end_with?("__")
                "public"  # dunder methods are public
              elsif name.start_with?("__")
                "private"
              elsif name.start_with?("_")
                "protected"
              else
                "public"
              end
              results << { name: name, line: idx + 1, visibility: visibility }
            end
          end
          results
        end

        def extract_decorators
          results = []
          @lines.each_with_index do |line, idx|
            if (match = line.match(/^\s*@(\w+(?:\.\w+)*)/))
              # Look ahead for the decorated function/method name
              method_name = nil
              ((idx + 1)...@lines.length).each do |next_idx|
                next_line = @lines[next_idx]
                if (fn_match = next_line.match(/^\s*(?:def|class)\s+(\w+)/))
                  method_name = fn_match[1]
                  break
                end
                # Skip other decorators stacked on top
                break unless next_line.match?(/^\s*@/)
              end
              results << {
                type: match[1],
                method: method_name || "unknown"
              }
            end
          end
          results
        end

        def extract_imports
          results = []
          @lines.each do |line|
            # import module
            if (match = line.match(/^\s*import\s+(\S+)/))
              results << match[1]
            # from module import ...
            elsif (match = line.match(/^\s*from\s+(\S+)\s+import/))
              results << match[1]
            end
          end
          results
        end

        def extract_constants
          results = []
          @lines.each_with_index do |line, idx|
            # UPPER_CASE = value (at module level — no leading whitespace or minimal)
            if (match = line.match(/^([A-Z][A-Z0-9_]+)\s*=/))
              results << { name: match[1], line: idx + 1 }
            end
          end
          results
        end
      end
    end
  end
end
