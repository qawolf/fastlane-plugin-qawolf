require 'fastlane/action'
require 'fastlane_core'
require 'securerandom'
require_relative '../helper/qawolf_helper'

module Fastlane
  module Actions
    module SharedValues
      QAWOLF_DEPLOYMENT_ID = :QAWOLF_DEPLOYMENT_ID
      QAWOLF_ENVIRONMENT_RUNS_URL = :QAWOLF_ENVIRONMENT_RUNS_URL
    end

    # Casing is important for the action name!
    class NotifyDeployQawolfAction < Action
      BASE_PATH = "/home/wolf/run-inputs-executables/"
      STATUSES = %w[pending success failure inactive]

      REMOVED_OPTIONS = {
        deployment_type: "`deployment_type` was removed in 1.0.0. Use `environment` instead, and check the value: `environment` must name an existing QA Wolf environment (its name or one of its aliases), because a name that matches nothing creates a new environment.",
        deduplication_key: "`deduplication_key` was removed in 1.0.0. A deployment is now identified by `provider_deployment_id`, which is derived from your CI environment and can be set explicitly.",
        deployment_url: "`deployment_url` was removed in 1.0.0. Use `deploy_target` instead, which must be an http(s) URL.",
        hosting_service: "`hosting_service` was removed in 1.0.0. QA Wolf resolves the code host from the linked repository, so pass `repository` as `owner/name` instead.",
        repository_name: "`repository_name` was removed in 1.0.0. Pass a single `repository` instead, e.g. `my-org/my-app`.",
        repository_owner: "`repository_owner` was removed in 1.0.0. Pass a single `repository` instead, e.g. `my-org/my-app`.",
        repository_namespace: "`repository_namespace` was removed in 1.0.0. Pass a single `repository` instead, e.g. `my-group/my-subgroup/my-app`."
      }

      def self.run(params)
        reject_removed_options(params)

        qawolf_api_key = params[:qawolf_api_key] # Required
        qawolf_base_url = params[:qawolf_base_url]

        UI.message("🐺 Reporting the deployment to QA Wolf...")

        options = {
          branch: presence(params[:branch]),
          commit_author_name: presence(params[:commit_author_name]),
          commit_message: presence(params[:commit_message]),
          commit_url: presence(params[:commit_url]),
          deploy_target: deploy_target(params),
          environment: environment(params),
          environment_variables: environment_variables(params),
          provider_deployment_id: provider_deployment_id(params),
          pull_request_number: pull_request_number(params),
          repository: repository(params),
          service: presence(params[:service]),
          sha: presence(params[:sha]),
          status: status(params),
          workspace_id: workspace_id(params)
        }

        deployment = Helper::QawolfHelper.report_deployment(qawolf_api_key, qawolf_base_url, options)

        deployment_id = deployment["id"]
        runs_url = deployment["url"]

        ENV["QAWOLF_DEPLOYMENT_ID"] = deployment_id
        Actions.lane_context[SharedValues::QAWOLF_DEPLOYMENT_ID] = deployment_id

        UI.success("🐺 QA Wolf recorded deployment #{deployment_id} as #{deployment['status']}")
        UI.success("🐺 Setting environment variable QAWOLF_DEPLOYMENT_ID = #{deployment_id}")
        UI.message("🐺 Runs matching your triggers start asynchronously, they are not part of this response.")

        if runs_url
          ENV["QAWOLF_ENVIRONMENT_RUNS_URL"] = runs_url
          Actions.lane_context[SharedValues::QAWOLF_ENVIRONMENT_RUNS_URL] = runs_url
          UI.message("🐺 Runs for this environment: #{runs_url}")
        end

        return deployment_id
      end

      def self.reject_removed_options(params)
        REMOVED_OPTIONS.each do |key, message|
          UI.user_error!("🐺 #{message}") unless params[key].nil?
        end
      end

      # Values reach the action either through a Fastlane configuration or as a
      # plain hash, and `branch` and `sha` may be `false` to send nothing.
      def self.presence(value)
        return nil unless value.kind_of?(String)
        return nil if value.strip.empty?

        return value
      end

      def self.workspace_id(params)
        workspace_id = presence(params[:workspace_id])
        if workspace_id.nil?
          UI.user_error!("🐺 `workspace_id` is required. Find it in the QA Wolf UI, or call `whoami` with your API key.")
        end

        return workspace_id
      end

      def self.environment(params)
        environment = presence(params[:environment])
        if environment.nil?
          UI.user_error!("🐺 `environment` is required. It must name an existing QA Wolf environment (its name or one of its aliases), because a name that matches nothing creates a new environment.")
        end

        return environment
      end

      def self.status(params)
        status = presence(params[:status]) || "success"
        unless STATUSES.include?(status)
          UI.user_error!("🐺 `status` must be one of #{STATUSES.join(', ')}.")
        end

        return status
      end

      def self.deploy_target(params)
        deploy_target = presence(params[:deploy_target])
        return nil if deploy_target.nil?

        unless deploy_target.start_with?("http://", "https://")
          UI.user_error!("🐺 `deploy_target` must be an http or https URL.")
        end

        return deploy_target
      end

      def self.repository(params)
        repository = presence(params[:repository])
        return nil if repository.nil?

        # A GitLab project in a subgroup has more than two segments.
        segments = repository.split("/", -1)
        unless segments.length >= 2 && segments.none? { |segment| segment.strip.empty? }
          UI.user_error!("🐺 `repository` must be the repository's full path, e.g. `my-org/my-app` or `my-group/my-subgroup/my-app`.")
        end

        return repository
      end

      # A GitLab merge request number is reported through the same field as a
      # GitHub pull request number.
      def self.pull_request_number(params)
        number = params[:pull_request_number] || params[:merge_request_number]
        return nil if number.nil?

        if repository(params).nil?
          UI.user_error!("🐺 `repository` is required alongside `pull_request_number` or `merge_request_number`, because a request number only names a request within one repository.")
        end

        return number.to_i
      end

      def self.environment_variables(params)
        variables = params[:variables] || {}
        executable_environment_key = params[:executable_environment_key]

        variables
          .merge({ executable_environment_key => run_input_path(params) })
          .each_with_object({}) { |(key, value), result| result[key.to_s] = value.to_s }
      end

      # A deployment's identity: reports sharing one update a single deployment.
      def self.provider_deployment_id(params)
        explicit = presence(params[:provider_deployment_id])
        discriminator = presence(params[:provider_deployment_discriminator])

        if !explicit.nil? && !discriminator.nil?
          UI.user_error!("🐺 Pass either `provider_deployment_id` or `provider_deployment_discriminator`, not both. The discriminator only separates the identifiers the plugin derives.")
        end

        return explicit unless explicit.nil?

        detected = Helper::QawolfHelper.detect_provider_deployment_id(ENV, discriminator)
        return detected unless detected.nil?

        generated = "fastlane-#{SecureRandom.uuid}"
        UI.important("🐺 No supported CI system was detected, so this deployment is reported under a generated id: #{generated}. Set `provider_deployment_id` to control it.")
        return generated
      end

      def self.run_input_path(params)
        if params[:executable_filename].nil?
          UI.user_error!("🐺 No executable filename found. Please run the `upload_to_qawolf` action first or set the `executable_filename` option.")
        end

        return "#{BASE_PATH}#{params[:executable_filename]}"
      end

      def self.description
        "Fastlane plugin for QA Wolf integration to report deployments."
      end

      def self.authors
        ["QA Wolf"]
      end

      def self.details
        "Reports a deployment to QA Wolf through the public `deployment.reportStatus` API, which evaluates your triggers and starts the matching runs asynchronously. Requires the `upload_to_qawolf` action to be run first."
      end

      def self.output
        [
          ['QAWOLF_DEPLOYMENT_ID', 'The ID of the deployment reported to QA Wolf.'],
          ['QAWOLF_ENVIRONMENT_RUNS_URL', "The URL of the environment's runs page in QA Wolf."]
        ]
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :qawolf_api_key,
                                       env_name: "QAWOLF_API_KEY",
                                       description: "Your QA Wolf API key",
                                       optional: false,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :qawolf_base_url,
                                       env_name: "QAWOLF_BASE_URL",
                                       description: "Your QA Wolf base URL",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :workspace_id,
                                       env_name: "QAWOLF_WORKSPACE_ID",
                                       description: "The QA Wolf workspace to report the deployment into. Required, even with a team API key",
                                       optional: false,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :environment,
                                       env_name: "QAWOLF_ENVIRONMENT",
                                       description: "The name or alias of the QA Wolf environment the deployment reports into. A value that matches no environment creates one, so check it against the environments in your workspace",
                                       optional: false,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :provider_deployment_id,
                                       description: "Your own identifier for this deployment. Defaults to an identifier derived from the CI system's environment variables, and to a generated identifier when no supported CI system is detected. Two reports sharing one identifier update a single deployment, and only the first `success` report evaluates triggers",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :provider_deployment_discriminator,
                                       description: "Appended to the identifier the plugin derives, to tell apart deployments made at the same time by one CI job, such as the legs of a build matrix. No CI system exposes which leg is running, so pass the platform or whatever else separates them. Cannot be combined with `provider_deployment_id`",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :status,
                                       description: "The deployment lifecycle status: `pending`, `success`, `failure` or `inactive`. Defaults to `success`, which is the status that evaluates triggers",
                                       optional: true,
                                       default_value: "success",
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :deploy_target,
                                       description: "The http(s) URL the deployment serves. Required when `environment` names no existing environment, because the created environment serves it",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :service,
                                       description: "Which application was deployed, e.g. `checkout-api`, when several services deploy into one environment",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :executable_environment_key,
                                       description: "Sets the environment key to use for the executable. Will alias the executable file's absolute path in tests to, for example, `process.env.RUN_INPUT_PATH` Defaults to `RUN_INPUT_PATH`",
                                       optional: true,
                                       default_value: "RUN_INPUT_PATH",
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :branch,
                                       description: "Defaults to the current git branch if available. Override by providing a custom value, or set it to false to send an empty value. Displayed in the QA Wolf UI to help find any pull requests in the linked repo",
                                       optional: true,
                                       default_value: Actions.git_branch,
                                       type: Object),
          FastlaneCore::ConfigItem.new(key: :commit_url,
                                       description: "A link to the deployed commit in your code host. Send this when QA Wolf cannot resolve the commit itself, for example when the QA Wolf GitHub App is not installed",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :commit_message,
                                       description: "The message of the deployed commit. The QA Wolf deployments list shows its first line",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :commit_author_name,
                                       description: "The display name of the person who authored the deployed commit",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :sha,
                                       description: "Defaults to the current git commit hash. Override by providing a custom value, or set to false to send an empty value. We use it to create commit checks if you also have a GitHub repo linked. Also displayed in the QA Wolf UI",
                                       optional: true,
                                       default_value: Actions.last_git_commit_hash(false),
                                       type: Object),
          FastlaneCore::ConfigItem.new(key: :variables,
                                       description: "Optional key-value pairs to pass to the runs this deployment requests. These will be available as `process.env` in tests, and replace the values a previous report stored",
                                       optional: true,
                                       default_value: {},
                                       type: Hash),
          FastlaneCore::ConfigItem.new(key: :repository,
                                       description: "The repository the deployed commit lives in, as its full path: `my-org/my-app` on GitHub, `my-group/my-subgroup/my-app` for a GitLab project in a subgroup. Required alongside `pull_request_number` or `merge_request_number`",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :pull_request_number,
                                       description: "The GitHub pull request number associated with this deployment. Requires `repository`",
                                       optional: true,
                                       type: Integer),
          FastlaneCore::ConfigItem.new(key: :merge_request_number,
                                       description: "The GitLab merge request number associated with this deployment. Requires `repository`",
                                       optional: true,
                                       type: Integer),
          FastlaneCore::ConfigItem.new(key: :executable_filename,
                                       env_name: "QAWOLF_EXECUTABLE_FILENAME",
                                       description: "The filename of the executable to use in QA Wolf. Set by the `upload_to_qawolf` action",
                                       optional: true,
                                       type: String),
          # Removed options, still declared so an unchanged 0.x lane fails with
          # an explanation rather than with "Could not find option".
          FastlaneCore::ConfigItem.new(key: :deployment_type,
                                       description: "Removed in 1.0.0, use `environment`",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :deduplication_key,
                                       description: "Removed in 1.0.0, use `provider_deployment_id`",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :deployment_url,
                                       description: "Removed in 1.0.0, use `deploy_target`",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :hosting_service,
                                       description: "Removed in 1.0.0, QA Wolf resolves the code host from `repository`",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :repository_name,
                                       description: "Removed in 1.0.0, use `repository`",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :repository_owner,
                                       description: "Removed in 1.0.0, use `repository`",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :repository_namespace,
                                       description: "Removed in 1.0.0, use `repository`",
                                       optional: true,
                                       type: String)
        ]
      end

      def self.is_supported?(platform)
        # Adjust this if your plugin only works for a particular platform (iOS vs. Android, for example)
        # See: https://docs.fastlane.tools/advanced/#control-configuration-by-lane-and-by-platform
        [:ios, :android].include?(platform)
      end

      def self.example_code
        [
          'notify_deploy_qawolf(
            qawolf_api_key: ENV["QAWOLF_API_KEY"],
            workspace_id: ENV["QAWOLF_WORKSPACE_ID"],
            environment: "Staging"
           )',
          'notify_deploy_qawolf(
            qawolf_api_key: ENV["QAWOLF_API_KEY"],
            workspace_id: ENV["QAWOLF_WORKSPACE_ID"],
            environment: "Staging",
            executable_environment_key: "MY_APP",
            executable_filename: "<FILENAME>",
            provider_deployment_id: "<UNIQUE_PER_BUILD_ID>",
            branch: "<BRANCH_NAME>",
            commit_url: "<URL>",
            repository: "my-org/my-app",
            pull_request_number: 123,
            sha: "<SHA>"
           )'
        ]
      end
    end
  end
end
