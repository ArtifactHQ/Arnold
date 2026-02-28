module ArnoldPipeline
  module Mcp
    module Tools
      class GetSpec < Base
        def self.tool_name
          "get_spec"
        end

        def self.description
          "Pull the full specification for context. Returns the spec content and metadata for a pipeline run."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Defaults to the latest run if not provided."
              },
              format: {
                type: "string",
                enum: %w[full summary],
                description: "full spec or condensed overview. Defaults to full.",
                default: "full"
              }
            },
            required: []
          }
        end

        def self.call(params, context)
          run_id = params["run_id"]
          format = params["format"] || "full"

          run = context.pipeline_run(run_id: run_id)
          unless run
            return { error: "No pipeline run found" }
          end

          spec = run.specification
          unless spec
            return { error: "No specification found for pipeline run ##{run.id}" }
          end

          spec_content = if format == "summary"
            summarize(spec.content)
          else
            spec.content
          end

          tasks = run.tasks
          {
            run_id: run.id.to_s,
            revision: spec.version.to_s,
            format: format,
            spec: spec_content,
            metadata: {
              personas: extract_personas(spec),
              domains: extract_domains(spec),
              recipes: extract_recipes(spec),
              total_tasks: tasks.count,
              completed_tasks: tasks.where(status: :completed).count
            }
          }
        end

        private_class_method def self.summarize(content)
          lines = content.to_s.lines
          # Return first 50 lines as summary, or full content if shorter
          if lines.length > 50
            lines.first(50).join + "\n... (truncated, #{lines.length} total lines)"
          else
            content
          end
        end

        private_class_method def self.extract_personas(spec)
          data = spec.structured_data
          return [] unless data.is_a?(Hash)

          (data["personas"] || data[:personas] || []).map { |p|
            p.is_a?(Hash) ? (p["name"] || p[:name]).to_s : p.to_s
          }
        end

        private_class_method def self.extract_domains(spec)
          data = spec.structured_data
          return [] unless data.is_a?(Hash)

          (data["domains"] || data[:domains] || []).map { |d|
            d.is_a?(Hash) ? (d["name"] || d[:name]).to_s : d.to_s
          }
        end

        private_class_method def self.extract_recipes(spec)
          data = spec.structured_data
          return [] unless data.is_a?(Hash)

          (data["recipes"] || data[:recipes] || []).map { |r|
            r.is_a?(Hash) ? (r["name"] || r[:name]).to_s : r.to_s
          }
        end
      end
    end
  end
end
