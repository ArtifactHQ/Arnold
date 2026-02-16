require "test_helper"
require "arnold_pipeline/acceptance_criterion"

module ArnoldPipeline
  class AcceptanceCriterionTest < ActiveSupport::TestCase
    test "from_hash creates criterion with type and description" do
      criterion = AcceptanceCriterion.from_hash(
        "type" => "file_exists",
        "description" => "Gemfile exists",
        "pattern" => "Gemfile"
      )

      assert_equal "file_exists", criterion.type
      assert_equal "Gemfile exists", criterion.description
      assert_equal({ "pattern" => "Gemfile" }, criterion.params)
    end

    test "from_hash handles symbol keys" do
      criterion = AcceptanceCriterion.from_hash(
        type: "http",
        description: "Login endpoint",
        method: "POST",
        path: "/api/sessions"
      )

      assert_equal "http", criterion.type
      assert_equal "Login endpoint", criterion.description
      assert_equal({ "method" => "POST", "path" => "/api/sessions" }, criterion.params)
    end

    test "from_hash defaults description to empty string" do
      criterion = AcceptanceCriterion.from_hash("type" => "file_exists", "pattern" => "Gemfile")

      assert_equal "", criterion.description
    end

    test "from_array creates multiple criteria" do
      criteria = AcceptanceCriterion.from_array([
        { "type" => "file_exists", "description" => "Has Gemfile", "pattern" => "Gemfile" },
        { "type" => "route_exists", "description" => "Has root route", "method" => "GET", "path" => "/" }
      ])

      assert_equal 2, criteria.size
      assert_equal "file_exists", criteria[0].type
      assert_equal "route_exists", criteria[1].type
    end

    test "from_array returns empty array for nil" do
      assert_equal [], AcceptanceCriterion.from_array(nil)
    end

    test "from_array returns empty array for empty array" do
      assert_equal [], AcceptanceCriterion.from_array([])
    end

    test "static? returns true for static types" do
      %w[file_exists test_exists model_has route_exists].each do |type|
        criterion = AcceptanceCriterion.new(type: type, description: "", params: {})
        assert criterion.static?, "Expected #{type} to be static"
      end
    end

    test "static? returns false for runtime types" do
      %w[http command_exits].each do |type|
        criterion = AcceptanceCriterion.new(type: type, description: "", params: {})
        refute criterion.static?, "Expected #{type} not to be static"
      end
    end

    test "runtime? returns true for runtime types" do
      %w[http command_exits].each do |type|
        criterion = AcceptanceCriterion.new(type: type, description: "", params: {})
        assert criterion.runtime?, "Expected #{type} to be runtime"
      end
    end

    test "runtime? returns false for static types" do
      %w[file_exists test_exists model_has route_exists].each do |type|
        criterion = AcceptanceCriterion.new(type: type, description: "", params: {})
        refute criterion.runtime?, "Expected #{type} not to be runtime"
      end
    end

    test "valid_type? returns true for all known types" do
      AcceptanceCriterion::VALID_TYPES.each do |type|
        criterion = AcceptanceCriterion.new(type: type, description: "", params: {})
        assert criterion.valid_type?, "Expected #{type} to be valid"
      end
    end

    test "valid_type? returns false for unknown type" do
      criterion = AcceptanceCriterion.new(type: "unknown", description: "", params: {})
      refute criterion.valid_type?
    end

    test "params captures all extra fields from hash" do
      criterion = AcceptanceCriterion.from_hash(
        "type" => "http",
        "description" => "Test endpoint",
        "method" => "POST",
        "path" => "/api/users",
        "input" => { "name" => "Test" },
        "expected_status" => 201,
        "expected_body_contains" => ["id"]
      )

      assert_equal "POST", criterion.params["method"]
      assert_equal "/api/users", criterion.params["path"]
      assert_equal({ "name" => "Test" }, criterion.params["input"])
      assert_equal 201, criterion.params["expected_status"]
      assert_equal ["id"], criterion.params["expected_body_contains"]
    end

    test "Data.define creates frozen immutable objects" do
      criterion = AcceptanceCriterion.new(type: "file_exists", description: "test", params: {})
      assert criterion.frozen?
    end
  end
end
