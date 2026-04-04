module ArnoldPipeline
  class PipelineEvent < ApplicationRecord
    VALID_STAGES = %w[
      spec_generation task_breakdown execution tier_gate analysis iteration lifecycle brownfield
    ].freeze

    enum :event_type, {
      library_selection: 0,
      spec_generated: 1,
      tasks_broken: 2,
      tier_execution_started: 3,
      tier_execution_completed: 4,
      task_published: 5,
      task_result_fetched: 6,
      tier_gate_evaluated: 7,
      analysis_completed: 8,
      iteration_decision: 9,
      spec_delta_merged: 10,
      pipeline_paused: 11,
      pipeline_failed: 12,
      pipeline_completed: 13,
      repo_context_scanned: 14,
      criteria_check: 15,
      verification_execution: 16,
      test_execution: 17,
      spec_test_execution: 18,
      post_merge_hooks: 19,
      verification_checks: 20,
      pipeline_finalized: 21,
      finalization_verification: 22,
      finalization_setup: 23,
      stack_detection: 24,
      codebase_profiling: 25,
      feature_extraction: 26,
      as_built_spec_generated: 27,
      health_baseline: 28,
      test_name_collection: 29,
      concern_diff_analysis: 30,
      file_manifest_built: 31,
      route_table_parsed: 32,
      git_activity_analyzed: 33,
      parallel_agents_completed: 34,
      pipeline_resumed: 35,
      spec_imported: 36
    }

    belongs_to :pipeline_run

    validates :event_type, presence: true
    validates :stage, presence: true, inclusion: { in: VALID_STAGES }
    validates :summary, exclusion: { in: [ nil ], message: "can't be blank" }

    scope :for_stage, ->(stage) { where(stage: stage) }
    scope :chronological, -> { order(:created_at) }
    scope :with_payloads, -> { where.not(payload: nil) }
  end
end
