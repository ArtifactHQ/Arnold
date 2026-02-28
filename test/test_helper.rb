require "simplecov"
SimpleCov.start "rails" do
  add_filter "/test/"
  add_filter "/lib/generators/"
  minimum_coverage 80
  coverage_dir "coverage"
end

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"
require "mocha/minitest"
require "webmock/minitest"
WebMock.disable_net_connect!(allow_localhost: true)
if defined?(Mutant)
  require "mutant/minitest/coverage"
elsif !Minitest::Test.respond_to?(:cover)
  # No-op when not running under mutant — cover declarations are inert
  Minitest::Test.singleton_class.define_method(:cover) { |*| }
end

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end
