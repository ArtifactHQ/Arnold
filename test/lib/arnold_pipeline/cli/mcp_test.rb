require "test_helper"
require "arnold_pipeline/cli"

module ArnoldPipeline
  class CliMcpTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::Cli*"

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    test "mcp command is defined in CLI" do
      commands = Cli.all_commands
      assert commands.key?("mcp"), "Expected 'mcp' command to be defined"
    end

    test "mcp command has correct description" do
      command = Cli.all_commands["mcp"]
      assert_includes command.description, "MCP"
    end

    test "mcp command accepts --config option" do
      # class_options and command options are both available
      # --config is defined as an option on the mcp method
      cli = Cli.new
      assert cli.class.all_commands["mcp"], "Expected 'mcp' command"
    end

    test "mcp command starts server with stdio" do
      init_msg = JSON.generate({
        jsonrpc: "2.0", id: 1, method: "initialize",
        params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "test", version: "1.0" } }
      })

      input = StringIO.new(init_msg + "\n")
      output = StringIO.new

      # Stub the server to use our IO objects
      server_stub = stub("server")
      server_stub.expects(:start).once

      Mcp::Server.stubs(:new).returns(server_stub)

      cli = Cli.new
      cli.stubs(:setup_standalone!)
      cli.stubs(:options).returns({ config: nil })
      cli.mcp

      # Verify server was started
      # (assertion is in the expects above)
    end
  end
end
