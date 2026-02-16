require "test_helper"
require "arnold_pipeline/acceptance_criterion"
require "arnold_pipeline/criteria_checker"
require "tmpdir"
require "fileutils"

module ArnoldPipeline
  class CriteriaCheckerTest < ActiveSupport::TestCase
    setup do
      @repo_path = Dir.mktmpdir("arnold_criteria_test")
    end

    teardown do
      FileUtils.rm_rf(@repo_path)
    end

    # --- file_exists ---

    test "file_exists verifies when file matches pattern" do
      FileUtils.touch(File.join(@repo_path, "Gemfile"))

      criteria = [criterion("file_exists", pattern: "Gemfile")]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:verified].size
      assert_empty result[:failed]
    end

    test "file_exists fails when no file matches pattern" do
      criteria = [criterion("file_exists", pattern: "Gemfile")]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_empty result[:verified]
      assert_equal 1, result[:failed].size
    end

    test "file_exists supports glob patterns" do
      FileUtils.mkdir_p(File.join(@repo_path, "app/models"))
      FileUtils.touch(File.join(@repo_path, "app/models/user.rb"))

      criteria = [criterion("file_exists", pattern: "app/models/*.rb")]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:verified].size
    end

    test "file_exists fails without pattern param" do
      criteria = [AcceptanceCriterion.new(type: "file_exists", description: "missing pattern", params: {})]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:failed].size
    end

    # --- test_exists ---

    test "test_exists verifies when test files match pattern" do
      FileUtils.mkdir_p(File.join(@repo_path, "test/models"))
      File.write(File.join(@repo_path, "test/models/user_test.rb"), <<~RUBY)
        class UserTest < ActiveSupport::TestCase
          test "validates name" do
            assert user.valid?
          end
        end
      RUBY

      criteria = [criterion("test_exists", pattern: "test/**/*user*")]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:verified].size
    end

    test "test_exists fails when no test files match" do
      criteria = [criterion("test_exists", pattern: "test/**/*user*")]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:failed].size
    end

    test "test_exists checks min_assertions count" do
      FileUtils.mkdir_p(File.join(@repo_path, "test"))
      File.write(File.join(@repo_path, "test/user_test.rb"), <<~RUBY)
        class UserTest < ActiveSupport::TestCase
          test "one" do
            assert true
          end
        end
      RUBY

      # 1 assertion matches the file; min_assertions = 5 should fail
      criteria = [criterion("test_exists", pattern: "test/*user*", min_assertions: 5)]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:failed].size
    end

    test "test_exists passes min_assertions when enough assertions exist" do
      FileUtils.mkdir_p(File.join(@repo_path, "test"))
      File.write(File.join(@repo_path, "test/user_test.rb"), <<~RUBY)
        class UserTest < ActiveSupport::TestCase
          test "one" do
            assert true
            assert_equal "a", "a"
            assert_not_nil obj
          end

          test "two" do
            assert valid?
            expect(result).to be_ok
          end
        end
      RUBY

      criteria = [criterion("test_exists", pattern: "test/*user*", min_assertions: 3)]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:verified].size
    end

    # --- model_has ---

    test "model_has verifies columns from schema.rb" do
      FileUtils.mkdir_p(File.join(@repo_path, "db"))
      File.write(File.join(@repo_path, "db/schema.rb"), <<~RUBY)
        ActiveRecord::Schema.define(version: 2025_01_01) do
          create_table "users" do |t|
            t.string "email"
            t.string "name"
            t.timestamps
          end
        end
      RUBY

      criteria = [criterion("model_has", model: "User", columns: %w[email name])]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:verified].size
    end

    test "model_has fails when column missing from schema" do
      FileUtils.mkdir_p(File.join(@repo_path, "db"))
      File.write(File.join(@repo_path, "db/schema.rb"), <<~RUBY)
        ActiveRecord::Schema.define(version: 2025_01_01) do
          create_table "users" do |t|
            t.string "email"
            t.timestamps
          end
        end
      RUBY

      criteria = [criterion("model_has", model: "User", columns: %w[email phone])]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:failed].size
    end

    test "model_has verifies associations from model file" do
      FileUtils.mkdir_p(File.join(@repo_path, "app/models"))
      File.write(File.join(@repo_path, "app/models/user.rb"), <<~RUBY)
        class User < ApplicationRecord
          has_many :posts
          belongs_to :organization
        end
      RUBY

      FileUtils.mkdir_p(File.join(@repo_path, "db"))
      File.write(File.join(@repo_path, "db/schema.rb"), <<~RUBY)
        ActiveRecord::Schema.define(version: 2025_01_01) do
          create_table "users" do |t|
            t.timestamps
          end
        end
      RUBY

      criteria = [criterion("model_has", model: "User", columns: [], associations: %w[has_many belongs_to])]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:verified].size
    end

    test "model_has fails when association missing" do
      FileUtils.mkdir_p(File.join(@repo_path, "app/models"))
      File.write(File.join(@repo_path, "app/models/user.rb"), <<~RUBY)
        class User < ApplicationRecord
          has_many :posts
        end
      RUBY

      FileUtils.mkdir_p(File.join(@repo_path, "db"))
      File.write(File.join(@repo_path, "db/schema.rb"), <<~RUBY)
        ActiveRecord::Schema.define(version: 2025_01_01) do
          create_table "users" do |t|
            t.timestamps
          end
        end
      RUBY

      criteria = [criterion("model_has", model: "User", columns: [], associations: %w[has_one])]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:failed].size
    end

    test "model_has fails without model param" do
      criteria = [AcceptanceCriterion.new(type: "model_has", description: "test", params: {})]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:failed].size
    end

    test "model_has passes when no columns or associations specified" do
      FileUtils.mkdir_p(File.join(@repo_path, "db"))
      File.write(File.join(@repo_path, "db/schema.rb"), "")

      criteria = [criterion("model_has", model: "User")]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:verified].size
    end

    # --- route_exists ---

    test "route_exists verifies route in routes file" do
      FileUtils.mkdir_p(File.join(@repo_path, "config"))
      File.write(File.join(@repo_path, "config/routes.rb"), <<~RUBY)
        Rails.application.routes.draw do
          post "/api/sessions", to: "sessions#create"
          resources :users
        end
      RUBY

      criteria = [criterion("route_exists", method: "POST", path: "/api/sessions")]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:verified].size
    end

    test "route_exists verifies resources declaration" do
      FileUtils.mkdir_p(File.join(@repo_path, "config"))
      File.write(File.join(@repo_path, "config/routes.rb"), <<~RUBY)
        Rails.application.routes.draw do
          resources :users
        end
      RUBY

      criteria = [criterion("route_exists", method: "GET", path: "/users")]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:verified].size
    end

    test "route_exists fails when routes file missing" do
      criteria = [criterion("route_exists", method: "GET", path: "/users")]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:failed].size
    end

    test "route_exists fails without method or path" do
      FileUtils.mkdir_p(File.join(@repo_path, "config"))
      File.write(File.join(@repo_path, "config/routes.rb"), "Rails.application.routes.draw do; end")

      criteria = [AcceptanceCriterion.new(type: "route_exists", description: "test", params: { "method" => "GET" })]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:failed].size
    end

    # --- runtime types go to unverified ---

    test "http criteria go to unverified" do
      criteria = [criterion("http", method: "GET", path: "/", expected_status: 200)]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:unverified].size
      assert_empty result[:verified]
      assert_empty result[:failed]
    end

    test "command_exits criteria go to unverified" do
      criteria = [criterion("command_exits", command: "bin/setup", expected_exit_code: 0)]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:unverified].size
    end

    # --- mixed criteria ---

    test "mixed criteria are sorted into correct buckets" do
      FileUtils.touch(File.join(@repo_path, "Gemfile"))

      criteria = [
        criterion("file_exists", pattern: "Gemfile"),
        criterion("file_exists", pattern: "nonexistent.txt"),
        criterion("http", method: "GET", path: "/", expected_status: 200)
      ]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:verified].size
      assert_equal 1, result[:failed].size
      assert_equal 1, result[:unverified].size
    end

    test "empty criteria returns empty result" do
      result = CriteriaChecker.call(criteria: [], repo_path: @repo_path)

      assert_empty result[:verified]
      assert_empty result[:failed]
      assert_empty result[:unverified]
    end

    test "unknown type goes to unverified" do
      criteria = [AcceptanceCriterion.new(type: "custom_check", description: "test", params: {})]
      result = CriteriaChecker.call(criteria: criteria, repo_path: @repo_path)

      assert_equal 1, result[:unverified].size
    end

    private

    def criterion(type, **params)
      AcceptanceCriterion.from_hash(params.merge("type" => type, "description" => "test #{type}"))
    end
  end
end
