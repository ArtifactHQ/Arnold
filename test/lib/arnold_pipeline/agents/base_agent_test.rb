require "test_helper"
require "arnold_pipeline/agents/base_agent"

module ArnoldPipeline
  module Agents
    class TestableAgent < BaseAgent
      public :parse_json, :chat_json
    end

    class BaseAgentTest < ActiveSupport::TestCase
      cover "ArnoldPipeline::Agents::BaseAgent*"

      setup do
        @llm = stub("llm")
        @agent = TestableAgent.new(llm: @llm, logger: Logger.new(File::NULL))
      end

      # -- Code fence extraction --

      test "extracts JSON from json-tagged code fence" do
        text = "Here is the result:\n```json\n{\"key\": \"value\"}\n```\nDone."
        assert_equal({ "key" => "value" }, @agent.parse_json(text))
      end

      test "extracts JSON from untagged code fence" do
        text = "Result:\n```\n[1, 2, 3]\n```"
        assert_equal([ 1, 2, 3 ], @agent.parse_json(text))
      end

      test "picks largest fence when multiple exist" do
        text = <<~TEXT
          ```json
          {"a": 1}
          ```
          Some text
          ```json
          {"a": 1, "b": 2, "c": 3}
          ```
        TEXT
        result = @agent.parse_json(text)
        assert_equal({ "a" => 1, "b" => 2, "c" => 3 }, result)
      end

      test "prefers json-tagged fence over untagged" do
        text = <<~TEXT
          ```
          {"untagged": true, "extra": "padding to be longer"}
          ```
          ```json
          {"tagged": true}
          ```
        TEXT
        result = @agent.parse_json(text)
        assert_equal({ "tagged" => true }, result)
      end

      test "falls through non-json fences to bracket extraction" do
        text = <<~TEXT
          ```ruby
          puts "hello"
          ```
          Here is the JSON: {"found": true}
        TEXT
        result = @agent.parse_json(text)
        assert_equal({ "found" => true }, result)
      end

      # -- Bracket extraction --

      test "extracts object from surrounding prose" do
        text = 'The tasks are: {"id": 1, "name": "test"} as shown above.'
        assert_equal({ "id" => 1, "name" => "test" }, @agent.parse_json(text))
      end

      test "extracts array from surrounding prose" do
        text = 'Results: [{"a": 1}, {"b": 2}] end.'
        assert_equal([ { "a" => 1 }, { "b" => 2 } ], @agent.parse_json(text))
      end

      test "handles nested braces and brackets" do
        text = 'Output: {"nested": {"deep": [1, [2, 3]]}} done'
        expected = { "nested" => { "deep" => [ 1, [ 2, 3 ] ] } }
        assert_equal(expected, @agent.parse_json(text))
      end

      # -- Sanitization --

      test "strips NUL bytes from values" do
        text = "{\"key\": \"val\x00ue\"}"
        assert_equal({ "key" => "value" }, @agent.parse_json(text))
      end

      test "preserves tabs and newlines" do
        text = "{\"key\": \"line1\\nline2\\ttab\"}"
        assert_equal({ "key" => "line1\nline2\ttab" }, @agent.parse_json(text))
      end

      test "handles trailing comma in object" do
        text = '{"a": 1, "b": 2,}'
        assert_equal({ "a" => 1, "b" => 2 }, @agent.parse_json(text))
      end

      test "handles trailing comma in array" do
        text = "[1, 2, 3,]"
        assert_equal([ 1, 2, 3 ], @agent.parse_json(text))
      end

      # -- Integration --

      test "handles code fence with trailing comma and control chars" do
        text = "Here:\n```json\n{\"key\": \"va\x00lue\", \"n\": 1,}\n```\nEnd."
        assert_equal({ "key" => "value", "n" => 1 }, @agent.parse_json(text))
      end

      test "handles prose wrapping a code fence with trailing text" do
        text = <<~TEXT
          I've analyzed the code and here are the tasks:

          ```json
          [
            {"title": "Setup DB", "priority": 1,},
            {"title": "Add API", "priority": 2,}
          ]
          ```

          Let me know if you need changes!
        TEXT
        result = @agent.parse_json(text)
        assert_equal 2, result.size
        assert_equal "Setup DB", result[0]["title"]
      end

      # -- Error cases --

      test "raises LlmParseError for truly unparseable text" do
        assert_raises(ArnoldPipeline::Agents::LlmParseError) do
          @agent.parse_json("This is just plain English with no JSON at all.")
        end
      end

      test "parse_json raises LlmParseError with raw_response for malformed JSON" do
        raw_text = "Here is your JSON:\n{invalid json"
        error = assert_raises(ArnoldPipeline::Agents::LlmParseError) do
          @agent.parse_json(raw_text)
        end

        assert_includes error.message, "unexpected"
        assert_equal raw_text, error.raw_response
        assert_kind_of JSON::ParserError, error.original_error
      end

      test "LlmParseError is a StandardError subclass" do
        error = ArnoldPipeline::Agents::LlmParseError.new("test")
        assert_kind_of StandardError, error
      end

      # -- prompt/response logging --

      test "chat logs system prompt and user messages at debug level" do
        log_output = StringIO.new
        debug_logger = Logger.new(log_output, level: Logger::DEBUG)
        agent = TestableAgent.new(llm: @llm, logger: debug_logger)

        @llm.stubs(:chat).returns("response text")

        agent.send(:chat, messages: [ { role: :user, content: "Hello world" } ], system: "You are helpful")

        log_content = log_output.string
        assert_match(/\[prompt:system\] You are helpful/, log_content)
        assert_match(/\[prompt:user:0\] Hello world/, log_content)
        assert_match(/\[response:text\] response text/, log_content)
      end

      test "chat_json logs system prompt, messages, and JSON response at debug level" do
        log_output = StringIO.new
        debug_logger = Logger.new(log_output, level: Logger::DEBUG)
        agent = TestableAgent.new(llm: @llm, logger: debug_logger)

        schema = { name: "test", schema: { type: "object" } }
        @llm.stubs(:chat_json).returns({ "key" => "value" })

        agent.chat_json(messages: [ { role: :user, content: "Analyze this" } ], system: "Be precise", schema: schema)

        log_content = log_output.string
        assert_match(/\[prompt:system\] Be precise/, log_content)
        assert_match(/\[prompt:user:0\] Analyze this/, log_content)
        assert_match(/\[response:json\]/, log_content)
        assert_match(/"key": "value"/, log_content)
      end

      test "chat does not log system prompt when nil" do
        log_output = StringIO.new
        debug_logger = Logger.new(log_output, level: Logger::DEBUG)
        agent = TestableAgent.new(llm: @llm, logger: debug_logger)

        @llm.stubs(:chat).returns("ok")

        agent.send(:chat, messages: [ { role: :user, content: "Hi" } ])

        log_content = log_output.string
        assert_no_match(/\[prompt:system\]/, log_content)
        assert_match(/\[prompt:user:0\] Hi/, log_content)
      end

      test "truncate_for_log truncates long text" do
        agent = TestableAgent.new(llm: @llm, logger: Logger.new(File::NULL))
        long_text = "x" * 3000

        result = agent.send(:truncate_for_log, long_text, 2000)

        assert result.length < 3000
        assert_match(/\[truncated, total: 3000 chars\]/, result)
      end

      test "truncate_for_log returns short text unchanged" do
        agent = TestableAgent.new(llm: @llm, logger: Logger.new(File::NULL))

        result = agent.send(:truncate_for_log, "short", 2000)

        assert_equal "short", result
      end

      test "truncate_for_log handles nil" do
        agent = TestableAgent.new(llm: @llm, logger: Logger.new(File::NULL))

        result = agent.send(:truncate_for_log, nil)

        assert_equal "(nil)", result
      end

      test "format_json_for_log pretty prints JSON" do
        agent = TestableAgent.new(llm: @llm, logger: Logger.new(File::NULL))

        result = agent.send(:format_json_for_log, { "a" => 1 })

        assert_match(/"a": 1/, result)
      end

      test "format_json_for_log falls back to inspect for non-serializable objects" do
        agent = TestableAgent.new(llm: @llm, logger: Logger.new(File::NULL))

        # Object that can't be JSON-serialized
        obj = Object.new

        result = agent.send(:format_json_for_log, obj)

        assert_kind_of String, result
      end

      # -- chat_json delegation --

      test "chat_json delegates to llm.chat_json and returns result" do
        schema = { name: "test", schema: { type: "object" } }
        expected = { "key" => "value" }
        @llm.expects(:chat_json).with(
          messages: [ { role: :user, content: "Hi" } ],
          system: nil,
          schema: schema
        ).returns(expected)

        result = @agent.chat_json(
          messages: [ { role: :user, content: "Hi" } ],
          schema: schema
        )
        assert_equal expected, result
      end
    end
  end
end
