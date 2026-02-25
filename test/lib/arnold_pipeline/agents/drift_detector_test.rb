require "test_helper"
require "arnold_pipeline/agents/drift_detector"

module ArnoldPipeline
  module Agents
    class DriftDetectorTest < ActiveSupport::TestCase
      cover "ArnoldPipeline::Agents::DriftDetector*"

      setup do
        @llm = stub("llm")
        @agent = DriftDetector.new(llm: @llm, logger: Logger.new(File::NULL))
        @run = PipelineRun.create!(nl_input: "Build a todo app")

        @spec_content = <<~SPEC
          # Todo App Spec
          ## Authentication
          Users can sign up, log in, and log out.
          ## Todo Management
          Users can create, edit, and delete todos.
          ## Dashboard
          Users see a summary of their todos.
        SPEC

        @task_with_diff = Task.create!(
          pipeline_run: @run,
          title: "Setup authentication",
          description: "Implement user auth",
          position: 0,
          status: :completed,
          labels: ["authentication"],
          result_diff: "+class User < ApplicationRecord\n+  has_secure_password\n+end"
        )

        @task_without_diff = Task.create!(
          pipeline_run: @run,
          title: "Build todo CRUD",
          description: "Create todo management",
          position: 1,
          status: :completed,
          labels: ["todo"],
          result_diff: nil
        )

        @task_pending = Task.create!(
          pipeline_run: @run,
          title: "Build dashboard",
          description: "Create dashboard view",
          position: 2,
          status: :pending,
          labels: ["dashboard"]
        )
      end

      # --- Structural detection ---

      test "structural detection finds completed tasks with empty diffs" do
        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "structural"
        )

        empty_diff_findings = findings.select { |f|
          f["drift_type"] == "structural" && f["description"].include?("no code changes")
        }
        assert_equal 1, empty_diff_findings.size
        assert_includes empty_diff_findings.first["description"], "Build todo CRUD"
        assert_equal "warning", empty_diff_findings.first["severity"]
        assert_includes empty_diff_findings.first["affected_tasks"], @task_without_diff.id.to_s
      end

      test "structural detection returns clean when all completed tasks have diffs" do
        @task_without_diff.update!(result_diff: "+class Todo\n+end")

        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "structural"
        )

        empty_diff_findings = findings.select { |f|
          f["drift_type"] == "structural" && f["description"].include?("no code changes")
        }
        assert_empty empty_diff_findings
      end

      test "structural detection also returns empty list for empty_diff string '[]'" do
        @task_without_diff.update!(result_diff: "[]")

        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "structural"
        )

        empty_diff_findings = findings.select { |f|
          f["drift_type"] == "structural" && f["description"].include?("no code changes")
        }
        assert_equal 1, empty_diff_findings.size
      end

      # --- Behavioral detection ---

      test "behavioral detection stubs LLM and returns findings" do
        behavioral_result = {
          "findings" => [
            {
              "domain" => "authentication",
              "drift_type" => "behavioral",
              "severity" => "warning",
              "description" => "Auth implementation missing password reset",
              "spec_expectation" => "Users can reset their passwords",
              "actual_state" => "No password reset endpoint",
              "files_examined" => ["app/models/user.rb"],
              "affected_tasks" => [],
              "recommendation" => "update_code"
            }
          ]
        }
        @llm.expects(:chat_json).returns(behavioral_result)

        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "behavioral"
        )

        behavioral = findings.select { |f| f["drift_type"] == "behavioral" }
        assert_equal 1, behavioral.size
        assert_equal "Auth implementation missing password reset", behavioral.first["description"]
      end

      test "behavioral detection returns empty when LLM finds no issues" do
        @llm.expects(:chat_json).returns({ "findings" => [] })

        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "behavioral"
        )

        behavioral = findings.select { |f| f["drift_type"] == "behavioral" }
        assert_empty behavioral
      end

      test "behavioral detection skips when no completed tasks with diffs" do
        @task_with_diff.update!(result_diff: nil)
        @task_without_diff.update!(result_diff: nil)

        # LLM should NOT be called
        @llm.expects(:chat_json).never

        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "behavioral"
        )

        behavioral = findings.select { |f| f["drift_type"] == "behavioral" }
        assert_empty behavioral
      end

      # --- Intent detection ---

      test "intent detection stubs LLM and returns findings" do
        behavioral_result = { "findings" => [] }
        intent_result = {
          "findings" => [
            {
              "domain" => "unknown",
              "drift_type" => "intent",
              "severity" => "info",
              "description" => "Task output includes admin panel not in spec",
              "spec_expectation" => "No admin panel specified",
              "actual_state" => "Admin controller and views present",
              "files_examined" => [],
              "affected_tasks" => [],
              "recommendation" => "update_spec"
            }
          ]
        }

        # Behavioral is called first, then intent
        @llm.stubs(:chat_json).returns(behavioral_result).then.returns(intent_result)

        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "full"
        )

        intent = findings.select { |f| f["drift_type"] == "intent" }
        assert_equal 1, intent.size
        assert_equal "Task output includes admin panel not in spec", intent.first["description"]
      end

      test "intent detection not called when depth is structural" do
        @llm.expects(:chat_json).never

        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "structural"
        )

        intent = findings.select { |f| f["drift_type"] == "intent" }
        assert_empty intent
      end

      test "intent detection not called when depth is behavioral" do
        @llm.expects(:chat_json).once.returns({ "findings" => [] })

        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "behavioral"
        )

        intent = findings.select { |f| f["drift_type"] == "intent" }
        assert_empty intent
      end

      # --- Scope filtering ---

      test "scope full checks all tasks" do
        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          scope: "full",
          depth: "structural"
        )

        # Should find the task without diff
        assert findings.any? { |f| f["description"].include?("Build todo CRUD") }
      end

      test "scope domain filters tasks by matching label" do
        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          scope: "domain",
          target: "authentication",
          depth: "structural"
        )

        # Should NOT find the todo task (wrong domain)
        assert findings.none? { |f| f["description"].include?("Build todo CRUD") }
      end

      test "scope task filters to single task by ID" do
        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          scope: "task",
          target: @task_with_diff.id.to_s,
          depth: "structural"
        )

        # Should not find the task_without_diff findings since we scoped to task_with_diff
        assert findings.none? { |f| f["description"].include?("Build todo CRUD") }
      end

      # --- Depth filtering ---

      test "depth structural only runs structural detection" do
        @llm.expects(:chat_json).never

        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "structural"
        )

        types = findings.map { |f| f["drift_type"] }.uniq
        assert types.all? { |t| t == "structural" }
      end

      test "depth behavioral runs only behavioral detection" do
        @llm.expects(:chat_json).once.returns({ "findings" => [] })

        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "behavioral"
        )

        # Only behavioral findings, no structural
        structural = findings.select { |f| f["drift_type"] == "structural" }
        assert_empty structural
      end

      test "depth full runs all three detection types" do
        @llm.stubs(:chat_json).returns({ "findings" => [] })

        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "full"
        )

        # At minimum structural findings should be present
        structural = findings.select { |f| f["drift_type"] == "structural" }
        assert structural.any?
      end

      # --- Finding structure ---

      test "structural findings have required keys" do
        findings = @agent.call(
          spec_content: @spec_content,
          tasks: @run.tasks.ordered,
          depth: "structural"
        )

        empty_diff_finding = findings.find { |f| f["description"].include?("no code changes") }
        assert_not_nil empty_diff_finding

        required_keys = %w[domain drift_type severity description spec_expectation actual_state files_examined affected_tasks recommendation]
        required_keys.each do |key|
          assert empty_diff_finding.key?(key), "Finding missing key: #{key}"
        end
      end
    end
  end
end
