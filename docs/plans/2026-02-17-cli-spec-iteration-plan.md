# CLI-Driven Spec Iteration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `arnold iterate ID "change request"` CLI command for user-initiated spec refinement with delta merging, task invalidation, fork-from-completed, and dry-run support.

**Architecture:** New SpecIterationAgent generates structured deltas from user NL input + current spec. Deltas flow through existing 3-tier merge chain (OpenSpec → structured append → legacy). A DeltaMerger service is extracted from AnalysisLoop to share merge logic between analysis-driven and user-driven iteration. Task invalidation uses a new `superseded` status. Completed runs fork into new PipelineRuns.

**Tech Stack:** Ruby 4.0, Rails 8.1, Mocha for test stubs, Thor CLI framework, existing OpenspecBridge.

**Design doc:** `docs/plans/2026-02-17-cli-spec-iteration-design.md`

---

## Team Parallelization

Tasks 1-4 are independent and can be implemented in parallel.
Task 5 depends on Tasks 1-4. Tasks 6-8 depend on Task 5.
Task 9 depends on Task 6. Task 10 is independent.

```
[Task 1: Model changes]  ──┐
[Task 2: SpecIterator agent] ──┤
[Task 3: DeltaMerger extract] ──┼──▶ [Task 5: Orchestrator] ──▶ [Task 6: CLI iterate] ──▶ [Task 8: Fork] ──▶ [Task 10: Spec+README]
[Task 4: DeltaPresenter]  ──┘              │                                │
                                           ▼                                ▼
                                  [Task 7: ResumeInferrer]     [Task 9: Version skew guard]
```

---

### Task 1: Model Changes — `superseded` status + `user_iterate` change source

Add `superseded` status to Task enum and `user_iterate` to SpecRevision CHANGE_SOURCES.

**Files:**
- Modify: `app/models/arnold_pipeline/task.rb:27-32`
- Modify: `app/models/arnold_pipeline/spec_revision.rb:3`
- Modify: `lib/arnold_pipeline/cli.rb:495-504` (format_task)
- Test: `test/models/arnold_pipeline/task_test.rb`
- Test: `test/models/arnold_pipeline/spec_revision_test.rb`
- Test: `test/lib/arnold_pipeline/cli_test.rb`

**Step 1: Add `superseded` to Task enum**

In `app/models/arnold_pipeline/task.rb`, change the enum:

```ruby
enum :status, {
  pending: 0,
  in_progress: 1,
  completed: 2,
  failed: 3,
  superseded: 4
}
```

**Step 2: Update `format_task` in CLI to show `[superseded]` label**

In `lib/arnold_pipeline/cli.rb`, update `format_task`:

```ruby
def format_task(task)
  lines = []
  label = task.superseded? ? " [superseded]" : ""
  lines << "## [#{task.position}] #{task.title}#{label}"
  lines << "Tier: #{task.tier} | Priority: #{task.priority} | Status: #{task.status}"
  lines << "Labels: #{task.labels.join(', ')}" if task.labels.any?
  lines << "Depends on: #{task.depends_on.join(', ')}" if task.depends_on.any?
  lines << "Link: #{task.external_url}" if task.external_url
  lines << ""
  lines << task.description if task.description.present?
  lines.join("\n")
end
```

**Step 3: Add `user_iterate` to SpecRevision**

In `app/models/arnold_pipeline/spec_revision.rb`:

```ruby
CHANGE_SOURCES = %w[spec_generation iterate_spec user_iterate].freeze
```

**Step 4: Write tests**

Test that `superseded` status works on Task model. Test that SpecRevision accepts `user_iterate` change_source. Test that `format_task` shows `[superseded]` label in CLI output.

**Step 5: Run tests**

Run: `bundle exec rails test test/models/ test/lib/arnold_pipeline/cli_test.rb`

**Step 6: Commit**

```bash
git add app/models/arnold_pipeline/task.rb app/models/arnold_pipeline/spec_revision.rb lib/arnold_pipeline/cli.rb test/
git commit -m "feat: add superseded task status and user_iterate change source [SPEC-CLI-ITERATE-001]"
```

---

### Task 2: SpecIterationAgent + Prompt Template

Create dedicated agent for processing user change requests against existing specs.

**Files:**
- Create: `lib/arnold_pipeline/agents/spec_iterator.rb`
- Create: `lib/arnold_pipeline/prompts/spec_iteration.rb`
- Test: `test/lib/arnold_pipeline/agents/spec_iterator_test.rb`
- Test: `test/lib/arnold_pipeline/prompts/spec_iteration_test.rb`

**Step 1: Create the prompt template**

Create `lib/arnold_pipeline/prompts/spec_iteration.rb`:

```ruby
module ArnoldPipeline
  module Prompts
    module SpecIteration
      def self.system_prompt
        <<~PROMPT
          You are a Specification Iteration Specialist. Your role is to apply user-requested
          changes to an existing software specification, producing structured deltas that
          precisely describe what should be added, modified, or removed.

          # Core Principles

          1. SURGICAL PRECISION — Make the minimum changes needed to fulfill the user's request.
             Do not reorganize, rewrite, or "improve" parts of the spec the user didn't ask about.

          2. PRESERVE STRUCTURE — The existing spec uses OpenSpec format with `### Requirement:`
             headers and `#### Scenario:` blocks using GIVEN/WHEN/THEN. Your deltas MUST use
             the same format.

          3. RIPPLE AWARENESS — When a change affects other parts of the spec (e.g., removing
             a feature that other features depend on), include all necessary cascading deltas.

          4. RATIONALE ALWAYS — Every delta must explain WHY the change was made, connecting
             it back to the user's request.

          # Output Format

          Return a JSON object with this structure:
          {
            "summary": "Brief description of changes made",
            "deltas": [...]
          }

          Each delta in the array follows one of three formats:

          For ADDING a new requirement:
          {
            "operation": "added",
            "section": "Section Name",
            "requirement": "Requirement Name",
            "content": "### Requirement: Name [REQ-DOMAIN-NNN]\\nDescription...\\n\\n#### Scenario: Name\\n- GIVEN ...\\n- WHEN ...\\n- THEN ...",
            "rationale": "Why this was added"
          }

          For MODIFYING an existing requirement:
          {
            "operation": "modified",
            "section": "Section Name",
            "requirement": "Existing Requirement Name",
            "before_content": "The current text of the requirement",
            "after_content": "The updated text with changes applied",
            "rationale": "Why this was changed"
          }

          For REMOVING a requirement:
          {
            "operation": "removed",
            "section": "Section Name",
            "requirement": "Requirement Name to Remove",
            "rationale": "Why this was removed"
          }

          # Delta Rules
          - Each delta targets ONE requirement in ONE section
          - "content" (added) and "after_content" (modified) MUST use `### Requirement:` / `#### Scenario:` / GIVEN-WHEN-THEN format
          - Each requirement MUST have at least one `#### Scenario:` block
          - "requirement" is required for modified and removed operations
          - Prefer multiple surgical deltas over one large rewrite
          - Include requirement IDs ([REQ-DOMAIN-NNN]) in added requirements, continuing the sequence from existing IDs
        PROMPT
      end

      def self.user_prompt(spec_content:, change_request:)
        <<~PROMPT
          # Current Specification

          #{spec_content}

          # Change Request

          #{change_request}

          Apply the requested changes to the specification. Return structured deltas as JSON.
        PROMPT
      end
    end
  end
end
```

**Step 2: Create the agent**

Create `lib/arnold_pipeline/agents/spec_iterator.rb`:

```ruby
require_relative "base_agent"
require "arnold_pipeline/prompts/spec_iteration"

module ArnoldPipeline
  module Agents
    class SpecIterator < BaseAgent
      SCHEMA = {
        name: "spec_iteration_result",
        schema: {
          type: "object",
          properties: {
            summary: { type: "string" },
            deltas: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  operation: { type: "string", enum: %w[added modified removed] },
                  section: { type: "string" },
                  requirement: { type: "string" },
                  content: { type: "string" },
                  before_content: { type: "string" },
                  after_content: { type: "string" },
                  rationale: { type: "string" }
                },
                required: %w[operation section rationale]
              }
            }
          },
          required: %w[summary deltas]
        }
      }.freeze

      def call(spec_content:, change_request:)
        logger.info { "Iterating spec for change request: #{change_request.truncate(80)}" }

        system = Prompts::SpecIteration.system_prompt
        user = Prompts::SpecIteration.user_prompt(spec_content:, change_request:)

        result = chat_json(
          messages: [{ role: :user, content: user }],
          system:,
          schema: SCHEMA
        )

        validate_deltas!(result)
        result
      end

      private

      def validate_deltas!(result)
        deltas = result["deltas"] || []
        deltas.each_with_index do |delta, i|
          op = delta["operation"]
          unless %w[added modified removed].include?(op)
            raise ArgumentError, "Delta #{i}: invalid operation '#{op}'"
          end

          if op == "added" && delta["content"].blank?
            raise ArgumentError, "Delta #{i}: 'added' operation requires 'content'"
          end

          if op == "modified" && delta["after_content"].blank?
            raise ArgumentError, "Delta #{i}: 'modified' operation requires 'after_content'"
          end

          if %w[modified removed].include?(op) && delta["requirement"].blank?
            raise ArgumentError, "Delta #{i}: '#{op}' operation requires 'requirement'"
          end
        end
      end
    end
  end
end
```

**Step 3: Write agent tests**

Create `test/lib/arnold_pipeline/agents/spec_iterator_test.rb` — Test the agent call with stubbed LLM returning a valid delta structure. Test validation rejects invalid deltas (missing content for added, missing requirement for modified/removed).

**Step 4: Write prompt tests**

Create `test/lib/arnold_pipeline/prompts/spec_iteration_test.rb` — Test system_prompt returns non-empty string containing key instructions. Test user_prompt includes spec content and change request.

**Step 5: Run tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/agents/spec_iterator_test.rb test/lib/arnold_pipeline/prompts/spec_iteration_test.rb`

**Step 6: Commit**

```bash
git add lib/arnold_pipeline/agents/spec_iterator.rb lib/arnold_pipeline/prompts/spec_iteration.rb test/
git commit -m "feat: add SpecIterationAgent for user-initiated spec changes [SPEC-CLI-ITERATE-001]"
```

---

### Task 3: Extract DeltaMerger Service from AnalysisLoop

Extract the delta merge logic (merge_deltas!, append_deltas!, openspec_merge, persist_deltas!, snapshot_revision!) into a shared service that both AnalysisLoop and Orchestrator can use.

**Files:**
- Create: `lib/arnold_pipeline/delta_merger.rb`
- Modify: `lib/arnold_pipeline/analysis_loop.rb:211-287`
- Test: `test/lib/arnold_pipeline/delta_merger_test.rb`

**Step 1: Create DeltaMerger service**

Create `lib/arnold_pipeline/delta_merger.rb`:

```ruby
require "arnold_pipeline/openspec_bridge"

module ArnoldPipeline
  class DeltaMerger
    attr_reader :logger

    def initialize(logger: Logger.new($stdout, level: Logger::INFO))
      @logger = logger
    end

    # Apply deltas to a specification: merge content, persist delta records, snapshot revision.
    # iteration: optional Iteration record (nil for user-initiated iterations)
    def apply!(spec:, raw_deltas:, change_source:, pipeline_run: nil, iteration: nil)
      persist_deltas!(spec, iteration, raw_deltas) if iteration
      merge_deltas!(spec, raw_deltas, pipeline_run)
      snapshot_revision!(spec, raw_deltas, change_source)

      merge_strategy = ArnoldPipeline.configuration.openspec_enabled ? "openspec" : "append"
      { merge_strategy:, delta_count: raw_deltas.size, new_version: spec.reload.version }
    end

    def merge_deltas!(spec, deltas, pipeline_run)
      if ArnoldPipeline.configuration.openspec_enabled
        merged = openspec_merge(spec, deltas, pipeline_run)
        return if merged
      end
      append_deltas!(spec, deltas)
    end

    def append_deltas!(spec, deltas)
      additions = deltas.select { |d| d["operation"] == "added" }.map { |d| d["content"] || d["after_content"] }
      modifications = deltas.select { |d| d["operation"] == "modified" }.map { |d| d["after_content"] }
      removals = deltas.select { |d| d["operation"] == "removed" }.map { |d| "REMOVED: #{d['requirement']} — #{d['rationale']}" }

      clarifications = (additions + modifications + removals).compact.join("\n\n")
      updated_content = "#{spec.content}\n\n## Spec Iteration\n#{clarifications}"
      spec.update!(content: updated_content, version: spec.version + 1)
    end

    def persist_deltas!(spec, iteration, raw_deltas)
      raw_deltas.each do |d|
        spec.spec_deltas.create!(
          iteration:,
          operation: d["operation"],
          section: d["section"],
          requirement: d["requirement"],
          before_content: d["before_content"],
          after_content: d["after_content"] || d["content"],
          rationale: d["rationale"]
        )
      end
    end

    def snapshot_revision!(spec, raw_deltas, change_source)
      summary = raw_deltas.map do |d|
        op = d["operation"]&.upcase
        req = d["requirement"] || "new requirement"
        section = d["section"]
        "#{op}: #{section} > #{req}"
      end

      spec.spec_revisions.create!(
        version: spec.version,
        content: spec.content,
        structured_data: spec.structured_data,
        change_source:,
        delta_summary: summary
      )
    rescue => e
      logger.warn { "[Arnold] Failed to snapshot revision: #{e.message}" }
    end

    private

    def openspec_merge(spec, deltas, pipeline_run)
      iteration = pipeline_run&.iterations&.order(:number)&.last
      change_name = iteration ? "iteration-#{iteration.number}" : "user-iterate-#{Time.current.to_i}"

      OpenspecBridge.with_workspace(logger:) do |bridge|
        bridge.write_spec!(spec)
        merged_content = bridge.write_delta_and_merge!(
          change_name:, deltas:
        )

        if merged_content
          spec.update!(content: merged_content, version: spec.version + 1)
          true
        end
      end
    rescue => e
      logger.warn { "[Arnold] OpenSpec merge error: #{e.message}" }
      nil
    end
  end
end
```

**Step 2: Update AnalysisLoop to use DeltaMerger**

In `lib/arnold_pipeline/analysis_loop.rb`, replace the delta methods with delegation:

- Add `require "arnold_pipeline/delta_merger"` at top
- In `initialize`, add: `@delta_merger = DeltaMerger.new(logger:)`
- Replace `handle_iterate_spec!` body:

```ruby
def handle_iterate_spec!(pipeline_run, analysis)
  logger.info { "[Arnold] Iterating spec based on analysis feedback..." }

  spec = pipeline_run.specification
  raw_deltas = analysis.dig("corrective_data", "deltas")

  if raw_deltas.present?
    iteration = pipeline_run.iterations.order(:number).last
    result = @delta_merger.apply!(
      spec:, raw_deltas:, change_source: "iterate_spec",
      pipeline_run:, iteration:
    )
    event_recorder&.record(
      event_type: :spec_delta_merged, stage: "iteration",
      summary: result
    )
  else
    legacy_append!(spec, analysis)
    event_recorder&.record(
      event_type: :spec_delta_merged, stage: "iteration",
      summary: { merge_strategy: "legacy", delta_count: 0, new_version: spec.reload.version }
    )
  end
end
```

- Remove the now-extracted methods: `merge_deltas!`, `openspec_merge`, `append_deltas!`, `persist_deltas!`, `snapshot_revision!`

**Step 3: Write DeltaMerger tests**

Test `apply!` with mock spec, deltas, and change_source. Test `append_deltas!` concatenates properly. Test `snapshot_revision!` creates SpecRevision. Test that OpenSpec path is attempted when config enabled.

**Step 4: Run full test suite**

Run: `bundle exec rails test` — Ensure all existing tests still pass since AnalysisLoop behavior is unchanged.

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/delta_merger.rb lib/arnold_pipeline/analysis_loop.rb test/
git commit -m "refactor: extract DeltaMerger service from AnalysisLoop [SPEC-CLI-ITERATE-001]"
```

---

### Task 4: DeltaPresenter for Terminal Display

Create a presenter that formats deltas for terminal output (used by `--dry-run`).

**Files:**
- Create: `lib/arnold_pipeline/cli/delta_presenter.rb`
- Test: `test/lib/arnold_pipeline/cli/delta_presenter_test.rb`

**Step 1: Create DeltaPresenter**

Create `lib/arnold_pipeline/cli/delta_presenter.rb`:

```ruby
module ArnoldPipeline
  module Cli
    class DeltaPresenter
      def initialize(deltas, from_version:, to_version:)
        @deltas = deltas
        @from_version = from_version
        @to_version = to_version
      end

      def to_s
        lines = ["Proposed changes to specification (v#{@from_version} → v#{@to_version}):", ""]

        @deltas.each do |delta|
          lines.concat(format_delta(delta))
          lines << ""
        end

        lines.join("\n")
      end

      def to_json_data
        @deltas.map do |delta|
          {
            operation: delta["operation"],
            section: delta["section"],
            requirement: delta["requirement"],
            rationale: delta["rationale"]
          }.compact
        end
      end

      private

      def format_delta(delta)
        lines = []
        case delta["operation"]
        when "added"
          lines << "  ADDED: #{delta['section']} > #{delta['requirement'] || 'New requirement'}"
          lines << "    #{delta['rationale']}"
        when "modified"
          lines << "  MODIFIED: #{delta['section']} > #{delta['requirement']}"
          if delta["before_content"].present? && delta["after_content"].present?
            lines << "    Before: #{truncate(delta['before_content'], 120)}"
            lines << "    After:  #{truncate(delta['after_content'], 120)}"
          end
          lines << "    Rationale: #{delta['rationale']}"
        when "removed"
          lines << "  REMOVED: #{delta['section']} > #{delta['requirement']}"
          lines << "    Rationale: #{delta['rationale']}"
        end
        lines
      end

      def truncate(text, max)
        clean = text.to_s.gsub(/\s+/, " ").strip
        clean.length > max ? "#{clean[0, max]}..." : clean
      end
    end
  end
end
```

**Step 2: Write tests**

Test `to_s` formats each operation type correctly. Test `to_json_data` returns structured data. Test truncation works for long content.

**Step 3: Run tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli/delta_presenter_test.rb`

**Step 4: Commit**

```bash
git add lib/arnold_pipeline/cli/delta_presenter.rb test/
git commit -m "feat: add DeltaPresenter for terminal delta display [SPEC-CLI-ITERATE-002]"
```

---

### Task 5: Orchestrator `iterate_spec!` Method

Add the core iteration method to the Orchestrator that coordinates the SpecIterationAgent, DeltaMerger, and task invalidation.

**Depends on:** Tasks 1, 2, 3

**Files:**
- Modify: `lib/arnold_pipeline/orchestrator.rb`
- Test: `test/lib/arnold_pipeline/orchestrator_test.rb`

**Step 1: Add require and initialize SpecIterator**

At top of `lib/arnold_pipeline/orchestrator.rb`, add:
```ruby
require "arnold_pipeline/agents/spec_iterator"
require "arnold_pipeline/delta_merger"
```

Update the constructor to accept `spec_iterator:` parameter:
```ruby
def initialize(
  library_manager: nil,
  spec_generator: nil,
  task_breaker: nil,
  executor: nil,
  analyzer: nil,
  tier_gate_check: nil,
  spec_iterator: nil,
  logger: nil
)
  # ... existing code ...
  @spec_iterator = spec_iterator || Agents::SpecIterator.new(logger: @logger)
  @delta_merger = DeltaMerger.new(logger: @logger)
end
```

Add `spec_iterator` and `delta_merger` to `attr_reader`.

**Step 2: Add `iterate_spec!` public method**

```ruby
def iterate_spec!(pipeline_run:, change_request:)
  validate_iterable!(pipeline_run)

  spec = pipeline_run.specification
  raise ArgumentError, "Pipeline run ##{pipeline_run.id} has no specification" unless spec

  @event_recorder = PipelineEventRecorder.new(pipeline_run:)

  result = @event_recorder.timed(
    event_type: :spec_delta_merged, stage: "iteration",
    summary: ->(r) { r || {} }
  ) do
    agent_result = spec_iterator.call(
      spec_content: spec.content,
      change_request:
    )

    raw_deltas = agent_result["deltas"]
    raise ArgumentError, "No deltas generated from change request" if raw_deltas.blank?

    # Mark existing tasks as superseded
    pipeline_run.tasks.where.not(status: :superseded).update_all(status: :superseded) if pipeline_run.tasks.any?

    delta_merger.apply!(
      spec:, raw_deltas:, change_source: "user_iterate", pipeline_run:
    )
  end

  pipeline_run.reload
  { pipeline_run:, deltas: result, spec_version: pipeline_run.specification.version }
end
```

**Step 3: Add `iterate_spec_dry_run!` method**

```ruby
def iterate_spec_dry_run!(pipeline_run:, change_request:)
  validate_iterable!(pipeline_run)

  spec = pipeline_run.specification
  raise ArgumentError, "Pipeline run ##{pipeline_run.id} has no specification" unless spec

  agent_result = spec_iterator.call(
    spec_content: spec.content,
    change_request:
  )

  raw_deltas = agent_result["deltas"]
  raise ArgumentError, "No deltas generated from change request" if raw_deltas.blank?

  { deltas: raw_deltas, summary: agent_result["summary"], current_version: spec.version }
end
```

**Step 4: Add validation helper**

```ruby
private

ITERABLE_STATES = %w[paused failed completed].freeze

def validate_iterable!(pipeline_run)
  unless ITERABLE_STATES.include?(pipeline_run.status)
    raise ArgumentError, "Cannot iterate a #{pipeline_run.status} pipeline run. " \
                         "Pause or wait for completion first."
  end
end
```

**Step 5: Write orchestrator tests**

Test `iterate_spec!` with a paused run: calls agent, applies deltas, marks tasks superseded, creates SpecRevision with `user_iterate` change_source. Test validation rejects active states (executing, analyzing, etc.). Test dry_run returns deltas without modifying DB.

**Step 6: Run tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/orchestrator_test.rb`

**Step 7: Commit**

```bash
git add lib/arnold_pipeline/orchestrator.rb test/
git commit -m "feat: add Orchestrator#iterate_spec! for user-initiated iteration [SPEC-CLI-ITERATE-001]"
```

---

### Task 6: CLI `iterate` Command

Register the `arnold iterate` command in the Thor CLI.

**Depends on:** Task 5

**Files:**
- Modify: `lib/arnold_pipeline/cli.rb`
- Test: `test/lib/arnold_pipeline/cli_test.rb`

**Step 1: Add the command definition**

After the `resume` method in `cli.rb` (around line 141), add:

```ruby
desc "iterate ID CHANGE_REQUEST", "Iterate on a pipeline run's specification with a natural language change"
option :config, type: :string, desc: "Path to YAML config file"
option :provider, type: :string, desc: "LLM provider (anthropic or openai)"
option :model, type: :string, desc: "LLM model name"
option :dry_run, type: :boolean, default: false, desc: "Show proposed deltas without applying"
option :json, type: :boolean, default: false, desc: "Output delta details as JSON"
option :verbose, type: :boolean, default: false, desc: "Show full before/after for modified requirements"
option :yes, type: :boolean, default: false, aliases: ["-y"], desc: "Skip confirmation prompt"
def iterate(id, change_request)
  if id == "--help" || id == "-h"
    invoke :help, ["iterate"]
    return
  end
  with_error_handling do
    setup_standalone!
    load_config!(options)
    require "arnold_pipeline/orchestrator"
    require "arnold_pipeline/cli/delta_presenter"

    run_record = PipelineRun.find_by(id:)
    unless run_record
      say_error "Pipeline run ##{id} not found", :red
      raise SystemExit.new(1)
    end

    if change_request.strip.empty?
      say_error "Change request cannot be empty", :red
      raise SystemExit.new(1)
    end

    logger = build_logger(options[:verbose])
    ArnoldPipeline.configuration.verbose_event_logging = true if options[:verbose]
    orchestrator = Orchestrator.new(logger:)

    if run_record.completed?
      handle_iterate_fork!(orchestrator, run_record, change_request)
      return
    end

    if options[:dry_run]
      handle_iterate_dry_run!(orchestrator, run_record, change_request)
      return
    end

    quiet_say "Iterating specification for pipeline run ##{id}...", :green
    result = orchestrator.iterate_spec!(pipeline_run: run_record, change_request:)

    quiet_say "\nSpecification updated to v#{result[:spec_version]}", :green
    quiet_say "  Deltas applied: #{result[:deltas][:delta_count]}"
    quiet_say "  Merge strategy: #{result[:deltas][:merge_strategy]}"

    superseded_count = run_record.tasks.where(status: :superseded).count
    if superseded_count > 0
      quiet_say "  Tasks superseded: #{superseded_count}"
    end

    quiet_say "\nRun 'arnold resume #{id}' to continue the pipeline with the updated spec.", :yellow
  end
end
```

**Step 2: Add dry-run handler method**

```ruby
private

def handle_iterate_dry_run!(orchestrator, run_record, change_request)
  quiet_say "Generating proposed changes (dry run)...", :green
  result = orchestrator.iterate_spec_dry_run!(pipeline_run: run_record, change_request:)

  presenter = Cli::DeltaPresenter.new(
    result[:deltas],
    from_version: result[:current_version],
    to_version: result[:current_version] + 1
  )

  if options[:json]
    say JSON.pretty_generate(presenter.to_json_data)
  else
    say presenter.to_s
    say "\nNo changes applied (dry run).", :yellow
  end
end
```

**Step 3: Add fork handler stub (placeholder for Task 8)**

```ruby
def handle_iterate_fork!(orchestrator, run_record, change_request)
  quiet_say "Pipeline run ##{run_record.id} is completed. Forking into new run...", :green
  result = orchestrator.fork!(pipeline_run: run_record, change_request:)
  new_run = result[:pipeline_run]

  quiet_say "\nNew pipeline run created!", :green
  quiet_say "  New run ID: #{new_run.id}"
  quiet_say "  Forked from: ##{run_record.id}"
  quiet_say "  Spec version: #{new_run.specification.version}"
  quiet_say "\nRun 'arnold resume #{new_run.id}' to continue.", :yellow
end
```

**Step 4: Write CLI tests**

- Test `iterate` with paused run applies changes and shows output
- Test `iterate` with non-existent ID shows error
- Test `iterate` with empty change request shows error
- Test `iterate --dry-run` shows deltas without applying
- Test `iterate --json` on dry-run outputs JSON
- Test `iterate` with executing run shows error (state validation)
- Test `iterate` on completed run calls fork flow

**Step 5: Run tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/cli_test.rb`

**Step 6: Commit**

```bash
git add lib/arnold_pipeline/cli.rb test/
git commit -m "feat: add arnold iterate CLI command [SPEC-CLI-ITERATE-001]"
```

---

### Task 7: Update ResumeInferrer for Superseded Tasks

When all tasks are superseded, resume should infer `:break_tasks` to regenerate from the updated spec.

**Depends on:** Task 1

**Files:**
- Modify: `lib/arnold_pipeline/resume_inferrer.rb`
- Test: `test/lib/arnold_pipeline/resume_inferrer_test.rb`

**Step 1: Update inference logic**

In `lib/arnold_pipeline/resume_inferrer.rb`, add a check after the tasks.empty? check:

```ruby
def self.call(pipeline_run)
  tasks = pipeline_run.tasks

  return :generate_spec unless pipeline_run.specification

  return :break_tasks if tasks.empty?

  # All tasks superseded → re-run task breakdown with updated spec
  return :break_tasks if tasks.all?(&:superseded?)

  return :execute if tasks.any? { |t| t.tier.nil? }
  # ... rest unchanged
end
```

**Step 2: Write tests**

Test that all-superseded tasks infers `:break_tasks`. Test that mix of superseded + pending still infers based on existing logic.

**Step 3: Run tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/resume_inferrer_test.rb`

**Step 4: Commit**

```bash
git add lib/arnold_pipeline/resume_inferrer.rb test/
git commit -m "feat: ResumeInferrer handles superseded tasks [SPEC-CLI-ITERATE-004]"
```

---

### Task 8: Fork from Completed Run

Add `Orchestrator#fork!` method that creates a new PipelineRun seeded with an iterated spec.

**Depends on:** Task 5

**Files:**
- Modify: `lib/arnold_pipeline/orchestrator.rb`
- Test: `test/lib/arnold_pipeline/orchestrator_test.rb`

**Step 1: Add `fork!` method**

```ruby
def fork!(pipeline_run:, change_request:)
  unless pipeline_run.completed? || pipeline_run.max_iterations_reached?
    raise ArgumentError, "Can only fork completed or max_iterations_reached runs"
  end

  spec = pipeline_run.specification
  raise ArgumentError, "Pipeline run ##{pipeline_run.id} has no specification" unless spec

  # Generate deltas against current spec
  agent_result = spec_iterator.call(
    spec_content: spec.content,
    change_request:
  )
  raw_deltas = agent_result["deltas"]
  raise ArgumentError, "No deltas generated from change request" if raw_deltas.blank?

  # Create new pipeline run
  new_run = PipelineRun.create!(
    nl_input: pipeline_run.nl_input,
    status: :pending,
    metadata: {
      "forked_from_run_id" => pipeline_run.id,
      "fork_change_request" => change_request
    }
  )

  # Copy spec to new run and apply deltas
  new_spec = new_run.create_specification!(
    content: spec.content,
    structured_data: spec.structured_data,
    version: spec.version
  )

  @event_recorder = PipelineEventRecorder.new(pipeline_run: new_run)
  delta_merger.apply!(
    spec: new_spec, raw_deltas:, change_source: "user_iterate", pipeline_run: new_run
  )

  # Pause at break_tasks checkpoint so resume picks it up
  new_run.update!(
    status: :paused,
    metadata: new_run.metadata.merge("paused_at" => "spec")
  )

  { pipeline_run: new_run.reload, deltas: raw_deltas }
end
```

**Step 2: Write tests**

- Test fork creates new PipelineRun with forked_from_run_id metadata
- Test fork copies spec and applies deltas
- Test fork creates SpecRevision with user_iterate change_source
- Test fork raises for non-completed runs
- Test new run is paused at spec checkpoint

**Step 3: Run tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/orchestrator_test.rb`

**Step 4: Commit**

```bash
git add lib/arnold_pipeline/orchestrator.rb test/
git commit -m "feat: add Orchestrator#fork! for iterating completed runs [SPEC-CLI-ITERATE-003]"
```

---

### Task 9: Analysis Version Skew Guard

When the spec has been iterated by the user past the version tasks were generated from, suppress `iterate_spec` decisions in the analysis loop.

**Depends on:** Task 5

**Files:**
- Modify: `lib/arnold_pipeline/analysis_loop.rb`
- Test: `test/lib/arnold_pipeline/analysis_loop_test.rb`

**Step 1: Track spec version at task generation**

In `break_tasks!` method (both in Orchestrator and AnalysisLoop), after generating tasks, record the spec version in pipeline_run metadata:

In `lib/arnold_pipeline/orchestrator.rb`, at the end of `break_tasks!`:
```ruby
pipeline_run.update!(
  metadata: (pipeline_run.metadata || {}).merge("tasks_generated_at_spec_version" => pipeline_run.specification.version)
)
```

Similarly in `lib/arnold_pipeline/analysis_loop.rb` `break_tasks!` method.

**Step 2: Add version skew check in AnalysisLoop**

In `run!` method, after the `analyze!` call, add a check:

```ruby
def run!(pipeline_run)
  max_iterations = ArnoldPipeline.configuration.max_iterations
  existing_iterations = pipeline_run.iterations.count
  iteration_number = existing_iterations

  loop do
    iteration_number += 1
    analysis = analyze!(pipeline_run, iteration_number)
    analysis = maybe_promote_to_done(analysis, iteration_number)
    analysis = suppress_iterate_spec_if_stale(analysis, pipeline_run, iteration_number)
    # ... rest unchanged
  end
end
```

Add the helper method:

```ruby
def suppress_iterate_spec_if_stale(analysis, pipeline_run, iteration_number)
  return analysis unless analysis["decision"] == "iterate_spec"

  tasks_spec_version = (pipeline_run.metadata || {})["tasks_generated_at_spec_version"]
  current_spec_version = pipeline_run.specification&.version

  return analysis unless tasks_spec_version && current_spec_version
  return analysis unless current_spec_version > tasks_spec_version

  logger.info { "[Arnold] Suppressing iterate_spec — spec v#{current_spec_version} is ahead of tasks generated at v#{tasks_spec_version}" }
  event_recorder&.record(
    event_type: :iteration_decision, stage: "iteration",
    summary: {
      decision: "done",
      suppressed_from: "iterate_spec",
      reason: "spec_version_skew",
      tasks_spec_version: tasks_spec_version,
      current_spec_version: current_spec_version
    },
    iteration_number: iteration_number
  )

  analysis.merge("decision" => "done", "suppressed_from" => "iterate_spec")
end
```

**Step 3: Write tests**

Test that iterate_spec is suppressed when spec version > tasks_generated_at_spec_version. Test that iterate_tasks is NOT suppressed (only iterate_spec). Test that without version metadata, no suppression occurs.

**Step 4: Run tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/analysis_loop_test.rb`

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/analysis_loop.rb lib/arnold_pipeline/orchestrator.rb test/
git commit -m "feat: suppress iterate_spec when spec version exceeds task generation version [SPEC-CLI-ITERATE-005]"
```

---

### Task 10: Update specification.md and README.md

Add spec items for the iterate feature and update README documentation.

**Depends on:** All implementation tasks complete

**Files:**
- Modify: `specification.md`
- Modify: `README.md`

**Step 1: Add spec items to specification.md**

Add the 5 SPEC-CLI-ITERATE items from the design document as new requirements in the CLI section.

**Step 2: Update README.md**

- Add `arnold iterate` to the CLI commands section
- Document the `--dry-run`, `--json`, `--verbose`, `--yes` flags
- Add examples showing the iteration workflow
- Document the fork-from-completed behavior
- Update the pipeline flow diagram to show the iteration loop

**Step 3: Commit**

```bash
git add specification.md README.md
git commit -m "docs: add spec iteration requirements and README documentation [SPEC-CLI-ITERATE-001]"
```

---

## Full Test Suite Verification

After all tasks are complete, run the full test suite:

```bash
bundle exec rails test
```

Expected: All tests pass (existing + new), 0 failures.
