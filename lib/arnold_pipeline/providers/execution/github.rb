require "octokit"
require_relative "base"

module ArnoldPipeline
  module Providers
    module Execution
      class Github < Base
        def initialize(token:, repo:, issue_mention: nil)
          @client = Octokit::Client.new(access_token: token)
          @client.auto_paginate = true
          @repo = repo
          @issue_mention = issue_mention
        end

        def async?
          true
        end

        def recoverable_errors
          [ Octokit::Error, Faraday::Error ]
        end

        def self.validate_configuration!(config)
          if config.github_token.nil? || config.github_token.empty?
            raise ConfigurationError, "GitHub token is required when using GitHub execution provider. Set github_token or GITHUB_TOKEN env var."
          end

          if config.github_repo.nil? || config.github_repo.empty?
            raise ConfigurationError, "GitHub repo is required when using GitHub execution provider (e.g., 'owner/repo')."
          end
        end

        def self.build_from_config(config, **options)
          new(
            token: options[:token] || config.github_token,
            repo: options[:repo] || config.github_repo,
            issue_mention: options[:issue_mention] || config.github_issue_mention
          )
        end

        def create_tasks(tasks:, pipeline_run:, prior_context: nil)
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
              build_issue_body(description, pipeline_run, dependencies: dep_refs, prior_context:),
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

        def fetch_results(pipeline_run:, tasks: nil)
          (tasks || pipeline_run.tasks).map do |task|
            next unless task.external_id

            issue_number = task.external_id.to_i
            issue = @client.issue(@repo, issue_number)
            issue_state = issue.state

            pulls = @client.pull_requests(@repo, state: "all", per_page: 100).select do |pr|
              pr.body&.include?("##{task.external_id}") ||
                pr.title&.include?("##{task.external_id}")
            end

            diffs = pulls.map do |pr|
              files = @client.pull_request_files(@repo, pr.number)
              files.map { |f| { filename: f.filename, patch: f.patch, status: f.status } }
            end.flatten

            comments = fetch_comments(issue_number, pulls)

            workflow_active, workflow_details = if ArnoldPipeline.configuration.workflow_status_enabled
              check_workflows_active?(issue_number, pulls)
            else
              [ false, "disabled" ]
            end

            {
              task_id: task.id,
              external_id: task.external_id,
              diffs: diffs,
              comments: comments,
              issue_state: issue_state,
              status: determine_status(pulls, issue_state:),
              workflow_active: workflow_active,
              workflow_details: workflow_details
            }
          end.compact
        end

        def merge_results(pipeline_run:, tasks: nil)
          merged = []
          (tasks || pipeline_run.tasks).each do |task|
            next unless task.external_id

            pulls = @client.pull_requests(@repo, state: "open", per_page: 100).select do |pr|
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

        def build_issue_body(description, pipeline_run, dependencies: [], prior_context: nil)
          body = description.to_s.dup
          if prior_context.present?
            body << "\n\n#{prior_context}"
          end
          if @issue_mention
            body << "\n\n#{@issue_mention}"
          end
          if dependencies.any?
            body << "\n\n**Depends on:** #{dependencies.join(', ')}"
          end
          body << "\n\n---\n_Pipeline Run ##{pipeline_run.id}_"
          body
        end

        def fetch_comments(issue_number, pulls)
          comments = []

          @client.issue_comments(@repo, issue_number).each do |c|
            comments << { source: "issue", author: c.user.login, body: c.body, created_at: c.created_at.to_s }
          end

          pulls.each do |pr|
            @client.pull_request_comments(@repo, pr.number).each do |c|
              comments << { source: "pr_review", author: c.user.login, body: c.body, created_at: c.created_at.to_s }
            end
          end

          comments
        end

        def check_workflows_active?(issue_number, pulls)
          # Strategy 1: Check runs on PR head commits
          pulls.each do |pr|
            next unless pr.respond_to?(:head) && pr.head&.respond_to?(:sha)

            check_runs = @client.check_runs_for_ref(@repo, pr.head.sha)
            runs = check_runs.respond_to?(:check_runs) ? check_runs.check_runs : []
            active_runs = runs.select { |run| %w[queued in_progress].include?(run.status) }
            if active_runs.any?
              details = active_runs.map { |r| "#{r.name}(#{r.status})" }.join(", ")
              return [ true, "PR ##{pr.number} check runs: #{details}" ]
            end
          end

          # Strategy 2: Match workflow runs by branch name containing issue number
          pattern = ArnoldPipeline.configuration.workflow_branch_pattern
          %w[in_progress queued].each do |status|
            workflow_runs = @client.repository_workflow_runs(@repo, status:)
            runs = workflow_runs.respond_to?(:workflow_runs) ? workflow_runs.workflow_runs : []
            matching = runs.select { |run| run.head_branch&.match?(pattern) && run.head_branch.match?(/#{issue_number}/) }
            if matching.any?
              details = matching.map { |r| "#{r.head_branch}(#{r.status})" }.join(", ")
              return [ true, "branch workflow runs: #{details}" ]
            end
          end

          [ false, "no active workflows" ]
        rescue Octokit::Error, Faraday::Error => e
          [ false, "error: #{e.message}" ]
        end

        def determine_status(pulls, issue_state: "open")
          if pulls.empty?
            return :failed if issue_state == "closed"
            return :pending
          end

          return :completed if pulls.all? { |pr| pr.merged_at || pr.state == "closed" }

          :in_progress
        end
      end

      register(:github, Github)
    end
  end
end
