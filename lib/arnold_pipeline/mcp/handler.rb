require_relative "context"
require_relative "tools/base"
require_relative "tools/get_spec"
require_relative "tools/get_tasks"
require_relative "tools/describe_product"
require_relative "tools/explore_domain"
require_relative "tools/propose_change"
require_relative "tools/confirm_change"
require_relative "tools/start_task"
require_relative "tools/complete_task"
require_relative "tools/report_issue"
require_relative "tools/validate_tier"
require_relative "tools/ask_engineer"
require_relative "tools/explore_architecture"
require_relative "tools/explain_recipe"
require_relative "tools/detect_drift"
require_relative "tools/resolve_drift"
require_relative "tools/create_product"
require_relative "tools/init_project"
require_relative "tools/explore_persona"
require_relative "tools/explore_capability"
require_relative "tools/what_if"
require_relative "tools/get_history"

module ArnoldPipeline
  module Mcp
    class Handler
      ERROR_METHOD_NOT_FOUND = -32601
      ERROR_INVALID_PARAMS = -32602
      ERROR_INTERNAL = -32603

      def initialize(context: nil)
        @context = context || Context.new
        @tools = {}
        register_default_tools
      end

      def register(tool_class)
        @tools[tool_class.tool_name] = tool_class
      end

      def tools_list
        @tools.values.map { |tool|
          {
            name: tool.tool_name,
            description: tool.description,
            inputSchema: tool.input_schema
          }
        }
      end

      def call_tool(name, arguments = {})
        tool = @tools[name]
        unless tool
          return error_result(ERROR_METHOD_NOT_FOUND, "Unknown tool: #{name}")
        end

        result = tool.call(arguments, @context)
        {
          content: [
            { type: "text", text: JSON.generate(result) }
          ]
        }
      rescue ArgumentError => e
        error_result(ERROR_INVALID_PARAMS, e.message)
      rescue => e
        location = e.backtrace&.first&.sub(%r{.*/lib/}, "lib/")
        error_result(ERROR_INTERNAL, "#{e.class}: #{e.message} (at #{location})")
      end

      private

      def register_default_tools
        register(Tools::GetSpec)
        register(Tools::GetTasks)
        register(Tools::DescribeProduct)
        register(Tools::ExploreDomain)
        register(Tools::ProposeChange)
        register(Tools::ConfirmChange)
        register(Tools::StartTask)
        register(Tools::CompleteTask)
        register(Tools::ReportIssue)
        register(Tools::ValidateTier)
        register(Tools::AskEngineer)
        register(Tools::ExploreArchitecture)
        register(Tools::ExplainRecipe)
        register(Tools::DetectDrift)
        register(Tools::ResolveDrift)
        register(Tools::CreateProduct)
        register(Tools::InitProject)
        register(Tools::ExplorePersona)
        register(Tools::ExploreCapability)
        register(Tools::WhatIf)
        register(Tools::GetHistory)
      end

      def error_result(code, message)
        { error: { code: code, message: message } }
      end
    end
  end
end
