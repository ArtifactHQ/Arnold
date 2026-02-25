require "json"
require_relative "handler"

module ArnoldPipeline
  module Mcp
    class Server
      PROTOCOL_VERSION = "2025-03-26"

      def initialize(input: $stdin, output: $stdout, logger: nil)
        @input = input
        @output = output
        @logger = logger || Logger.new(File::NULL)
        @handler = Handler.new
        @running = false
      end

      def start
        @running = true
        setup_signal_handlers
        @logger.info("MCP server starting")

        while @running
          line = @input.gets
          break unless line

          line = line.strip
          next if line.empty?

          handle_line(line)
        end

        @logger.info("MCP server stopped")
      end

      def stop
        @running = false
      end

      def handle_message(request)
        method = request["method"]
        id = request["id"]
        params = request["params"] || {}

        # Notifications (no id) get no response
        if id.nil?
          handle_notification(method, params)
          return nil
        end

        result = case method
        when "initialize"
          handle_initialize(params)
        when "ping"
          {}
        when "tools/list"
          handle_tools_list
        when "tools/call"
          handle_tools_call(params)
        else
          { error: { code: -32601, message: "Method not found: #{method}" } }
        end

        build_response(id, result)
      end

      private

      def setup_signal_handlers
        trap("INT") { stop }
        trap("TERM") { stop }
      rescue ArgumentError
        # Signal trapping not supported on this platform
      end

      def handle_line(line)
        request = JSON.parse(line)
        response = handle_message(request)
        send_response(response) if response
      rescue JSON::ParserError => e
        error_response = {
          jsonrpc: "2.0",
          id: nil,
          error: { code: -32700, message: "Parse error: #{e.message}" }
        }
        send_response(error_response)
      end

      def handle_notification(method, params)
        case method
        when "notifications/initialized"
          @logger.info("Client initialized")
        else
          @logger.debug("Unknown notification: #{method}")
        end
      end

      def handle_initialize(params)
        {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: {} },
          serverInfo: {
            name: "arnold",
            version: ArnoldPipeline::VERSION
          }
        }
      end

      def handle_tools_list
        { tools: @handler.tools_list }
      end

      def handle_tools_call(params)
        name = params["name"]
        arguments = params["arguments"] || {}
        @handler.call_tool(name, arguments)
      end

      def build_response(id, result)
        if result.key?(:error)
          { jsonrpc: "2.0", id: id, error: result[:error] }
        else
          { jsonrpc: "2.0", id: id, result: result }
        end
      end

      def send_response(response)
        json = JSON.generate(response)
        @output.write(json + "\n")
        @output.flush
      end
    end
  end
end
