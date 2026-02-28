module ArnoldPipeline
  module Mcp
    module Tools
      class Base
        def self.tool_name
          raise NotImplementedError, "#{name} must implement .tool_name"
        end

        def self.description
          raise NotImplementedError, "#{name} must implement .description"
        end

        def self.input_schema
          raise NotImplementedError, "#{name} must implement .input_schema"
        end

        def self.call(params, context)
          raise NotImplementedError, "#{name} must implement .call"
        end
      end
    end
  end
end
