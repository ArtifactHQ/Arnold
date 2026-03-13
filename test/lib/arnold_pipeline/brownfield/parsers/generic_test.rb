require "test_helper"
require "arnold_pipeline/brownfield/parsers/generic"

module ArnoldPipeline
  module Brownfield
    module Parsers
      class GenericTest < ActiveSupport::TestCase
        test "extracts class with superclass" do
          result = Generic.call(content: "class Foo extends Bar {")
          assert_equal 1, result[:classes].length
          assert_equal "Foo", result[:classes][0][:name]
          assert_equal "Bar", result[:classes][0][:superclass]
        end

        test "extracts class with colon inheritance" do
          # C#, C++ style
          result = Generic.call(content: "public class Admin : User {")
          assert_equal 1, result[:classes].length
          assert_equal "Admin", result[:classes][0][:name]
          assert_equal "User", result[:classes][0][:superclass]
        end

        test "extracts class with paren inheritance" do
          # Python style
          result = Generic.call(content: "class Config(BaseConfig):")
          assert_equal 1, result[:classes].length
          assert_equal "Config", result[:classes][0][:name]
          assert_equal "BaseConfig", result[:classes][0][:superclass]
        end

        test "extracts class without superclass" do
          result = Generic.call(content: "class SimpleService {")
          assert_equal 1, result[:classes].length
          assert_equal "SimpleService", result[:classes][0][:name]
          assert_nil result[:classes][0][:superclass]
        end

        test "extracts struct" do
          result = Generic.call(content: "pub struct DataPoint {")
          assert_equal 1, result[:classes].length
          assert_equal "DataPoint", result[:classes][0][:name]
        end

        test "extracts function keyword functions" do
          result = Generic.call(content: "function processData(input) {")
          assert_equal 1, result[:methods].length
          assert_equal "processData", result[:methods][0][:name]
        end

        test "extracts def keyword functions" do
          result = Generic.call(content: "def calculate(x):")
          assert_equal 1, result[:methods].length
          assert_equal "calculate", result[:methods][0][:name]
        end

        test "extracts fn keyword functions" do
          result = Generic.call(content: "pub fn process(input: &str) {")
          assert_equal 1, result[:methods].length
          assert_equal "process", result[:methods][0][:name]
        end

        test "extracts func keyword functions" do
          # Go style
          result = Generic.call(content: "func handleRequest(w http.ResponseWriter) {")
          assert_equal 1, result[:methods].length
          assert_equal "handleRequest", result[:methods][0][:name]
        end

        test "extracts arrow function assignments" do
          result = Generic.call(content: "const processItems = (items) => {")
          assert_equal 1, result[:methods].length
          assert_equal "processItems", result[:methods][0][:name]
        end

        test "does not extract control flow as functions" do
          code = <<~CODE
            function real_function() {
              if (true) {
                for (x in items) {
                }
              }
            }
          CODE
          result = Generic.call(content: code)
          names = result[:methods].map { |m| m[:name] }
          assert_includes names, "real_function"
          refute_includes names, "if"
          refute_includes names, "for"
        end

        test "extracts constants" do
          code = <<~CODE
            MAX_SIZE = 100
            const API_URL = "https://example.com"
            DEFAULT_TIMEOUT = 30
          CODE
          result = Generic.call(content: code)
          names = result[:constants].map { |c| c[:name] }
          assert_includes names, "MAX_SIZE"
          assert_includes names, "API_URL"
          assert_includes names, "DEFAULT_TIMEOUT"
        end

        test "does not extract short uppercase as constants" do
          # Require at least 3 chars to avoid single-letter matches
          result = Generic.call(content: "AB = 1")
          assert_empty result[:constants]
        end

        test "returns all standard keys" do
          result = Generic.call(content: "")
          expected_keys = %i[classes modules methods associations validations callbacks scopes includes constants]
          assert_equal expected_keys.sort, result.keys.sort
        end

        test "returns empty arrays for inapplicable concepts" do
          result = Generic.call(content: "function foo() {}")
          assert_empty result[:modules]
          assert_empty result[:associations]
          assert_empty result[:validations]
          assert_empty result[:callbacks]
          assert_empty result[:scopes]
          assert_empty result[:includes]
        end

        test "realistic Go file parsing" do
          code = <<~GO
            const MAX_WORKERS = 10
            const DEFAULT_PORT = 8080

            struct Config {
              port int
              host string
            }

            func NewServer(config Config) {
              // ...
            }

            func handleRequest(w http.ResponseWriter) {
              // ...
            }
          GO
          result = Generic.call(content: code)

          assert_equal 1, result[:classes].length
          assert_equal "Config", result[:classes][0][:name]

          assert_equal 2, result[:methods].length
          method_names = result[:methods].map { |m| m[:name] }
          assert_includes method_names, "NewServer"
          assert_includes method_names, "handleRequest"

          assert_equal 2, result[:constants].length
        end

        test "realistic mixed/unknown language file" do
          code = <<~CODE
            # Configuration file
            MAX_RETRIES = 5
            API_VERSION = "v2"

            class ServiceHandler extends BaseHandler {
              function process(data) {
                return data
              }

              function validate(input) {
                return true
              }
            }
          CODE
          result = Generic.call(content: code)

          assert_equal 1, result[:classes].length
          assert_equal "ServiceHandler", result[:classes][0][:name]
          assert_equal "BaseHandler", result[:classes][0][:superclass]

          assert result[:methods].length >= 2
          assert result[:constants].length >= 2
        end
      end
    end
  end
end
