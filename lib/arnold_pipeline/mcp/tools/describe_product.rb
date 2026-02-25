require_relative "base"

module ArnoldPipeline
  module Mcp
    module Tools
      class DescribeProduct < Base
        def self.tool_name
          "describe_product"
        end

        def self.description
          "Returns a narrative product description organized by persona and domain. " \
            "Extracts product information from the specification and task state."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Defaults to the latest run if not provided."
              }
            },
            required: []
          }
        end

        def self.call(params, context)
          run_id = params["run_id"]

          run = context.pipeline_run(run_id: run_id)
          unless run
            return { error: "No pipeline run found" }
          end

          spec = run.specification
          unless spec
            return { error: "No specification found for pipeline run ##{run.id}" }
          end

          tasks = run.tasks

          {
            product_name: extract_product_name(spec, run),
            summary: extract_summary(spec, run),
            personas: build_personas(spec, context),
            domains: build_domains(spec, tasks, context)
          }
        end

        private_class_method def self.extract_product_name(spec, run)
          data = spec.structured_data
          if data.is_a?(Hash)
            name = data["product_name"] || data[:product_name] ||
                   data["name"] || data[:name] ||
                   data["title"] || data[:title]
            return name.to_s if name.present?
          end

          # Fall back to extracting from spec content heading
          first_heading = spec.content.to_s.lines.find { |l| l.match?(/^#\s/) }
          if first_heading
            first_heading.sub(/^#+\s*/, "").strip
          else
            run.nl_input.to_s.truncate(80)
          end
        end

        private_class_method def self.extract_summary(spec, run)
          data = spec.structured_data
          if data.is_a?(Hash)
            summary = data["summary"] || data[:summary] ||
                      data["description"] || data[:description]
            return summary.to_s if summary.present?
          end

          # Fall back to the purpose section from spec content
          content = spec.content.to_s
          purpose_match = content.match(/##\s*Purpose\s*\n(.*?)(?=\n##|\z)/m)
          if purpose_match
            purpose_match[1].strip.truncate(500)
          else
            "Product based on: #{run.nl_input.to_s.truncate(200)}"
          end
        end

        private_class_method def self.build_personas(spec, context)
          data = spec.structured_data
          personas_from_data = if data.is_a?(Hash)
            (data["personas"] || data[:personas] || [])
          else
            []
          end

          if personas_from_data.any?
            personas_from_data.map do |p|
              if p.is_a?(Hash)
                {
                  name: (p["name"] || p[:name]).to_s,
                  description: (p["description"] || p[:description] || p["role"] || p[:role]).to_s,
                  capabilities: Array(p["capabilities"] || p[:capabilities] || [])
                }
              else
                { name: p.to_s, description: "", capabilities: [] }
              end
            end
          else
            # Fall back to library personas matched against the spec content
            extract_personas_from_content(spec, context)
          end
        end

        private_class_method def self.extract_personas_from_content(spec, context)
          library = context.library_manager
          content = spec.content.to_s.downcase

          library.all_personas.select { |p|
            p.keywords.any? { |kw| content.include?(kw.downcase) }
          }.map do |p|
            {
              name: p.name,
              description: p.description.to_s,
              capabilities: []
            }
          end
        end

        private_class_method def self.build_domains(spec, tasks, context)
          data = spec.structured_data
          domains_from_data = if data.is_a?(Hash)
            (data["domains"] || data[:domains] || [])
          else
            []
          end

          if domains_from_data.any?
            domains_from_data.map do |d|
              domain_name = d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s
              domain_desc = d.is_a?(Hash) ? (d["description"] || d[:description]).to_s : ""

              {
                name: domain_name,
                description: domain_desc,
                status: domain_status(domain_name, tasks)
              }
            end
          else
            # Fall back to extracting domains from task labels
            extract_domains_from_tasks(tasks)
          end
        end

        private_class_method def self.extract_domains_from_tasks(tasks)
          label_groups = tasks.group_by { |t| (t.labels || []).first.to_s }
          label_groups.reject { |k, _| k.blank? }.map do |label, group_tasks|
            {
              name: label.titleize,
              description: "Domain covering #{label} tasks",
              status: compute_status(group_tasks)
            }
          end
        end

        private_class_method def self.domain_status(domain_name, tasks)
          # Match tasks to domain by checking labels
          domain_lower = domain_name.downcase
          matching = tasks.select { |t|
            labels = (t.labels || []).map(&:downcase)
            title = t.title.to_s.downcase
            labels.any? { |l| l.include?(domain_lower) || domain_lower.include?(l) } ||
              title.include?(domain_lower)
          }

          return "defined" if matching.empty?
          compute_status(matching)
        end

        private_class_method def self.compute_status(task_list)
          return "defined" if task_list.empty?
          return "complete" if task_list.all? { |t| t.status == "completed" }
          return "in_progress" if task_list.any? { |t| t.status.in?(%w[in_progress completed]) }

          "defined"
        end
      end
    end
  end
end
