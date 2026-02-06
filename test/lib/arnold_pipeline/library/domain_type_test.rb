require "test_helper"
require "arnold_pipeline/library/domain_type"

module ArnoldPipeline
  module Library
    class DomainTypeTest < ActiveSupport::TestCase
      test "DomainType is a Data.define value object" do
        dt = DomainType.new(
          code: "GAME",
          name: "Game / Interactive Entertainment",
          keywords: ["game", "play"],
          description: "Entertainment apps",
          primary_value: "Fun, engagement",
          emphasis: ["Progression systems"],
          document_focus: ["Win/loss conditions"],
          watch_for: ["Game balance"],
          terminology: { "user" => "player" }
        )

        assert_equal "GAME", dt.code
        assert_equal "Game / Interactive Entertainment", dt.name
        assert_equal ["game", "play"], dt.keywords
        assert_equal "Entertainment apps", dt.description
        assert_equal "Fun, engagement", dt.primary_value
        assert_equal ["Progression systems"], dt.emphasis
        assert_equal ["Win/loss conditions"], dt.document_focus
        assert_equal ["Game balance"], dt.watch_for
        assert_equal({ "user" => "player" }, dt.terminology)
      end

      test "DomainType is immutable" do
        dt = DomainType.new(
          code: "GAME",
          name: "Game",
          keywords: ["game"],
          description: "desc",
          primary_value: "fun",
          emphasis: [],
          document_focus: [],
          watch_for: [],
          terminology: {}
        )

        assert dt.frozen?
      end

      test "DomainType responds to all expected fields" do
        dt = DomainType.new(
          code: "TEST", name: "Test", keywords: [], description: "test",
          primary_value: "test", emphasis: [], document_focus: [],
          watch_for: [], terminology: {}
        )

        %i[code name keywords description primary_value emphasis document_focus watch_for terminology].each do |field|
          assert_respond_to dt, field
        end
      end
    end
  end
end
