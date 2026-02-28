require "test_helper"
require "arnold_pipeline/mcp/server"

module ArnoldPipeline
  module Mcp
    class ServerTest < ActiveSupport::TestCase
      cover "ArnoldPipeline::Mcp::Server*"

      setup do
        @input = StringIO.new
        @output = StringIO.new
        @logger = Logger.new(File::NULL)
        @server = Server.new(input: @input, output: @output, logger: @logger)
      end

      teardown do
        ArnoldPipeline.reset_configuration!
      end

      test "handle_message responds to initialize with server info" do
        request = {
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => {
            "protocolVersion" => "2025-03-26",
            "capabilities" => {},
            "clientInfo" => { "name" => "test", "version" => "1.0" }
          }
        }

        response = @server.handle_message(request)

        assert_equal "2.0", response[:jsonrpc]
        assert_equal 1, response[:id]
        assert_equal "2025-03-26", response[:result][:protocolVersion]
        assert_equal "arnold", response[:result][:serverInfo][:name]
        assert_equal ArnoldPipeline::VERSION, response[:result][:serverInfo][:version]
        assert response[:result][:capabilities][:tools]
      end

      test "handle_message responds to ping with empty result" do
        request = { "jsonrpc" => "2.0", "id" => 2, "method" => "ping" }
        response = @server.handle_message(request)

        assert_equal "2.0", response[:jsonrpc]
        assert_equal 2, response[:id]
        assert_equal({}, response[:result])
      end

      test "handle_message responds to tools/list with tool definitions" do
        request = { "jsonrpc" => "2.0", "id" => 3, "method" => "tools/list", "params" => {} }
        response = @server.handle_message(request)

        assert_equal "2.0", response[:jsonrpc]
        assert_equal 3, response[:id]
        tools = response[:result][:tools]
        assert_kind_of Array, tools
        names = tools.map { |t| t[:name] }
        assert_includes names, "get_spec"
        assert_includes names, "get_tasks"
      end

      test "handle_message responds to tools/call" do
        run = PipelineRun.create!(nl_input: "test")
        Specification.create!(pipeline_run: run, content: "# Spec", version: 1)

        request = {
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => { "name" => "get_spec", "arguments" => {} }
        }
        response = @server.handle_message(request)

        assert_equal "2.0", response[:jsonrpc]
        assert_equal 4, response[:id]
        assert response[:result][:content]
        assert_equal "text", response[:result][:content].first[:type]
      end

      test "handle_message returns error for unknown method" do
        request = { "jsonrpc" => "2.0", "id" => 5, "method" => "unknown/method" }
        response = @server.handle_message(request)

        assert_equal "2.0", response[:jsonrpc]
        assert_equal 5, response[:id]
        assert response[:error]
        assert_equal(-32601, response[:error][:code])
      end

      test "handle_message returns nil for notifications (no id)" do
        request = { "jsonrpc" => "2.0", "method" => "notifications/initialized" }
        response = @server.handle_message(request)
        assert_nil response
      end

      test "handle_message returns nil for unknown notifications" do
        request = { "jsonrpc" => "2.0", "method" => "notifications/unknown" }
        response = @server.handle_message(request)
        assert_nil response
      end

      test "start reads lines and writes responses" do
        init_request = JSON.generate({
          jsonrpc: "2.0", id: 1, method: "initialize",
          params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "test", version: "1.0" } }
        })

        @input = StringIO.new(init_request + "\n")
        server = Server.new(input: @input, output: @output, logger: @logger)
        server.start

        @output.rewind
        lines = @output.read.split("\n")
        assert_equal 1, lines.length

        response = JSON.parse(lines.first)
        assert_equal 1, response["id"]
        assert_equal "arnold", response.dig("result", "serverInfo", "name")
      end

      test "start handles multiple requests" do
        requests = [
          JSON.generate({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "test", version: "1.0" } } }),
          JSON.generate({ jsonrpc: "2.0", method: "notifications/initialized" }),
          JSON.generate({ jsonrpc: "2.0", id: 2, method: "ping" })
        ].join("\n") + "\n"

        @input = StringIO.new(requests)
        server = Server.new(input: @input, output: @output, logger: @logger)
        server.start

        @output.rewind
        lines = @output.read.strip.split("\n")
        # Only 2 responses: initialize and ping (notification gets no response)
        assert_equal 2, lines.length
      end

      test "start skips empty lines" do
        requests = "\n" + JSON.generate({ jsonrpc: "2.0", id: 1, method: "ping" }) + "\n\n"
        @input = StringIO.new(requests)
        server = Server.new(input: @input, output: @output, logger: @logger)
        server.start

        @output.rewind
        lines = @output.read.strip.split("\n")
        assert_equal 1, lines.length
      end

      test "start handles invalid JSON gracefully" do
        @input = StringIO.new("not json\n")
        server = Server.new(input: @input, output: @output, logger: @logger)
        server.start

        @output.rewind
        response = JSON.parse(@output.read.strip)
        assert_equal(-32700, response.dig("error", "code"))
      end

      test "stop sets running to false" do
        @server.stop
        # After stop, start on empty input returns immediately
        @input = StringIO.new("")
        server = Server.new(input: @input, output: @output, logger: @logger)
        server.start

        @output.rewind
        assert_equal "", @output.read.strip
      end

      test "PROTOCOL_VERSION is defined" do
        assert_equal "2025-03-26", Server::PROTOCOL_VERSION
      end
    end
  end
end
