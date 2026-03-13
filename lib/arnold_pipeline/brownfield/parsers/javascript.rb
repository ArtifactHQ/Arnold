module ArnoldPipeline
  module Brownfield
    module Parsers
      class Javascript
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
            callbacks: [],
            scopes: [],
            includes: extract_imports,
            constants: extract_constants
          }
        end

        private

        def extract_classes
          results = []
          @lines.each_with_index do |line, idx|
            # class Foo extends Bar
            if (match = line.match(/^\s*(?:export\s+(?:default\s+)?)?class\s+(\w+)(?:\s+extends\s+(\w+))?\s*\{?/))
              results << {
                name: match[1],
                superclass: match[2],
                line: idx + 1
              }
            end
          end

          # React functional components: const Foo = (props) => { or function Foo(
          @lines.each_with_index do |line, idx|
            # const ComponentName = (props) => or const ComponentName = () =>
            if (match = line.match(/^\s*(?:export\s+(?:default\s+)?)?(?:const|let|var)\s+([A-Z]\w*)\s*=\s*(?:\([^)]*\)|[a-z]\w*)\s*=>/))
              # Only add if not already found as a class
              unless results.any? { |r| r[:name] == match[1] }
                results << {
                  name: match[1],
                  superclass: nil,
                  line: idx + 1
                }
              end
            end
            # function ComponentName( — only if starts with capital (React convention)
            if (match = line.match(/^\s*(?:export\s+(?:default\s+)?)?function\s+([A-Z]\w*)\s*\(/))
              unless results.any? { |r| r[:name] == match[1] }
                results << {
                  name: match[1],
                  superclass: nil,
                  line: idx + 1
                }
              end
            end
          end
          results
        end

        def extract_methods
          results = []
          @lines.each_with_index do |line, idx|
            # function declarations: function foo(
            if (match = line.match(/^\s*(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s+([a-z_]\w*)\s*\(/))
              results << { name: match[1], line: idx + 1, visibility: "public" }
            end

            # const/let/var foo = (...) => or const foo = function(
            if (match = line.match(/^\s*(?:export\s+(?:default\s+)?)?(?:const|let|var)\s+([a-z_]\w*)\s*=\s*(?:async\s+)?(?:\([^)]*\)|[a-z]\w*)\s*=>/))
              results << { name: match[1], line: idx + 1, visibility: "public" }
            elsif (match = line.match(/^\s*(?:export\s+(?:default\s+)?)?(?:const|let|var)\s+([a-z_]\w*)\s*=\s*(?:async\s+)?function/))
              results << { name: match[1], line: idx + 1, visibility: "public" }
            end

            # class method: methodName( { or async methodName(
            if (match = line.match(/^\s*(?:async\s+)?([a-z_]\w*)\s*\([^)]*\)\s*\{/))
              name = match[1]
              # Skip control flow keywords
              next if %w[if for while switch catch].include?(name)
              results << { name: name, line: idx + 1, visibility: "public" }
            end
          end
          results
        end

        def extract_imports
          results = []
          @lines.each do |line|
            # import X from 'y'
            if (match = line.match(/^\s*import\s+(.+?)\s+from\s+['"]([^'"]+)['"]/))
              results << match[2]
            # import 'y'
            elsif (match = line.match(/^\s*import\s+['"]([^'"]+)['"]/))
              results << match[1]
            # const X = require('y')
            elsif (match = line.match(/require\s*\(\s*['"]([^'"]+)['"]\s*\)/))
              results << match[1]
            end
          end
          results
        end

        def extract_constants
          results = []
          @lines.each_with_index do |line, idx|
            # const UPPER_CASE = value
            if (match = line.match(/^\s*(?:export\s+)?const\s+([A-Z][A-Z0-9_]+)\s*=/))
              results << { name: match[1], line: idx + 1 }
            end
          end
          results
        end
      end
    end
  end
end
