module ArnoldPipeline
  module Library
    Recipe = Data.define(:name, :type, :keywords, :description, :framework, :sections, :verification, :finalization) do
      def initialize(name:, type:, keywords:, description:, framework:, sections:, verification:, finalization: {})
        super
      end
    end
  end
end
