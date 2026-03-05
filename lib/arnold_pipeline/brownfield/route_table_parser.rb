require "open3"

module ArnoldPipeline
  module Brownfield
    class RouteTableParser
      TIMEOUT = 15

      def self.call(repo_path:, stack_fingerprint:)
        new(repo_path:, stack_fingerprint:).call
      end

      def initialize(repo_path:, stack_fingerprint:)
        @repo_path = repo_path
        @stack_fingerprint = stack_fingerprint
      end

      def call
        language = @stack_fingerprint[:language] || @stack_fingerprint["language"]
        framework = @stack_fingerprint[:framework] || @stack_fingerprint["framework"]

        case language
        when "ruby"
          parse_rails_routes
        when "python"
          parse_django_routes
        when "javascript", "typescript"
          return parse_nextjs_routes if framework&.to_s&.downcase == "nextjs"

          []
        else
          []
        end
      rescue => e
        []
      end

      private

      # --- Rails ---

      def parse_rails_routes
        output = run_command("bin/rails routes --expanded")
        if output
          routes = parse_rails_expanded_output(output)
          return routes if routes.any?
        end

        parse_rails_routes_file
      rescue => e
        parse_rails_routes_file
      end

      def run_command(command)
        stdout, _stderr, status = Open3.capture3(
          command,
          chdir: @repo_path,
          timeout: TIMEOUT
        )
        return nil unless status.success?

        stdout
      rescue Errno::ENOENT, Errno::EACCES
        nil
      rescue => e
        nil
      end

      def parse_rails_expanded_output(output)
        routes = []
        current = {}

        output.each_line do |line|
          line = line.strip
          if line.match?(/\A--\[/)
            routes << build_route(current) if current[:controller_action]
            current = {}
          elsif (m = line.match(/\APrefix\s*\|\s*(.*)/))
            current[:name] = m[1].strip
            current[:name] = nil if current[:name].empty?
          elsif (m = line.match(/\AVerb\s*\|\s*(.*)/))
            current[:verb] = m[1].strip
            current[:verb] = nil if current[:verb].empty?
          elsif (m = line.match(/\AURI\s*\|\s*(.*)/))
            uri = m[1].strip
            # Strip format suffix like (.:format)
            current[:path] = uri.sub(/\(\.:format\)\z/, "")
          elsif (m = line.match(/\AController#Action\s*\|\s*(.*)/))
            current[:controller_action] = m[1].strip
          end
        end

        routes << build_route(current) if current[:controller_action]
        routes
      end

      def build_route(hash)
        {
          verb: hash[:verb],
          path: hash[:path],
          controller_action: hash[:controller_action],
          name: hash[:name]
        }
      end

      def parse_rails_routes_file
        routes_file = File.join(@repo_path, "config", "routes.rb")
        return [] unless File.exist?(routes_file)

        content = File.read(routes_file)
        routes = []

        content.each_line do |line|
          stripped = line.strip
          next if stripped.start_with?("#")
          next if stripped.empty?

          routes.concat(parse_rails_route_line(stripped))
        end

        routes
      rescue => e
        []
      end

      def parse_rails_route_line(line)
        routes = []

        # root to: "controller#action" or root "controller#action"
        if (m = line.match(/\Aroot\s+(?:to:\s*)?["']([^"']+)["']/))
          routes << { verb: "GET", path: "/", controller_action: m[1], name: "root" }
          return routes
        end

        # resources :users (plural)
        if (m = line.match(/\Aresources\s+:(\w+)/))
          resource_name = m[1]
          routes.concat(expand_resources(resource_name))
          return routes
        end

        # resource :session (singular)
        if (m = line.match(/\Aresource\s+:(\w+)/))
          resource_name = m[1]
          routes.concat(expand_singular_resource(resource_name))
          return routes
        end

        # get/post/put/patch/delete "/path", to: "controller#action"
        if (m = line.match(/\A(get|post|put|patch|delete)\s+["']([^"']+)["'](?:.*to:\s*["']([^"']+)["'])?/i))
          verb = m[1].upcase
          path = m[2]
          controller_action = m[3]
          routes << { verb: verb, path: path, controller_action: controller_action, name: nil }
          return routes
        end

        routes
      end

      def expand_resources(name)
        controller = name
        [
          { verb: "GET", path: "/#{name}", controller_action: "#{controller}#index", name: "#{name}" },
          { verb: "GET", path: "/#{name}/new", controller_action: "#{controller}#new", name: "new_#{name.chomp('s')}" },
          { verb: "POST", path: "/#{name}", controller_action: "#{controller}#create", name: nil },
          { verb: "GET", path: "/#{name}/:id", controller_action: "#{controller}#show", name: name.chomp("s") },
          { verb: "GET", path: "/#{name}/:id/edit", controller_action: "#{controller}#edit", name: "edit_#{name.chomp('s')}" },
          { verb: "PATCH", path: "/#{name}/:id", controller_action: "#{controller}#update", name: nil },
          { verb: "PUT", path: "/#{name}/:id", controller_action: "#{controller}#update", name: nil },
          { verb: "DELETE", path: "/#{name}/:id", controller_action: "#{controller}#destroy", name: nil }
        ]
      end

      def expand_singular_resource(name)
        controller = "#{name}s"
        [
          { verb: "GET", path: "/#{name}/new", controller_action: "#{controller}#new", name: "new_#{name}" },
          { verb: "POST", path: "/#{name}", controller_action: "#{controller}#create", name: nil },
          { verb: "GET", path: "/#{name}", controller_action: "#{controller}#show", name: name },
          { verb: "GET", path: "/#{name}/edit", controller_action: "#{controller}#edit", name: "edit_#{name}" },
          { verb: "PATCH", path: "/#{name}", controller_action: "#{controller}#update", name: nil },
          { verb: "PUT", path: "/#{name}", controller_action: "#{controller}#update", name: nil },
          { verb: "DELETE", path: "/#{name}", controller_action: "#{controller}#destroy", name: nil }
        ]
      end

      # --- Django ---

      def parse_django_routes
        output = run_command("python manage.py show_urls")
        if output
          routes = parse_django_show_urls(output)
          return routes if routes.any?
        end

        parse_django_urls_file
      rescue => e
        parse_django_urls_file
      end

      def parse_django_show_urls(output)
        routes = []
        output.each_line do |line|
          stripped = line.strip
          next if stripped.empty?
          next if stripped.start_with?("/") == false && !stripped.match?(%r{\A\S+\s+/})

          # show_urls format: "/path/\tview_name\turl_name"
          parts = stripped.split(/\s+/)
          next if parts.size < 2

          path = parts[0]
          controller_action = parts[1]
          name = parts[2]

          routes << { verb: nil, path: path, controller_action: controller_action, name: name }
        end
        routes
      end

      def parse_django_urls_file
        urls_file = find_django_urls_file
        return [] unless urls_file && File.exist?(urls_file)

        content = File.read(urls_file)
        routes = []

        # Match path("route/", view, name="name") patterns
        content.scan(/path\(\s*["']([^"']*)["']\s*,\s*([^,)]+?)(?:\s*,\s*name\s*=\s*["']([^"']+)["'])?\s*\)/) do |path, view, name|
          routes << { verb: nil, path: "/#{path}", controller_action: view.strip, name: name }
        end

        # Match url(r"^route/$", view, name="name") patterns
        content.scan(/url\(\s*r?["']([^"']*)["']\s*,\s*([^,)]+?)(?:\s*,\s*name\s*=\s*["']([^"']+)["'])?\s*\)/) do |pattern, view, name|
          # Convert regex pattern to path
          clean_path = pattern.gsub(/[\^$]/, "").gsub("\\", "")
          clean_path = "/#{clean_path}" unless clean_path.start_with?("/")
          routes << { verb: nil, path: clean_path, controller_action: view.strip, name: name }
        end

        routes
      rescue => e
        []
      end

      def find_django_urls_file
        # Check common locations
        candidates = [
          File.join(@repo_path, "urls.py"),
          File.join(@repo_path, "config", "urls.py")
        ]

        # Also scan for */urls.py in top-level directories (project package)
        Dir.glob(File.join(@repo_path, "*", "urls.py")).each do |f|
          candidates << f
        end

        candidates.find { |f| File.exist?(f) }
      end

      # --- Next.js ---

      def parse_nextjs_routes
        routes = []

        # App Router: app/ directory
        app_dir = File.join(@repo_path, "app")
        if Dir.exist?(app_dir)
          routes.concat(scan_nextjs_app_dir(app_dir, ""))
        end

        # Also check src/app/
        src_app_dir = File.join(@repo_path, "src", "app")
        if Dir.exist?(src_app_dir)
          routes.concat(scan_nextjs_app_dir(src_app_dir, ""))
        end

        # Pages Router: pages/ directory
        pages_dir = File.join(@repo_path, "pages")
        if Dir.exist?(pages_dir)
          routes.concat(scan_nextjs_pages_dir(pages_dir, ""))
        end

        # Also check src/pages/
        src_pages_dir = File.join(@repo_path, "src", "pages")
        if Dir.exist?(src_pages_dir)
          routes.concat(scan_nextjs_pages_dir(src_pages_dir, ""))
        end

        routes
      rescue => e
        []
      end

      def scan_nextjs_app_dir(dir, prefix)
        routes = []

        Dir.entries(dir).sort.each do |entry|
          next if entry.start_with?(".")
          next if entry.start_with?("_")

          full_path = File.join(dir, entry)

          if File.directory?(full_path)
            segment = convert_nextjs_segment(entry)
            child_prefix = prefix.empty? ? "/#{segment}" : "#{prefix}/#{segment}"
            routes.concat(scan_nextjs_app_dir(full_path, child_prefix))
          elsif entry.match?(/\Apage\.(tsx?|jsx?)\z/)
            path = prefix.empty? ? "/" : prefix
            routes << { verb: "GET", path: path, controller_action: nil, name: nil }
          elsif entry.match?(/\Aroute\.(tsx?|jsx?)\z/)
            path = prefix.empty? ? "/" : prefix
            routes << { verb: nil, path: path, controller_action: nil, name: nil }
          end
        end

        routes
      end

      def scan_nextjs_pages_dir(dir, prefix)
        routes = []

        Dir.entries(dir).sort.each do |entry|
          next if entry.start_with?(".")
          next if entry.start_with?("_")

          full_path = File.join(dir, entry)

          if File.directory?(full_path)
            segment = convert_nextjs_segment(entry)
            child_prefix = "#{prefix}/#{segment}"
            routes.concat(scan_nextjs_pages_dir(full_path, child_prefix))
          elsif (file_match = entry.match(/\A(.+)\.(tsx?|jsx?)\z/))
            basename = file_match[1]
            next if basename.start_with?("_")

            segment = convert_nextjs_segment(basename)
            if segment == "index"
              path = prefix.empty? ? "/" : prefix
            else
              path = "#{prefix}/#{segment}"
            end
            routes << { verb: "GET", path: path, controller_action: nil, name: nil }
          end
        end

        routes
      end

      def convert_nextjs_segment(name)
        # Convert [id] to :id, [...slug] to :slug, [[...slug]] to :slug
        name
          .gsub(/\[\[\.\.\.(\w+)\]\]/, ':\1')
          .gsub(/\[\.\.\.(\w+)\]/, ':\1')
          .gsub(/\[(\w+)\]/, ':\1')
      end
    end
  end
end
