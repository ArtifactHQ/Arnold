require "test_helper"
require "arnold_pipeline/delta_presenter"

module ArnoldPipeline
  class DeltaPresenterTest < ActiveSupport::TestCase
    test "to_s includes version numbers in header" do
      presenter = DeltaPresenter.new([], from_version: 1, to_version: 2)

      output = presenter.to_s

      assert_includes output, "v1"
      assert_includes output, "v2"
    end

    test "to_s formats added delta with section and requirement" do
      deltas = [
        {
          "operation" => "added",
          "section" => "Authentication",
          "requirement" => "Password Reset",
          "content" => "### Requirement: Password Reset",
          "rationale" => "User requested password recovery flow"
        }
      ]
      presenter = DeltaPresenter.new(deltas, from_version: 1, to_version: 2)

      output = presenter.to_s

      assert_includes output, "ADDED: Authentication > Password Reset"
      assert_includes output, "User requested password recovery flow"
    end

    test "to_s formats added delta with nil requirement as New requirement" do
      deltas = [
        {
          "operation" => "added",
          "section" => "Payments",
          "requirement" => nil,
          "content" => "### Requirement: Stripe Integration",
          "rationale" => "Adding payment processing"
        }
      ]
      presenter = DeltaPresenter.new(deltas, from_version: 1, to_version: 2)

      output = presenter.to_s

      assert_includes output, "ADDED: Payments > New requirement"
    end

    test "to_s formats modified delta with before and after content" do
      deltas = [
        {
          "operation" => "modified",
          "section" => "API",
          "requirement" => "Rate Limiting",
          "before_content" => "100 requests per minute",
          "after_content" => "500 requests per minute with burst allowance",
          "rationale" => "Increased limits for enterprise tier"
        }
      ]
      presenter = DeltaPresenter.new(deltas, from_version: 2, to_version: 3)

      output = presenter.to_s

      assert_includes output, "MODIFIED: API > Rate Limiting"
      assert_includes output, "Before: 100 requests per minute"
      assert_includes output, "After:  500 requests per minute with burst allowance"
      assert_includes output, "Rationale: Increased limits for enterprise tier"
    end

    test "to_s formats modified delta without before/after content" do
      deltas = [
        {
          "operation" => "modified",
          "section" => "API",
          "requirement" => "Rate Limiting",
          "rationale" => "Updated rate limits"
        }
      ]
      presenter = DeltaPresenter.new(deltas, from_version: 1, to_version: 2)

      output = presenter.to_s

      assert_includes output, "MODIFIED: API > Rate Limiting"
      assert_includes output, "Rationale: Updated rate limits"
      refute_includes output, "Before:"
      refute_includes output, "After:"
    end

    test "to_s formats removed delta" do
      deltas = [
        {
          "operation" => "removed",
          "section" => "Legacy",
          "requirement" => "XML Export",
          "rationale" => "Deprecated in favor of JSON"
        }
      ]
      presenter = DeltaPresenter.new(deltas, from_version: 3, to_version: 4)

      output = presenter.to_s

      assert_includes output, "REMOVED: Legacy > XML Export"
      assert_includes output, "Rationale: Deprecated in favor of JSON"
    end

    test "to_s handles multiple deltas of different types" do
      deltas = [
        { "operation" => "added", "section" => "Auth", "requirement" => "OAuth", "rationale" => "Add SSO" },
        { "operation" => "modified", "section" => "API", "requirement" => "Endpoints", "rationale" => "Updated paths" },
        { "operation" => "removed", "section" => "Legacy", "requirement" => "SOAP API", "rationale" => "Removed legacy" }
      ]
      presenter = DeltaPresenter.new(deltas, from_version: 1, to_version: 2)

      output = presenter.to_s

      assert_includes output, "ADDED: Auth > OAuth"
      assert_includes output, "MODIFIED: API > Endpoints"
      assert_includes output, "REMOVED: Legacy > SOAP API"
    end

    test "truncation shortens content beyond 120 characters" do
      long_text = "a" * 200
      deltas = [
        {
          "operation" => "modified",
          "section" => "API",
          "requirement" => "Desc",
          "before_content" => long_text,
          "after_content" => long_text,
          "rationale" => "Changed"
        }
      ]
      presenter = DeltaPresenter.new(deltas, from_version: 1, to_version: 2)

      output = presenter.to_s

      assert_includes output, "..."
      before_line = output.lines.find { |l| l.include?("Before:") }
      content_part = before_line.strip.sub("Before: ", "")
      assert_equal 123, content_part.length # 120 + "..."
    end

    test "truncation collapses whitespace" do
      multiline = "line one\n\n  line two\n\tline three"
      deltas = [
        {
          "operation" => "modified",
          "section" => "Sec",
          "requirement" => "Req",
          "before_content" => multiline,
          "after_content" => "short",
          "rationale" => "Simplified"
        }
      ]
      presenter = DeltaPresenter.new(deltas, from_version: 1, to_version: 2)

      output = presenter.to_s

      assert_includes output, "Before: line one line two line three"
    end

    test "to_json_data returns array of hashes with correct keys" do
      deltas = [
        {
          "operation" => "added",
          "section" => "Auth",
          "requirement" => "Login",
          "content" => "### Requirement: Login",
          "rationale" => "Core feature"
        },
        {
          "operation" => "removed",
          "section" => "Legacy",
          "requirement" => "Old Login",
          "rationale" => "Replaced"
        }
      ]
      presenter = DeltaPresenter.new(deltas, from_version: 1, to_version: 2)

      result = presenter.to_json_data

      assert_equal 2, result.length

      assert_equal "added", result[0][:operation]
      assert_equal "Auth", result[0][:section]
      assert_equal "Login", result[0][:requirement]
      assert_equal "Core feature", result[0][:rationale]

      assert_equal "removed", result[1][:operation]
      assert_equal "Legacy", result[1][:section]
      assert_equal "Old Login", result[1][:requirement]
      assert_equal "Replaced", result[1][:rationale]
    end

    test "to_json_data omits nil values via compact" do
      deltas = [
        {
          "operation" => "added",
          "section" => "Payments",
          "requirement" => nil,
          "rationale" => "New feature"
        }
      ]
      presenter = DeltaPresenter.new(deltas, from_version: 1, to_version: 2)

      result = presenter.to_json_data

      assert_equal 1, result.length
      refute result[0].key?(:requirement)
      assert_equal "added", result[0][:operation]
      assert_equal "Payments", result[0][:section]
      assert_equal "New feature", result[0][:rationale]
    end

    test "to_s with empty deltas only shows header" do
      presenter = DeltaPresenter.new([], from_version: 5, to_version: 6)

      output = presenter.to_s

      assert_includes output, "v5"
      assert_includes output, "v6"
      assert_includes output, "Proposed changes"
    end
  end
end
