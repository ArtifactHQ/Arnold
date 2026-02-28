require "test_helper"

module ArnoldPipeline
  class DriftFindingTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::DriftFinding*"

    setup do
      @run = PipelineRun.create!(nl_input: "Build a todo app")
      @spec = @run.create_specification!(content: "# Spec", version: 1)
      @revision = @spec.spec_revisions.create!(version: 1, content: "# Spec", change_source: "spec_generation")
    end

    test "valid finding with all required fields" do
      finding = DriftFinding.new(
        pipeline_run: @run,
        spec_revision: @revision,
        domain: "backend",
        drift_type: "structural",
        severity: "warning",
        description: "Task has no diff",
        spec_expectation: "Should produce code",
        actual_state: "No diff recorded",
        recommendation: "review_needed"
      )
      assert finding.valid?, "Expected finding to be valid: #{finding.errors.full_messages}"
    end

    test "valid finding without optional fields" do
      finding = DriftFinding.new(
        pipeline_run: @run,
        drift_type: "behavioral",
        severity: "info",
        description: "Minor behavioral drift"
      )
      assert finding.valid?, "Expected finding to be valid: #{finding.errors.full_messages}"
    end

    test "requires drift_type" do
      finding = DriftFinding.new(pipeline_run: @run, severity: "warning", description: "desc")
      assert_not finding.valid?
      assert_includes finding.errors[:drift_type], "can't be blank"
    end

    test "drift_type must be structural, behavioral, or intent" do
      %w[structural behavioral intent].each do |type|
        finding = DriftFinding.new(pipeline_run: @run, drift_type: type, severity: "info", description: "d")
        assert finding.valid?, "Expected #{type} to be valid"
      end

      finding = DriftFinding.new(pipeline_run: @run, drift_type: "invalid", severity: "info", description: "d")
      assert_not finding.valid?
      assert_includes finding.errors[:drift_type], "is not included in the list"
    end

    test "requires severity" do
      finding = DriftFinding.new(pipeline_run: @run, drift_type: "structural", description: "desc")
      assert_not finding.valid?
      assert_includes finding.errors[:severity], "can't be blank"
    end

    test "severity must be critical, warning, or info" do
      %w[critical warning info].each do |sev|
        finding = DriftFinding.new(pipeline_run: @run, drift_type: "structural", severity: sev, description: "d")
        assert finding.valid?, "Expected #{sev} to be valid"
      end

      finding = DriftFinding.new(pipeline_run: @run, drift_type: "structural", severity: "high", description: "d")
      assert_not finding.valid?
      assert_includes finding.errors[:severity], "is not included in the list"
    end

    test "requires description" do
      finding = DriftFinding.new(pipeline_run: @run, drift_type: "structural", severity: "info")
      assert_not finding.valid?
      assert_includes finding.errors[:description], "can't be blank"
    end

    test "recommendation must be valid when present" do
      %w[update_spec update_code review_needed].each do |rec|
        finding = DriftFinding.new(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d", recommendation: rec)
        assert finding.valid?, "Expected recommendation #{rec} to be valid"
      end

      finding = DriftFinding.new(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d", recommendation: "invalid")
      assert_not finding.valid?
    end

    test "recommendation can be nil" do
      finding = DriftFinding.new(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d", recommendation: nil)
      assert finding.valid?
    end

    test "resolution must be valid when present" do
      %w[update_spec update_code accepted ignored].each do |res|
        finding = DriftFinding.new(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d", resolution: res)
        assert finding.valid?, "Expected resolution #{res} to be valid"
      end

      finding = DriftFinding.new(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d", resolution: "invalid")
      assert_not finding.valid?
    end

    test "resolution can be nil" do
      finding = DriftFinding.new(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d", resolution: nil)
      assert finding.valid?
    end

    test "resolved? returns false when resolution is nil" do
      finding = DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d")
      assert_not finding.resolved?
    end

    test "resolved? returns true when resolution is present" do
      finding = DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d", resolution: "accepted", resolved_at: Time.current)
      assert finding.resolved?
    end

    test "resolve! transitions from nil to accepted" do
      finding = DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d")

      finding.resolve!("accepted", notes: "This is fine")

      assert_equal "accepted", finding.resolution
      assert_not_nil finding.resolved_at
      assert_equal "This is fine", finding.notes
    end

    test "resolve! transitions from nil to ignored" do
      finding = DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d")

      finding.resolve!("ignored")

      assert_equal "ignored", finding.resolution
      assert_not_nil finding.resolved_at
    end

    test "resolve! transitions from nil to update_spec" do
      finding = DriftFinding.create!(pipeline_run: @run, drift_type: "behavioral", severity: "warning", description: "d")
      finding.resolve!("update_spec")
      assert_equal "update_spec", finding.resolution
    end

    test "resolve! transitions from nil to update_code" do
      finding = DriftFinding.create!(pipeline_run: @run, drift_type: "behavioral", severity: "critical", description: "d")
      finding.resolve!("update_code")
      assert_equal "update_code", finding.resolution
    end

    test "resolve! raises on already-resolved finding" do
      finding = DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d", resolution: "accepted", resolved_at: Time.current)

      error = assert_raises(RuntimeError) { finding.resolve!("ignored") }
      assert_equal "Already resolved", error.message
    end

    test "resolve! raises on invalid resolution type" do
      finding = DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d")

      error = assert_raises(RuntimeError) { finding.resolve!("invalid") }
      assert_equal "Invalid resolution", error.message
    end

    # Scopes

    test "unresolved scope returns only findings without resolution" do
      DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "unresolved")
      DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "resolved", resolution: "accepted", resolved_at: Time.current)

      unresolved = DriftFinding.unresolved
      assert_equal 1, unresolved.count
      assert_equal "unresolved", unresolved.first.description
    end

    test "resolved scope returns only findings with resolution" do
      DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "unresolved")
      DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "resolved", resolution: "accepted", resolved_at: Time.current)

      resolved = DriftFinding.resolved
      assert_equal 1, resolved.count
      assert_equal "resolved", resolved.first.description
    end

    test "for_domain scope filters by domain" do
      DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d1", domain: "backend")
      DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d2", domain: "frontend")

      backend = DriftFinding.for_domain("backend")
      assert_equal 1, backend.count
      assert_equal "d1", backend.first.description
    end

    test "critical scope returns only critical findings" do
      DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "critical", description: "bad")
      DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "ok")

      critical = DriftFinding.critical
      assert_equal 1, critical.count
      assert_equal "bad", critical.first.description
    end

    test "accepted_for_revision scope returns accepted findings for a specific revision" do
      DriftFinding.create!(pipeline_run: @run, spec_revision: @revision, drift_type: "structural", severity: "info", description: "accepted", resolution: "accepted", resolved_at: Time.current)
      DriftFinding.create!(pipeline_run: @run, spec_revision: @revision, drift_type: "structural", severity: "info", description: "ignored", resolution: "ignored", resolved_at: Time.current)
      DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "unresolved")

      accepted = DriftFinding.accepted_for_revision(@revision.id)
      assert_equal 1, accepted.count
      assert_equal "accepted", accepted.first.description
    end

    test "belongs_to pipeline_run" do
      finding = DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d")
      assert_equal @run, finding.pipeline_run
    end

    test "belongs_to spec_revision optionally" do
      finding_with = DriftFinding.create!(pipeline_run: @run, spec_revision: @revision, drift_type: "structural", severity: "info", description: "d")
      assert_equal @revision, finding_with.spec_revision

      finding_without = DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d2")
      assert_nil finding_without.spec_revision
    end

    test "stores files_examined as JSON array" do
      finding = DriftFinding.create!(
        pipeline_run: @run, drift_type: "structural", severity: "info", description: "d",
        files_examined: [ "app/models/user.rb", "app/controllers/users_controller.rb" ]
      )
      assert_equal [ "app/models/user.rb", "app/controllers/users_controller.rb" ], finding.reload.files_examined
    end

    test "stores affected_tasks as JSON array" do
      finding = DriftFinding.create!(
        pipeline_run: @run, drift_type: "structural", severity: "info", description: "d",
        affected_tasks: [ "1", "2", "3" ]
      )
      assert_equal [ "1", "2", "3" ], finding.reload.affected_tasks
    end

    test "pipeline_run has_many drift_findings with dependent destroy" do
      DriftFinding.create!(pipeline_run: @run, drift_type: "structural", severity: "info", description: "d1")
      DriftFinding.create!(pipeline_run: @run, drift_type: "behavioral", severity: "warning", description: "d2")

      assert_equal 2, @run.drift_findings.count

      @run.destroy!
      assert_equal 0, DriftFinding.where(pipeline_run_id: @run.id).count
    end
  end
end
