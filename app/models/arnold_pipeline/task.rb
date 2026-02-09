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

    RESOLUTION_PATTERNS = [
      # Completion signals
      /finished/i,
      /completed/i,
      /created? pr/i,
      /Create PR/i,
      # Failure/blocker signals
      /\bcan'?t\b/i,
      /unable to/i,
      /\bfailed\b/i,
      /\berror\b/i
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

    scope :ordered, -> { order(:position) }

    def has_substantive_comments?
      return false if result_comments.blank?

      result_comments.any? { |comment| resolution_comment?(comment) }
    end

    def resolution_summary
      parts = []
      parts << "workflow_active" if workflow_active?
      parts << "has_diffs" if result_diff.present? && result_diff != "[]"
      parts << "failed" if failed?
      parts << "resolution_comments" if has_substantive_comments?
      if parts.empty?
        if result_comments.present?
          wip = result_comments.any? { |c| WIP_PATTERNS.any? { |p| c["body"].to_s.match?(p) } }
          parts << (wip ? "wip_comments_only" : "non_resolution_comments")
        else
          parts << "no_signals"
        end
      end
      "#{title} (##{external_id}): #{parts.join(', ')}"
    end

    private

    def resolution_comment?(comment)
      body = comment["body"].to_s
      RESOLUTION_PATTERNS.any? { |pattern| body.match?(pattern) }
    end
  end
end
