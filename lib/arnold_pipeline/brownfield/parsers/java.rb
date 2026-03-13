module ArnoldPipeline
  module Brownfield
    module Parsers
      class Java
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
            classes: extract_classes_and_interfaces,
            modules: [],
            methods: extract_methods,
            associations: [],
            validations: [],
            callbacks: extract_annotations,
            scopes: [],
            includes: extract_imports,
            constants: extract_constants
          }
        end

        private

        def extract_classes_and_interfaces
          results = []
          @lines.each_with_index do |line, idx|
            # public class Foo extends Bar implements Baz, Qux {
            if (match = line.match(/^\s*(?:public\s+|private\s+|protected\s+)?(?:abstract\s+|final\s+|static\s+)*(class|interface|enum)\s+(\w+)(?:<[^>]*>)?(?:\s+extends\s+(\w+)(?:<[^>]*>)?)?(?:\s+implements\s+([^{]+))?\s*\{?/))
              superclass = match[3]
              # For interfaces, extends is the "superclass"
              results << {
                name: match[2],
                superclass: superclass,
                line: idx + 1
              }
            end
          end
          results
        end

        def extract_methods
          results = []
          visibility = "public"

          @lines.each_with_index do |line, idx|
            # Skip annotations, imports, package declarations
            next if line.strip.start_with?("@", "import ", "package ")

            # Method pattern: [visibility] [static] [returnType] methodName(
            if (match = line.match(/^\s*(public|private|protected)?\s*(?:static\s+)?(?:final\s+)?(?:synchronized\s+)?(?:abstract\s+)?(?:\w+(?:<[^>]*>)?(?:\[\])*)\s+(\w+)\s*\(/))
              vis = match[1] || "package-private"
              name = match[2]
              # Skip constructors (name matches class) and common false positives
              next if name == "if" || name == "for" || name == "while" || name == "switch" || name == "catch"
              results << { name: name, line: idx + 1, visibility: vis }
            end
          end
          results
        end

        def extract_annotations
          results = []
          @lines.each_with_index do |line, idx|
            if (match = line.match(/^\s*@(\w+(?:\.\w+)*)/))
              annotation = match[1]
              # Look ahead for the annotated method/class name
              method_name = nil
              ((idx + 1)...@lines.length).each do |next_idx|
                next_line = @lines[next_idx]
                # Skip other annotations
                next if next_line.strip.start_with?("@")
                # Look for method or class declaration
                if (fn_match = next_line.match(/(?:class|interface|enum)\s+(\w+)/))
                  method_name = fn_match[1]
                  break
                elsif (fn_match = next_line.match(/(?:public|private|protected|static|final|abstract|synchronized|\w+(?:<[^>]*>)?(?:\[\])*)\s+(\w+)\s*\(/))
                  method_name = fn_match[1]
                  break
                end
                break
              end
              results << {
                type: annotation,
                method: method_name || "unknown"
              }
            end
          end
          results
        end

        def extract_imports
          results = []
          @lines.each do |line|
            if (match = line.match(/^\s*import\s+(?:static\s+)?([^;]+);/))
              results << match[1].strip
            end
          end
          results
        end

        def extract_constants
          results = []
          @lines.each_with_index do |line, idx|
            # static final TYPE CONSTANT_NAME = value
            if (match = line.match(/^\s*(?:public\s+|private\s+|protected\s+)?static\s+final\s+\w+(?:<[^>]*>)?\s+([A-Z][A-Z0-9_]+)\s*=/))
              results << { name: match[1], line: idx + 1 }
            end
          end
          results
        end
      end
    end
  end
end
