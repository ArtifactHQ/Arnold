require_relative "base"
require "arnold_pipeline/setup/orchestrator"

module ArnoldPipeline
  module Mcp
    module Tools
      class InitProject < Base
        def self.tool_name
          "init_project"
        end

        def self.description
          "Initialize a new project with Arnold Pipeline. Creates project directory, " \
            "writes configuration, and optionally generates a spec + task preview. " \
            "Returns status with missing fields if more input is needed."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              project_path: {
                type: "string",
                description: "Absolute path for the new project directory"
              },
              description: {
                type: "string",
                description: "Natural language description of the product to build " \
                  "(e.g. 'a dog walking app where walkers find clients nearby')"
              },
              llm_provider: {
                type: "string",
                enum: %w[anthropic openai],
                description: "LLM provider to use (default: auto-detected from API key)"
              },
              llm_api_key: {
                type: "string",
                description: "API key for the LLM provider (can also use env vars)"
              },
              execution_provider: {
                type: "string",
                enum: %w[github claude_code null],
                description: "Execution provider (default: claude_code)"
              },
              github_token: {
                type: "string",
                description: "GitHub token (required when execution_provider is github)"
              },
              github_repo: {
                type: "string",
                description: "GitHub repo in owner/repo format (required when execution_provider is github)"
              },
              config_overrides: {
                type: "object",
                description: "Additional config keys to write (these always win over existing config)"
              }
            },
            required: []
          }
        end

        def self.call(params, context)
          request = ArnoldPipeline::Setup::Request.new(
            project_path: params["project_path"]&.strip.presence,
            description: params["description"]&.strip.presence,
            llm_provider: params["llm_provider"]&.strip.presence,
            llm_api_key: params["llm_api_key"]&.strip.presence,
            execution_provider: params["execution_provider"]&.strip.presence,
            github_token: params["github_token"]&.strip.presence,
            github_repo: params["github_repo"]&.strip.presence,
            config_overrides: params["config_overrides"] || {}
          )

          orchestrator = ArnoldPipeline::Setup::Orchestrator.new(
            logger: Logger.new(File::NULL)
          )
          result = orchestrator.call(request)

          build_response(result)
        rescue => e
          { error: "Failed to initialize project: #{e.message}" }
        end

        private_class_method def self.build_response(result)
          case result.status
          when :needs_input
            {
              status: "needs_input",
              message: "Additional information is required to proceed.",
              missing_fields: result.missing_fields.map(&:to_s),
              field_hints: field_hints_for(result.missing_fields)
            }
          when :error
            {
              status: "error",
              errors: result.errors
            }
          when :complete
            {
              status: "complete",
              project_path: result.project_path,
              config_path: result.config_path,
              run_id: result.run_id.to_s,
              spec_summary: result.spec_summary,
              task_summary: result.task_summary,
              next_actions: [
                "Run 'arnold run \"<description>\"' to execute the full pipeline",
                "Run 'arnold resume #{result.run_id}' to continue from the preview",
                "Edit #{result.config_path} to adjust configuration"
              ]
            }
          end
        end

        private_class_method def self.field_hints_for(fields)
          hints = {}
          fields.each do |field|
            hints[field.to_s] = case field
            when :project_path
              "Absolute path where the new project should be created"
            when :description
              "Describe what you want to build in at least 10 characters"
            when :llm_api_key
              "Set ANTHROPIC_API_KEY or OPENAI_API_KEY env var, or provide directly"
            when :github_token
              "GitHub personal access token (required for GitHub execution provider)"
            when :github_repo
              "GitHub repository in owner/repo format"
            end
          end
          hints
        end
      end
    end
  end
end
