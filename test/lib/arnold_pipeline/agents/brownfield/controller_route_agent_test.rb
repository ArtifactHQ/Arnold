require "test_helper"
require "arnold_pipeline/agents/brownfield/controller_route_agent"
require "arnold_pipeline/brownfield/analysis_context"
require "arnold_pipeline/brownfield/file_content_cache"
require "tmpdir"

module ArnoldPipeline
  module Agents
    module Brownfield
      class ControllerRouteAgentTest < ActiveSupport::TestCase
        setup do
          @dir = Dir.mktmpdir("ctrl_test_")
          @llm = mock("llm")
          @logger = Logger.new(IO::NULL)
          @agent = ControllerRouteAgent.new(llm: @llm, logger: @logger)
          @file_cache = ArnoldPipeline::Brownfield::FileContentCache.new(repo_path: @dir)
          @stack_fingerprint = { language: "ruby", framework: "rails" }
        end

        teardown do
          FileUtils.rm_rf(@dir)
        end

        test "returns structured endpoint analysis" do
          FileUtils.mkdir_p(File.join(@dir, "app/controllers"))
          File.write(File.join(@dir, "app/controllers/users_controller.rb"), <<~RUBY)
            class UsersController < ApplicationController
              def index
                @users = User.all
              end
            end
          RUBY

          context = build_context(
            file_manifest: { "app/controllers/users_controller.rb" => { lines: 5 } },
            route_table: "GET /users users#index"
          )

          llm_result = {
            "endpoints" => [
              {
                "verb" => "GET",
                "path" => "/users",
                "controller" => "UsersController",
                "action" => "index",
                "description" => "Lists all users",
                "access_control" => "public",
                "side_effects" => [],
                "error_handling" => "default Rails error handling",
                "input_params" => [],
                "output_format" => "HTML",
                "status" => "implemented"
              }
            ]
          }

          @llm.expects(:chat_json).once.with { |messages:, schema:, **|
            content = messages.first[:content]
            schema[:name] == "controller_route_analysis" &&
              content.include?("UsersController") &&
              content.include?("GET /users")
          }.returns(llm_result)

          result = @agent.call(context:, file_cache: @file_cache)

          assert_kind_of Hash, result
          assert_equal llm_result, result[:data]
          assert result[:tokens_used] > 0
          assert_equal 1, result[:data]["endpoints"].size
          assert_equal "GET", result[:data]["endpoints"].first["verb"]
        end

        test "selects only controller files from manifest" do
          FileUtils.mkdir_p(File.join(@dir, "app/controllers"))
          FileUtils.mkdir_p(File.join(@dir, "app/models"))
          File.write(File.join(@dir, "app/controllers/posts_controller.rb"), "class PostsController; end")
          File.write(File.join(@dir, "app/models/post.rb"), "class PostModel; end")

          context = build_context(
            file_manifest: {
              "app/controllers/posts_controller.rb" => { lines: 1 },
              "app/models/post.rb" => { lines: 1 },
              "config/routes.rb" => { lines: 10 }
            }
          )

          @llm.expects(:chat_json).once.with { |messages:, schema:, **|
            content = messages.first[:content]
            content.include?("PostsController") && !content.include?("PostModel")
          }.returns({ "endpoints" => [] })

          result = @agent.call(context:, file_cache: @file_cache)

          assert_equal({ "endpoints" => [] }, result[:data])
        end

        test "handles empty file manifest" do
          context = build_context(file_manifest: {})

          @llm.expects(:chat_json).once.with { |messages:, schema:, **|
            messages.first[:content].include?("(no controller files found)")
          }.returns({ "endpoints" => [] })

          result = @agent.call(context:, file_cache: @file_cache)

          assert_equal({ "endpoints" => [] }, result[:data])
          assert result[:tokens_used] > 0
        end

        test "handles nil file manifest" do
          context = build_context(file_manifest: nil)

          @llm.expects(:chat_json).once.returns({ "endpoints" => [] })

          result = @agent.call(context:, file_cache: @file_cache)

          assert_equal({ "endpoints" => [] }, result[:data])
        end

        test "includes route table in prompt" do
          context = build_context(
            route_table: "GET    /users          users#index\nPOST   /users          users#create",
            file_manifest: {}
          )

          @llm.expects(:chat_json).once.with { |messages:, **|
            content = messages.first[:content]
            content.include?("users#index") && content.include?("users#create")
          }.returns({ "endpoints" => [] })

          @agent.call(context:, file_cache: @file_cache)
        end

        test "handles nil route table" do
          context = build_context(route_table: nil, file_manifest: {})

          @llm.expects(:chat_json).once.with { |messages:, **|
            messages.first[:content].include?("(no route table available)")
          }.returns({ "endpoints" => [] })

          @agent.call(context:, file_cache: @file_cache)
        end

        test "includes stack fingerprint in prompt" do
          context = build_context(
            file_manifest: {},
            stack_fingerprint: { language: "python", framework: "django" }
          )

          @llm.expects(:chat_json).once.with { |messages:, **|
            content = messages.first[:content]
            content.include?("python") && content.include?("django")
          }.returns({ "endpoints" => [] })

          @agent.call(context:, file_cache: @file_cache)
        end

        test "selects nested controller files" do
          FileUtils.mkdir_p(File.join(@dir, "app/controllers/api/v1"))
          File.write(File.join(@dir, "app/controllers/api/v1/items_controller.rb"), "class Api::V1::ItemsController; end")

          context = build_context(
            file_manifest: {
              "app/controllers/api/v1/items_controller.rb" => { lines: 1 }
            }
          )

          @llm.expects(:chat_json).once.with { |messages:, **|
            messages.first[:content].include?("Api::V1::ItemsController")
          }.returns({ "endpoints" => [] })

          @agent.call(context:, file_cache: @file_cache)
        end

        private

        def build_context(overrides = {})
          ArnoldPipeline::Brownfield::AnalysisContext.new(
            repo_path: @dir,
            stack_fingerprint: overrides.fetch(:stack_fingerprint, @stack_fingerprint),
            artifacts: overrides.fetch(:artifacts, []),
            overlay: overrides.fetch(:overlay, {}),
            file_manifest: overrides.fetch(:file_manifest, {}),
            route_table: overrides.fetch(:route_table, nil),
            git_activity: overrides.fetch(:git_activity, {}),
            test_names: overrides.fetch(:test_names, {}),
            concerns: overrides.fetch(:concerns, {}),
            reference_materials: overrides.fetch(:reference_materials, []),
            change_request: overrides.fetch(:change_request, nil)
          )
        end
      end
    end
  end
end
