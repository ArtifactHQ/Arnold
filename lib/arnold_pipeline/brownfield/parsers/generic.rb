module ArnoldPipeline
  module Brownfield
    module Parsers
      class Generic
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
            methods: extract_functions,
            associations: [],
            validations: [],
            callbacks: [],
            scopes: [],
            includes: [],
            constants: extract_constants
          }
        end

        private

        def extract_classes
          results = []
          @lines.each_with_index do |line, idx|
            # Common class patterns across languages
            # class Foo, class Foo extends Bar, class Foo(Base):, class Foo : Bar
            if (match = line.match(/^\s*(?:(?:public|private|protected|abstract|final|export)\s+)*class\s+(\w+)(?:\s*(?:<|extends|:|inherits|\()\s*(\w+))?/))
              results << { name: match[1], superclass: match[2], line: idx + 1 }
            end
            # struct Foo
            if (match = line.match(/^\s*(?:pub\s+)?struct\s+(\w+)/))
              results << { name: match[1], superclass: nil, line: idx + 1 }
            end
          end
          results
        end

        def extract_functions
          results = []
          @lines.each_with_index do |line, idx|
            # function foo(, def foo(, fn foo(, func foo(, fun foo(, sub foo(
            if (match = line.match(/^\s*(?:(?:public|private|protected|export|async|static|pub)\s+)*(?:function|def|fn|func|fun|sub|proc)\s+(\w+)\s*[\(\{:]/))
              name = match[1]
              next if %w[if for while switch catch].include?(name)
              results << { name: name, line: idx + 1, visibility: "public" }
            end
            # Arrow function or const assignment: const foo = (...) =>
            if (match = line.match(/^\s*(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?(?:\([^)]*\)|[a-z]\w*)\s*=>/))
              results << { name: match[1], line: idx + 1, visibility: "public" }
            end
          end
          results
        end

        def extract_constants
          results = []
          @lines.each_with_index do |line, idx|
            # UPPER_CASE = value or const UPPER_CASE = value or static final ... UPPER_CASE =
            if (match = line.match(/(?:^|\s)([A-Z][A-Z0-9_]{2,})\s*[:=]/))
              results << { name: match[1], line: idx + 1 }
            end
          end
          results
        end
      end
    end
  end
end
