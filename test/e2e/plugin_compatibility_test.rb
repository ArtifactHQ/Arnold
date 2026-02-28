require "test_helper"
require "arnold_pipeline/mcp/handler"

module ArnoldPipeline
  module E2e
    class PluginCompatibilityTest < ActiveSupport::TestCase
      PLUGIN_PATH = File.expand_path(
        ENV.fetch("ARNOLD_PLUGIN_PATH", "~/Documents/Projects/artifact/arnold-claude-code-plugin")
      )

      # Backtick-quoted identifiers in plugin docs that are not Arnold MCP tools
      NON_TOOL_IDENTIFIERS = %w[open_questions].freeze

      setup do
        skip "Plugin repo not found at #{PLUGIN_PATH}" unless File.directory?(PLUGIN_PATH)
        @handler = Mcp::Handler.new
        @actual_tools = @handler.tools_list.map { |t| t[:name] }
      end

      teardown do
        ArnoldPipeline.reset_configuration!
      end

      test "plugin mcp-servers config references valid arnold command" do
        config_path = File.join(PLUGIN_PATH, "mcp-servers", "arnold.json")
        assert File.exist?(config_path), "Expected mcp-servers/arnold.json to exist"

        config = JSON.parse(File.read(config_path))
        assert config.key?("arnold"), "Config must have 'arnold' key"
        assert_equal "arnold", config["arnold"]["command"]
        assert_equal [ "mcp" ], config["arnold"]["args"]
      end

      test "plugin agent references all tools that Arnold exposes" do
        agent_path = File.join(PLUGIN_PATH, "agents", "arnold.md")
        assert File.exist?(agent_path), "Expected agents/arnold.md to exist"

        agent_md = File.read(agent_path)

        # Every tool Arnold exposes should be mentioned in the agent definition
        @actual_tools.each do |tool_name|
          assert_includes agent_md, tool_name,
            "Plugin agent definition missing tool: #{tool_name}"
        end
      end

      test "plugin agent does not reference nonexistent tools" do
        agent_path = File.join(PLUGIN_PATH, "agents", "arnold.md")
        agent_md = File.read(agent_path)

        # Extract backtick-quoted identifiers that look like tool names
        # (snake_case words inside backticks)
        backtick_names = agent_md.scan(/`(\w+)`/).flatten.uniq

        # Filter to names that match arnold tool naming convention (snake_case with underscores)
        tool_like_names = backtick_names
          .select { |n| n.include?("_") && n == n.downcase }
          .reject { |n| NON_TOOL_IDENTIFIERS.include?(n) }

        # Each tool-like name should be a real Arnold tool
        tool_like_names.each do |name|
          assert_includes @actual_tools, name,
            "Plugin agent references '#{name}' which is not a registered Arnold tool"
        end
      end

      test "plugin version compatibility" do
        plugin_json_path = File.join(PLUGIN_PATH, "plugin.json")
        assert File.exist?(plugin_json_path), "Expected plugin.json to exist"

        plugin_json = JSON.parse(File.read(plugin_json_path))
        assert plugin_json.key?("min_arnold_version"), "Plugin must declare min_arnold_version"
        assert plugin_json.key?("version"), "Plugin must declare version"
        assert plugin_json.key?("name"), "Plugin must declare name"
        assert_equal "arnold", plugin_json["name"]
      end

      test "all plugin commands reference only valid tools" do
        commands_dir = File.join(PLUGIN_PATH, "commands")
        skip "No commands directory found" unless File.directory?(commands_dir)

        command_files = Dir.glob(File.join(commands_dir, "*.md"))
        assert command_files.any?, "Expected at least one command file"

        command_files.each do |cmd_file|
          content = File.read(cmd_file)
          basename = File.basename(cmd_file)

          # Extract backtick-quoted tool-like names
          tool_references = content.scan(/`(\w+)`/).flatten.uniq
          tool_like = tool_references
            .select { |n| n.include?("_") && n == n.downcase }
            .reject { |n| NON_TOOL_IDENTIFIERS.include?(n) }

          tool_like.each do |name|
            assert_includes @actual_tools, name,
              "Command #{basename} references unknown tool: #{name}"
          end
        end
      end

      test "plugin hooks.json is valid" do
        hooks_path = File.join(PLUGIN_PATH, "hooks", "hooks.json")
        assert File.exist?(hooks_path), "Expected hooks/hooks.json to exist"

        hooks = JSON.parse(File.read(hooks_path))
        assert hooks.key?("hooks"), "hooks.json must have 'hooks' key"
        assert_kind_of Array, hooks["hooks"], "hooks must be an array"

        hooks["hooks"].each do |hook|
          assert hook.key?("matcher"), "Each hook must have a 'matcher' key"
          assert hook.key?("hooks"), "Each hook entry must have a 'hooks' array"
          assert_kind_of Array, hook["hooks"]
        end
      end

      test "plugin tool count matches Arnold tool count" do
        agent_path = File.join(PLUGIN_PATH, "agents", "arnold.md")
        agent_md = File.read(agent_path)

        # Count tool names mentioned in the agent definition
        mentioned = @actual_tools.select { |name| agent_md.include?(name) }

        assert_equal @actual_tools.length, mentioned.length,
          "Plugin agent mentions #{mentioned.length} tools, but Arnold exposes #{@actual_tools.length}. " \
          "Missing: #{(@actual_tools - mentioned).join(', ')}"
      end

      test "plugin mcp-servers config has required fields" do
        config_path = File.join(PLUGIN_PATH, "mcp-servers", "arnold.json")
        config = JSON.parse(File.read(config_path))

        arnold_config = config["arnold"]
        assert arnold_config.key?("command"), "MCP server config must have 'command'"
        assert arnold_config.key?("args"), "MCP server config must have 'args'"
        assert_kind_of Array, arnold_config["args"], "'args' must be an array"
      end

      test "plugin.json has required metadata fields" do
        plugin_json = JSON.parse(File.read(File.join(PLUGIN_PATH, "plugin.json")))

        %w[name description version].each do |field|
          assert plugin_json.key?(field), "plugin.json must have '#{field}' field"
          refute_empty plugin_json[field].to_s, "plugin.json '#{field}' must not be empty"
        end
      end

      test "plugin directory structure is complete" do
        expected_dirs = %w[agents commands hooks mcp-servers]
        expected_dirs.each do |dir|
          path = File.join(PLUGIN_PATH, dir)
          assert File.directory?(path), "Expected directory: #{dir}"
        end

        expected_files = %w[plugin.json agents/arnold.md mcp-servers/arnold.json hooks/hooks.json]
        expected_files.each do |file|
          path = File.join(PLUGIN_PATH, file)
          assert File.exist?(path), "Expected file: #{file}"
        end
      end
    end
  end
end
