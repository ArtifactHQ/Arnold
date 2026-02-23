# Claude Code Provider Enhancements Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enhance the Claude Code execution provider to parse JSON output, generate library-driven CLAUDE.md files, use system prompts, support tool restrictions, add cost/turn guardrails, and surface execution metadata through an extended provider contract.

**Architecture:** Eight improvements organized into 10 implementation tasks. The provider contract gains an optional `execution_metadata` field. A new `ClaudeMdGenerator` service assembles worktree CLAUDE.md files from Library persona/recipe/domain_type YAML. The CLI command construction is restructured into three prompt layers (system prompt, CLAUDE.md, task prompt). JSON output parsing feeds both metadata and failure diagnostics.

**Tech Stack:** Ruby 4.0, Rails 8.1.2, Minitest, Mocha

**Design doc:** `docs/plans/2026-02-21-claude-code-provider-enhancements-design.md`

---

### Task 1: Migration — Add `execution_metadata` Column to Tasks

**Files:**
- Create: `db/migrate/20250212000001_add_execution_metadata_to_arnold_pipeline_tasks.rb`
- Modify: `test/dummy/db/schema.rb` (update directly to avoid DuplicateMigrationNameError)

**Step 1: Create the migration**

```ruby
# db/migrate/20250212000001_add_execution_metadata_to_arnold_pipeline_tasks.rb
class AddExecutionMetadataToArnoldPipelineTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :arnold_pipeline_tasks, :execution_metadata, :json, default: {}
  end
end
```

**Step 2: Update dummy app schema**

Add to the `arnold_pipeline_tasks` table in `test/dummy/db/schema.rb`:
```ruby
t.json "execution_metadata", default: {}
```

**Step 3: Run tests to verify migration doesn't break anything**

Run: `bundle exec rails test test/models/arnold_pipeline/task_test.rb`
Expected: All existing tests pass

**Step 4: Commit**

```bash
git add db/migrate/20250212000001_add_execution_metadata_to_arnold_pipeline_tasks.rb test/dummy/db/schema.rb
git commit -m "feat(db): add execution_metadata json column to tasks [SPEC-EXEC-001]"
```

---

### Task 2: Contract Extension — SharedProviderTests + Conformance Checklist

**Files:**
- Modify: `test/lib/arnold_pipeline/providers/execution/shared_provider_tests.rb`
- Modify: `docs/provider_conformance_checklist.md`

**Step 1: Add optional execution_metadata shape test to SharedProviderTests**

Add after the existing `test_async_returns_boolean` method at `shared_provider_tests.rb:31`:

```ruby
def test_fetch_results_execution_metadata_shape
  # Providers may return execution_metadata as nil or Hash
  # This test verifies the contract is respected when results exist
  # Subclasses must set up @pipeline_run with at least one task that has stored results
  return unless respond_to?(:setup_fetch_results_for_metadata_test)

  setup_fetch_results_for_metadata_test
  results = provider_instance.fetch_results(pipeline_run: @pipeline_run)
  results.each do |r|
    meta = r[:execution_metadata]
    assert(meta.nil? || meta.is_a?(Hash),
      "execution_metadata must be nil or Hash, got #{meta.class}")
    assert_nothing_raised { meta&.to_json }
  end
end
```

**Step 2: Add conformance checklist section**

Add after the existing "Comments (if provided)" section in `docs/provider_conformance_checklist.md`:

```markdown
### Execution metadata (optional)

- [ ] Each element may include `:execution_metadata` (Hash or nil)
      **Source:** `executor.rb` — stored on task record when present
- [ ] `:execution_metadata` values are JSON-serializable
      **Verify:** `assert_nothing_raised { result[:execution_metadata]&.to_json }`
- [ ] Provider functions correctly when `:execution_metadata` is omitted or nil
      **Why:** This field is optional — the Executor must not crash when it's absent
```

**Step 3: Run SharedProviderTests to confirm no breakage**

Run: `bundle exec rails test test/lib/arnold_pipeline/providers/execution/`
Expected: All existing tests pass (new test is opt-in via `setup_fetch_results_for_metadata_test`)

**Step 4: Commit**

```bash
git add test/lib/arnold_pipeline/providers/execution/shared_provider_tests.rb docs/provider_conformance_checklist.md
git commit -m "feat(contract): add optional execution_metadata to provider contract [SPEC-EXEC-001]"
```

---

### Task 3: Executor — Store `execution_metadata` on Task Records

**Files:**
- Modify: `lib/arnold_pipeline/agents/executor.rb:42-48`
- Test: `test/lib/arnold_pipeline/agents/executor_test.rb`

**Step 1: Write the failing test**

Add to `executor_test.rb`:

```ruby
test "fetch_results stores execution_metadata on task when present" do
  task = @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "ext-1")
  metadata = { "cost_usd" => 0.034, "duration_ms" => 28470, "num_turns" => 12 }

  @provider.stubs(:fetch_results).returns([{
    task_id: task.id,
    external_id: "ext-1",
    diffs: [],
    comments: [],
    status: :completed,
    workflow_active: false,
    execution_metadata: metadata
  }])

  @executor.fetch_results(pipeline_run: @pipeline_run)

  task.reload
  assert_equal metadata, task.execution_metadata
end

test "fetch_results handles missing execution_metadata gracefully" do
  task = @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "ext-1")

  @provider.stubs(:fetch_results).returns([{
    task_id: task.id,
    external_id: "ext-1",
    diffs: [],
    comments: [],
    status: :completed,
    workflow_active: false
  }])

  @executor.fetch_results(pipeline_run: @pipeline_run)

  task.reload
  assert_equal({}, task.execution_metadata)
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/lib/arnold_pipeline/agents/executor_test.rb -n /execution_metadata/`
Expected: FAIL — `execution_metadata` not being stored yet

**Step 3: Implement in executor**

In `lib/arnold_pipeline/agents/executor.rb`, modify the `fetch_results` method. After line 47 (`updates[:workflow_active] = ...`), add:

```ruby
updates[:execution_metadata] = result[:execution_metadata] if result[:execution_metadata].present?
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/agents/executor_test.rb`
Expected: All pass

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/agents/executor.rb test/lib/arnold_pipeline/agents/executor_test.rb
git commit -m "feat(executor): store execution_metadata on task records [SPEC-EXEC-001]"
```

---

### Task 4: Configuration — New Options + Default Changes

**Files:**
- Modify: `lib/arnold_pipeline/configuration.rb`
- Test: `test/lib/arnold_pipeline/configuration_test.rb`

**Step 1: Write failing tests**

Add to configuration test file:

```ruby
test "claude_code_max_turns defaults to 25" do
  config = ArnoldPipeline::Configuration.new
  assert_equal 25, config.claude_code_max_turns
end

test "claude_code_max_budget_usd defaults to nil" do
  config = ArnoldPipeline::Configuration.new
  assert_nil config.claude_code_max_budget_usd
end

test "claude_code_tools defaults to nil" do
  config = ArnoldPipeline::Configuration.new
  assert_nil config.claude_code_tools
end

test "claude_code_allowed_tools defaults to nil" do
  config = ArnoldPipeline::Configuration.new
  assert_nil config.claude_code_allowed_tools
end

test "claude_code_disallowed_tools defaults to nil" do
  config = ArnoldPipeline::Configuration.new
  assert_nil config.claude_code_disallowed_tools
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/configuration_test.rb -n /claude_code_max_turns_defaults_to_25/`
Expected: FAIL — current default is nil

**Step 3: Add new attrs and change defaults in configuration.rb**

In `lib/arnold_pipeline/configuration.rb`:

Add to `attr_accessor` list (line 18):
```ruby
:claude_code_max_budget_usd,
:claude_code_tools, :claude_code_allowed_tools, :claude_code_disallowed_tools
```

Change in `initialize`:
```ruby
@claude_code_max_turns      = 25        # was nil
@claude_code_max_budget_usd = nil
@claude_code_tools           = nil
@claude_code_allowed_tools   = nil
@claude_code_disallowed_tools = nil
```

Add validation method:
```ruby
def validate_claude_code_max_budget_usd!
  return if @claude_code_max_budget_usd.nil?
  return if @claude_code_max_budget_usd.is_a?(Numeric) && @claude_code_max_budget_usd > 0

  raise ConfigurationError, "claude_code_max_budget_usd must be nil or a positive number"
end
```

Call `validate_claude_code_max_budget_usd!` from `validate!`.

**Step 4: Write validation tests**

```ruby
test "validate! rejects invalid claude_code_max_budget_usd" do
  config = build_valid_config
  [0, -5, "30"].each do |bad|
    config.claude_code_max_budget_usd = bad
    assert_raises(ArnoldPipeline::ConfigurationError) { config.validate! }
  end
end

test "validate! accepts valid claude_code_max_budget_usd" do
  config = build_valid_config
  [nil, 1.0, 5, 0.5].each do |good|
    config.claude_code_max_budget_usd = good
    assert_nothing_raised { config.validate! }
  end
end
```

**Step 5: Run all configuration tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/configuration_test.rb`
Expected: All pass

**Step 6: Commit**

```bash
git add lib/arnold_pipeline/configuration.rb test/lib/arnold_pipeline/configuration_test.rb
git commit -m "feat(config): add budget, tool restriction config; default max_turns to 25 [SPEC-PROVIDER-001]"
```

---

### Task 5: ClaudeMdGenerator Service

**Files:**
- Create: `lib/arnold_pipeline/services/claude_md_generator.rb`
- Create: `test/lib/arnold_pipeline/services/claude_md_generator_test.rb`

**Step 1: Create test directory and write failing tests**

```ruby
# test/lib/arnold_pipeline/services/claude_md_generator_test.rb
require "test_helper"
require "arnold_pipeline/services/claude_md_generator"

module ArnoldPipeline
  module Services
    class ClaudeMdGeneratorTest < ActiveSupport::TestCase
      setup do
        @recipe = Library::Recipe.new(
          name: "Web App", type: "web_app", keywords: [],
          description: "Full-stack web application",
          framework: { "primary" => "Rails 8+", "frontend" => "Hotwire", "css" => "Tailwind CSS" },
          sections: [
            { "name" => "Local Development", "phase" => "pipeline",
              "guidance" => ["Use bin/dev to start", "SQLite for development"] }
          ],
          verification: {
            "test_command" => "bin/rails test:all",
            "setup_commands" => ["bundle install", "bin/rails db:prepare"],
            "boot_command" => "bin/rails server -p 3000 -d",
            "health_checks" => [{ "url" => "http://localhost:3000/up", "expected_status" => 200 }]
          }
        )

        @domain_type = Library::DomainType.new(
          code: "GAME", name: "Game / Interactive Entertainment",
          keywords: [], description: "Game apps",
          primary_value: "Fun, engagement",
          emphasis: ["Progression systems", "Difficulty curves"],
          document_focus: ["Win/loss conditions"],
          watch_for: ["Game balance"],
          terminology: { "user" => "player", "account" => "profile" }
        )

        @persona = Library::Persona.new(
          name: "Software Architect", role: "system_design",
          keywords: [], description: "Designs architectures",
          system_prompt: "You are a Software Architect"
        )
      end

      test "call returns a string" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_kind_of String, result
      end

      test "includes tech stack from recipe framework" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes result, "Rails 8+"
        assert_includes result, "Hotwire"
        assert_includes result, "Tailwind CSS"
      end

      test "includes conventions from recipe sections guidance" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes result, "Use bin/dev to start"
        assert_includes result, "SQLite for development"
      end

      test "includes testing from recipe verification" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes result, "bin/rails test:all"
        assert_includes result, "bundle install"
      end

      test "includes domain context" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes result, "Game / Interactive Entertainment"
        assert_includes result, "Progression systems"
      end

      test "includes terminology mappings" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes result, "player"
        assert_includes result, "profile"
      end

      test "includes watch_for items" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes result, "Game balance"
      end

      test "handles nil persona gracefully" do
        result = ClaudeMdGenerator.call(persona: nil, recipe: @recipe, domain_type: @domain_type)
        assert_kind_of String, result
      end

      test "handles nil recipe gracefully" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: nil, domain_type: @domain_type)
        assert_kind_of String, result
        refute_includes result, "Tech Stack"
      end

      test "handles nil domain_type gracefully" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: nil)
        assert_kind_of String, result
        refute_includes result, "Domain Context"
      end

      test "handles all-nil inputs" do
        result = ClaudeMdGenerator.call(persona: nil, recipe: nil, domain_type: nil)
        assert_kind_of String, result
        assert_includes result, "# Project Instructions"
      end

      test "omits empty sections" do
        empty_recipe = Library::Recipe.new(
          name: "Generic", type: "generic", keywords: [],
          description: "Generic", framework: {},
          sections: [], verification: {}
        )
        result = ClaudeMdGenerator.call(persona: @persona, recipe: empty_recipe, domain_type: @domain_type)
        refute_includes result, "## Tech Stack"
        refute_includes result, "## Conventions"
      end
    end
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/services/claude_md_generator_test.rb`
Expected: FAIL — file doesn't exist yet

**Step 3: Create the services directory and implement**

```ruby
# lib/arnold_pipeline/services/claude_md_generator.rb
module ArnoldPipeline
  module Services
    class ClaudeMdGenerator
      def self.call(persona:, recipe:, domain_type:)
        new(persona:, recipe:, domain_type:).generate
      end

      def initialize(persona:, recipe:, domain_type:)
        @persona = persona
        @recipe = recipe
        @domain_type = domain_type
      end

      def generate
        sections = []
        sections << "# Project Instructions"
        sections << tech_stack_section
        sections << conventions_section
        sections << testing_section
        sections << domain_context_section
        sections << terminology_section
        sections << watch_for_section

        sections.compact.join("\n\n")
      end

      private

      def tech_stack_section
        framework = @recipe&.framework
        return nil if framework.nil? || framework.empty?

        lines = framework.map { |key, value| "- **#{key.capitalize}:** #{value}" }
        "## Tech Stack\n\n#{lines.join("\n")}"
      end

      def conventions_section
        return nil unless @recipe&.sections&.any?

        guidance_items = @recipe.sections
          .select { |s| s["phase"] == "pipeline" }
          .flat_map { |s| s["guidance"] || [] }
          .compact

        return nil if guidance_items.empty?

        lines = guidance_items.map { |g| "- #{g}" }
        "## Conventions\n\n#{lines.join("\n")}"
      end

      def testing_section
        verification = @recipe&.verification
        return nil if verification.nil? || verification.empty?

        lines = []
        lines << "- **Test command:** #{verification["test_command"]}" if verification["test_command"]

        if (setup = verification["setup_commands"])&.any?
          lines << "- **Setup:** #{setup.join(", ")}"
        end

        lines << "- **Boot command:** #{verification["boot_command"]}" if verification["boot_command"]

        if (checks = verification["health_checks"])&.any?
          checks.each do |check|
            lines << "- **Health check:** GET #{check["url"]} → #{check["expected_status"]}"
          end
        end

        return nil if lines.empty?

        "## Testing\n\n#{lines.join("\n")}"
      end

      def domain_context_section
        return nil unless @domain_type

        lines = []
        lines << "- **Domain:** #{@domain_type.name}"
        lines << "- **Primary value:** #{@domain_type.primary_value}" if @domain_type.primary_value&.present?

        if @domain_type.emphasis.any?
          lines << "- **Priorities:**"
          @domain_type.emphasis.each { |e| lines << "  - #{e}" }
        end

        "## Domain Context\n\n#{lines.join("\n")}"
      end

      def terminology_section
        return nil unless @domain_type&.terminology&.any?

        lines = @domain_type.terminology.map { |from, to| "- #{from} → #{to}" }
        "## Terminology\n\n#{lines.join("\n")}"
      end

      def watch_for_section
        return nil unless @domain_type&.watch_for&.any?

        lines = @domain_type.watch_for.map { |w| "- #{w}" }
        "## Watch For\n\n#{lines.join("\n")}"
      end
    end
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/services/claude_md_generator_test.rb`
Expected: All pass

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/services/claude_md_generator.rb test/lib/arnold_pipeline/services/claude_md_generator_test.rb
git commit -m "feat(services): add ClaudeMdGenerator — library-driven CLAUDE.md generation [SPEC-PROVIDER-001]"
```

---

### Task 6: Orchestrator — Store Library Selections on Pipeline Run

**Files:**
- Modify: `lib/arnold_pipeline/orchestrator.rb:262` (after event recording, before spec generation)
- Test: `test/lib/arnold_pipeline/orchestrator_test.rb`

**Step 1: Write the failing test**

Add to orchestrator test:

```ruby
test "generate_spec stores library_selections in pipeline_run metadata" do
  pipeline_run = ArnoldPipeline::PipelineRun.create!(nl_input: "Build a web game", status: :pending)

  @orchestrator.call(nl_input: pipeline_run.nl_input, stop_after: :spec)

  pipeline_run.reload
  selections = pipeline_run.metadata["library_selections"]
  assert_not_nil selections
  assert selections.key?("persona")
  assert selections.key?("recipe")
  assert selections.key?("domain_type")
end
```

Note: This test depends on the existing orchestrator test setup with stubbed LLM calls. Match the existing test patterns in the file.

**Step 2: Run test to verify it fails**

Run: `bundle exec rails test test/lib/arnold_pipeline/orchestrator_test.rb -n /library_selections/`
Expected: FAIL — metadata doesn't contain library_selections yet

**Step 3: Implement in orchestrator**

In `lib/arnold_pipeline/orchestrator.rb`, after the event recording block (line 262) and before the `@event_recorder&.timed` call (line 264), add:

```ruby
pipeline_run.update!(metadata: (pipeline_run.metadata || {}).merge(
  "library_selections" => {
    "persona" => persona&.name,
    "recipe" => recipe&.name,
    "supporting_recipes" => supporting_recipes&.map(&:name),
    "domain_type" => domain_type&.code
  }
))
```

**Step 4: Run tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/orchestrator_test.rb`
Expected: All pass

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/orchestrator.rb test/lib/arnold_pipeline/orchestrator_test.rb
git commit -m "feat(orchestrator): persist library_selections in pipeline_run metadata [SPEC-PROVIDER-001]"
```

---

### Task 7: Provider — JSON Output Parsing + Execution Metadata + Failure Comments

**Files:**
- Modify: `lib/arnold_pipeline/providers/execution/claude_code.rb`
- Modify: `test/lib/arnold_pipeline/providers/execution/claude_code_test.rb`

**Step 1: Write failing tests for JSON parsing**

```ruby
test "parse_claude_output extracts fields from valid JSON" do
  json = {
    "result" => "Task completed successfully",
    "total_cost_usd" => 0.034,
    "duration_ms" => 28470,
    "num_turns" => 12,
    "session_id" => "abc-123",
    "is_error" => false,
    "subtype" => "success"
  }.to_json

  parsed = @provider.send(:parse_claude_output, json)

  assert_equal "Task completed successfully", parsed[:result]
  assert_equal 0.034, parsed[:cost_usd]
  assert_equal 28470, parsed[:duration_ms]
  assert_equal 12, parsed[:num_turns]
  assert_equal "abc-123", parsed[:session_id]
  assert_equal false, parsed[:is_error]
end

test "parse_claude_output handles invalid JSON gracefully" do
  parsed = @provider.send(:parse_claude_output, "not json at all")

  assert_equal "not json at all", parsed[:result]
  assert_nil parsed[:cost_usd]
  assert_nil parsed[:duration_ms]
  assert_nil parsed[:num_turns]
end

test "parse_claude_output handles empty string" do
  parsed = @provider.send(:parse_claude_output, "")
  assert_equal "", parsed[:result]
end
```

**Step 2: Run to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/providers/execution/claude_code_test.rb -n /parse_claude_output/`
Expected: FAIL — method doesn't exist

**Step 3: Implement `parse_claude_output`**

Add private method to `claude_code.rb`:

```ruby
def parse_claude_output(raw_output)
  parsed = JSON.parse(raw_output)
  {
    result: parsed["result"],
    cost_usd: parsed["total_cost_usd"],
    duration_ms: parsed["duration_ms"],
    num_turns: parsed["num_turns"],
    session_id: parsed["session_id"],
    is_error: parsed["is_error"],
    subtype: parsed["subtype"]
  }
rescue JSON::ParserError
  { result: raw_output, cost_usd: nil, duration_ms: nil, num_turns: nil,
    session_id: nil, is_error: nil, subtype: nil }
end
```

**Step 4: Run parse tests to verify they pass**

Run: `bundle exec rails test test/lib/arnold_pipeline/providers/execution/claude_code_test.rb -n /parse_claude_output/`
Expected: All pass

**Step 5: Write failing tests for execution_metadata in fetch_results**

```ruby
test "fetch_results populates execution_metadata from parsed output" do
  task = @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "cc-1-0")
  @provider.instance_variable_set(:@results, {
    "cc-1-0" => {
      success: true, diff: "diff --git a/f.rb b/f.rb\n+x", output: "Done",
      parsed: { cost_usd: 0.034, duration_ms: 28470, num_turns: 12, session_id: "abc" }
    }
  })

  results = @provider.fetch_results(pipeline_run: @pipeline_run)
  meta = results.first[:execution_metadata]

  assert_kind_of Hash, meta
  assert_equal 0.034, meta[:cost_usd]
  assert_equal 28470, meta[:duration_ms]
  assert_equal 12, meta[:num_turns]
end

test "fetch_results returns empty execution_metadata when no parsed data" do
  task = @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "cc-1-0")
  @provider.instance_variable_set(:@results, {
    "cc-1-0" => { success: true, diff: "", output: "Done" }
  })

  results = @provider.fetch_results(pipeline_run: @pipeline_run)
  meta = results.first[:execution_metadata]

  assert_kind_of Hash, meta
  assert meta.empty?
end
```

**Step 6: Write failing tests for failure comments**

```ruby
test "fetch_results includes failure comment with Claude's message on failure" do
  task = @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "cc-1-0")
  @provider.instance_variable_set(:@results, {
    "cc-1-0" => {
      success: false, diff: "", error: "CLI exited with code 1",
      parsed: { result: "I couldn't complete this because the database wasn't configured" }
    }
  })

  results = @provider.fetch_results(pipeline_run: @pipeline_run)
  comments = results.first[:comments]

  assert_equal 1, comments.size
  assert_equal "claude_code", comments.first["source"]
  assert_equal "claude", comments.first["author"]
  assert_includes comments.first["body"], "database wasn't configured"
end

test "fetch_results returns empty comments on success" do
  task = @pipeline_run.tasks.create!(title: "Task", position: 0, external_id: "cc-1-0")
  @provider.instance_variable_set(:@results, {
    "cc-1-0" => {
      success: true, diff: "diff --git a/f.rb b/f.rb\n+x", output: "Done",
      parsed: { result: "All done" }
    }
  })

  results = @provider.fetch_results(pipeline_run: @pipeline_run)
  assert_equal [], results.first[:comments]
end
```

**Step 7: Implement changes to fetch_results and execute_work_item**

Modify `execute_work_item` to parse output and store parsed data:

```ruby
def execute_work_item(item)
  result = execute_claude_code(
    prompt: item[:prompt],
    branch: item[:branch_name],
    external_id: item[:external_id]
  )

  parsed = parse_claude_output(result[:output] || "")

  if result[:success]
    worktree_path = File.join(repo_path, ".worktrees", item[:branch_name])
    normalize_worktree(worktree_path: worktree_path, title: item[:title])
  end

  diff = capture_diff(branch: item[:branch_name])

  if result[:success] && diff.strip.empty?
    result = result.merge(
      success: false,
      error: "Task completed with exit code 0 but produced no code changes"
    )
  end

  @results_mutex.synchronize do
    @results[item[:external_id]] = {
      success: result[:success],
      output: result[:output],
      diff: diff,
      branch: item[:branch_name],
      error: result[:error],
      parsed: parsed
    }
  end

  { external_id: item[:external_id], external_url: nil, title: item[:title] }
end
```

Modify `fetch_results` to populate `execution_metadata` and `comments`:

```ruby
def fetch_results(pipeline_run:, tasks: nil)
  (tasks || pipeline_run.tasks).filter_map do |task|
    next unless task.external_id

    stored = @results[task.external_id]
    next unless stored

    parsed = stored[:parsed] || {}

    comments = if !stored[:success] && parsed[:result]
      [{ "source" => "claude_code", "author" => "claude",
         "body" => "Task failed: #{parsed[:result]}" }]
    else
      []
    end

    metadata = {
      cost_usd: parsed[:cost_usd],
      duration_ms: parsed[:duration_ms],
      num_turns: parsed[:num_turns],
      model: model,
      session_id: parsed[:session_id]
    }.compact

    {
      task_id: task.id,
      external_id: task.external_id,
      diffs: parse_diff_to_array(stored[:diff] || ""),
      comments: comments,
      status: stored[:success] ? :completed : :failed,
      workflow_active: false,
      workflow_details: "claude code execution",
      execution_metadata: metadata
    }
  end
end
```

**Step 8: Run all claude_code tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/providers/execution/claude_code_test.rb`
Expected: All pass (including existing tests — the `fetch_results` shape test needs updating since `comments` is no longer always `[]`)

Note: The existing test `"fetch_results always returns empty comments"` at line 167 will need updating — it should now test that successful tasks with no parsed data return empty comments.

**Step 9: Commit**

```bash
git add lib/arnold_pipeline/providers/execution/claude_code.rb test/lib/arnold_pipeline/providers/execution/claude_code_test.rb
git commit -m "feat(claude_code): parse JSON output, surface execution_metadata and failure comments [SPEC-PROVIDER-001]"
```

---

### Task 8: Provider — System Prompt, Tool Restrictions, Budget Flag

**Files:**
- Modify: `lib/arnold_pipeline/providers/execution/claude_code.rb`
- Modify: `test/lib/arnold_pipeline/providers/execution/claude_code_test.rb`

**Step 1: Write failing tests for system_prompt**

```ruby
test "system_prompt includes behavioral instructions" do
  prompt = @provider.send(:system_prompt)
  assert_includes prompt, "automated pipeline"
  assert_includes prompt, "without asking questions"
  assert_includes prompt, "test suite"
  assert_includes prompt, "Commit all changes"
  assert_includes prompt, "do not create project subdirectories"
end
```

**Step 2: Write failing tests for tool_restriction_flags**

```ruby
test "tool_restriction_flags returns empty when all nil" do
  assert_equal [], @provider.send(:tool_restriction_flags)
end

test "tool_restriction_flags includes --tools when configured" do
  ArnoldPipeline.configure { |c| c.claude_code_tools = ["Bash", "Edit", "Read"] }
  flags = @provider.send(:tool_restriction_flags)
  assert_includes flags, "--tools"
  assert_includes flags, "Bash,Edit,Read"
ensure
  ArnoldPipeline.reset_configuration!
end

test "tool_restriction_flags includes --allowedTools for each pattern" do
  ArnoldPipeline.configure { |c| c.claude_code_allowed_tools = ["Bash(git *)", "Read"] }
  flags = @provider.send(:tool_restriction_flags)
  assert_equal ["--allowedTools", "Bash(git *)", "--allowedTools", "Read"], flags
ensure
  ArnoldPipeline.reset_configuration!
end

test "tool_restriction_flags includes --disallowedTools for each pattern" do
  ArnoldPipeline.configure { |c| c.claude_code_disallowed_tools = ["WebSearch"] }
  flags = @provider.send(:tool_restriction_flags)
  assert_equal ["--disallowedTools", "WebSearch"], flags
ensure
  ArnoldPipeline.reset_configuration!
end
```

**Step 3: Write failing tests for build_cli_command changes**

```ruby
test "build_cli_command includes --append-system-prompt" do
  cmd = @provider.send(:build_cli_command, "test prompt")
  assert_includes cmd, "--append-system-prompt"
end

test "build_cli_command includes --max-budget-usd when configured" do
  provider = ClaudeCode.new(repo_path: @repo_path, max_budget_usd: 5.0)
  cmd = provider.send(:build_cli_command, "test prompt")
  assert_includes cmd, "--max-budget-usd"
  assert_includes cmd, "5.0"
end

test "build_cli_command omits --max-budget-usd when nil" do
  cmd = @provider.send(:build_cli_command, "test prompt")
  refute_includes cmd, "--max-budget-usd"
end

test "build_cli_command includes max_turns by default (25)" do
  provider = ClaudeCode.new(repo_path: @repo_path)
  cmd = provider.send(:build_cli_command, "test prompt")
  assert_includes cmd, "--max-turns"
  assert_includes cmd, "25"
end
```

**Step 4: Run tests to verify they fail**

Run: `bundle exec rails test test/lib/arnold_pipeline/providers/execution/claude_code_test.rb -n /system_prompt|tool_restriction|build_cli_command/`
Expected: FAIL

**Step 5: Implement system_prompt, tool_restriction_flags, and update build_cli_command**

Add `max_budget_usd` to `attr_reader`, constructor, and `build_from_config`:

```ruby
attr_reader :repo_path, :model, :max_turns, :permission_mode, :max_budget_usd

def initialize(repo_path:, model: "sonnet", max_turns: 25, permission_mode: "bypassPermissions", max_budget_usd: nil)
  @repo_path = repo_path
  @model = model
  @max_turns = max_turns
  @permission_mode = permission_mode
  @max_budget_usd = max_budget_usd
  @results = {}
  @results_mutex = Mutex.new
  @worktree_mutex = Mutex.new
end

def self.build_from_config(config, **options)
  new(
    repo_path: options[:repo_path] || config.claude_code_repo_path,
    model: options[:model] || config.claude_code_model || "sonnet",
    max_turns: options[:max_turns] || config.claude_code_max_turns || 25,
    permission_mode: options[:permission_mode] || config.claude_code_permission_mode || "bypassPermissions",
    max_budget_usd: options[:max_budget_usd] || config.claude_code_max_budget_usd
  )
end
```

Add private methods:

```ruby
def system_prompt
  <<~SYSTEM.strip
    You are an implementation agent in an automated pipeline.
    Complete the task fully without asking questions.
    Make reasonable decisions and document assumptions in code comments.
    Run the project's test suite after implementing changes. If tests fail, fix them.
    Only commit once tests pass.
    Do not create project subdirectories — work in the current directory.
    Do not run `git init` — this directory is already tracked by git.
    If scaffolding a Rails app, use `rails new . --force` (dot = current dir).
    Commit all changes when finished.
  SYSTEM
end

def tool_restriction_flags
  flags = []
  if (tools = ArnoldPipeline.configuration.claude_code_tools)
    flags += ["--tools", Array(tools).join(",")]
  end
  if (allowed = ArnoldPipeline.configuration.claude_code_allowed_tools)
    Array(allowed).each { |t| flags += ["--allowedTools", t] }
  end
  if (disallowed = ArnoldPipeline.configuration.claude_code_disallowed_tools)
    Array(disallowed).each { |t| flags += ["--disallowedTools", t] }
  end
  flags
end
```

Update `build_cli_command`:

```ruby
def build_cli_command(prompt)
  cmd_parts = [
    "claude", "--print", "--output-format", "json",
    "--model", model,
    "--permission-mode", permission_mode,
    "--append-system-prompt", system_prompt
  ]

  cmd_parts += ["--max-turns", max_turns.to_s] if max_turns
  cmd_parts += ["--max-budget-usd", max_budget_usd.to_s] if max_budget_usd
  cmd_parts += tool_restriction_flags

  cmd_parts << prompt

  cmd_parts.shelljoin
end
```

Update `build_prompt` to remove behavioral instructions (now in system_prompt):

```ruby
def build_prompt(title:, description:, labels:, prior_context:)
  context_section = if prior_context
    <<~CTX
      ## Prior Implementation Context
      Previous tiers have already implemented and merged code into this repository.
      You can see their work in the existing files. Here is a summary:

      #{prior_context}

      Build on top of existing code. Do not rewrite or duplicate what already exists.
    CTX
  else
    "This is the first implementation tier. Start from the project's current state."
  end

  <<~PROMPT
    ## Task
    **#{title}**
    #{description}
    #{"Labels: #{Array(labels).join(', ')}" if Array(labels).any?}

    #{context_section}
  PROMPT
end
```

**Step 6: Update existing prompt tests**

The test `"build_prompt includes working directory rules"` at line 264 must be updated — working directory rules now live in `system_prompt`, not `build_prompt`. Change it to test `system_prompt` instead, and add a new test verifying `build_prompt` is task-content-only.

**Step 7: Update existing constructor test**

The test `"constructor sets defaults"` at line 770 must be updated — `max_turns` default changed from nil to 25:
```ruby
assert_equal 25, provider.max_turns  # was assert_nil
```

**Step 8: Run all tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/providers/execution/claude_code_test.rb`
Expected: All pass

**Step 9: Commit**

```bash
git add lib/arnold_pipeline/providers/execution/claude_code.rb test/lib/arnold_pipeline/providers/execution/claude_code_test.rb
git commit -m "feat(claude_code): add system prompt, tool restrictions, budget flag [SPEC-PROVIDER-001]"
```

---

### Task 9: Provider — CLAUDE.md Generation in Worktrees

**Files:**
- Modify: `lib/arnold_pipeline/providers/execution/claude_code.rb`
- Modify: `test/lib/arnold_pipeline/providers/execution/claude_code_test.rb`

**Step 1: Write failing tests**

```ruby
test "create_tasks resolves library_selections from pipeline_run metadata" do
  @pipeline_run.update!(metadata: {
    "library_selections" => {
      "persona" => "Software Architect",
      "recipe" => "Web App",
      "domain_type" => "GAME"
    }
  })

  tasks = [{ "title" => "Setup", "description" => "Init" }]
  @provider.stubs(:execute_claude_code).returns({ success: true, output: "{}", error: nil })
  @provider.stubs(:normalize_worktree)
  @provider.stubs(:capture_diff).returns("diff --git a/f.rb b/f.rb\n+x")
  @provider.stubs(:setup_worktree).returns(@repo_path)

  @provider.create_tasks(tasks:, pipeline_run: @pipeline_run)

  selections = @provider.instance_variable_get(:@library_selections)
  assert_not_nil selections
  assert_not_nil selections[:recipe]
  assert_equal "Web App", selections[:recipe].name
end

test "write_claude_md! writes CLAUDE.md when repo has none" do
  @provider.instance_variable_set(:@library_selections, {
    persona: ArnoldPipeline::Library::Persona.new(
      name: "SA", role: "sa", keywords: [], description: "d", system_prompt: "sp"
    ),
    recipe: ArnoldPipeline::Library::Recipe.new(
      name: "Web App", type: "web_app", keywords: [], description: "d",
      framework: { "primary" => "Rails 8+" }, sections: [], verification: {}
    ),
    domain_type: ArnoldPipeline::Library::DomainType.new(
      code: "GAME", name: "Game", keywords: [], description: "d",
      primary_value: "Fun", emphasis: [], document_focus: [], watch_for: [], terminology: {}
    )
  })

  worktree_path = Dir.mktmpdir
  @provider.send(:write_claude_md!, worktree_path)

  claude_md_path = File.join(worktree_path, "CLAUDE.md")
  assert File.exist?(claude_md_path)
  content = File.read(claude_md_path)
  assert_includes content, "Rails 8+"
ensure
  FileUtils.remove_entry(worktree_path)
end

test "write_claude_md! writes to .claude/CLAUDE.md when repo has existing CLAUDE.md" do
  @provider.instance_variable_set(:@library_selections, {
    persona: nil,
    recipe: ArnoldPipeline::Library::Recipe.new(
      name: "Web App", type: "web_app", keywords: [], description: "d",
      framework: { "primary" => "Rails 8+" }, sections: [], verification: {}
    ),
    domain_type: nil
  })

  worktree_path = Dir.mktmpdir
  File.write(File.join(worktree_path, "CLAUDE.md"), "# Existing project instructions")

  @provider.send(:write_claude_md!, worktree_path)

  # Original untouched
  assert_equal "# Existing project instructions", File.read(File.join(worktree_path, "CLAUDE.md"))
  # Generated in subdirectory
  generated = File.join(worktree_path, ".claude", "CLAUDE.md")
  assert File.exist?(generated)
  assert_includes File.read(generated), "Rails 8+"
ensure
  FileUtils.remove_entry(worktree_path)
end

test "write_claude_md! is no-op when library_selections is nil" do
  @provider.instance_variable_set(:@library_selections, nil)

  worktree_path = Dir.mktmpdir
  @provider.send(:write_claude_md!, worktree_path)

  refute File.exist?(File.join(worktree_path, "CLAUDE.md"))
  refute File.exist?(File.join(worktree_path, ".claude", "CLAUDE.md"))
ensure
  FileUtils.remove_entry(worktree_path)
end
```

**Step 2: Run to verify failure**

Run: `bundle exec rails test test/lib/arnold_pipeline/providers/execution/claude_code_test.rb -n /write_claude_md|library_selections/`
Expected: FAIL

**Step 3: Implement `resolve_library_selections` and `write_claude_md!`**

Add `require` at top of `claude_code.rb`:

```ruby
require "arnold_pipeline/services/claude_md_generator"
```

Add to `create_tasks` method, before the `work_items` construction:

```ruby
def create_tasks(tasks:, pipeline_run:, prior_context: nil)
  @library_selections = resolve_library_selections(pipeline_run)

  work_items = tasks.each_with_index.map do |task, index|
    # ... existing code
  end
  # ... rest of method
end
```

Add private methods:

```ruby
def resolve_library_selections(pipeline_run)
  selections = pipeline_run.metadata&.dig("library_selections")
  return nil unless selections

  manager = Library::Manager.new
  {
    persona: manager.all_personas.find { |p| p.name == selections["persona"] },
    recipe: manager.all_recipes.find { |r| r.name == selections["recipe"] },
    domain_type: manager.all_domain_types.find { |d| d.code == selections["domain_type"] }
  }
end

def write_claude_md!(worktree_path)
  return unless @library_selections

  content = Services::ClaudeMdGenerator.call(
    persona: @library_selections[:persona],
    recipe: @library_selections[:recipe],
    domain_type: @library_selections[:domain_type]
  )

  if File.exist?(File.join(worktree_path, "CLAUDE.md"))
    FileUtils.mkdir_p(File.join(worktree_path, ".claude"))
    File.write(File.join(worktree_path, ".claude", "CLAUDE.md"), content)
  else
    File.write(File.join(worktree_path, "CLAUDE.md"), content)
  end
end
```

Add `write_claude_md!` call to `setup_worktree`:

```ruby
def setup_worktree(branch)
  worktree_path = File.join(repo_path, ".worktrees", branch)
  cleanup_worktree(branch)
  system("git", "-C", repo_path, "worktree", "add", "-b", branch, worktree_path, exception: true)
  ensure_gitignore!(worktree_path)
  write_claude_md!(worktree_path)
  worktree_path
end
```

**Step 4: Run all tests**

Run: `bundle exec rails test test/lib/arnold_pipeline/providers/execution/claude_code_test.rb`
Expected: All pass

**Step 5: Commit**

```bash
git add lib/arnold_pipeline/providers/execution/claude_code.rb test/lib/arnold_pipeline/providers/execution/claude_code_test.rb
git commit -m "feat(claude_code): generate library-driven CLAUDE.md in worktrees [SPEC-PROVIDER-001]"
```

---

### Task 10: README + Full Test Suite Verification

**Files:**
- Modify: `README.md`

**Step 1: Run the full test suite**

Run: `bundle exec rails test`
Expected: All tests pass (1216+ tests, 0 failures)

Fix any failures before proceeding.

**Step 2: Update README**

Update the Claude Code Provider config table (around line 295):

| Option | Default | Description |
|--------|---------|-------------|
| `claude_code_max_turns` | `25` | Max turns per task |
| `claude_code_max_budget_usd` | `nil` | Per-task dollar budget limit (nil = unlimited) |
| `claude_code_tools` | `nil` | Tool whitelist via `--tools` (nil = all tools) |
| `claude_code_allowed_tools` | `nil` | Auto-approve tool patterns via `--allowedTools` |
| `claude_code_disallowed_tools` | `nil` | Block tool patterns via `--disallowedTools` |

Update the Configuration Reference table (around line 579):
- Change `claude_code_max_turns` default from `nil` to `25`
- Add the four new config options

Update the full config example (around line 448):
```ruby
config.claude_code_max_turns       = 25       # default; set nil for unlimited
config.claude_code_max_budget_usd  = nil      # per-task dollar limit
config.claude_code_tools           = nil      # tool whitelist (nil = all)
config.claude_code_allowed_tools   = nil      # auto-approve patterns
config.claude_code_disallowed_tools = nil     # blocked tool patterns
```

Add a new subsection under the Claude Code Provider section describing:
- JSON output parsing and execution metadata
- Library-driven CLAUDE.md generation (auto-generated per worktree from persona/recipe/domain_type)
- System prompt separation (`--append-system-prompt` for behavioral instructions)
- Test-running instructions (Claude is told to run tests and fix failures before committing)

Update the architecture file tree (around line 1000):
```
services/
  claude_md_generator.rb   # Library-driven CLAUDE.md generation for worktrees
```

**Step 3: Run the readme-maintainer agent**

Use the readme-maintainer agent to do the actual README updates and verify cross-references.

**Step 4: Run full test suite one final time**

Run: `bundle exec rails test`
Expected: All pass

**Step 5: Commit**

```bash
git add README.md
git commit -m "docs: update README with Claude Code provider enhancements [SPEC-PROVIDER-001]"
```
