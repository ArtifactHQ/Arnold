require_relative "base"

module ArnoldPipeline
  module Mcp
    module Tools
      class GetHistory < Base
        def self.tool_name
          "get_history"
        end

        def self.description
          "Review the evolution of the spec. Returns a chronological list of revisions with " \
            "product-level summaries of what changed. Supports filtering by domain."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Defaults to the latest run if not provided."
              },
              domain: {
                type: %w[string null],
                description: "Optional domain name to filter revisions by."
              },
              limit: {
                type: "integer",
                description: "Maximum number of revisions to return (default 10)."
              }
            },
            required: []
          }
        end

        def self.call(params, context)
          run_id = params["run_id"]
          domain_filter = params["domain"].to_s.strip.presence
          limit = (params["limit"] || 10).to_i.clamp(1, 100)

          run = context.pipeline_run(run_id: run_id)
          return { error: "No pipeline run found" } unless run

          spec = run.specification
          return { error: "No specification found for pipeline run ##{run.id}" } unless spec

          revisions = spec.spec_revisions.ordered
          revision_list = build_revision_list(revisions, spec, domain_filter)

          { revisions: revision_list.first(limit) }
        end

        private_class_method def self.build_revision_list(revisions, spec, domain_filter)
          previous_content = nil

          revisions.filter_map { |rev|
            domains_affected = detect_affected_domains(rev, previous_content, spec)
            summary = generate_summary(rev, previous_content)
            previous_content = rev.content

            # Apply domain filter if specified
            if domain_filter
              next unless domains_affected.any? { |d|
                d.downcase.include?(domain_filter.downcase) || domain_filter.downcase.include?(d.downcase)
              }
            end

            {
              revision: rev.version.to_s,
              timestamp: rev.created_at&.iso8601,
              change_source: rev.change_source || "unknown",
              summary: summary,
              domains_affected: domains_affected
            }
          }
        end

        private_class_method def self.generate_summary(revision, previous_content)
          case revision.change_source
          when "spec_generation"
            "Initial specification generated"
          when "mcp_confirm"
            summarize_diff(revision.content, previous_content, "Specification updated via proposal")
          when "iterate_spec"
            summarize_diff(revision.content, previous_content, "Specification refined during analysis")
          when "user_iterate"
            summarize_diff(revision.content, previous_content, "Specification updated by user")
          when "drift_resolution"
            summarize_diff(revision.content, previous_content, "Specification updated to resolve drift")
          else
            summarize_diff(revision.content, previous_content, "Specification updated")
          end
        end

        private_class_method def self.summarize_diff(current_content, previous_content, default_summary)
          return default_summary unless previous_content

          current_lines = current_content.to_s.lines.map(&:strip)
          previous_lines = previous_content.to_s.lines.map(&:strip)

          added = current_lines - previous_lines
          removed = previous_lines - current_lines

          parts = []
          parts << "#{added.size} lines added" if added.any?
          parts << "#{removed.size} lines removed" if removed.any?

          if parts.any?
            "#{default_summary} (#{parts.join(', ')})"
          else
            default_summary
          end
        end

        private_class_method def self.detect_affected_domains(revision, previous_content, spec)
          data = spec.structured_data
          known_domains = if data.is_a?(Hash)
            (data["domains"] || data[:domains] || []).map { |d|
              d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s
            }
          else
            []
          end

          return known_domains if previous_content.nil? # Initial creation affects all

          current = revision.content.to_s.downcase
          previous = previous_content.to_s.downcase

          # Find domains whose content sections changed
          known_domains.select { |domain|
            domain_lower = domain.downcase
            # Check if content around domain references changed
            current_mentions = count_domain_context(current, domain_lower)
            previous_mentions = count_domain_context(previous, domain_lower)
            current_mentions != previous_mentions
          }
        end

        private_class_method def self.count_domain_context(content, domain_lower)
          # Count lines that mention this domain — changes in count indicate affected domain
          content.lines.count { |line| line.include?(domain_lower) }
        end
      end
    end
  end
end
