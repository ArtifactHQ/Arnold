require_relative "base"

module ArnoldPipeline
  module Mcp
    module Tools
      class ExploreDomain < Base
        def self.tool_name
          "explore_domain"
        end

        def self.description
          "Drills into a specific domain with capabilities and relationships. " \
            "Finds the domain by fuzzy name matching and extracts details from the spec and tasks."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              domain: {
                type: "string",
                description: "The domain name to explore (case-insensitive, partial match supported)."
              },
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Defaults to the latest run if not provided."
              }
            },
            required: ["domain"]
          }
        end

        def self.call(params, context)
          domain_query = params["domain"].to_s.strip
          run_id = params["run_id"]

          if domain_query.empty?
            return { error: "Domain name is required" }
          end

          run = context.pipeline_run(run_id: run_id)
          unless run
            return { error: "No pipeline run found" }
          end

          spec = run.specification
          unless spec
            return { error: "No specification found for pipeline run ##{run.id}" }
          end

          tasks = run.tasks
          domain_info = find_domain(domain_query, spec)

          unless domain_info
            available = list_available_domains(spec, tasks)
            return {
              error: "Domain '#{domain_query}' not found",
              available_domains: available
            }
          end

          domain_tasks = tasks_for_domain(domain_info[:name], tasks)
          all_domains = extract_all_domain_names(spec, tasks)

          {
            domain: domain_info[:name],
            description: domain_info[:description],
            personas_involved: find_involved_personas(domain_info[:name], spec),
            capabilities: build_capabilities(domain_info[:name], spec, domain_tasks),
            relationships: find_relationships(domain_info[:name], all_domains, spec, tasks)
          }
        end

        private_class_method def self.find_domain(query, spec)
          query_lower = query.downcase
          data = spec.structured_data

          if data.is_a?(Hash)
            domains = data["domains"] || data[:domains] || []
            # Exact match first
            exact = domains.find { |d|
              name = d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s
              name.downcase == query_lower
            }
            return domain_hash(exact) if exact

            # Partial match
            partial = domains.find { |d|
              name = d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s
              name.downcase.include?(query_lower) || query_lower.include?(name.downcase)
            }
            return domain_hash(partial) if partial
          end

          # Fall back to scanning spec content for section headers matching the query
          content = spec.content.to_s
          section_match = content.match(/^##\s*(.*#{Regexp.escape(query)}.*)/i)
          if section_match
            section_name = section_match[1].strip
            # Extract description from lines following the header
            section_start = content.index(section_match[0])
            following = content[section_start + section_match[0].length..]
            desc_lines = following.to_s.lines.take_while { |l| !l.match?(/^##\s/) }
            desc = desc_lines.join.strip.truncate(300)
            return { name: section_name, description: desc }
          end

          nil
        end

        private_class_method def self.domain_hash(domain_entry)
          return nil unless domain_entry

          if domain_entry.is_a?(Hash)
            {
              name: (domain_entry["name"] || domain_entry[:name]).to_s,
              description: (domain_entry["description"] || domain_entry[:description]).to_s
            }
          else
            { name: domain_entry.to_s, description: "" }
          end
        end

        private_class_method def self.list_available_domains(spec, tasks)
          domains = []
          data = spec.structured_data
          if data.is_a?(Hash)
            (data["domains"] || data[:domains] || []).each do |d|
              name = d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s
              domains << name
            end
          end

          # Also add unique labels from tasks as potential domains
          tasks.each do |t|
            (t.labels || []).each do |label|
              domains << label.titleize unless domains.any? { |d| d.downcase == label.downcase }
            end
          end

          domains.uniq
        end

        private_class_method def self.extract_all_domain_names(spec, tasks)
          list_available_domains(spec, tasks)
        end

        private_class_method def self.tasks_for_domain(domain_name, tasks)
          domain_lower = domain_name.downcase
          tasks.select { |t|
            labels = (t.labels || []).map(&:downcase)
            title = t.title.to_s.downcase
            description = t.description.to_s.downcase
            labels.any? { |l| l.include?(domain_lower) || domain_lower.include?(l) } ||
              title.include?(domain_lower) ||
              description.include?(domain_lower)
          }
        end

        private_class_method def self.find_involved_personas(domain_name, spec)
          data = spec.structured_data
          return [] unless data.is_a?(Hash)

          personas = data["personas"] || data[:personas] || []
          domain_lower = domain_name.downcase

          # Check if personas have domain associations
          involved = personas.select { |p|
            if p.is_a?(Hash)
              p_domains = Array(p["domains"] || p[:domains] || [])
              p_desc = (p["description"] || p[:description]).to_s.downcase
              p_domains.any? { |d| d.to_s.downcase.include?(domain_lower) } ||
                p_desc.include?(domain_lower)
            else
              false
            end
          }

          # If no explicit associations, return all persona names
          if involved.empty?
            personas.map { |p| p.is_a?(Hash) ? (p["name"] || p[:name]).to_s : p.to_s }
          else
            involved.map { |p| p.is_a?(Hash) ? (p["name"] || p[:name]).to_s : p.to_s }
          end
        end

        private_class_method def self.build_capabilities(domain_name, spec, domain_tasks)
          capabilities = []

          # Extract from tasks
          domain_tasks.each do |task|
            capabilities << {
              description: task.title,
              status: task_status_to_capability_status(task.status)
            }
          end

          # If no tasks, try to extract from spec content
          if capabilities.empty?
            capabilities = extract_capabilities_from_content(domain_name, spec)
          end

          capabilities
        end

        private_class_method def self.extract_capabilities_from_content(domain_name, spec)
          content = spec.content.to_s
          domain_lower = domain_name.downcase

          # Find the section for this domain and extract requirement headers
          capabilities = []
          in_domain_section = false
          content.lines.each do |line|
            if line.match?(/^##\s/i)
              in_domain_section = line.downcase.include?(domain_lower)
            elsif in_domain_section && (m = line.match(/^###\s*Requirement:\s*(.+)/i))
              req_name = m[1].strip.sub(/\s*\[REQ-.*?\]\s*$/, "")
              capabilities << { description: req_name, status: "defined" }
            elsif in_domain_section && (m = line.match(/^[-*]\s+(.+)/))
              cap = m[1].strip
              capabilities << { description: cap, status: "defined" } if cap.length > 5
            end
          end

          capabilities.first(20)
        end

        private_class_method def self.task_status_to_capability_status(status)
          case status.to_s
          when "completed" then "complete"
          when "in_progress" then "in_progress"
          else "defined"
          end
        end

        private_class_method def self.find_relationships(domain_name, all_domains, spec, tasks)
          domain_lower = domain_name.downcase
          other_domains = all_domains.reject { |d| d.downcase == domain_lower }

          relationships = []
          domain_tasks = tasks_for_domain(domain_name, tasks)
          domain_task_ids = domain_tasks.map { |t| t.id.to_s }

          other_domains.each do |other|
            other_lower = other.downcase
            relationship = detect_relationship(domain_lower, other_lower, domain_tasks, domain_task_ids, tasks, spec)
            relationships << { domain: other, relationship: relationship } if relationship
          end

          relationships
        end

        private_class_method def self.detect_relationship(domain_lower, other_lower, domain_tasks, domain_task_ids, tasks, spec)
          other_tasks = tasks.select { |t|
            labels = (t.labels || []).map(&:downcase)
            labels.any? { |l| l.include?(other_lower) || other_lower.include?(l) }
          }

          # Check dependency relationships
          depends_on_other = domain_tasks.any? { |t|
            (t.depends_on || []).any? { |dep_id|
              other_tasks.any? { |ot| ot.id.to_s == dep_id.to_s }
            }
          }
          return "depends_on" if depends_on_other

          other_depends_on_domain = other_tasks.any? { |t|
            (t.depends_on || []).any? { |dep_id|
              domain_task_ids.include?(dep_id.to_s)
            }
          }
          return "depended_on_by" if other_depends_on_domain

          # Check content cross-references
          content = spec.content.to_s.downcase
          # Look for both domains mentioned in the same paragraph
          paragraphs = content.split(/\n\n+/)
          co_occurring = paragraphs.any? { |p|
            p.include?(domain_lower) && p.include?(other_lower)
          }
          return "related" if co_occurring

          nil
        end
      end
    end
  end
end
