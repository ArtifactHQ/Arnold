require "test_helper"
require "arnold_pipeline/agents/brownfield/data_model_agent"
require "arnold_pipeline/brownfield/analysis_context"
require "arnold_pipeline/brownfield/file_content_cache"
require "tmpdir"

module ArnoldPipeline
  module Agents
    module Brownfield
      class DataModelAgentTest < ActiveSupport::TestCase
        setup do
          @dir = Dir.mktmpdir("data_model_test_")
          @llm = mock("llm")
          @logger = Logger.new(IO::NULL)
          @agent = DataModelAgent.new(llm: @llm, logger: @logger)
          @file_cache = ArnoldPipeline::Brownfield::FileContentCache.new(repo_path: @dir)
          @stack_fingerprint = { language: "ruby", framework: "rails" }
        end

        teardown do
          FileUtils.rm_rf(@dir)
        end

        test "returns structured analysis result with data and tokens_used" do
          FileUtils.mkdir_p(File.join(@dir, "app/models"))
          File.write(File.join(@dir, "app/models/user.rb"), "class User < ApplicationRecord; end")

          context = build_context(
            file_manifest: { "app/models/user.rb" => { size: 35 } }
          )

          llm_result = {
            "entities" => [
              {
                "name" => "User",
                "table" => "users",
                "file" => "app/models/user.rb",
                "attributes" => [{ "name" => "email", "type" => "string" }],
                "associations" => [{ "type" => "has_many", "name" => "posts" }],
                "validations" => ["validates :email, presence: true"],
                "callbacks" => ["before_save :normalize_email"],
                "scopes" => ["scope :active, -> { where(active: true) }"],
                "business_methods" => [{ "name" => "full_name", "description" => "Returns first + last name" }],
                "status" => "implemented"
              }
            ],
            "relationships" => [
              { "from" => "User", "to" => "Post", "type" => "has_many", "through" => nil }
            ]
          }

          @llm.expects(:chat_json).once.returns(llm_result)

          result = @agent.call(context:, file_cache: @file_cache)

          assert_kind_of Hash, result
          assert_equal llm_result, result[:data]
          assert_kind_of Integer, result[:tokens_used]
          assert result[:tokens_used] > 0
        end

        test "selects model and schema files from file_manifest" do
          context = build_context(
            file_manifest: {
              "app/models/user.rb" => { size: 100 },
              "app/models/post.rb" => { size: 80 },
              "app/models/concerns/searchable.rb" => { size: 50 },
              "db/schema.rb" => { size: 2000 },
              "db/migrate/20240101_create_users.rb" => { size: 200 },
              "app/controllers/users_controller.rb" => { size: 300 },
              "config/routes.rb" => { size: 100 }
            }
          )

          selected = Prompts::Brownfield::DataModel.select_files(context)

          assert_includes selected, "app/models/user.rb"
          assert_includes selected, "app/models/post.rb"
          assert_includes selected, "app/models/concerns/searchable.rb"
          assert_includes selected, "db/schema.rb"
          assert_includes selected, "db/migrate/20240101_create_users.rb"
          refute_includes selected, "app/controllers/users_controller.rb"
          refute_includes selected, "config/routes.rb"
        end

        test "handles empty file_manifest" do
          context = build_context(file_manifest: {})

          llm_result = { "entities" => [], "relationships" => [] }
          @llm.expects(:chat_json).once.returns(llm_result)

          result = @agent.call(context:, file_cache: @file_cache)

          assert_empty result[:data]["entities"]
          assert_empty result[:data]["relationships"]
        end

        test "passes correct schema to chat_json" do
          context = build_context(file_manifest: {})

          @llm.expects(:chat_json).with { |messages:, schema:, **|
            schema[:name] == "data_model_analysis" &&
            schema[:schema][:properties].key?(:entities) &&
            schema[:schema][:properties].key?(:relationships)
          }.returns({ "entities" => [], "relationships" => [] })

          @agent.call(context:, file_cache: @file_cache)
        end

        test "includes schema artifact in prompt when not in file_contents" do
          context = build_context(
            file_manifest: {},
            artifacts: [{ role: "schema", path: "db/schema.rb", content: "create_table :users do |t|\n  t.string :email\nend", format: "ruby" }]
          )

          prompt_text = nil
          @llm.expects(:chat_json).with { |messages:, **|
            prompt_text = messages.first[:content]
            true
          }.returns({ "entities" => [], "relationships" => [] })

          @agent.call(context:, file_cache: @file_cache)

          assert_match(/create_table :users/, prompt_text)
        end

        test "includes route_table in prompt" do
          context = build_context(
            file_manifest: {},
            route_table: "GET /users users#index\nPOST /users users#create"
          )

          prompt_text = nil
          @llm.expects(:chat_json).with { |messages:, **|
            prompt_text = messages.first[:content]
            true
          }.returns({ "entities" => [], "relationships" => [] })

          @agent.call(context:, file_cache: @file_cache)

          assert_match(%r{GET /users}, prompt_text)
        end

        test "entities include all required fields" do
          context = build_context(file_manifest: {})

          entity = {
            "name" => "Order",
            "table" => "orders",
            "file" => "app/models/order.rb",
            "attributes" => [],
            "associations" => [],
            "validations" => [],
            "callbacks" => [],
            "scopes" => [],
            "business_methods" => [],
            "status" => "stubbed"
          }

          @llm.expects(:chat_json).once.returns({ "entities" => [entity], "relationships" => [] })

          result = @agent.call(context:, file_cache: @file_cache)

          returned_entity = result[:data]["entities"].first
          assert_equal "Order", returned_entity["name"]
          assert_equal "stubbed", returned_entity["status"]
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
