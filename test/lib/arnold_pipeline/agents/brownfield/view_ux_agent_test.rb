require "test_helper"
require "arnold_pipeline/agents/brownfield/view_ux_agent"
require "arnold_pipeline/brownfield/analysis_context"
require "arnold_pipeline/brownfield/file_content_cache"
require "tmpdir"

module ArnoldPipeline
  module Agents
    module Brownfield
      class ViewUxAgentTest < ActiveSupport::TestCase
        setup do
          @dir = Dir.mktmpdir("view_test_")
          @llm = mock("llm")
          @logger = Logger.new(IO::NULL)
          @agent = ViewUxAgent.new(llm: @llm, logger: @logger)
          @file_cache = ArnoldPipeline::Brownfield::FileContentCache.new(repo_path: @dir)
          @stack_fingerprint = { language: "ruby", framework: "rails" }
        end

        teardown do
          FileUtils.rm_rf(@dir)
        end

        test "returns structured page analysis" do
          FileUtils.mkdir_p(File.join(@dir, "app/views/users"))
          File.write(File.join(@dir, "app/views/users/index.html.erb"), <<~ERB)
            <h1>Users</h1>
            <% @users.each do |user| %>
              <p><%= user.name %></p>
            <% end %>
          ERB

          context = build_context(
            file_manifest: { "app/views/users/index.html.erb" => { lines: 4 } }
          )

          llm_result = {
            "pages" => [
              {
                "name" => "User List",
                "path" => "app/views/users/index.html.erb",
                "description" => "Displays a list of all users",
                "data_displayed" => ["user names"],
                "actions" => [],
                "role_adaptations" => [],
                "layout" => "application",
                "javascript_controllers" => [],
                "status" => "implemented"
              }
            ]
          }

          @llm.expects(:chat_json).once.with { |messages:, schema:, **|
            content = messages.first[:content]
            schema[:name] == "view_ux_analysis" &&
              content.include?("Users") &&
              content.include?("user.name")
          }.returns(llm_result)

          result = @agent.call(context:, file_cache: @file_cache)

          assert_kind_of Hash, result
          assert_equal llm_result, result[:data]
          assert result[:tokens_used] > 0
          assert_equal 1, result[:data]["pages"].size
          assert_equal "User List", result[:data]["pages"].first["name"]
        end

        test "selects view, helper, js controller, and component files" do
          FileUtils.mkdir_p(File.join(@dir, "app/views/posts"))
          FileUtils.mkdir_p(File.join(@dir, "app/helpers"))
          FileUtils.mkdir_p(File.join(@dir, "app/javascript/controllers"))
          FileUtils.mkdir_p(File.join(@dir, "app/components"))
          File.write(File.join(@dir, "app/views/posts/show.html.erb"), "<h1>Post</h1>")
          File.write(File.join(@dir, "app/helpers/posts_helper.rb"), "module PostsHelper; end")
          File.write(File.join(@dir, "app/javascript/controllers/modal_controller.js"), "export default class {}")
          File.write(File.join(@dir, "app/components/card_component.rb"), "class CardComponent; end")

          context = build_context(
            file_manifest: {
              "app/views/posts/show.html.erb" => { lines: 1 },
              "app/helpers/posts_helper.rb" => { lines: 1 },
              "app/javascript/controllers/modal_controller.js" => { lines: 1 },
              "app/components/card_component.rb" => { lines: 1 },
              "app/models/post.rb" => { lines: 1 }
            }
          )

          @llm.expects(:chat_json).once.with { |messages:, **|
            content = messages.first[:content]
            content.include?("Post</h1>") &&
              content.include?("PostsHelper") &&
              content.include?("modal_controller") &&
              content.include?("CardComponent") &&
              !content.include?("app/models/post.rb")
          }.returns({ "pages" => [] })

          @agent.call(context:, file_cache: @file_cache)
        end

        test "excludes non-view files from selection" do
          context = build_context(
            file_manifest: {
              "app/models/user.rb" => { lines: 10 },
              "app/controllers/users_controller.rb" => { lines: 20 },
              "config/routes.rb" => { lines: 5 },
              "db/schema.rb" => { lines: 50 }
            }
          )

          @llm.expects(:chat_json).once.with { |messages:, **|
            content = messages.first[:content]
            content.include?("(no view templates found)") &&
              content.include?("(no helper files found)")
          }.returns({ "pages" => [] })

          @agent.call(context:, file_cache: @file_cache)
        end

        test "handles empty file manifest" do
          context = build_context(file_manifest: {})

          @llm.expects(:chat_json).once.with { |messages:, **|
            content = messages.first[:content]
            content.include?("(no view templates found)") &&
              content.include?("(no helper files found)") &&
              content.include?("(no JavaScript controllers found)") &&
              content.include?("(no component files found)")
          }.returns({ "pages" => [] })

          result = @agent.call(context:, file_cache: @file_cache)

          assert_equal({ "pages" => [] }, result[:data])
          assert result[:tokens_used] > 0
        end

        test "handles nil file manifest" do
          context = build_context(file_manifest: nil)

          @llm.expects(:chat_json).once.returns({ "pages" => [] })

          result = @agent.call(context:, file_cache: @file_cache)

          assert_equal({ "pages" => [] }, result[:data])
        end

        test "includes stack fingerprint in prompt" do
          context = build_context(
            file_manifest: {},
            stack_fingerprint: { language: "python", framework: "django" }
          )

          @llm.expects(:chat_json).once.with { |messages:, **|
            content = messages.first[:content]
            content.include?("python") && content.include?("django")
          }.returns({ "pages" => [] })

          @agent.call(context:, file_cache: @file_cache)
        end

        test "categorizes files into correct prompt sections" do
          FileUtils.mkdir_p(File.join(@dir, "app/views/layouts"))
          FileUtils.mkdir_p(File.join(@dir, "app/helpers"))
          File.write(File.join(@dir, "app/views/layouts/application.html.erb"), "<%= yield %>")
          File.write(File.join(@dir, "app/helpers/application_helper.rb"), "module ApplicationHelper; end")

          context = build_context(
            file_manifest: {
              "app/views/layouts/application.html.erb" => { lines: 1 },
              "app/helpers/application_helper.rb" => { lines: 1 }
            }
          )

          @llm.expects(:chat_json).once.with { |messages:, **|
            content = messages.first[:content]
            # View should be under View Templates section, helper under Helper Files section
            view_idx = content.index("## View Templates")
            helper_idx = content.index("## Helper Files")
            view_content_idx = content.index("application.html.erb")
            helper_content_idx = content.index("ApplicationHelper")
            view_idx && helper_idx && view_content_idx && helper_content_idx &&
              view_content_idx > view_idx && helper_content_idx > helper_idx
          }.returns({ "pages" => [] })

          @agent.call(context:, file_cache: @file_cache)
        end

        test "tokens_used reflects prompt and result size" do
          context = build_context(file_manifest: {})

          @llm.expects(:chat_json).once.returns({ "pages" => [] })

          result = @agent.call(context:, file_cache: @file_cache)

          # tokens_used should be positive and based on prompt + result character counts / 4
          assert_kind_of Integer, result[:tokens_used]
          assert result[:tokens_used] > 0
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
