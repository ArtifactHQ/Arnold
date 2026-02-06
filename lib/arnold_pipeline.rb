require "arnold_pipeline/version"
require "arnold_pipeline/engine" if defined?(Rails)
require "arnold_pipeline/configuration"

module ArnoldPipeline
  class Error < StandardError; end
  class ConfigurationError < Error; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
