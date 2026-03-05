require "test_helper"
require "arnold_pipeline/agents/brownfield/business_logic_agent"
require "arnold_pipeline/brownfield/analysis_context"
require "arnold_pipeline/brownfield/file_content_cache"
require "tmpdir"

module ArnoldPipeline
  module Agents
    module Brownfield
      class BusinessLogicAgentTest < ActiveSupport::TestCase
        setup do
          @dir = Dir.mktmpdir("biz_logic_test_")
          @llm = mock("llm")
          @logger = Logger.new(IO::NULL)
          @agent = BusinessLogicAgent.new(llm: @llm, logger: @logger)
          @file_cache = ArnoldPipeline::Brownfield::FileContentCache.new(repo_path: @dir)
          @stack_fingerprint = { language: "ruby", framework: "rails" }
        end

        teardown do
          FileUtils.rm_rf(@dir)
        end

        test "returns structured analysis result with data and tokens_used" do
          FileUtils.mkdir_p(File.join(@dir, "app/services"))
          File.write(File.join(@dir, "app/services/order_processor.rb"), "class OrderProcessor\n  def call(order)\n    order.process!\n  end\nend")

          context = build_context(
            file_manifest: { "app/services/order_processor.rb" => { size: 60 } }
          )

          llm_result = {
            "services" => [
              {
                "name" => "OrderProcessor",
                "file" => "app/services/order_processor.rb",
                "purpose" => "Processes incoming orders",
                "rules" => [ "Order must have items" ],
                "state_transitions" => [ "order: pending -> processing" ],
                "side_effects" => [ "Sends confirmation email" ],
                "error_handling" => "Raises OrderError on failure",
                "dependencies" => [ "Order", "NotificationMailer" ],
                "status" => "implemented"
              }
            ]
          }

          @llm.expects(:chat_json).once.returns(llm_result)

          result = @agent.call(context:, file_cache: @file_cache)

          assert_kind_of Hash, result
          assert_equal llm_result, result[:data]
          assert_kind_of Integer, result[:tokens_used]
          assert result[:tokens_used] > 0
        end

        test "selects service, job, mailer, and lib files" do
          context = build_context(
            file_manifest: {
              "app/services/order_processor.rb" => { size: 100 },
              "app/jobs/cleanup_job.rb" => { size: 50 },
              "app/mailers/user_mailer.rb" => { size: 80 },
              "lib/utils/formatter.rb" => { size: 40 },
              "app/models/user.rb" => { size: 200 },
              "app/controllers/orders_controller.rb" => { size: 300 }
            }
          )

          selected = Prompts::Brownfield::BusinessLogic.select_files(context)

          assert_includes selected, "app/services/order_processor.rb"
          assert_includes selected, "app/jobs/cleanup_job.rb"
          assert_includes selected, "app/mailers/user_mailer.rb"
          assert_includes selected, "lib/utils/formatter.rb"
          refute_includes selected, "app/models/user.rb"
          refute_includes selected, "app/controllers/orders_controller.rb"
        end

        test "excludes lib/tasks and lib/generators" do
          context = build_context(
            file_manifest: {
              "lib/tasks/seed.rake" => { size: 100 },
              "lib/generators/my_gen/my_gen_generator.rb" => { size: 200 },
              "lib/my_service.rb" => { size: 50 }
            }
          )

          selected = Prompts::Brownfield::BusinessLogic.select_files(context)

          refute_includes selected, "lib/tasks/seed.rake"
          refute_includes selected, "lib/generators/my_gen/my_gen_generator.rb"
          assert_includes selected, "lib/my_service.rb"
        end

        test "handles empty file_manifest" do
          context = build_context(file_manifest: {})

          llm_result = { "services" => [] }
          @llm.expects(:chat_json).once.returns(llm_result)

          result = @agent.call(context:, file_cache: @file_cache)

          assert_empty result[:data]["services"]
        end

        test "passes correct schema to chat_json" do
          context = build_context(file_manifest: {})

          @llm.expects(:chat_json).with { |messages:, schema:, **|
            schema[:name] == "business_logic_analysis" &&
            schema[:schema][:properties].key?(:services)
          }.returns({ "services" => [] })

          @agent.call(context:, file_cache: @file_cache)
        end

        test "includes git_activity in prompt" do
          context = build_context(
            file_manifest: {},
            git_activity: [
              { path: "app/services/order_processor.rb", commits: 15 },
              { path: "app/services/payment_service.rb", commits: 8 }
            ]
          )

          prompt_text = nil
          @llm.expects(:chat_json).with { |messages:, **|
            prompt_text = messages.first[:content]
            true
          }.returns({ "services" => [] })

          @agent.call(context:, file_cache: @file_cache)

          assert_match(/order_processor\.rb/, prompt_text)
          assert_match(/15 commits/, prompt_text)
        end

        test "includes test_names in prompt" do
          context = build_context(
            file_manifest: {},
            test_names: { "payments" => [ "test charges the card", "test refunds on cancellation" ] }
          )

          prompt_text = nil
          @llm.expects(:chat_json).with { |messages:, **|
            prompt_text = messages.first[:content]
            true
          }.returns({ "services" => [] })

          @agent.call(context:, file_cache: @file_cache)

          assert_match(/charges the card/, prompt_text)
          assert_match(/refunds on cancellation/, prompt_text)
        end

        test "services include all required fields" do
          context = build_context(file_manifest: {})

          service = {
            "name" => "PaymentService",
            "file" => "app/services/payment_service.rb",
            "purpose" => "Handles payment processing",
            "rules" => [],
            "state_transitions" => [],
            "side_effects" => [],
            "error_handling" => "none",
            "dependencies" => [],
            "status" => "stubbed"
          }

          @llm.expects(:chat_json).once.returns({ "services" => [ service ] })

          result = @agent.call(context:, file_cache: @file_cache)

          returned_service = result[:data]["services"].first
          assert_equal "PaymentService", returned_service["name"]
          assert_equal "stubbed", returned_service["status"]
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
