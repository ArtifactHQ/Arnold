require "test_helper"
require "arnold_pipeline/brownfield/stack_aware_file_selector"
require "arnold_pipeline/brownfield/analysis_context"

module ArnoldPipeline
  module Brownfield
    class StackAwareFileSelectorTest < ActiveSupport::TestCase
      setup do
        StackAwareFileSelector.reset!
      end

      teardown do
        StackAwareFileSelector.reset!
      end

      # -- select_files --

      test "selects files for react_native infrastructure agent" do
        context = build_context(
          stack_fingerprint: { language: "javascript", framework: "react_native" },
          file_manifest: {
            "metro.config.js" => {},
            "babel.config.js" => {},
            "tsconfig.json" => {},
            "src/App.tsx" => {},
            "src/components/Button.tsx" => {},
            "app.json" => {}
          }
        )

        files = StackAwareFileSelector.select_files(context, "infrastructure")

        assert_includes files, "metro.config.js"
        assert_includes files, "babel.config.js"
        assert_includes files, "tsconfig.json"
        assert_includes files, "app.json"
        refute_includes files, "src/App.tsx"
        refute_includes files, "src/components/Button.tsx"
      end

      test "selects files for react_native view_ux agent" do
        context = build_context(
          stack_fingerprint: { language: "javascript", framework: "react_native" },
          file_manifest: {
            "src/pages/Dashboard.tsx" => {},
            "src/screens/Login.tsx" => {},
            "src/components/ui/Button.tsx" => {},
            "src/redux/store.ts" => {},
            "src/App.tsx" => {}
          }
        )

        files = StackAwareFileSelector.select_files(context, "view_ux")

        assert_includes files, "src/pages/Dashboard.tsx"
        assert_includes files, "src/screens/Login.tsx"
        assert_includes files, "src/components/ui/Button.tsx"
        assert_includes files, "src/App.tsx"
        refute_includes files, "src/redux/store.ts"
      end

      test "selects files for react_native data_model agent" do
        context = build_context(
          stack_fingerprint: { language: "javascript", framework: "react_native" },
          file_manifest: {
            "src/redux/reducers/auth/authSlice.ts" => {},
            "src/api/clients.ts" => {},
            "src/config/api.ts" => {},
            "src/context/AuthContext.tsx" => {},
            "src/components/Button.tsx" => {}
          }
        )

        files = StackAwareFileSelector.select_files(context, "data_model")

        assert_includes files, "src/redux/reducers/auth/authSlice.ts"
        assert_includes files, "src/api/clients.ts"
        assert_includes files, "src/config/api.ts"
        assert_includes files, "src/context/AuthContext.tsx"
        refute_includes files, "src/components/Button.tsx"
      end

      test "selects files for react_native business_logic agent with exclusions" do
        context = build_context(
          stack_fingerprint: { language: "javascript", framework: "react_native" },
          file_manifest: {
            "src/redux/sagas/auth/loginSaga.ts" => {},
            "src/hooks/useAuth.ts" => {},
            "src/utils/format.ts" => {},
            "src/hooks/useAuth.test.ts" => {},
            "src/components/Button.tsx" => {}
          }
        )

        files = StackAwareFileSelector.select_files(context, "business_logic")

        assert_includes files, "src/redux/sagas/auth/loginSaga.ts"
        assert_includes files, "src/hooks/useAuth.ts"
        assert_includes files, "src/utils/format.ts"
        refute_includes files, "src/hooks/useAuth.test.ts"
        refute_includes files, "src/components/Button.tsx"
      end

      test "returns nil for unknown stack" do
        context = build_context(
          stack_fingerprint: { language: "cobol", framework: "mainframe" },
          file_manifest: { "program.cbl" => {} }
        )

        result = StackAwareFileSelector.select_files(context, "infrastructure")

        assert_nil result
      end

      test "returns nil when stack_fingerprint is nil" do
        context = build_context(
          stack_fingerprint: nil,
          file_manifest: { "foo.rb" => {} }
        )

        result = StackAwareFileSelector.select_files(context, "infrastructure")

        assert_nil result
      end

      test "selects files for ruby_rails data_model agent" do
        context = build_context(
          stack_fingerprint: { language: "ruby", framework: "rails" },
          file_manifest: {
            "app/models/user.rb" => {},
            "db/schema.rb" => {},
            "db/migrate/001_create_users.rb" => {},
            "app/controllers/users_controller.rb" => {}
          }
        )

        files = StackAwareFileSelector.select_files(context, "data_model")

        assert_includes files, "app/models/user.rb"
        assert_includes files, "db/schema.rb"
        assert_includes files, "db/migrate/001_create_users.rb"
        refute_includes files, "app/controllers/users_controller.rb"
      end

      # -- stack_family --

      test "returns mobile family for react_native" do
        context = build_context(
          stack_fingerprint: { language: "javascript", framework: "react_native" }
        )

        assert_equal "mobile", StackAwareFileSelector.stack_family(context)
      end

      test "returns server_monolith family for rails" do
        context = build_context(
          stack_fingerprint: { language: "ruby", framework: "rails" }
        )

        assert_equal "server_monolith", StackAwareFileSelector.stack_family(context)
      end

      test "returns client_spa family for nextjs" do
        context = build_context(
          stack_fingerprint: { language: "typescript", framework: "nextjs" }
        )

        assert_equal "client_spa", StackAwareFileSelector.stack_family(context)
      end

      test "returns nil family for unknown stack" do
        context = build_context(
          stack_fingerprint: { language: "cobol", framework: "mainframe" }
        )

        assert_nil StackAwareFileSelector.stack_family(context)
      end

      test "returns nil family when context has nil stack_fingerprint" do
        context = build_context(stack_fingerprint: nil)

        assert_nil StackAwareFileSelector.stack_family(context)
      end

      # -- resolve_stack_key --

      test "resolves framework when present" do
        context = build_context(
          stack_fingerprint: { language: "ruby", framework: "rails" }
        )

        assert_equal "rails", StackAwareFileSelector.resolve_stack_key(context)
      end

      test "falls back to language when framework is nil" do
        context = build_context(
          stack_fingerprint: { language: "rust", framework: nil }
        )

        assert_equal "rust", StackAwareFileSelector.resolve_stack_key(context)
      end

      # -- glob_match? --

      test "glob_match matches simple filename" do
        assert StackAwareFileSelector.glob_match?("metro.config.js", "metro.config.js")
        refute StackAwareFileSelector.glob_match?("metro.config.js", "other.config.js")
      end

      test "glob_match matches ** patterns" do
        assert StackAwareFileSelector.glob_match?("src/redux/**", "src/redux/store.ts")
        assert StackAwareFileSelector.glob_match?("src/redux/**", "src/redux/reducers/auth.ts")
        refute StackAwareFileSelector.glob_match?("src/redux/**", "src/api/client.ts")
      end

      test "glob_match matches * patterns" do
        assert StackAwareFileSelector.glob_match?("*.config.js", "metro.config.js")
        assert StackAwareFileSelector.glob_match?("*.config.js", "babel.config.js")
        refute StackAwareFileSelector.glob_match?("*.config.js", "src/metro.config.js")
      end

      test "glob_match matches mixed patterns" do
        assert StackAwareFileSelector.glob_match?("src/components/**/*.tsx", "src/components/ui/Button.tsx")
        assert StackAwareFileSelector.glob_match?("src/components/**/*.tsx", "src/components/Button.tsx")
        refute StackAwareFileSelector.glob_match?("src/components/**/*.tsx", "src/components/Button.ts")
      end

      private

      def build_context(overrides = {})
        ArnoldPipeline::Brownfield::AnalysisContext.new(
          repo_path: "/tmp/test",
          stack_fingerprint: overrides.fetch(:stack_fingerprint, { language: "ruby", framework: "rails" }),
          artifacts: [],
          overlay: {},
          file_manifest: overrides.fetch(:file_manifest, {}),
          route_table: nil,
          git_activity: {},
          test_names: {},
          concerns: {},
          reference_materials: [],
          change_request: nil
        )
      end
    end
  end
end
