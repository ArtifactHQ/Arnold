module ArnoldPipeline
  class DriftFinding < ApplicationRecord
    DRIFT_TYPES = %w[structural behavioral intent].freeze
    SEVERITIES = %w[critical warning info].freeze
    RECOMMENDATIONS = %w[update_spec update_code review_needed].freeze
    RESOLUTIONS = %w[update_spec update_code accepted ignored].freeze

    belongs_to :pipeline_run
    belongs_to :spec_revision, optional: true

    validates :drift_type, presence: true, inclusion: { in: DRIFT_TYPES }
    validates :severity, presence: true, inclusion: { in: SEVERITIES }
    validates :description, presence: true
    validates :recommendation, inclusion: { in: RECOMMENDATIONS }, allow_nil: true
    validates :resolution, inclusion: { in: RESOLUTIONS }, allow_nil: true

    scope :unresolved, -> { where(resolution: nil) }
    scope :resolved, -> { where.not(resolution: nil) }
    scope :for_domain, ->(domain) { where(domain: domain) }
    scope :critical, -> { where(severity: "critical") }
    scope :accepted_for_revision, ->(rev_id) { where(spec_revision_id: rev_id, resolution: "accepted") }

    def resolved?
      resolution.present?
    end

    def resolve!(resolution_type, notes: nil)
      raise "Already resolved" if resolved?
      raise "Invalid resolution" unless RESOLUTIONS.include?(resolution_type)
      update!(resolution: resolution_type, resolved_at: Time.current, notes: notes)
    end
  end
end
