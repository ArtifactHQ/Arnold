require "test_helper"
require "arnold_pipeline/post_merge_hook"

module ArnoldPipeline
  class PostMergeHookTest < ActiveSupport::TestCase
    test "triggered_by? matches glob patterns against changed files" do
      hook = PostMergeHook.new(
        name: "bundler",
        trigger_paths: ["Gemfile", "*.gemspec"],
        command: "bundle install"
      )

      assert hook.triggered_by?(["Gemfile", "app/models/user.rb"])
      assert hook.triggered_by?(["arnold_pipeline.gemspec"])
    end

    test "triggered_by? returns false when no patterns match" do
      hook = PostMergeHook.new(
        name: "bundler",
        trigger_paths: ["Gemfile", "*.gemspec"],
        command: "bundle install"
      )

      refute hook.triggered_by?(["app/models/user.rb", "config/routes.rb"])
    end

    test "triggered_by? handles nested path patterns" do
      hook = PostMergeHook.new(
        name: "migrate",
        trigger_paths: ["db/migrate/**"],
        command: "rails db:migrate"
      )

      assert hook.triggered_by?(["db/migrate/20240101_create_users.rb"])
      refute hook.triggered_by?(["db/schema.rb"])
    end

    test "triggered_by? handles exact file patterns" do
      hook = PostMergeHook.new(
        name: "bundler",
        trigger_paths: ["Gemfile"],
        command: "bundle install"
      )

      assert hook.triggered_by?(["Gemfile"])
      refute hook.triggered_by?(["Gemfile.lock"])
    end

    test "defaults commit_message when not provided" do
      hook = PostMergeHook.new(
        name: "bundler",
        trigger_paths: ["Gemfile"],
        command: "bundle install"
      )

      assert_equal "Post-merge hook: bundler", hook.commit_message
    end

    test "uses provided commit_message" do
      hook = PostMergeHook.new(
        name: "bundler",
        trigger_paths: ["Gemfile"],
        command: "bundle install",
        commit_message: "chore: update bundle"
      )

      assert_equal "chore: update bundle", hook.commit_message
    end

    test "wraps trigger_paths and commit_paths with Array()" do
      hook = PostMergeHook.new(
        name: "single",
        trigger_paths: "Gemfile",
        command: "bundle install",
        commit_paths: "Gemfile.lock"
      )

      assert_equal ["Gemfile"], hook.trigger_paths
      assert_equal ["Gemfile.lock"], hook.commit_paths
    end

    test "commit_paths defaults to empty array" do
      hook = PostMergeHook.new(
        name: "check",
        trigger_paths: ["*.rb"],
        command: "rubocop"
      )

      assert_equal [], hook.commit_paths
    end
  end
end
