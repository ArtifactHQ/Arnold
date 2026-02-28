module ArnoldPipeline
  module Mcp
    module Tools
      class StartTask < Base
        def self.tool_name
          "start_task"
        end

        def self.description
          "Signal that work is beginning on a task. Transitions the task to in_progress and returns contextual guidance."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              task_id: {
                type: "string",
                description: "The ID of the task to start."
              }
            },
            required: [ "task_id" ]
          }
        end

        def self.call(params, context)
          task_id = params["task_id"]
          return { error: "task_id is required" } unless task_id

          run = context.pipeline_run
          return { error: "No pipeline run found" } unless run

          task = run.tasks.find_by(id: task_id)
          return { error: "Task not found: #{task_id}" } unless task

          # Idempotent: already in_progress is fine
          unless task.pending? || task.in_progress?
            return { error: "Task cannot be started — current status is '#{task.status}'" }
          end

          # Check dependencies
          dependency_warnings = check_dependencies(task, run)

          # Transition to in_progress (idempotent if already there)
          task.update!(status: :in_progress) unless task.in_progress?

          {
            task_id: task.id.to_s,
            status: "in_progress",
            warnings: dependency_warnings,
            context: {
              spec_excerpt: build_spec_excerpt(task, run),
              prior_context: build_prior_context(task, run),
              persona_guidance: build_persona_guidance(context, run),
              recipe_guidance: build_recipe_guidance(context, task, run)
            }
          }
        end

        private_class_method def self.check_dependencies(task, run)
          warnings = []
          dep_ids = task.depends_on || []
          return warnings if dep_ids.empty?

          dep_tasks = run.tasks.where(id: dep_ids)
          dep_tasks.each do |dep|
            unless dep.completed?
              warnings << "Dependency '#{dep.title}' (#{dep.id}) is #{dep.status} — not yet completed"
            end
          end

          warnings
        end

        private_class_method def self.build_spec_excerpt(task, run)
          spec = run.specification
          return "" unless spec&.content

          content = spec.content
          labels = task.labels || []
          title_words = (task.title || "").downcase.split(/\s+/)

          # Try to find a section matching the task's labels or title keywords
          sections = content.split(/^(## .+)$/)
          matched_sections = []

          sections.each_cons(2) do |header, body|
            next unless header.start_with?("## ")

            header_lower = header.downcase
            match = labels.any? { |l| header_lower.include?(l.downcase) } ||
                    title_words.any? { |w| w.length > 3 && header_lower.include?(w) }

            if match
              matched_sections << "#{header}\n#{body}"
            end
          end

          if matched_sections.any?
            matched_sections.join("\n\n").strip
          else
            # Fall back to first 30 lines of spec
            lines = content.lines
            if lines.length > 30
              lines.first(30).join + "\n... (spec truncated)"
            else
              content
            end
          end
        end

        private_class_method def self.build_prior_context(task, run)
          dep_ids = task.depends_on || []
          return "" if dep_ids.empty?

          dep_tasks = run.tasks.where(id: dep_ids).where(status: :completed)
          return "" if dep_tasks.empty?

          summaries = dep_tasks.map do |dep|
            comments = dep.result_comments || []
            summary = comments.map { |c| c["body"].to_s }.reject(&:blank?).join("\n")
            summary = "(no result comments)" if summary.blank?
            "- #{dep.title}: #{summary}"
          end

          summaries.join("\n")
        end

        private_class_method def self.build_persona_guidance(context, run)
          metadata = run.metadata || {}
          library_selections = metadata["library_selections"] || {}
          persona_name = library_selections["persona"]

          if persona_name
            manager = context.library_manager
            persona = manager.all_personas.find { |p| p.name.downcase == persona_name.downcase }
            return "#{persona.name} (#{persona.role}): #{persona.description}" if persona
          end

          # Fall back to default persona
          manager = context.library_manager
          persona = manager.find_persona(run.nl_input)
          return "" unless persona

          "#{persona.name} (#{persona.role}): #{persona.description}"
        end

        private_class_method def self.build_recipe_guidance(context, task, run)
          metadata = run.metadata || {}
          library_selections = metadata["library_selections"] || {}
          recipe_name = library_selections["recipe"]

          manager = context.library_manager
          recipe = if recipe_name
            manager.all_recipes.find { |r| r.name.downcase == recipe_name.downcase } ||
              manager.find_recipe(run.nl_input)
          else
            manager.find_recipe(run.nl_input)
          end

          return "" unless recipe

          parts = [ "#{recipe.name}: #{recipe.description}" ]

          # Include relevant sections based on task labels/tier
          if recipe.sections.any?
            task_labels = (task.labels || []).map(&:downcase)
            relevant = recipe.sections.select do |section|
              section_name = (section["name"] || section[:name]).to_s.downcase
              task_labels.any? { |l| section_name.include?(l) } ||
                section_name.include?("general") ||
                section_name.include?("setup")
            end
            relevant = recipe.sections.first(3) if relevant.empty?

            relevant.each do |section|
              name = section["name"] || section[:name]
              desc = section["description"] || section[:description]
              parts << "  - #{name}: #{desc}" if desc
            end
          end

          parts.join("\n")
        end
      end
    end
  end
end
