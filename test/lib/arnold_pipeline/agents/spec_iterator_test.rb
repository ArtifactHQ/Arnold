require "test_helper"
require "arnold_pipeline/agents/spec_iterator"

module ArnoldPipeline
  module Agents
    class SpecIteratorTest < ActiveSupport::TestCase
      cover "ArnoldPipeline::Agents::SpecIterator*"

      setup do
        @llm = stub("llm")
        @agent = SpecIterator.new(llm: @llm, logger: Logger.new(File::NULL))
      end

      test "returns parsed result with summary and deltas" do
        llm_result = {
          "summary" => "Added password reset feature",
          "deltas" => [
            {
              "operation" => "added",
              "section" => "Authentication",
              "requirement" => "Password Reset",
              "content" => "### Requirement: Password Reset [REQ-AUTH-003]\nUsers SHALL be able to reset their password.\n\n#### Scenario: Successful Reset\n- GIVEN a registered user\n- WHEN they request a password reset\n- THEN a reset email is sent",
              "rationale" => "User requested password reset functionality"
            }
          ]
        }
        @llm.expects(:chat_json).returns(llm_result)

        result = @agent.call(spec_content: "# Spec", change_request: "Add password reset")

        assert_equal "Added password reset feature", result["summary"]
        assert_equal 1, result["deltas"].size
        assert_equal "added", result["deltas"][0]["operation"]
      end

      test "accepts valid modified delta" do
        llm_result = {
          "summary" => "Updated login requirement",
          "deltas" => [
            {
              "operation" => "modified",
              "section" => "Authentication",
              "requirement" => "User Login",
              "before_content" => "### Requirement: User Login\nBasic login.",
              "after_content" => "### Requirement: User Login\nUsers SHALL authenticate with email/password or OAuth.\n\n#### Scenario: OAuth Login\n- GIVEN a user\n- WHEN they click OAuth\n- THEN authenticated",
              "rationale" => "Added OAuth support"
            }
          ]
        }
        @llm.expects(:chat_json).returns(llm_result)

        result = @agent.call(spec_content: "# Spec", change_request: "Add OAuth login")

        assert_equal "modified", result["deltas"][0]["operation"]
        assert_equal "User Login", result["deltas"][0]["requirement"]
      end

      test "accepts valid removed delta" do
        llm_result = {
          "summary" => "Removed SMS verification",
          "deltas" => [
            {
              "operation" => "removed",
              "section" => "Authentication",
              "requirement" => "SMS Verification",
              "rationale" => "No longer needed per user request"
            }
          ]
        }
        @llm.expects(:chat_json).returns(llm_result)

        result = @agent.call(spec_content: "# Spec", change_request: "Remove SMS verification")

        assert_equal "removed", result["deltas"][0]["operation"]
      end

      test "validation rejects added delta without content" do
        llm_result = {
          "summary" => "Bad delta",
          "deltas" => [
            {
              "operation" => "added",
              "section" => "Features",
              "rationale" => "Missing content field"
            }
          ]
        }
        @llm.expects(:chat_json).returns(llm_result)

        error = assert_raises(ArgumentError) do
          @agent.call(spec_content: "# Spec", change_request: "Add something")
        end
        assert_match(/added.*requires.*content/i, error.message)
      end

      test "validation rejects modified delta without after_content" do
        llm_result = {
          "summary" => "Bad delta",
          "deltas" => [
            {
              "operation" => "modified",
              "section" => "Features",
              "requirement" => "Some Feature",
              "rationale" => "Missing after_content"
            }
          ]
        }
        @llm.expects(:chat_json).returns(llm_result)

        error = assert_raises(ArgumentError) do
          @agent.call(spec_content: "# Spec", change_request: "Modify something")
        end
        assert_match(/modified.*requires.*after_content/i, error.message)
      end

      test "validation rejects modified delta without requirement" do
        llm_result = {
          "summary" => "Bad delta",
          "deltas" => [
            {
              "operation" => "modified",
              "section" => "Features",
              "after_content" => "Updated content",
              "rationale" => "Missing requirement field"
            }
          ]
        }
        @llm.expects(:chat_json).returns(llm_result)

        error = assert_raises(ArgumentError) do
          @agent.call(spec_content: "# Spec", change_request: "Modify something")
        end
        assert_match(/modified.*requires.*requirement/i, error.message)
      end

      test "validation rejects removed delta without requirement" do
        llm_result = {
          "summary" => "Bad delta",
          "deltas" => [
            {
              "operation" => "removed",
              "section" => "Features",
              "rationale" => "Missing requirement field"
            }
          ]
        }
        @llm.expects(:chat_json).returns(llm_result)

        error = assert_raises(ArgumentError) do
          @agent.call(spec_content: "# Spec", change_request: "Remove something")
        end
        assert_match(/removed.*requires.*requirement/i, error.message)
      end

      test "passes through multiple valid deltas" do
        llm_result = {
          "summary" => "Multiple changes",
          "deltas" => [
            {
              "operation" => "added",
              "section" => "Features",
              "requirement" => "New Feature",
              "content" => "### Requirement: New Feature\nContent\n\n#### Scenario: Test\n- GIVEN x\n- WHEN y\n- THEN z",
              "rationale" => "User requested"
            },
            {
              "operation" => "removed",
              "section" => "Features",
              "requirement" => "Old Feature",
              "rationale" => "Replaced by new feature"
            }
          ]
        }
        @llm.expects(:chat_json).returns(llm_result)

        result = @agent.call(spec_content: "# Spec", change_request: "Replace old with new")

        assert_equal 2, result["deltas"].size
      end

      test "accepts empty deltas array" do
        llm_result = {
          "summary" => "No changes needed",
          "deltas" => []
        }
        @llm.expects(:chat_json).returns(llm_result)

        result = @agent.call(spec_content: "# Spec", change_request: "Nothing to change")

        assert_empty result["deltas"]
      end
    end
  end
end
