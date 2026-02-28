require "test_helper"
require "arnold_pipeline/mcp/handler"

module ArnoldPipeline
  module Mcp
    class HandlerTest < ActiveSupport::TestCase
      cover "ArnoldPipeline::Mcp::Handler*"

      setup do
        @context = Context.new
        @handler = Handler.new(context: @context)
        @run = PipelineRun.create!(nl_input: "test app")
        Specification.create!(pipeline_run: @run, content: "# Spec", version: 1)
      end

      teardown do
        ArnoldPipeline.reset_configuration!
      end

      test "tools_list returns registered tools" do
        tools = @handler.tools_list
        assert_kind_of Array, tools
        names = tools.map { |t| t[:name] }
        assert_includes names, "get_spec"
        assert_includes names, "get_tasks"
      end

      test "tools_list includes description and inputSchema for each tool" do
        tools = @handler.tools_list
        tools.each do |tool|
          assert tool[:name], "Tool must have a name"
          assert tool[:description], "Tool must have a description"
          assert tool[:inputSchema], "Tool must have an inputSchema"
        end
      end

      test "call_tool dispatches to correct tool" do
        result = @handler.call_tool("get_spec", {})
        assert result[:content]
        assert_equal "text", result[:content].first[:type]

        parsed = JSON.parse(result[:content].first[:text])
        assert_equal @run.id.to_s, parsed["run_id"]
      end

      test "call_tool returns MCP content format" do
        result = @handler.call_tool("get_spec", {})

        assert_kind_of Array, result[:content]
        assert_equal 1, result[:content].length
        assert_equal "text", result[:content].first[:type]
        assert_kind_of String, result[:content].first[:text]
      end

      test "call_tool returns error for unknown tool" do
        result = @handler.call_tool("nonexistent_tool", {})
        assert result[:error]
        assert_equal Handler::ERROR_METHOD_NOT_FOUND, result[:error][:code]
        assert_includes result[:error][:message], "nonexistent_tool"
      end

      test "call_tool handles internal errors gracefully" do
        Tools::GetSpec.stubs(:call).raises(RuntimeError, "something broke")
        result = @handler.call_tool("get_spec", {})
        assert result[:error]
        assert_equal Handler::ERROR_INTERNAL, result[:error][:code]
        assert_includes result[:error][:message], "something broke"
      end

      test "call_tool handles argument errors" do
        Tools::GetSpec.stubs(:call).raises(ArgumentError, "bad param")
        result = @handler.call_tool("get_spec", {})
        assert result[:error]
        assert_equal Handler::ERROR_INVALID_PARAMS, result[:error][:code]
      end

      test "register adds a new tool" do
        custom_tool = Class.new(Tools::Base) do
          def self.tool_name = "custom_tool"
          def self.description = "A custom tool"
          def self.input_schema = { type: "object", properties: {} }
          def self.call(params, context) = { result: "ok" }
        end

        @handler.register(custom_tool)
        names = @handler.tools_list.map { |t| t[:name] }
        assert_includes names, "custom_tool"
      end

      test "registered custom tool can be called" do
        custom_tool = Class.new(Tools::Base) do
          def self.tool_name = "custom_tool"
          def self.description = "A custom tool"
          def self.input_schema = { type: "object", properties: {} }
          def self.call(params, context) = { hello: "world" }
        end

        @handler.register(custom_tool)
        result = @handler.call_tool("custom_tool", {})
        parsed = JSON.parse(result[:content].first[:text])
        assert_equal "world", parsed["hello"]
      end
    end
  end
end
