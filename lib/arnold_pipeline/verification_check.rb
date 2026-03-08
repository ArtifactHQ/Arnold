module ArnoldPipeline
  class VerificationCheck
    TYPES = %i[boot test_suite custom solid_stack].freeze

    CHECK_TYPE_DEFAULTS = {
      solid_stack: { default_tier: 0, tier_gate: true, finalization: true },
      boot:        { default_tier: 0, tier_gate: true, finalization: true },
      test_suite:  { default_tier: nil, tier_gate: true, finalization: false },
      custom:      { default_tier: nil, tier_gate: true, finalization: true }
    }.freeze

    attr_reader :name, :command, :type, :required

    def initialize(name:, command: nil, type: :custom, required: false)
      @name = name
      @command = command
      @type = type.to_sym
      @required = required
    end

    def required?
      @required
    end

    def scheduled_for_tier?(tier_number)
      default_tier = CHECK_TYPE_DEFAULTS.dig(@type, :default_tier)
      default_tier.nil? || default_tier == tier_number
    end

    def eligible_for_finalization?
      CHECK_TYPE_DEFAULTS.dig(@type, :finalization) != false
    end
  end
end
