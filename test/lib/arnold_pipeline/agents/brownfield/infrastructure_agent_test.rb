require "test_helper"
require "arnold_pipeline/agents/brownfield/infrastructure_agent"
require "arnold_pipeline/brownfield/analysis_context"
require "arnold_pipeline/brownfield/file_content_cache"
require "tmpdir"

module ArnoldPipeline
  module Agents
    module Brownfield
      class InfrastructureAgentTest < ActiveSupport::TestCase
        setup do
          @dir = Dir.mktmpdir("infra_test_")
          @llm = mock("llm")
          @logger = Logger.new(IO::NULL)
          @agent = InfrastructureAgent.new(llm: @llm, logger: @logger)
          @file_cache = ArnoldPipeline::Brownfield::FileContentCache.new(repo_path: @dir)
          @stack_fingerprint = { language: "ruby", framework: "rails", version: "8.0" }
        end

        teardown do
          FileUtils.rm_rf(@dir)
        end

        test "returns structured analysis result with data and tokens_used" do
          FileUtils.mkdir_p(File.join(@dir, "config"))
          File.write(File.join(@dir, "config/database.yml"), "development:\n  adapter: sqlite3")

          context = build_context(
            file_manifest: { "config/database.yml" => { size: 40 } }
          )

          llm_result = {
            "conventions" => {
              "naming_conventions" => "snake_case",
              "architecture_pattern" => "MVC",
              "test_framework" => "minitest",
              "code_style" => "standard ruby",
              "dependency_management" => "bundler",
              "error_handling" => "rescue blocks",
              "configuration_approach" => "env vars"
            },
            "infrastructure" => [
              { "area" => "database", "description" => "SQLite3 configured", "status" => "configured", "files" => [ "config/database.yml" ] }
            ],
            "concerns" => [
              { "concern_id" => "data_layer", "status" => "present", "implementation" => "ActiveRecord", "files" => [ "config/database.yml" ], "notes" => "SQLite3 adapter" }
            ]
          }

          @llm.expects(:chat_json).once.returns(llm_result)

          result = @agent.call(context:, file_cache: @file_cache)

          assert_kind_of Hash, result
          assert_equal llm_result, result[:data]
          assert_kind_of Integer, result[:tokens_used]
          assert result[:tokens_used] > 0
        end

        test "selects config files from file_manifest" do
          FileUtils.mkdir_p(File.join(@dir, "config"))
          FileUtils.mkdir_p(File.join(@dir, "app/models"))
          File.write(File.join(@dir, "config/routes.rb"), "Rails.application.routes.draw {}")
          File.write(File.join(@dir, "config/database.yml"), "test: {}")
          File.write(File.join(@dir, "app/models/user.rb"), "class User; end")

          context = build_context(
            file_manifest: {
              "config/routes.rb" => { size: 40 },
              "config/database.yml" => { size: 10 },
              "app/models/user.rb" => { size: 20 }
            }
          )

          selected = Prompts::Brownfield::Infrastructure.select_files(context)

          assert_includes selected, "config/routes.rb"
          assert_includes selected, "config/database.yml"
          refute_includes selected, "app/models/user.rb"
        end

        test "selects CI and deployment files" do
          context = build_context(
            file_manifest: {
              ".github/workflows/ci.yml" => { size: 500 },
              "Procfile" => { size: 50 },
              "Dockerfile" => { size: 200 },
              "app/services/foo.rb" => { size: 100 }
            }
          )

          selected = Prompts::Brownfield::Infrastructure.select_files(context)

          assert_includes selected, ".github/workflows/ci.yml"
          assert_includes selected, "Procfile"
          assert_includes selected, "Dockerfile"
          refute_includes selected, "app/services/foo.rb"
        end

        test "selects layout and javascript controller files" do
          context = build_context(
            file_manifest: {
              "app/views/layouts/application.html.erb" => { size: 300 },
              "app/javascript/controllers/hello_controller.js" => { size: 100 },
              "app/assets/stylesheets/application.css" => { size: 200 }
            }
          )

          selected = Prompts::Brownfield::Infrastructure.select_files(context)

          assert_includes selected, "app/views/layouts/application.html.erb"
          assert_includes selected, "app/javascript/controllers/hello_controller.js"
          assert_includes selected, "app/assets/stylesheets/application.css"
        end

        test "handles empty file_manifest" do
          context = build_context(file_manifest: {})

          llm_result = {
            "conventions" => {
              "naming_conventions" => "unknown",
              "architecture_pattern" => "unknown",
              "test_framework" => "unknown",
              "code_style" => "unknown",
              "dependency_management" => "unknown",
              "error_handling" => "unknown",
              "configuration_approach" => "unknown"
            },
            "infrastructure" => [],
            "concerns" => []
          }

          @llm.expects(:chat_json).once.returns(llm_result)

          result = @agent.call(context:, file_cache: @file_cache)

          assert_empty result[:data]["infrastructure"]
          assert_empty result[:data]["concerns"]
        end

        test "passes correct schema to chat_json" do
          context = build_context(file_manifest: {})

          @llm.expects(:chat_json).with { |messages:, schema:, **|
            schema[:name] == "infrastructure_analysis" &&
            schema[:schema][:properties].key?(:conventions) &&
            schema[:schema][:properties].key?(:infrastructure) &&
            schema[:schema][:properties].key?(:concerns)
          }.returns({
            "conventions" => {
              "naming_conventions" => "x", "architecture_pattern" => "x",
              "test_framework" => "x", "code_style" => "x",
              "dependency_management" => "x", "error_handling" => "x",
              "configuration_approach" => "x"
            },
            "infrastructure" => [],
            "concerns" => []
          })

          @agent.call(context:, file_cache: @file_cache)
        end

        test "includes overlay and artifacts in prompt" do
          context = build_context(
            file_manifest: {},
            overlay: { "auth" => { "expected_locations" => [ "app/models/user.rb" ], "typical_implementations" => [ "Devise" ] } },
            artifacts: [ { role: "schema", path: "db/schema.rb", content: "create_table :users", format: "ruby" } ]
          )

          prompt_text = nil
          @llm.expects(:chat_json).with { |messages:, **|
            prompt_text = messages.first[:content]
            true
          }.returns({
            "conventions" => {
              "naming_conventions" => "x", "architecture_pattern" => "x",
              "test_framework" => "x", "code_style" => "x",
              "dependency_management" => "x", "error_handling" => "x",
              "configuration_approach" => "x"
            },
            "infrastructure" => [],
            "concerns" => []
          })

          @agent.call(context:, file_cache: @file_cache)

          assert_match(/Devise/, prompt_text)
          assert_match(/create_table :users/, prompt_text)
        end

        private

        def build_context(file_manifest: {}, overlay: {}, artifacts: [], concerns: {}, route_table: nil, git_activity: [], test_names: {}, reference_materials: [], change_request: nil)
          ArnoldPipeline::Brownfield::AnalysisContext.new(
            repo_path: @dir,
            stack_fingerprint: @stack_fingerprint,
            artifacts:,
            overlay:,
            file_manifest:,
            route_table:,
            git_activity:,
            test_names:,
            concerns:,
            reference_materials:,
            change_request:
          )
        end
      end
    end
  end
end
