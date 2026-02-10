require "test_helper"

module ArnoldPipeline
  class SpecRevisionTest < ActiveSupport::TestCase
    setup do
      @run = PipelineRun.create!(nl_input: "Build a todo app")
      @spec = @run.create_specification!(content: "# Spec", version: 1)
    end

    test "valid revision" do
      revision = @spec.spec_revisions.build(
        version: 1,
        content: "# Spec v1",
        change_source: "spec_generation"
      )
      assert revision.valid?
    end

    test "requires version" do
      revision = @spec.spec_revisions.build(version: nil, content: "content")
      assert_not revision.valid?
      assert_includes revision.errors[:version], "can't be blank"
    end

    test "version must be greater than 0" do
      assert_not @spec.spec_revisions.build(version: 0, content: "c").valid?
      assert @spec.spec_revisions.build(version: 1, content: "c").valid?
    end

    test "requires content" do
      revision = @spec.spec_revisions.build(version: 1, content: nil)
      assert_not revision.valid?
      assert_includes revision.errors[:content], "can't be blank"
    end

    test "validates change_source inclusion" do
      revision = @spec.spec_revisions.build(version: 1, content: "c", change_source: "invalid")
      assert_not revision.valid?
      assert_includes revision.errors[:change_source], "is not included in the list"
    end

    test "accepts valid change_sources" do
      %w[spec_generation iterate_spec].each do |source|
        revision = @spec.spec_revisions.build(version: 1, content: "c", change_source: source)
        assert revision.valid?, "Expected #{source} to be valid"
      end
    end

    test "allows nil change_source" do
      revision = @spec.spec_revisions.build(version: 1, content: "c", change_source: nil)
      assert revision.valid?
    end

    test "unique version per specification" do
      @spec.spec_revisions.create!(version: 1, content: "v1")

      duplicate = @spec.spec_revisions.build(version: 1, content: "v1 again")
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save! }
    end

    test "ordered scope returns by version ascending" do
      @spec.spec_revisions.create!(version: 2, content: "v2")
      @spec.spec_revisions.create!(version: 1, content: "v1")
      @spec.spec_revisions.create!(version: 3, content: "v3")

      versions = @spec.spec_revisions.ordered.map(&:version)
      assert_equal [1, 2, 3], versions
    end

    test "stores structured_data as JSON" do
      revision = @spec.spec_revisions.create!(
        version: 1,
        content: "c",
        structured_data: { "features" => ["auth"] }
      )
      assert_equal({ "features" => ["auth"] }, revision.reload.structured_data)
    end

    test "stores delta_summary as JSON array" do
      summary = ["ADDED: Auth > Password Reset", "MODIFIED: Auth > Login"]
      revision = @spec.spec_revisions.create!(
        version: 1,
        content: "c",
        delta_summary: summary
      )
      assert_equal summary, revision.reload.delta_summary
    end

    test "belongs to specification" do
      revision = @spec.spec_revisions.create!(version: 1, content: "c")
      assert_equal @spec, revision.specification
    end

    test "specification has_many spec_revisions with dependent destroy" do
      @spec.spec_revisions.create!(version: 1, content: "c")
      assert_equal 1, @spec.spec_revisions.count

      @spec.destroy!
      assert_equal 0, SpecRevision.where(specification_id: @spec.id).count
    end
  end
end
