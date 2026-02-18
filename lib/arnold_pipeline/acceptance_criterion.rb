module ArnoldPipeline
  AcceptanceCriterion = Data.define(
    :type,
    :description,
    :params
  )

  class AcceptanceCriterion
    STATIC_TYPES = %w[file_exists test_exists model_has route_exists].freeze
    RUNTIME_TYPES = %w[http command_exits].freeze
    VALID_TYPES = (STATIC_TYPES + RUNTIME_TYPES).freeze

    def self.from_hash(hash)
      hash = hash.transform_keys(&:to_s)
      type = hash.fetch("type")
      description = hash["description"] || ""
      params = if hash.key?("params") && hash["params"].is_a?(Hash)
                 hash["params"].transform_keys(&:to_s)
               else
                 hash.except("type", "description", "params")
               end
      new(type: type, description: description, params: params)
    end

    def self.from_array(array)
      return [] if array.nil? || array.empty?
      array.map { |h| from_hash(h) }
    end

    def static?
      STATIC_TYPES.include?(type)
    end

    def runtime?
      RUNTIME_TYPES.include?(type)
    end

    def valid_type?
      VALID_TYPES.include?(type)
    end
  end
end
