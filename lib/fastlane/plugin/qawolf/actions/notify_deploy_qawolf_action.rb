require 'fastlane/action'
require 'fastlane_core'
require_relative '../helper/qawolf_helper'

module Fastlane
  module Actions
    module SharedValues
      QAWOLF_RUN_ID = :QAWOLF_RUN_ID
    end

    # Casing is important for the action name!
    class NotifyDeployQawolfAction < Action
      def self.run(params)
        qawolf_api_key = params[:qawolf_api_key] # Required
        qawolf_base_url = params[:qawolf_base_url]
        run_input_path = params[:run_input_path] || Actions.lane_context[SharedValues::QAWOLF_RUN_INPUT_PATH]

        if run_input_path.nil?
          UI.user_error!("🐺 No run input path found. Please run the `upload_to_qawolf` action first or set the `run_input_path` option.")
        end

        if params[:run_input_path].nil? == false && Actions.lane_context[SharedValues::QAWOLF_RUN_INPUT_PATH].nil? == false
          UI.important("🐺 Both `run_input_path` and `QAWOLF_RUN_INPUT_PATH` are set. Using `run_input_path`.")
        end

        UI.message("🐺 Calling QA Wolf deploy success webhook...")

        variables = params[:variables] || {}

        options = {
          branch: params[:branch],
          commit_url: params[:commit_url],
          deployment_type: params[:deployment_type],
          deployment_url: params[:deployment_url],
          deduplication_key: params[:deduplication_key],
          hosting_service: params[:hosting_service],
          sha: params[:sha],
          variables: variables.merge({
            RUN_INPUT_PATH: run_input_path
          })
        }

        run_id = Helper::QawolfHelper.notify_deploy(qawolf_api_key, qawolf_base_url, options)

        UI.success("🐺 QA Wolf triggered run: #{run_id}")
        UI.success("🐺 Setting environment variable QAWOLF_RUN_ID = #{run_id}")

        Actions.lane_context[SharedValues::QAWOLF_RUN_ID] = run_id
      end

      def self.description
        "Fastlane plugin for QA Wolf integration to trigger test runs."
      end

      def self.authors
        ["QA Wolf"]
      end

      def self.details
        "Calls the QA Wolf deployment success webhook to trigger test runs. Requires the `upload_to_qawolf` action to be run first."
      end

      def self.output
        [
          ['QAWOLF_RUN_ID', 'The ID of the run triggered in QA Wolf.']
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
          FastlaneCore::ConfigItem.new(key: :branch,
                                       description: "If using Git, set this to the branch name so it can be displayed in the QA Wolf UI and find any pull requests in the linked repo",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :commit_url,
                                       description: "If you do not specify a hosting service, include this and the `sha` option to ensure the commit hash is a clickable link in QA Wolf",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :deduplication_key,
                                       description: "By default, new runs will cancel ongoing runs if the `branch` and `environment` combination is matched, so setting this will instead cancel runs that have the same key",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :deployment_type,
                                       description: "Arbitrary string to describe the deployment type. Configured in the QA Wolf UI when creating deployment triggers",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :deployment_url,
                                       description: "When set, will be available as `process.env.URL` in tests",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :hosting_service,
                                       description: "GitHub, GitLab, etc. Must be configured in QA Wolf",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :sha,
                                       description: "If a Git commit triggered this, include the commit hash so that we can create commit checks if you also have a GitHub repo linked. Also displayed in the QA Wolf UI",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :variables,
                                       description: "Optional key-value pairs to pass to the test run. These will be available as `process.env` in tests",
                                       optional: true,
                                       type: Object),
          FastlaneCore::ConfigItem.new(key: :run_input_path,
                                       env_name: "QAWOLF_RUN_INPUT_PATH",
                                       description: "The path of the run input file to run in QA Wolf. Set by the `upload_to_qawolf` action",
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
          'notify_deploy_qawolf',
          'notify_deploy_qawolf(
            qawolf_api_key: ENV["QAWOLF_API_KEY"],
            branch: "<BRANCH_NAME>",
            commit_url: "<URL>",
            deployment_type: "<DEPLOYMENT_TYPE>",
            deployment_url: "<URL>",
            hosting_service: "GitHub|GitLab",
            sha: "<SHA>"
           )'
        ]
      end
    end
  end
end
