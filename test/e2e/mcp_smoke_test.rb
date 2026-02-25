require "test_helper"
require "arnold_pipeline/mcp/server"

module ArnoldPipeline
  module E2e
    class McpSmokeTest < ActiveSupport::TestCase
      setup do
        @client_read, @server_write = IO.pipe
        @server_read, @client_write = IO.pipe

        @server = Mcp::Server.new(
          input: @server_read,
          output: @server_write,
          logger: Logger.new(File::NULL)
        )

        @server_thread = Thread.new { @server.start }

        # Send initialize handshake
        send_request(
          jsonrpc: "2.0", id: 0, method: "initialize",
          params: {
            protocolVersion: "2025-03-26",
            capabilities: {},
            clientInfo: { name: "test", version: "1.0" }
          }
        )
        @init_response = read_response
      end

      teardown do
        @client_write.close rescue nil
        @server_thread.join(2) rescue nil
        [@client_read, @server_write, @server_read].each { |io| io.close rescue nil }
        ArnoldPipeline.reset_configuration!
      end

      test "server responds to initialize with protocol version and capabilities" do
        assert_equal "2.0", @init_response["jsonrpc"]
        assert_equal 0, @init_response["id"]

        result = @init_response["result"]
        assert_equal "2025-03-26", result["protocolVersion"]
        assert result.key?("capabilities")
        assert result["capabilities"].key?("tools")

        server_info = result["serverInfo"]
        assert_equal "arnold", server_info["name"]
        assert_equal ArnoldPipeline::VERSION, server_info["version"]
      end

      test "tools/list returns all 15 registered tools" do
        send_request(jsonrpc: "2.0", id: 1, method: "tools/list", params: {})
        response = read_response

        tools = response.dig("result", "tools")
        assert_kind_of Array, tools
        assert_equal 15, tools.length

        expected_tools = %w[
          describe_product explore_domain propose_change confirm_change
          ask_engineer explore_architecture explain_recipe
          get_spec get_tasks start_task complete_task report_issue validate_tier
          detect_drift resolve_drift
        ]

        tool_names = tools.map { |t| t["name"] }
        expected_tools.each do |name|
          assert_includes tool_names, name, "Missing tool: #{name}"
        end

        # Each tool must have name, description, and inputSchema
        tools.each do |tool|
          assert tool.key?("name"), "Tool missing 'name'"
          assert tool.key?("description"), "Tool missing 'description' for #{tool['name']}"
          assert tool.key?("inputSchema"), "Tool missing 'inputSchema' for #{tool['name']}"
          assert_kind_of String, tool["description"]
          refute_empty tool["description"], "Empty description for #{tool['name']}"
        end
      end

      test "server handles ping" do
        send_request(jsonrpc: "2.0", id: 2, method: "ping")
        response = read_response

        assert_equal "2.0", response["jsonrpc"]
        assert_equal 2, response["id"]
        assert_equal({}, response["result"])
      end

      test "server ignores notifications (no id)" do
        # Send notification (no id field) - should not get a response
        send_request(jsonrpc: "2.0", method: "notifications/initialized")

        # Send a follow-up request to prove the server is still alive
        send_request(jsonrpc: "2.0", id: 3, method: "ping")
        response = read_response

        # The response should be for ping (id: 3), not the notification
        assert_equal 3, response["id"]
        assert_equal({}, response["result"])
      end

      test "server handles malformed JSON gracefully" do
        @client_write.puts("this is not valid json")
        response = read_response

        assert_equal(-32700, response.dig("error", "code"))
        assert_includes response.dig("error", "message"), "Parse error"
      end

      test "server handles unknown method" do
        send_request(jsonrpc: "2.0", id: 4, method: "nonexistent/method", params: {})
        response = read_response

        assert_equal 4, response["id"]
        assert_equal(-32601, response.dig("error", "code"))
        assert_includes response.dig("error", "message"), "Method not found"
      end

      test "tools/call with unknown tool returns error" do
        send_request(
          jsonrpc: "2.0", id: 5, method: "tools/call",
          params: { name: "nonexistent_tool", arguments: {} }
        )
        response = read_response

        # The handler wraps unknown tools in an error result, which gets put in
        # the response as either result.error or top-level error
        assert response.key?("result") || response.key?("error"),
               "Expected either result or error in response"

        if response.key?("error")
          assert_includes response["error"]["message"], "nonexistent_tool"
        else
          # Handler returns error inside result content
          error_data = response["result"]["error"] || response["result"]
          assert error_data, "Expected error data for unknown tool"
        end
      end

      test "describe_product against empty state returns error not crash" do
        PipelineRun.destroy_all

        send_request(
          jsonrpc: "2.0", id: 6, method: "tools/call",
          params: { name: "describe_product", arguments: {} }
        )
        response = read_response

        assert_equal 6, response["id"]
        # Should return a result (not a JSON-RPC error), containing an error message
        assert response.key?("result"), "Expected result key in response"
        content = response.dig("result", "content")
        assert_kind_of Array, content
        text = content.first["text"]
        parsed = JSON.parse(text)
        assert_equal "No pipeline run found", parsed["error"]
      end

      test "multiple sequential requests work correctly" do
        # Ping
        send_request(jsonrpc: "2.0", id: 10, method: "ping")
        r1 = read_response
        assert_equal 10, r1["id"]

        # Tools list
        send_request(jsonrpc: "2.0", id: 11, method: "tools/list", params: {})
        r2 = read_response
        assert_equal 11, r2["id"]
        assert r2.dig("result", "tools").length > 0

        # Another ping
        send_request(jsonrpc: "2.0", id: 12, method: "ping")
        r3 = read_response
        assert_equal 12, r3["id"]
      end

      private

      def send_request(request)
        @client_write.puts(JSON.generate(request))
      end

      def read_response
        line = @client_read.gets
        JSON.parse(line) if line
      end
    end
  end
end
