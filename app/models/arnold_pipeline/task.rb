module ArnoldPipeline
  class Task < ApplicationRecord
    WIP_PATTERNS = [
      /is working/i,
      /get back to you/i,
      /working on/i,
      /\bin progress\b/i,
      /starting work/i,
      /I'll analyze/i,
      /picking up/i,
      /looking into/i
    ].freeze

    COMPLETION_PATTERNS = [
      /finished/i,
      /completed/i,
      /created? pr/i,
      /\bcan'?t\b/i,
      /unable to/i,
      /\bfailed\b/i,
      /\berror\b/i,
      /Create PR/i
    ].freeze

    enum :status, {
      pending: 0,
      in_progress: 1,
      completed: 2,
      failed: 3
    }

    belongs_to :pipeline_run

    validates :title, presence: true
    validates :position, presence: true, numericality: { greater_than_or_equal_to: 0 }

    scope :in_tier, ->(tier) { where(tier: tier) }

    default_scope { order(:position) }

    def has_substantive_comments?
      return false if result_comments.blank?

      result_comments.any? { |comment| !wip_comment?(comment) }
    end

    private

    def wip_comment?(comment)
      body = comment["body"].to_s
      matches_wip = WIP_PATTERNS.any? { |pattern| body.match?(pattern) }
      matches_completion = COMPLETION_PATTERNS.any? { |pattern| body.match?(pattern) }

      matches_wip && !matches_completion
    end
  end
end
