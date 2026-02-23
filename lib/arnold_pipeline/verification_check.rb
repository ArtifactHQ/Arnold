module ArnoldPipeline
  class VerificationCheck
    TYPES = %i[boot test_suite custom solid_stack].freeze

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
  end
end
