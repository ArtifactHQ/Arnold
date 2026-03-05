require "test_helper"
require "arnold_pipeline/brownfield/git_activity_analyzer"

module ArnoldPipeline
  module Brownfield
    class GitActivityAnalyzerTest < ActiveSupport::TestCase
      setup do
        @repo_path = "/tmp/test_repo"
        @success_status = stub(success?: true)
        @failure_status = stub(success?: false)
      end

      test "parses git log output correctly" do
        git_output = <<~GIT
          abc123|Alice|2025-01-15T10:30:00+00:00

          app/models/user.rb
          app/controllers/users_controller.rb

          def456|Bob|2025-02-01T14:00:00+00:00

          app/models/user.rb
          config/routes.rb
        GIT

        Open3.stubs(:capture3).returns([ git_output, "", @success_status ])

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        assert_kind_of Hash, result
        assert_equal 3, result.keys.size
        assert_includes result.keys, "app/models/user.rb"
        assert_includes result.keys, "app/controllers/users_controller.rb"
        assert_includes result.keys, "config/routes.rb"
      end

      test "aggregates multiple commits for same file" do
        git_output = <<~GIT
          abc123|Alice|2025-01-15T10:30:00+00:00

          app/models/user.rb

          def456|Bob|2025-02-01T14:00:00+00:00

          app/models/user.rb

          ghi789|Alice|2025-03-10T09:00:00+00:00

          app/models/user.rb
        GIT

        Open3.stubs(:capture3).returns([ git_output, "", @success_status ])

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        assert_equal 3, result["app/models/user.rb"][:commits]
      end

      test "tracks unique authors per file" do
        git_output = <<~GIT
          abc123|Alice|2025-01-15T10:30:00+00:00

          app/models/user.rb

          def456|Bob|2025-02-01T14:00:00+00:00

          app/models/user.rb

          ghi789|Alice|2025-03-10T09:00:00+00:00

          app/models/user.rb
        GIT

        Open3.stubs(:capture3).returns([ git_output, "", @success_status ])

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        authors = result["app/models/user.rb"][:authors]
        assert_equal 2, authors.size
        assert_includes authors, "Alice"
        assert_includes authors, "Bob"
      end

      test "returns most recent modification date" do
        git_output = <<~GIT
          abc123|Alice|2025-01-15T10:30:00+00:00

          app/models/user.rb

          def456|Bob|2025-03-20T14:00:00+00:00

          app/models/user.rb

          ghi789|Carol|2025-02-10T09:00:00+00:00

          app/models/user.rb
        GIT

        Open3.stubs(:capture3).returns([ git_output, "", @success_status ])

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        # git log outputs most recent first, but we track the max date regardless
        assert_equal "2025-03-20", result["app/models/user.rb"][:last_modified]
      end

      test "returns empty hash on non-git repo (command failure)" do
        Open3.stubs(:capture3).returns([ "", "fatal: not a git repository", @failure_status ])

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        assert_equal({}, result)
      end

      test "returns empty hash on timeout" do
        Open3.stubs(:capture3).raises(Timeout::Error.new("execution expired"))

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        assert_equal({}, result)
      end

      test "returns empty hash on empty output" do
        Open3.stubs(:capture3).returns([ "", "", @success_status ])

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        assert_equal({}, result)
      end

      test "returns empty hash on whitespace-only output" do
        Open3.stubs(:capture3).returns([ "  \n  \n  ", "", @success_status ])

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        assert_equal({}, result)
      end

      test "custom since parameter is passed to git command" do
        expected_command = 'git log --name-only --format="%H|%an|%aI" --since="3 months ago"'

        Open3.expects(:capture3).with(
          expected_command,
          chdir: @repo_path,
          timeout: 30
        ).returns([ "", "", @success_status ])

        GitActivityAnalyzer.call(repo_path: @repo_path, since: "3 months ago")
      end

      test "uses default since of 6 months ago when not specified" do
        expected_command = 'git log --name-only --format="%H|%an|%aI" --since="6 months ago"'

        Open3.expects(:capture3).with(
          expected_command,
          chdir: @repo_path,
          timeout: 30
        ).returns([ "", "", @success_status ])

        GitActivityAnalyzer.call(repo_path: @repo_path)
      end

      test "returns empty hash on Errno::ENOENT" do
        Open3.stubs(:capture3).raises(Errno::ENOENT)

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        assert_equal({}, result)
      end

      test "returns empty hash on Errno::EACCES" do
        Open3.stubs(:capture3).raises(Errno::EACCES)

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        assert_equal({}, result)
      end

      test "handles single commit with multiple files" do
        git_output = <<~GIT
          abc123|Alice|2025-01-15T10:30:00+00:00

          app/models/user.rb
          app/models/post.rb
          app/controllers/posts_controller.rb
        GIT

        Open3.stubs(:capture3).returns([ git_output, "", @success_status ])

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        assert_equal 3, result.keys.size
        assert_equal 1, result["app/models/user.rb"][:commits]
        assert_equal 1, result["app/models/post.rb"][:commits]
        assert_equal 1, result["app/controllers/posts_controller.rb"][:commits]
        assert_equal [ "Alice" ], result["app/models/user.rb"][:authors]
        assert_equal "2025-01-15", result["app/models/user.rb"][:last_modified]
      end

      test "handles file appearing in only one commit" do
        git_output = <<~GIT
          abc123|Alice|2025-06-01T12:00:00+00:00

          config/database.yml
        GIT

        Open3.stubs(:capture3).returns([ git_output, "", @success_status ])

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        entry = result["config/database.yml"]
        assert_equal 1, entry[:commits]
        assert_equal "2025-06-01", entry[:last_modified]
        assert_equal [ "Alice" ], entry[:authors]
      end

      test "handles author names with special characters" do
        git_output = <<~GIT
          abc123|Jean-Pierre O'Brien|2025-01-15T10:30:00+00:00

          README.md
        GIT

        Open3.stubs(:capture3).returns([ git_output, "", @success_status ])

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        assert_includes result["README.md"][:authors], "Jean-Pierre O'Brien"
      end

      test "handles file paths with spaces" do
        git_output = <<~GIT
          abc123|Alice|2025-01-15T10:30:00+00:00

          app/views/home page/index.html.erb
        GIT

        Open3.stubs(:capture3).returns([ git_output, "", @success_status ])

        result = GitActivityAnalyzer.call(repo_path: @repo_path)

        assert_includes result.keys, "app/views/home page/index.html.erb"
      end
    end
  end
end
