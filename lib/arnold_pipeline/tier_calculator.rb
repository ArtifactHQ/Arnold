module ArnoldPipeline
  class TierCalculator
    class CycleError < ArnoldPipeline::Error; end

    def self.call(tasks)
      new(tasks).call
    end

    def initialize(tasks)
      @tasks = tasks
      @position_to_task = {}
      @tiers = {}
      @visiting = Set.new

      @tasks.each do |task|
        pos = task.respond_to?(:position) ? task.position : task["position"]
        @position_to_task[pos] = task
      end
    end

    def call
      @position_to_task.each_key { |pos| compute_tier(pos) }

      @tasks.each do |task|
        pos = task.respond_to?(:position) ? task.position : task["position"]
        tier = @tiers[pos]
        task.update!(tier: tier) if task.respond_to?(:update!)
      end

      @tiers
    end

    private

    def compute_tier(position)
      return @tiers[position] if @tiers.key?(position)

      if @visiting.include?(position)
        raise CycleError, "Dependency cycle detected involving position #{position}"
      end

      @visiting.add(position)

      task = @position_to_task[position]
      deps = if task.respond_to?(:depends_on)
        task.depends_on || []
      else
        task["depends_on"] || []
      end

      tier = if deps.empty?
        0
      else
        deps.map { |dep_pos| compute_tier(dep_pos) }.max + 1
      end

      @visiting.delete(position)
      @tiers[position] = tier
    end
  end
end
