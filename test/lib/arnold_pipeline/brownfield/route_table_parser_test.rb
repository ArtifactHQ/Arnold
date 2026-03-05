require "test_helper"
require "arnold_pipeline/brownfield/route_table_parser"

module ArnoldPipeline
  module Brownfield
    class RouteTableParserTest < ActiveSupport::TestCase
      setup do
        @repo_path = Dir.mktmpdir("route_parser_")
        @rails_fingerprint = { language: "ruby", framework: "rails" }
        @django_fingerprint = { language: "python", framework: "django" }
        @nextjs_ts_fingerprint = { language: "typescript", framework: "nextjs" }
        @nextjs_js_fingerprint = { language: "javascript", framework: "nextjs" }
        @unknown_fingerprint = { language: "cobol", framework: nil }
      end

      teardown do
        FileUtils.rm_rf(@repo_path)
      end

      # --- Rails: bin/rails routes --expanded ---

      test "parses rails expanded route output from command" do
        expanded_output = <<~OUTPUT
          --[ Route 1 ]--
          Prefix | home
          Verb   | GET
          URI    | /(.:format)
          Controller#Action | home#index
          --[ Route 2 ]--
          Prefix | users
          Verb   | GET
          URI    | /users(.:format)
          Controller#Action | users#index
          --[ Route 3 ]--
          Prefix | user
          Verb   | GET
          URI    | /users/:id(.:format)
          Controller#Action | users#show
        OUTPUT

        Open3.stubs(:capture3).returns([ expanded_output, "", stub(success?: true) ])

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        assert_equal 3, routes.size

        assert_equal "GET", routes[0][:verb]
        assert_equal "/", routes[0][:path]
        assert_equal "home#index", routes[0][:controller_action]
        assert_equal "home", routes[0][:name]

        assert_equal "GET", routes[1][:verb]
        assert_equal "/users", routes[1][:path]
        assert_equal "users#index", routes[1][:controller_action]
        assert_equal "users", routes[1][:name]

        assert_equal "GET", routes[2][:verb]
        assert_equal "/users/:id", routes[2][:path]
        assert_equal "users#show", routes[2][:controller_action]
        assert_equal "user", routes[2][:name]
      end

      test "handles rails expanded output with empty verb" do
        expanded_output = <<~OUTPUT
          --[ Route 1 ]--
          Prefix |
          Verb   |
          URI    | /cable
          Controller#Action | action_cable#connect
        OUTPUT

        Open3.stubs(:capture3).returns([ expanded_output, "", stub(success?: true) ])

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        assert_equal 1, routes.size
        assert_nil routes[0][:verb]
        assert_nil routes[0][:name]
        assert_equal "/cable", routes[0][:path]
        assert_equal "action_cable#connect", routes[0][:controller_action]
      end

      # --- Rails: fallback to config/routes.rb ---

      test "falls back to routes.rb when command fails" do
        FileUtils.mkdir_p(File.join(@repo_path, "config"))
        File.write(File.join(@repo_path, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            root to: "home#index"
            get "/about", to: "pages#about"
          end
        RUBY

        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        assert_equal 2, routes.size
        assert_equal({ verb: "GET", path: "/", controller_action: "home#index", name: "root" }, routes[0])
        assert_equal({ verb: "GET", path: "/about", controller_action: "pages#about", name: nil }, routes[1])
      end

      test "falls back to routes.rb when command returns empty output" do
        FileUtils.mkdir_p(File.join(@repo_path, "config"))
        File.write(File.join(@repo_path, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            get "/health", to: "health#show"
          end
        RUBY

        Open3.stubs(:capture3).returns([ "", "", stub(success?: false) ])

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        assert_equal 1, routes.size
        assert_equal "GET", routes[0][:verb]
        assert_equal "/health", routes[0][:path]
        assert_equal "health#show", routes[0][:controller_action]
      end

      test "falls back to routes.rb when command output parses to zero routes" do
        FileUtils.mkdir_p(File.join(@repo_path, "config"))
        File.write(File.join(@repo_path, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            post "/webhooks", to: "webhooks#create"
          end
        RUBY

        # Command succeeds but output is gibberish/no valid route blocks
        Open3.stubs(:capture3).returns([ "some junk output\nno routes here\n", "", stub(success?: true) ])

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        assert_equal 1, routes.size
        assert_equal "POST", routes[0][:verb]
        assert_equal "/webhooks", routes[0][:path]
      end

      # --- Rails: resources expansion ---

      test "expands resources into standard REST routes" do
        FileUtils.mkdir_p(File.join(@repo_path, "config"))
        File.write(File.join(@repo_path, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            resources :users
          end
        RUBY

        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        assert_equal 8, routes.size

        verbs = routes.map { |r| r[:verb] }
        assert_includes verbs, "GET"
        assert_includes verbs, "POST"
        assert_includes verbs, "PATCH"
        assert_includes verbs, "PUT"
        assert_includes verbs, "DELETE"

        paths = routes.map { |r| r[:path] }
        assert_includes paths, "/users"
        assert_includes paths, "/users/new"
        assert_includes paths, "/users/:id"
        assert_includes paths, "/users/:id/edit"

        actions = routes.map { |r| r[:controller_action] }
        assert_includes actions, "users#index"
        assert_includes actions, "users#show"
        assert_includes actions, "users#new"
        assert_includes actions, "users#create"
        assert_includes actions, "users#edit"
        assert_includes actions, "users#update"
        assert_includes actions, "users#destroy"
      end

      # --- Rails: singular resource expansion ---

      test "expands singular resource into REST routes without index" do
        FileUtils.mkdir_p(File.join(@repo_path, "config"))
        File.write(File.join(@repo_path, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            resource :session
          end
        RUBY

        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        assert_equal 7, routes.size

        actions = routes.map { |r| r[:controller_action] }
        refute_includes actions, "sessions#index"
        assert_includes actions, "sessions#show"
        assert_includes actions, "sessions#new"
        assert_includes actions, "sessions#create"
        assert_includes actions, "sessions#edit"
        assert_includes actions, "sessions#update"
        assert_includes actions, "sessions#destroy"

        # Singular resource paths don't have :id
        paths = routes.map { |r| r[:path] }
        assert_includes paths, "/session"
        assert_includes paths, "/session/new"
        assert_includes paths, "/session/edit"
        refute paths.any? { |p| p.include?(":id") }
      end

      # --- Rails: root route ---

      test "parses root route" do
        FileUtils.mkdir_p(File.join(@repo_path, "config"))
        File.write(File.join(@repo_path, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            root "home#index"
          end
        RUBY

        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        assert_equal 1, routes.size
        assert_equal "GET", routes[0][:verb]
        assert_equal "/", routes[0][:path]
        assert_equal "home#index", routes[0][:controller_action]
        assert_equal "root", routes[0][:name]
      end

      # --- Rails: verb + path patterns ---

      test "parses various HTTP verb route patterns" do
        FileUtils.mkdir_p(File.join(@repo_path, "config"))
        File.write(File.join(@repo_path, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            get "/about", to: "pages#about"
            post "/contact", to: "pages#contact"
            put "/profile", to: "profiles#update"
            patch "/settings", to: "settings#update"
            delete "/account", to: "accounts#destroy"
          end
        RUBY

        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        assert_equal 5, routes.size
        assert_equal "GET", routes[0][:verb]
        assert_equal "/about", routes[0][:path]
        assert_equal "pages#about", routes[0][:controller_action]

        assert_equal "POST", routes[1][:verb]
        assert_equal "/contact", routes[1][:path]

        assert_equal "PUT", routes[2][:verb]
        assert_equal "PATCH", routes[3][:verb]
        assert_equal "DELETE", routes[4][:verb]
      end

      test "parses route file with mixed patterns" do
        FileUtils.mkdir_p(File.join(@repo_path, "config"))
        File.write(File.join(@repo_path, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            root to: "home#index"
            resources :posts
            resource :profile
            get "/search", to: "search#index"
            # This is a comment
          end
        RUBY

        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        # root(1) + resources :posts(8) + resource :profile(7) + get /search(1) = 17
        assert_equal 17, routes.size
      end

      test "skips comment lines in routes.rb" do
        FileUtils.mkdir_p(File.join(@repo_path, "config"))
        File.write(File.join(@repo_path, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            # get "/hidden", to: "hidden#index"
            get "/visible", to: "visible#index"
          end
        RUBY

        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        assert_equal 1, routes.size
        assert_equal "/visible", routes[0][:path]
      end

      # --- Django: python manage.py show_urls ---

      test "parses django show_urls command output" do
        show_urls_output = <<~OUTPUT
          /\tcore.views.home\thome
          /admin/\tdjango.contrib.admin.sites.AdminSite.index\tadmin:index
          /api/users/\tapi.views.UserListView\tuser-list
        OUTPUT

        Open3.stubs(:capture3).returns([ show_urls_output, "", stub(success?: true) ])

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @django_fingerprint)

        assert_equal 3, routes.size

        assert_equal "/", routes[0][:path]
        assert_equal "core.views.home", routes[0][:controller_action]
        assert_equal "home", routes[0][:name]

        assert_equal "/api/users/", routes[2][:path]
        assert_equal "api.views.UserListView", routes[2][:controller_action]
        assert_equal "user-list", routes[2][:name]
      end

      # --- Django: fallback to urls.py ---

      test "falls back to urls.py parsing when command fails for django" do
        project_dir = File.join(@repo_path, "myproject")
        FileUtils.mkdir_p(project_dir)
        File.write(File.join(project_dir, "urls.py"), <<~PYTHON)
          from django.urls import path
          from . import views

          urlpatterns = [
              path('', views.home, name='home'),
              path('users/', views.user_list, name='user-list'),
              path('users/<int:pk>/', views.user_detail, name='user-detail'),
          ]
        PYTHON

        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @django_fingerprint)

        assert_equal 3, routes.size

        assert_equal "/", routes[0][:path]
        assert_equal "views.home", routes[0][:controller_action]
        assert_equal "home", routes[0][:name]

        assert_equal "/users/", routes[1][:path]
        assert_equal "views.user_list", routes[1][:controller_action]
        assert_equal "user-list", routes[1][:name]
      end

      test "parses django url() patterns in urls.py" do
        FileUtils.mkdir_p(File.join(@repo_path, "config"))
        File.write(File.join(@repo_path, "urls.py"), <<~PYTHON)
          from django.conf.urls import url
          from . import views

          urlpatterns = [
              url(r'^$', views.home, name='home'),
              url(r'^about/$', views.about, name='about'),
          ]
        PYTHON

        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @django_fingerprint)

        assert_equal 2, routes.size
        assert_equal "/", routes[0][:path]
        assert_equal "/about/", routes[1][:path]
      end

      # --- Next.js: App Router ---

      test "parses nextjs app router directory structure" do
        app_dir = File.join(@repo_path, "app")
        FileUtils.mkdir_p(app_dir)
        File.write(File.join(app_dir, "page.tsx"), "export default function Home() {}")

        about_dir = File.join(app_dir, "about")
        FileUtils.mkdir_p(about_dir)
        File.write(File.join(about_dir, "page.tsx"), "export default function About() {}")

        contact_dir = File.join(app_dir, "contact")
        FileUtils.mkdir_p(contact_dir)
        File.write(File.join(contact_dir, "page.jsx"), "export default function Contact() {}")

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @nextjs_ts_fingerprint)

        assert_equal 3, routes.size

        paths = routes.map { |r| r[:path] }
        assert_includes paths, "/"
        assert_includes paths, "/about"
        assert_includes paths, "/contact"

        routes.each { |r| assert_equal "GET", r[:verb] }
      end

      test "parses nextjs dynamic route segments" do
        app_dir = File.join(@repo_path, "app")
        users_dir = File.join(app_dir, "users", "[id]")
        FileUtils.mkdir_p(users_dir)
        File.write(File.join(users_dir, "page.tsx"), "export default function User() {}")

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @nextjs_ts_fingerprint)

        assert_equal 1, routes.size
        assert_equal "/users/:id", routes[0][:path]
      end

      test "parses nextjs catch-all route segments" do
        app_dir = File.join(@repo_path, "app")
        docs_dir = File.join(app_dir, "docs", "[...slug]")
        FileUtils.mkdir_p(docs_dir)
        File.write(File.join(docs_dir, "page.tsx"), "export default function Docs() {}")

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @nextjs_ts_fingerprint)

        assert_equal 1, routes.size
        assert_equal "/docs/:slug", routes[0][:path]
      end

      test "parses nextjs route.ts as API route" do
        app_dir = File.join(@repo_path, "app")
        api_dir = File.join(app_dir, "api", "users")
        FileUtils.mkdir_p(api_dir)
        File.write(File.join(api_dir, "route.ts"), "export async function GET() {}")

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @nextjs_ts_fingerprint)

        assert_equal 1, routes.size
        assert_equal "/api/users", routes[0][:path]
        # route.ts has no specific verb since it can export GET/POST/etc
        assert_nil routes[0][:verb]
      end

      # --- Next.js: Pages Router ---

      test "parses nextjs pages router directory structure" do
        pages_dir = File.join(@repo_path, "pages")
        FileUtils.mkdir_p(pages_dir)
        File.write(File.join(pages_dir, "index.tsx"), "export default function Home() {}")

        about_dir = File.join(pages_dir, "about.tsx")
        File.write(about_dir, "export default function About() {}")

        api_dir = File.join(pages_dir, "api")
        FileUtils.mkdir_p(api_dir)
        File.write(File.join(api_dir, "users.ts"), "export default handler")

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @nextjs_ts_fingerprint)

        assert_equal 3, routes.size

        paths = routes.map { |r| r[:path] }
        assert_includes paths, "/"
        assert_includes paths, "/about"
        assert_includes paths, "/api/users"
      end

      test "parses nextjs pages with dynamic segments" do
        pages_dir = File.join(@repo_path, "pages")
        posts_dir = File.join(pages_dir, "posts")
        FileUtils.mkdir_p(posts_dir)
        File.write(File.join(posts_dir, "[id].tsx"), "export default function Post() {}")

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @nextjs_ts_fingerprint)

        assert_equal 1, routes.size
        assert_equal "/posts/:id", routes[0][:path]
      end

      test "skips _app and _document files in pages router" do
        pages_dir = File.join(@repo_path, "pages")
        FileUtils.mkdir_p(pages_dir)
        File.write(File.join(pages_dir, "_app.tsx"), "export default function App() {}")
        File.write(File.join(pages_dir, "_document.tsx"), "export default function Doc() {}")
        File.write(File.join(pages_dir, "index.tsx"), "export default function Home() {}")

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @nextjs_ts_fingerprint)

        assert_equal 1, routes.size
        assert_equal "/", routes[0][:path]
      end

      test "handles nextjs javascript fingerprint" do
        app_dir = File.join(@repo_path, "app")
        FileUtils.mkdir_p(app_dir)
        File.write(File.join(app_dir, "page.js"), "export default function Home() {}")

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @nextjs_js_fingerprint)

        assert_equal 1, routes.size
        assert_equal "/", routes[0][:path]
      end

      test "handles nextjs src/app directory" do
        src_app_dir = File.join(@repo_path, "src", "app")
        FileUtils.mkdir_p(src_app_dir)
        File.write(File.join(src_app_dir, "page.tsx"), "export default function Home() {}")

        dashboard_dir = File.join(src_app_dir, "dashboard")
        FileUtils.mkdir_p(dashboard_dir)
        File.write(File.join(dashboard_dir, "page.tsx"), "export default function Dashboard() {}")

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @nextjs_ts_fingerprint)

        assert_equal 2, routes.size
        paths = routes.map { |r| r[:path] }
        assert_includes paths, "/"
        assert_includes paths, "/dashboard"
      end

      test "handles nextjs src/pages directory" do
        src_pages_dir = File.join(@repo_path, "src", "pages")
        FileUtils.mkdir_p(src_pages_dir)
        File.write(File.join(src_pages_dir, "index.tsx"), "export default function Home() {}")

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @nextjs_ts_fingerprint)

        assert_equal 1, routes.size
        assert_equal "/", routes[0][:path]
      end

      # --- Unknown stack ---

      test "returns empty array for unknown stack" do
        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @unknown_fingerprint)

        assert_equal [], routes
      end

      test "returns empty array for non-nextjs javascript stack" do
        routes = RouteTableParser.call(
          repo_path: @repo_path,
          stack_fingerprint: { language: "javascript", framework: "express" }
        )

        assert_equal [], routes
      end

      # --- Graceful failure ---

      test "returns empty array on unexpected error" do
        parser = RouteTableParser.new(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)
        parser.stubs(:parse_rails_routes).raises(RuntimeError, "something went wrong")

        assert_equal [], parser.call
      end

      test "returns empty array when routes.rb does not exist and command fails" do
        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        assert_equal [], routes
      end

      test "returns empty array when django urls.py does not exist and command fails" do
        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @django_fingerprint)

        assert_equal [], routes
      end

      test "returns empty array when nextjs has no app or pages directories" do
        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @nextjs_ts_fingerprint)

        assert_equal [], routes
      end

      # --- String keys in fingerprint ---

      test "handles string keys in stack_fingerprint" do
        FileUtils.mkdir_p(File.join(@repo_path, "config"))
        File.write(File.join(@repo_path, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            root to: "home#index"
          end
        RUBY

        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(
          repo_path: @repo_path,
          stack_fingerprint: { "language" => "ruby", "framework" => "rails" }
        )

        assert_equal 1, routes.size
        assert_equal "/", routes[0][:path]
      end

      # --- Optional catch-all segments ---

      test "parses nextjs optional catch-all segments" do
        app_dir = File.join(@repo_path, "app")
        shop_dir = File.join(app_dir, "shop", "[[...slug]]")
        FileUtils.mkdir_p(shop_dir)
        File.write(File.join(shop_dir, "page.tsx"), "export default function Shop() {}")

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @nextjs_ts_fingerprint)

        assert_equal 1, routes.size
        assert_equal "/shop/:slug", routes[0][:path]
      end

      # --- Route hash structure ---

      test "all routes have consistent keys" do
        FileUtils.mkdir_p(File.join(@repo_path, "config"))
        File.write(File.join(@repo_path, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            root to: "home#index"
            resources :posts
          end
        RUBY

        Open3.stubs(:capture3).raises(Errno::ENOENT)

        routes = RouteTableParser.call(repo_path: @repo_path, stack_fingerprint: @rails_fingerprint)

        routes.each do |route|
          assert route.key?(:verb), "Route missing :verb key"
          assert route.key?(:path), "Route missing :path key"
          assert route.key?(:controller_action), "Route missing :controller_action key"
          assert route.key?(:name), "Route missing :name key"
        end
      end
    end
  end
end
