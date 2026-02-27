require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/get_history"

module ArnoldPipeline
  module Mcp
    module Tools
      class GetHistoryTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::GetHistory*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a dog walking app")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Dog Walking App\n\n## Booking\n- Schedule walks\n\n## Messaging\n- In-app chat",
            version: 3,
            structured_data: {
              "domains" => [
                { "name" => "Booking", "description" => "Walk scheduling" },
                { "name" => "Messaging", "description" => "In-app communication" }
              ]
            }
          )

          # Create revision history
          @rev1 = SpecRevision.create!(
            specification: @spec,
            version: 1,
            content: "# Dog Walking App\n\n## Booking\n- Schedule walks",
            change_source: "spec_generation",
            created_at: 3.hours.ago
          )
          @rev2 = SpecRevision.create!(
            specification: @spec,
            version: 2,
            content: "# Dog Walking App\n\n## Booking\n- Schedule walks\n- Cancel bookings\n\n## Messaging\n- In-app chat",
            change_source: "mcp_confirm",
            created_at: 2.hours.ago
          )
          @rev3 = SpecRevision.create!(
            specification: @spec,
            version: 3,
            content: "# Dog Walking App\n\n## Booking\n- Schedule walks\n- Cancel bookings\n- Recurring booking\n\n## Messaging\n- In-app chat\n- Push notifications",
            change_source: "iterate_spec",
            created_at: 1.hour.ago
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns get_history" do
          assert_equal "get_history", GetHistory.tool_name
        end

        test "description is present and non-empty" do
          assert_kind_of String, GetHistory.description
          refute_empty GetHistory.description
        end

        test "input_schema has optional params" do
          schema = GetHistory.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:run_id)
          assert schema[:properties].key?(:domain)
          assert schema[:properties].key?(:limit)
          assert_equal [], schema[:required]
        end

        test "returns revisions in chronological order" do
          result = GetHistory.call({}, @context)

          revisions = result[:revisions]
          assert_equal 3, revisions.length
          assert_equal "1", revisions[0][:revision]
          assert_equal "2", revisions[1][:revision]
          assert_equal "3", revisions[2][:revision]
        end

        test "respects limit parameter" do
          result = GetHistory.call({ "limit" => 2 }, @context)

          assert_equal 2, result[:revisions].length
          assert_equal "1", result[:revisions][0][:revision]
          assert_equal "2", result[:revisions][1][:revision]
        end

        test "default limit is 10" do
          # Only 3 revisions, so all returned
          result = GetHistory.call({}, @context)
          assert_equal 3, result[:revisions].length
        end

        test "domain filter returns only matching revisions" do
          # "Messaging" was added in rev2, so rev1 (no messaging) should be included
          # (initial creation affects all domains), but domain filter checks content changes
          result = GetHistory.call({ "domain" => "Messaging" }, @context)

          revisions = result[:revisions]
          # Rev1 is initial (affects all domains), Rev2 added messaging, Rev3 changed messaging
          assert revisions.any?, "Should have revisions affecting Messaging"
          revisions.each do |rev|
            assert rev[:domains_affected].any? { |d| d.downcase.include?("messaging") },
              "Revision #{rev[:revision]} should affect Messaging domain"
          end
        end

        test "each revision has product-level summary" do
          result = GetHistory.call({}, @context)

          result[:revisions].each do |rev|
            assert_kind_of String, rev[:summary]
            refute_empty rev[:summary]
          end
        end

        test "initial revision has spec_generation summary" do
          result = GetHistory.call({}, @context)

          first = result[:revisions].first
          assert_equal "spec_generation", first[:change_source]
          assert_includes first[:summary], "Initial specification generated"
        end

        test "change_source is present and accurate" do
          result = GetHistory.call({}, @context)

          sources = result[:revisions].map { |r| r[:change_source] }
          assert_equal "spec_generation", sources[0]
          assert_equal "mcp_confirm", sources[1]
          assert_equal "iterate_spec", sources[2]
        end

        test "domains_affected populated" do
          result = GetHistory.call({}, @context)

          result[:revisions].each do |rev|
            assert_kind_of Array, rev[:domains_affected]
          end

          # Initial revision should affect all domains
          first = result[:revisions].first
          assert first[:domains_affected].length >= 1
        end

        test "single revision returns correctly" do
          # Remove extra revisions
          @rev2.destroy!
          @rev3.destroy!

          result = GetHistory.call({}, @context)

          assert_equal 1, result[:revisions].length
          assert_equal "1", result[:revisions][0][:revision]
        end

        test "unknown run_id returns error" do
          result = GetHistory.call({ "run_id" => "99999" }, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "no specification returns error" do
          run_no_spec = PipelineRun.create!(nl_input: "no spec")
          result = GetHistory.call({ "run_id" => run_no_spec.id.to_s }, @context)
          assert_includes result[:error], "No specification found"
        end

        test "timestamp is present" do
          result = GetHistory.call({}, @context)

          result[:revisions].each do |rev|
            assert_kind_of String, rev[:timestamp]
          end
        end

        test "response has all expected keys" do
          result = GetHistory.call({}, @context)

          assert result.key?(:revisions)
          rev = result[:revisions].first
          assert rev.key?(:revision)
          assert rev.key?(:timestamp)
          assert rev.key?(:change_source)
          assert rev.key?(:summary)
          assert rev.key?(:domains_affected)
        end

        test "mcp_confirm summary includes diff info" do
          result = GetHistory.call({}, @context)

          mcp_rev = result[:revisions].find { |r| r[:change_source] == "mcp_confirm" }
          assert_includes mcp_rev[:summary], "updated via proposal"
        end
      end
    end
  end
end
