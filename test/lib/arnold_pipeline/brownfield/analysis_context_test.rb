require "test_helper"
require "arnold_pipeline/brownfield/analysis_context"

module ArnoldPipeline
  module Brownfield
    class AnalysisContextTest < ActiveSupport::TestCase
      test "creates immutable context with all fields" do
        ctx = AnalysisContext.new(
          repo_path: "/tmp/repo",
          stack_fingerprint: { language: "ruby", framework: "rails" },
          artifacts: [],
          overlay: {},
          file_manifest: {},
          route_table: [],
          git_activity: {},
          test_names: {},
          concerns: {},
          reference_materials: [],
          change_request: nil
        )

        assert_equal "/tmp/repo", ctx.repo_path
        assert_equal "ruby", ctx.stack_fingerprint[:language]
        assert_nil ctx.change_request
      end

      test "is frozen/immutable" do
        ctx = AnalysisContext.new(
          repo_path: "/tmp/repo",
          stack_fingerprint: {},
          artifacts: [],
          overlay: {},
          file_manifest: {},
          route_table: [],
          git_activity: {},
          test_names: {},
          concerns: {},
          reference_materials: [],
          change_request: "add auth"
        )

        assert ctx.frozen?
        assert_equal "add auth", ctx.change_request
      end

      test "supports keyword access for all fields" do
        ctx = AnalysisContext.new(
          repo_path: "/repo",
          stack_fingerprint: { language: "python" },
          artifacts: [ { role: "schema" } ],
          overlay: { "auth" => {} },
          file_manifest: { "app.py" => {} },
          route_table: [ { verb: "GET", path: "/" } ],
          git_activity: { "app.py" => { commits: 5 } },
          test_names: { "auth" => [ "test_login" ] },
          concerns: { "auth" => { "status" => "present" } },
          reference_materials: [ { path: "README.md" } ],
          change_request: "add oauth"
        )

        assert_equal 1, ctx.artifacts.size
        assert_equal 1, ctx.route_table.size
        assert_equal 5, ctx.git_activity["app.py"][:commits]
        assert_equal "add oauth", ctx.change_request
      end
    end
  end
end
