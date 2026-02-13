require "open3"
require "tmpdir"
require "fileutils"

module ArnoldPipeline
  class OpenspecBridge
    OPENSPEC_DIR = "openspec"

    attr_reader :working_dir

    def initialize(working_dir:, logger: Logger.new($stdout))
      @working_dir = working_dir
      @logger = logger
    end

    def self.with_workspace(logger: Logger.new($stdout))
      dir = Dir.mktmpdir("arnold_openspec_")
      bridge = new(working_dir: dir, logger:)
      bridge.scaffold!
      yield bridge
    ensure
      FileUtils.remove_entry(dir, true) if dir
    end

    def scaffold!
      specs_dir = File.join(@working_dir, OPENSPEC_DIR, "specs")
      changes_dir = File.join(@working_dir, OPENSPEC_DIR, "changes")
      FileUtils.mkdir_p(specs_dir)
      FileUtils.mkdir_p(changes_dir)

      config_path = File.join(@working_dir, OPENSPEC_DIR, "config.yaml")
      unless File.exist?(config_path)
        File.write(config_path, "schema: spec-driven\n")
      end
    end

    def write_spec!(specification, domain: "app")
      spec_dir = File.join(@working_dir, OPENSPEC_DIR, "specs", domain)
      FileUtils.mkdir_p(spec_dir)
      File.write(File.join(spec_dir, "spec.md"), specification.content)
    end

    def write_delta_and_merge!(change_name:, domain: "app", deltas:)
      delta_dir = File.join(@working_dir, OPENSPEC_DIR, "changes", change_name, "specs", domain)
      FileUtils.mkdir_p(delta_dir)

      delta_md = format_delta_markdown(deltas)
      File.write(File.join(delta_dir, "spec.md"), delta_md)

      proposal_dir = File.join(@working_dir, OPENSPEC_DIR, "changes", change_name)
      File.write(File.join(proposal_dir, "proposal.md"), <<~PROPOSAL)
        # #{change_name}

        ## Why
        Automated spec iteration from analysis feedback. #{deltas.map { |d| d["rationale"] }.compact.first}

        ## What Changes
        #{summarize_deltas(deltas)}
      PROPOSAL

      valid = run_openspec("validate", change_name)
      unless valid
        @logger.warn { "[Arnold] OpenSpec validation failed for #{change_name}" }
        return nil
      end

      success = run_openspec("archive", change_name, "--yes")

      if success
        merged_path = File.join(@working_dir, OPENSPEC_DIR, "specs", domain, "spec.md")
        File.read(merged_path)
      else
        @logger.warn { "[Arnold] OpenSpec archive failed, falling back to append merge" }
        nil
      end
    end

    private

    def run_openspec(*args)
      cli_path = ArnoldPipeline.configuration.openspec_cli_path
      Dir.chdir(@working_dir) do
        stdout, stderr, status = Open3.capture3(cli_path, *args)
        unless status.success?
          @logger.warn { "[Arnold] #{cli_path} #{args.join(' ')} failed: #{stderr}" }
        end
        status.success?
      end
    rescue Errno::ENOENT => e
      @logger.warn { "[Arnold] OpenSpec CLI not found: #{e.message}" }
      false
    end

    def format_delta_markdown(deltas)
      sections = { "added" => [], "modified" => [], "removed" => [] }

      deltas.each do |d|
        op = d["operation"]&.downcase
        sections[op] << d if sections.key?(op)
      end

      parts = []

      if sections["added"].any?
        parts << "## ADDED Requirements\n"
        sections["added"].each do |d|
          parts << d["content"]
          parts << ""
        end
      end

      if sections["modified"].any?
        parts << "## MODIFIED Requirements\n"
        sections["modified"].each do |d|
          parts << d["after_content"]
          parts << ""
        end
      end

      if sections["removed"].any?
        parts << "## REMOVED Requirements\n"
        sections["removed"].each do |d|
          parts << "### Requirement: #{d['requirement']}"
          parts << ""
        end
      end

      parts.join("\n")
    end

    def summarize_deltas(deltas)
      deltas.map do |d|
        op = d["operation"]&.upcase
        req = d["requirement"] || "new requirement"
        section = d["section"]
        "#{op}: #{section} > #{req}"
      end.join(". ")
    end
  end
end
