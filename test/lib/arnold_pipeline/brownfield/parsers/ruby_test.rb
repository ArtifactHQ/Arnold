require "test_helper"
require "arnold_pipeline/brownfield/parsers/ruby"

module ArnoldPipeline
  module Brownfield
    module Parsers
      class RubyTest < ActiveSupport::TestCase
        test "extracts class with superclass" do
          result = Ruby.call(content: "class User < ApplicationRecord\nend")
          assert_equal [ { name: "User", superclass: "ApplicationRecord", line: 1 } ], result[:classes]
        end

        test "extracts class without superclass" do
          result = Ruby.call(content: "class UserService\nend")
          assert_equal [ { name: "UserService", superclass: nil, line: 1 } ], result[:classes]
        end

        test "extracts namespaced class" do
          result = Ruby.call(content: "class Admin::UsersController < ApplicationController\nend")
          assert_equal [ { name: "Admin::UsersController", superclass: "ApplicationController", line: 1 } ], result[:classes]
        end

        test "extracts multiple classes" do
          code = <<~RUBY
            class Foo
            end

            class Bar < Baz
            end
          RUBY
          result = Ruby.call(content: code)
          assert_equal 2, result[:classes].length
          assert_equal "Foo", result[:classes][0][:name]
          assert_equal "Bar", result[:classes][1][:name]
          assert_equal "Baz", result[:classes][1][:superclass]
        end

        test "extracts modules" do
          code = <<~RUBY
            module Authenticatable
              module ClassMethods
              end
            end
          RUBY
          result = Ruby.call(content: code)
          assert_equal 2, result[:modules].length
          assert_equal "Authenticatable", result[:modules][0][:name]
          assert_equal 1, result[:modules][0][:line]
          assert_equal "ClassMethods", result[:modules][1][:name]
          assert_equal 2, result[:modules][1][:line]
        end

        test "extracts namespaced modules" do
          result = Ruby.call(content: "module ArnoldPipeline::Brownfield\nend")
          assert_equal [ { name: "ArnoldPipeline::Brownfield", line: 1 } ], result[:modules]
        end

        test "extracts instance methods" do
          code = <<~RUBY
            class Foo
              def bar
              end

              def baz?
              end

              def save!
              end
            end
          RUBY
          result = Ruby.call(content: code)
          assert_equal 3, result[:methods].length
          assert_equal "bar", result[:methods][0][:name]
          assert_equal 2, result[:methods][0][:line]
          assert_equal "public", result[:methods][0][:visibility]
          assert_equal "baz?", result[:methods][1][:name]
          assert_equal "save!", result[:methods][2][:name]
        end

        test "extracts class methods" do
          code = <<~RUBY
            class Foo
              def self.call
              end
            end
          RUBY
          result = Ruby.call(content: code)
          assert_equal [ { name: "self.call", line: 2, visibility: "public" } ], result[:methods]
        end

        test "tracks visibility across sections" do
          code = <<~RUBY
            class Foo
              def public_method
              end

              private

              def private_method
              end

              protected

              def protected_method
              end
            end
          RUBY
          result = Ruby.call(content: code)
          assert_equal 3, result[:methods].length
          assert_equal "public", result[:methods][0][:visibility]
          assert_equal "private", result[:methods][1][:visibility]
          assert_equal "protected", result[:methods][2][:visibility]
        end

        test "extracts has_many association" do
          result = Ruby.call(content: "  has_many :posts")
          assert_equal 1, result[:associations].length
          assert_equal "has_many", result[:associations][0][:type]
          assert_equal "posts", result[:associations][0][:name]
        end

        test "extracts belongs_to association" do
          result = Ruby.call(content: "  belongs_to :user")
          assert_equal [ { type: "belongs_to", name: "user", options: {} } ], result[:associations]
        end

        test "extracts has_one association" do
          result = Ruby.call(content: "  has_one :profile")
          assert_equal [ { type: "has_one", name: "profile", options: {} } ], result[:associations]
        end

        test "extracts has_and_belongs_to_many association" do
          result = Ruby.call(content: "  has_and_belongs_to_many :tags")
          assert_equal [ { type: "has_and_belongs_to_many", name: "tags", options: {} } ], result[:associations]
        end

        test "extracts association with options" do
          result = Ruby.call(content: '  has_many :comments, dependent: :destroy, class_name: "Comment"')
          assoc = result[:associations][0]
          assert_equal "has_many", assoc[:type]
          assert_equal "comments", assoc[:name]
          assert_equal "destroy", assoc[:options]["dependent"]
        end

        test "extracts multiple associations" do
          code = <<~RUBY
            class User < ApplicationRecord
              has_many :posts
              has_many :comments
              belongs_to :organization
              has_one :profile
            end
          RUBY
          result = Ruby.call(content: code)
          assert_equal 4, result[:associations].length
        end

        test "extracts validates" do
          result = Ruby.call(content: "  validates :email, presence: true")
          assert_equal 1, result[:validations].length
          assert_equal "validates", result[:validations][0][:type]
          assert_equal "email", result[:validations][0][:field]
          assert_equal "presence: true", result[:validations][0][:options]
        end

        test "extracts validate (custom)" do
          result = Ruby.call(content: "  validate :check_email_format")
          assert_equal 1, result[:validations].length
          assert_equal "validate", result[:validations][0][:type]
          assert_equal "check_email_format", result[:validations][0][:field]
        end

        test "extracts before_save callback" do
          result = Ruby.call(content: "  before_save :normalize_email")
          assert_equal [ { type: "before_save", method: "normalize_email" } ], result[:callbacks]
        end

        test "extracts after_create callback" do
          result = Ruby.call(content: "  after_create :send_welcome_email")
          assert_equal [ { type: "after_create", method: "send_welcome_email" } ], result[:callbacks]
        end

        test "extracts before_action callback" do
          result = Ruby.call(content: "  before_action :authenticate_user!")
          assert_equal [ { type: "before_action", method: "authenticate_user!" } ], result[:callbacks]
        end

        test "extracts multiple callbacks" do
          code = <<~RUBY
            class User < ApplicationRecord
              before_save :normalize_email
              after_create :send_welcome_email
              around_save :log_changes
              before_validation :set_defaults
            end
          RUBY
          result = Ruby.call(content: code)
          assert_equal 4, result[:callbacks].length
        end

        test "extracts scopes" do
          code = <<~RUBY
            class User < ApplicationRecord
              scope :active, -> { where(active: true) }
              scope :recent, -> { order(created_at: :desc) }
            end
          RUBY
          result = Ruby.call(content: code)
          assert_equal 2, result[:scopes].length
          assert_equal "active", result[:scopes][0][:name]
          assert_equal "recent", result[:scopes][1][:name]
        end

        test "extracts includes and extends" do
          code = <<~RUBY
            class User < ApplicationRecord
              include Authenticatable
              include Searchable
              extend ClassMethods
            end
          RUBY
          result = Ruby.call(content: code)
          assert_equal [ "Authenticatable", "Searchable", "ClassMethods" ], result[:includes]
        end

        test "extracts constants" do
          code = <<~RUBY
            class Config
              MAX_RETRIES = 3
              DEFAULT_TIMEOUT = 30
              API_VERSION = "v2"
            end
          RUBY
          result = Ruby.call(content: code)
          assert_equal 3, result[:constants].length
          assert_equal "MAX_RETRIES", result[:constants][0][:name]
          assert_equal 2, result[:constants][0][:line]
          assert_equal "DEFAULT_TIMEOUT", result[:constants][1][:name]
          assert_equal "API_VERSION", result[:constants][2][:name]
        end

        test "returns all keys even for empty content" do
          result = Ruby.call(content: "")
          expected_keys = %i[classes modules methods associations validations callbacks scopes includes constants]
          assert_equal expected_keys.sort, result.keys.sort
          expected_keys.each do |key|
            assert_kind_of Array, result[key], "Expected #{key} to be an Array"
          end
        end

        test "realistic Rails model parsing" do
          code = <<~RUBY
            module Authentication
            end

            class User < ApplicationRecord
              include Authentication
              include Searchable

              MAX_LOGIN_ATTEMPTS = 5
              DEFAULT_ROLE = "member"

              has_many :posts, dependent: :destroy
              has_many :comments
              belongs_to :organization
              has_one :profile

              validates :email, presence: true
              validates :name, length: { minimum: 2 }
              validate :check_age

              before_save :normalize_email
              after_create :send_welcome_email

              scope :active, -> { where(active: true) }
              scope :admins, -> { where(role: "admin") }

              def full_name
                "\#{first_name} \#{last_name}"
              end

              def self.search(query)
                where("name LIKE ?", "%\#{query}%")
              end

              private

              def normalize_email
                self.email = email.downcase
              end
            end
          RUBY

          result = Ruby.call(content: code)

          assert_equal 1, result[:modules].length
          assert_equal "Authentication", result[:modules][0][:name]

          assert_equal 1, result[:classes].length
          assert_equal "User", result[:classes][0][:name]
          assert_equal "ApplicationRecord", result[:classes][0][:superclass]

          assert_equal 2, result[:includes].length
          assert_equal 4, result[:associations].length
          assert_equal 3, result[:validations].length
          assert_equal 2, result[:callbacks].length
          assert_equal 2, result[:scopes].length
          assert_equal 2, result[:constants].length
          assert_equal 3, result[:methods].length

          # Check visibility
          assert_equal "public", result[:methods][0][:visibility] # full_name
          assert_equal "public", result[:methods][1][:visibility] # self.search
          assert_equal "private", result[:methods][2][:visibility] # normalize_email
        end
      end
    end
  end
end
