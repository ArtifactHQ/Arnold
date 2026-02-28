require "test_helper"
require "arnold_pipeline/mcp/tools/base"

module ArnoldPipeline
  module Mcp
    module Tools
      class BaseTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::Base*"

        test "tool_name raises NotImplementedError" do
          assert_raises(NotImplementedError) { Base.tool_name }
        end

        test "description raises NotImplementedError" do
          assert_raises(NotImplementedError) { Base.description }
        end

        test "input_schema raises NotImplementedError" do
          assert_raises(NotImplementedError) { Base.input_schema }
        end

        test "call raises NotImplementedError" do
          assert_raises(NotImplementedError) { Base.call({}, nil) }
        end
      end
    end
  end
end
