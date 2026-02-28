require "test_helper"
require "arnold_pipeline/mcp/handler"

module ArnoldPipeline
  module Mcp
    module Integration
      class EngineeringConsultationTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp*"

        setup do
          @handler = Handler.new
          @run = PipelineRun.create!(
            nl_input: "Build a real-time collaboration web app with chat",
            metadata: {
              "library_selections" => {
                "persona" => "Software Architect",
                "recipe" => "Web App",
                "supporting_recipes" => ["API Service"],
                "domain_type" => "PRODUCTIVITY"
              }
            }
          )
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Collaboration App\n\n## Purpose\nA real-time collaboration tool for teams.\n\n## Messaging\n- Real-time chat\n- Message history\n\n## Documents\n- Collaborative document editing\n- Version history\n\n## Tech Stack\n- Rails 8+\n- Hotwire / Turbo Streams\n- SQLite with Solid Queue",
            version: 1,
            structured_data: {
              "product_name" => "Collaboration App",
              "tech_stack" => { "backend" => "Rails 8+", "frontend" => "Hotwire", "database" => "SQLite" },
              "personas" => [
                { "name" => "Team Member", "description" => "Collaborates on documents and chats" },
                { "name" => "Admin", "description" => "Manages team settings and permissions" }
              ],
              "domains" => [
                { "name" => "Messaging", "description" => "Real-time chat and notifications" },
                { "name" => "Documents", "description" => "Collaborative document editing" }
              ],
              "recipes" => [{ "name" => "Web App" }]
            }
          )

          # Tasks
          @task_setup = @run.tasks.create!(
            title: "Setup project foundation",
            tier: 0, position: 0, status: :completed,
            labels: ["backend", "setup"],
            depends_on: []
          )
          @task_messaging = @run.tasks.create!(
            title: "Build messaging system",
            tier: 1, position: 1, status: :pending,
            labels: ["backend", "messaging"],
            depends_on: [@task_setup.id]
          )
          @task_documents = @run.tasks.create!(
            title: "Build document collaboration",
            tier: 1, position: 2, status: :pending,
            labels: ["backend", "documents"],
            depends_on: [@task_setup.id]
          )

          # Stub LLM for ask_engineer and explore_architecture
          @ask_engineer_response = {
            "answer" => "Use Action Cable with Turbo Streams for real-time messaging. " \
                        "The Web App recipe provides Hotwire as the frontend stack, " \
                        "which includes Turbo Streams for live updates without a full SPA.",
            "recipes_referenced" => [
              { "name" => "Web App", "relevance" => "Provides Hotwire/Turbo Streams stack for real-time" }
            ],
            "constraints" => [
              "Must use Hotwire (from recipe)",
              "Backend: Rails 8+",
              "Database: SQLite"
            ],
            "alternatives_considered" => [
              { "approach" => "WebSocket library (e.g. AnyCable)", "reason_rejected" => "Action Cable is built-in and sufficient for this scale" },
              { "approach" => "Polling-based updates", "reason_rejected" => "Not truly real-time, poor UX for chat" }
            ]
          }

          @architecture_response = {
            "architecture" => {
              "stack" => "Rails 8+ with Hotwire and SQLite",
              "rationale" => "Full-stack Ruby framework with real-time capabilities via Turbo Streams",
              "domains" => [
                {
                  "name" => "Messaging",
                  "components" => "MessagesController, Message model, ChatChannel",
                  "recipes_used" => ["Web App"],
                  "data_summary" => "Message belongs_to User, belongs_to Conversation",
                  "integrations" => "Uses Action Cable for real-time, shares auth with Documents"
                },
                {
                  "name" => "Documents",
                  "components" => "DocumentsController, Document model, CollaborationChannel",
                  "recipes_used" => ["Web App"],
                  "data_summary" => "Document has_many Versions, belongs_to User",
                  "integrations" => "Uses Turbo Streams for live editing, shares auth with Messaging"
                }
              ]
            }
          }

          @llm_stub = stub("llm")
          @llm_stub.stubs(:chat_json).returns(@ask_engineer_response)
          ArnoldPipeline::Providers::Llm.stubs(:build).returns(@llm_stub)
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        # --- Full engineering consultation flow ---

        test "engineering consultation: get_spec -> ask_engineer -> explore_architecture -> explain_recipe" do
          # Step 1: get_spec — establish context
          spec_result = call_and_parse("get_spec", { "run_id" => @run.id.to_s })

          assert_includes spec_result["spec"], "Collaboration App"
          assert_includes spec_result["metadata"]["recipes"], "Web App"
          assert_equal 2, spec_result["metadata"]["domains"].length

          # Step 2: ask_engineer — consult on tech decisions
          ask_result = call_and_parse("ask_engineer", {
            "question" => "How should I implement real-time messaging?",
            "run_id" => @run.id.to_s
          })

          assert_kind_of String, ask_result["answer"]
          assert ask_result["answer"].length > 10, "Answer should be substantive"
          assert_kind_of Array, ask_result["recipes_referenced"]
          assert_kind_of Array, ask_result["constraints"]
          assert_kind_of Array, ask_result["alternatives_considered"]

          # Step 3: explore_architecture — get structural overview
          # Switch LLM stub to return architecture response
          @llm_stub.stubs(:chat_json).returns(@architecture_response)

          arch_result = call_and_parse("explore_architecture", { "run_id" => @run.id.to_s })

          assert arch_result.key?("architecture")
          architecture = arch_result["architecture"]
          assert_kind_of String, architecture["stack"]
          assert_kind_of String, architecture["rationale"]
          assert_kind_of Array, architecture["domains"]
          assert architecture["domains"].length >= 1

          # Step 4: explain_recipe — get recipe details referenced by ask_engineer
          recipe_result = call_and_parse("explain_recipe", {
            "recipe" => "Web App",
            "run_id" => @run.id.to_s
          })

          assert_equal "Web App", recipe_result["recipe"]
          assert_kind_of String, recipe_result["purpose"]
          assert_kind_of Array, recipe_result["provides"]
          assert_kind_of Hash, recipe_result["configuration"]
          assert_kind_of Array, recipe_result["trade_offs"]
          assert_kind_of String, recipe_result["rationale"]
        end

        # --- Context consistency across tools ---

        test "ask_engineer references recipes that exist in explain_recipe" do
          ask_result = call_and_parse("ask_engineer", {
            "question" => "What framework should I use?",
            "run_id" => @run.id.to_s
          })

          referenced_recipes = ask_result["recipes_referenced"].map { |r| r["name"] }

          # Each referenced recipe should be explainable
          referenced_recipes.each do |recipe_name|
            recipe_result = call_and_parse("explain_recipe", {
              "recipe" => recipe_name,
              "run_id" => @run.id.to_s
            })

            refute recipe_result.key?("error"),
              "Recipe '#{recipe_name}' referenced by ask_engineer should exist in explain_recipe"
            assert_equal recipe_name, recipe_result["recipe"]
          end
        end

        test "explore_architecture domains align with describe_product domains" do
          # Get product domains
          describe_result = call_and_parse("describe_product", { "run_id" => @run.id.to_s })
          product_domain_names = describe_result["domains"].map { |d| d["name"].downcase }

          # Get architecture domains
          @llm_stub.stubs(:chat_json).returns(@architecture_response)
          arch_result = call_and_parse("explore_architecture", { "run_id" => @run.id.to_s })

          arch_domain_names = arch_result["architecture"]["domains"].map { |d| d["name"].downcase }

          # Architecture domains should be a subset of or overlap with product domains
          overlap = arch_domain_names & product_domain_names
          assert overlap.any?,
            "Architecture domains #{arch_domain_names} should overlap with product domains #{product_domain_names}"
        end

        test "explore_architecture scoped to domain is consistent with explore_domain" do
          # explore_domain — product level
          domain_result = call_and_parse("explore_domain", {
            "domain" => "Messaging",
            "run_id" => @run.id.to_s
          })

          assert_equal "Messaging", domain_result["domain"]
          assert_kind_of Array, domain_result["capabilities"]

          # explore_architecture with domain filter — technical level
          messaging_arch_response = {
            "architecture" => {
              "stack" => "Rails 8+ with Hotwire",
              "rationale" => "Real-time messaging via Action Cable",
              "domains" => [
                {
                  "name" => "Messaging",
                  "components" => "MessagesController, ChatChannel, Message model",
                  "recipes_used" => ["Web App"],
                  "data_summary" => "Message belongs_to Conversation belongs_to User",
                  "integrations" => "Action Cable for real-time delivery"
                }
              ]
            }
          }
          @llm_stub.stubs(:chat_json).returns(messaging_arch_response)

          arch_result = call_and_parse("explore_architecture", {
            "domain" => "Messaging",
            "run_id" => @run.id.to_s
          })

          # Both should reference the Messaging domain
          arch_domains = arch_result["architecture"]["domains"]
          messaging_arch = arch_domains.find { |d| d["name"].downcase.include?("messaging") }

          assert_not_nil messaging_arch,
            "Architecture should include the Messaging domain when filtered"

          # Architecture provides technical detail, domain provides product detail
          assert_kind_of String, messaging_arch["components"]
          assert_kind_of String, domain_result["description"]
        end

        # --- Explain recipe rationale matches pipeline selections ---

        test "explain_recipe rationale reflects pipeline selection status" do
          # Web App is the primary recipe
          webapp_result = call_and_parse("explain_recipe", {
            "recipe" => "Web App",
            "run_id" => @run.id.to_s
          })

          assert_includes webapp_result["rationale"], "primary recipe",
            "Web App rationale should mention it was selected as primary"

          # API Service is a supporting recipe
          api_result = call_and_parse("explain_recipe", {
            "recipe" => "API Service",
            "run_id" => @run.id.to_s
          })

          assert_includes api_result["rationale"], "supporting recipe",
            "API Service rationale should mention it was selected as supporting"
        end

        test "explain_recipe for non-selected recipe explains it was not chosen" do
          # Try a recipe that was not selected for this run
          # Find an available recipe that isn't "Web App" or "API Service"
          library_manager = ArnoldPipeline::Mcp::Context.new.library_manager
          all_recipe_names = library_manager.all_recipes.map(&:name)
          non_selected = all_recipe_names.find { |n|
            n != "Web App" && n != "API Service" && n != "Generic"
          }

          if non_selected
            result = call_and_parse("explain_recipe", {
              "recipe" => non_selected,
              "run_id" => @run.id.to_s
            })

            refute result.key?("error"), "Should find the recipe"
            assert_includes result["rationale"], "not selected",
              "Should explain the recipe was not selected for this run"
          end
        end

        # --- ask_engineer provides constraints from spec ---

        test "ask_engineer constraints reflect tech stack from spec" do
          ask_result = call_and_parse("ask_engineer", {
            "question" => "What database should I use?",
            "run_id" => @run.id.to_s
          })

          assert_kind_of Array, ask_result["constraints"]
          # The LLM response includes constraints from the spec
          # (Our stub returns constraints including backend/database info)
          assert ask_result["constraints"].any?, "Should have constraints"
        end

        # --- Fallback behavior when LLM fails ---

        test "ask_engineer falls back gracefully when LLM fails" do
          ArnoldPipeline::Providers::Llm.stubs(:build).raises(StandardError.new("LLM unavailable"))

          result = call_and_parse("ask_engineer", {
            "question" => "What framework to use?",
            "run_id" => @run.id.to_s
          })

          # Should return a fallback response, not an error
          assert result.key?("answer"), "Fallback should include an answer"
          assert_kind_of Array, result["recipes_referenced"]
          assert_kind_of Array, result["constraints"]
        end

        test "explore_architecture falls back when LLM fails" do
          ArnoldPipeline::Providers::Llm.stubs(:build).raises(StandardError.new("LLM unavailable"))

          result = call_and_parse("explore_architecture", { "run_id" => @run.id.to_s })

          # Should return a fallback response extracted from spec data
          assert result.key?("architecture")
          arch = result["architecture"]
          assert_kind_of String, arch["stack"]
          assert_kind_of Array, arch["domains"]
        end

        # --- Cross-track consistency: engineering + product ---

        test "get_spec metadata matches what engineering tools reference" do
          spec_result = call_and_parse("get_spec", { "run_id" => @run.id.to_s })

          # Spec metadata lists domains and recipes
          spec_domains = spec_result["metadata"]["domains"]
          spec_recipes = spec_result["metadata"]["recipes"]

          # explain_recipe should know about recipes in the spec
          spec_recipes.each do |recipe_name|
            recipe_result = call_and_parse("explain_recipe", {
              "recipe" => recipe_name,
              "run_id" => @run.id.to_s
            })
            refute recipe_result.key?("error"),
              "Recipe '#{recipe_name}' from spec metadata should be explainable"
          end

          # explore_domain should know about domains in the spec
          spec_domains.each do |domain_name|
            domain_result = call_and_parse("explore_domain", {
              "domain" => domain_name,
              "run_id" => @run.id.to_s
            })
            refute domain_result.key?("error"),
              "Domain '#{domain_name}' from spec metadata should be explorable"
          end
        end

        private

        def call_and_parse(tool_name, arguments = {})
          result = @handler.call_tool(tool_name, arguments)
          assert result[:content],
            "Tool #{tool_name} should return content, got: #{result.inspect.truncate(300)}"
          assert_equal "text", result[:content].first[:type]
          JSON.parse(result[:content].first[:text])
        end
      end
    end
  end
end
