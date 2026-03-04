require "test_helper"
require "arnold_pipeline/agents/brownfield_analyzer"

module ArnoldPipeline
  module Agents
    class BrownfieldAnalyzerTest < ActiveSupport::TestCase
      setup do
        @llm = mock("llm")
        @agent = BrownfieldAnalyzer.new(llm: @llm)
        @stack_fingerprint = { language: "ruby", framework: "rails" }
        @artifacts = [
          { role: "schema", path: "db/schema.rb", content: "ActiveRecord::Schema.define {}", format: "ruby" },
          { role: "routes", path: "config/routes.rb", content: "Rails.application.routes.draw {}", format: "ruby" }
        ]
        @overlay = {
          "auth" => { "typical_implementations" => ["Devise"], "expected_locations" => ["app/models/user.rb"] },
          "data_layer" => { "typical_implementations" => ["ActiveRecord"], "expected_locations" => ["app/models/"] }
        }
        ArnoldPipeline.configure { |c| c.brownfield_scan_budget = 100_000 }
      end

      teardown do
        ArnoldPipeline.reset_configuration!
      end

      test "runs concern mapping and convention extraction" do
        concern_json = '{"concerns": {"auth": {"status": "present", "implementation": "devise", "files": [], "notes": "ok"}}}'
        convention_json = '{"naming_conventions": "snake_case", "architecture_pattern": "MVC", "test_framework": "minitest"}'

        @llm.expects(:chat).twice.returns(concern_json, convention_json)

        result = @agent.call(
          repo_path: "/tmp/test",
          stack_fingerprint: @stack_fingerprint,
          artifacts: @artifacts,
          overlay: @overlay
        )

        assert result[:recipe_alignment]["concerns"]["auth"]["status"] == "present"
        assert result[:conventions]["naming_conventions"] == "snake_case"
        assert_nil result[:documentation_fidelity]
        assert_nil result[:change_surface]
        assert result[:token_budget_used] > 0
      end

      test "runs doc fidelity when reference_materials provided" do
        concern_json = '{"concerns": {}}'
        convention_json = '{"naming_conventions": "snake_case"}'
        fidelity_json = '{"alignment_score": 75, "discrepancies": [], "summary": "ok"}'

        @llm.expects(:chat).times(3).returns(concern_json, convention_json, fidelity_json)

        Dir.mktmpdir do |dir|
          ref_path = File.join(dir, "README.md")
          File.write(ref_path, "# My App\nSome docs")

          result = @agent.call(
            repo_path: "/tmp/test",
            stack_fingerprint: @stack_fingerprint,
            artifacts: @artifacts,
            overlay: @overlay,
            reference_materials: [ref_path]
          )

          assert_equal 75, result[:documentation_fidelity]["alignment_score"]
        end
      end

      test "runs change surface when change_request provided" do
        concern_json = '{"concerns": {}}'
        convention_json = '{"naming_conventions": "snake_case"}'
        change_json = '{"affected_concerns": ["auth"], "new_concerns": [], "estimated_files": [], "risk_areas": [], "summary": "ok"}'

        @llm.expects(:chat).times(3).returns(concern_json, convention_json, change_json)

        result = @agent.call(
          repo_path: "/tmp/test",
          stack_fingerprint: @stack_fingerprint,
          artifacts: @artifacts,
          overlay: @overlay,
          change_request: "Add user authentication"
        )

        assert_includes result[:change_surface]["affected_concerns"], "auth"
      end

      test "respects token budget" do
        ArnoldPipeline.configure { |c| c.brownfield_scan_budget = 1 }

        concern_json = '{"concerns": {}}'
        convention_json = '{"naming_conventions": "snake_case"}'

        @llm.expects(:chat).twice.returns(concern_json, convention_json)

        result = @agent.call(
          repo_path: "/tmp/test",
          stack_fingerprint: @stack_fingerprint,
          artifacts: @artifacts,
          overlay: @overlay,
          reference_materials: ["/tmp/fake.md"],
          change_request: "Add auth"
        )

        # Budget exceeded after first two calls, so optional passes skipped
        assert_nil result[:documentation_fidelity]
        assert_nil result[:change_surface]
      end
    end
  end
end
