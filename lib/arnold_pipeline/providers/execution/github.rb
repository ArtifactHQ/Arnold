require "octokit"
require_relative "base"

module ArnoldPipeline
  module Providers
    module Execution
      class Github < Base
        def initialize(token:, repo:, issue_mention: nil)
          @client = Octokit::Client.new(access_token: token)
          @repo = repo
          @issue_mention = issue_mention
        end

        def create_tasks(tasks:, pipeline_run:)
          position_to_issue = {}

          tasks.map do |task|
            labels = task.respond_to?(:labels) ? (task.labels || []) : (task["labels"] || [])
            title = task.respond_to?(:title) ? task.title : task["title"]
            description = task.respond_to?(:description) ? task.description : task["description"]
            position = task.respond_to?(:position) ? task.position : task["position"]
            depends_on = task.respond_to?(:depends_on) ? (task.depends_on || []) : (task["depends_on"] || [])

            dep_refs = depends_on.filter_map { |pos| position_to_issue[pos] }
                                 .map { |num| "##{num}" }

            issue = @client.create_issue(
              @repo,
              title,
              build_issue_body(description, pipeline_run, dependencies: dep_refs),
              labels: labels.map(&:to_s)
            )

            position_to_issue[position] = issue.number

            {
              external_id: issue.number.to_s,
              external_url: issue.html_url,
              title: title
            }
          end
        end

        def fetch_results(pipeline_run:)
          pipeline_run.tasks.map do |task|
            next unless task.external_id

            pulls = @client.pull_requests(@repo, state: "all").select do |pr|
              pr.body&.include?("##{task.external_id}") ||
                pr.title&.include?("##{task.external_id}")
            end

            diffs = pulls.map do |pr|
              files = @client.pull_request_files(@repo, pr.number)
              files.map { |f| { filename: f.filename, patch: f.patch, status: f.status } }
            end.flatten

            {
              task_id: task.id,
              external_id: task.external_id,
              diffs: diffs,
              status: determine_status(pulls)
            }
          end.compact
        end

        def merge_results(pipeline_run:)
          merged = []
          pipeline_run.tasks.each do |task|
            next unless task.external_id

            pulls = @client.pull_requests(@repo, state: "open").select do |pr|
              pr.body&.include?("##{task.external_id}") ||
                pr.title&.include?("##{task.external_id}")
            end

            pulls.each do |pr|
              if @client.merge_pull_request(@repo, pr.number)
                merged << { pr_number: pr.number, task_id: task.id }
              end
            end
          end
          merged
        end

        private

        def build_issue_body(description, pipeline_run, dependencies: [])
          body = description.to_s.dup
          if @issue_mention
            body << "\n\n#{@issue_mention}"
          end
          if dependencies.any?
            body << "\n\n**Depends on:** #{dependencies.join(', ')}"
          end
          body << "\n\n---\n_Pipeline Run ##{pipeline_run.id}_"
          body
        end

        def determine_status(pulls)
          return :pending if pulls.empty?
          return :completed if pulls.all? { |pr| pr.merged_at || pr.state == "closed" }

          :in_progress
        end
      end
    end
  end
end
