require 'fastlane/action'
require 'fastlane_core'
require_relative '../helper/qawolf_helper'
require_relative 'upload_to_qawolf_action'

module Fastlane
  module Actions
    module SharedValues
      QAWOLF_BUILD_ID = :QAWOLF_BUILD_ID
      QAWOLF_BUILD_IDS = :QAWOLF_BUILD_IDS
    end

    # Casing is important for the action name!
    class UploadBuildToQawolfAction < Action
      SUPPORTED_FILE_EXTENSIONS = %w[apk aab ipa]
      MAX_FILE_BYTES = 500 * 1024 * 1024
      FILE_NAME_PATTERN = /\A[A-Za-z0-9._-]{1,255}\z/

      def self.run(params)
        file_path = params[:file_path] || UploadToQawolfAction.default_file_path
        file_name = upload_file_name(file_path)
        file_size_bytes = file_size(file_path)
        environment = environment_selector(params)

        UI.message("🐺 Uploading #{file_name} (#{file_size_bytes} bytes) to QA Wolf as a build...")

        qawolf_api_key = params[:qawolf_api_key]
        qawolf_base_url = params[:qawolf_base_url]
        workspace_id = presence(params[:workspace_id])

        upload = Helper::QawolfHelper.request_build_upload(
          qawolf_api_key,
          qawolf_base_url,
          file_name: file_name,
          file_size_bytes: file_size_bytes,
          workspace_id: workspace_id
        )
        Helper::QawolfHelper.put_build_file(upload['uploadUrl'], upload['uploadHeaders'], file_path)
        build = Helper::QawolfHelper.create_build(qawolf_api_key, qawolf_base_url, {
          'branch' => presence(params[:branch]),
          'buildId' => upload['buildId'],
          'commitSha' => presence(params[:sha]),
          'environment' => environment,
          'workspaceId' => workspace_id
        }.compact)

        record_build_id(build['id'])
        report(build, environment)

        return build
      end

      # `branch` and `sha` may be `false`, meaning send nothing.
      def self.presence(value)
        return nil unless value.kind_of?(String)
        return nil if value.strip.empty?

        return value
      end

      # QA Wolf stores a build under its file name, which must be one path
      # segment of letters, digits, dots, dashes and underscores.
      def self.upload_file_name(file_path)
        UI.user_error!("🐺 `file_path` is required, unless gym or gradle built the app earlier in the lane.") unless presence(file_path)
        UI.user_error!("🐺 No file found at '#{file_path}'.") unless File.file?(file_path)
        UI.user_error!("🐺 The file at '#{file_path}' isn't readable.") unless File.readable?(file_path)

        extension = File.extname(file_path).delete_prefix('.').downcase
        unless SUPPORTED_FILE_EXTENSIONS.include?(extension)
          UI.user_error!("🐺 A build is an .apk, .aab or .ipa file, not '#{File.basename(file_path)}'.")
        end

        file_name = File.basename(file_path).tr(' ', '-')
        unless FILE_NAME_PATTERN.match?(file_name)
          UI.user_error!("🐺 Rename '#{File.basename(file_path)}': a build's file name may only hold letters, digits, dots, dashes and underscores, at most 255 characters.")
        end

        return file_name
      end

      def self.file_size(file_path)
        size = File.size(file_path)
        UI.user_error!("🐺 The file at '#{file_path}' is empty.") if size.zero?
        UI.user_error!("🐺 The file at '#{file_path}' is over 500 MB, the largest build QA Wolf accepts.") if size > MAX_FILE_BYTES

        return size
      end

      # The environment whose runs install the build from now on. An explicit
      # `environment_id` wins over a name read from QAWOLF_ENVIRONMENT.
      def self.environment_selector(params)
        check_environment_options(params)

        environment_id = presence(params[:environment_id])
        return { 'id' => environment_id } if environment_id

        return named_environment_selector(params)
      end

      def self.check_environment_options(params)
        ephemeral = params[:ephemeral_environment] == true

        if presence(params[:environment]) && presence(params[:environment_id])
          UI.user_error!("🐺 Pass either `environment` or `environment_id`, not both.")
        end
        if presence(params[:base_environment]) && !ephemeral
          UI.user_error!("🐺 `base_environment` only applies with `ephemeral_environment: true`, which creates the environment it copies.")
        end
        if ephemeral && presence(params[:environment_id])
          UI.user_error!("🐺 `ephemeral_environment` needs `environment`, not `environment_id`: an id never creates an environment.")
        end
      end

      def self.named_environment_selector(params)
        name = presence(params[:environment]) || presence(ENV.fetch("QAWOLF_ENVIRONMENT", nil))
        ephemeral = params[:ephemeral_environment] == true

        if ephemeral && name.nil?
          UI.user_error!("🐺 `ephemeral_environment` needs `environment`, the name of the preview environment to create.")
        end
        return nil if name.nil?

        return {
          'name' => name,
          'ephemeral' => ephemeral ? true : nil,
          'baseEphemeralEnvironment' => presence(params[:base_environment])
        }.compact
      end

      def self.record_build_id(build_id)
        previous_build_ids = Actions.lane_context[SharedValues::QAWOLF_BUILD_IDS] || []

        ENV["QAWOLF_BUILD_ID"] = build_id
        Actions.lane_context[SharedValues::QAWOLF_BUILD_ID] = build_id
        Actions.lane_context[SharedValues::QAWOLF_BUILD_IDS] = previous_build_ids + [build_id]
      end

      def self.report(build, environment)
        version = [build['version'], build['buildNumber'] && "(#{build['buildNumber']})"].compact.join(' ')
        UI.success("🐺 Created build #{build['id']}: #{build['appId']} #{version} for #{build['platform']}".strip)
        UI.success("🐺 Setting environment variable QAWOLF_BUILD_ID = #{build['id']}")
        UI.message("🐺 Builds: #{build['url']}") if build['url']

        if environment.nil?
          UI.important("🐺 No environment was given, so only runs and deployments that name this build install it. Pass `environment` (or set QAWOLF_ENVIRONMENT) so every later run in it does.")
        end
      end

      def self.description
        "Uploads an app build (.apk, .aab or .ipa) to QA Wolf."
      end

      def self.authors
        ["QA Wolf"]
      end

      def self.details
        "Uploads the file, then creates a QA Wolf build from it, which reads the app ID, version and build number from the file. With an environment, every later run there installs this build until a newer build of the same app and platform arrives. `notify_deploy_qawolf` reports the builds uploaded earlier in the lane with the deployment."
      end

      def self.output
        [
          ['QAWOLF_BUILD_ID', 'The ID of the uploaded build.'],
          ['QAWOLF_BUILD_IDS', 'The IDs of every build uploaded in this lane, in order. Lane context only.']
        ]
      end

      def self.return_value
        "The created build: its `id`, `appId`, `platform`, `version`, `buildNumber` and the other fields QA Wolf returns."
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
                                       description: "The QA Wolf workspace to upload into. Required with an organization or user API key; a team API key needs none",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :file_path,
                                       description: "Path to the .apk, .aab or .ipa file, at most 500 MB. Defaults to the file gym or gradle built earlier in the lane",
                                       optional: true,
                                       type: String),
          # Read from QAWOLF_ENVIRONMENT in `run`, so an explicit
          # `environment_id` can win over it.
          FastlaneCore::ConfigItem.new(key: :environment,
                                       description: "The name or alias of the QA Wolf environment whose runs install this build from now on. Defaults to QAWOLF_ENVIRONMENT, the environment `notify_deploy_qawolf` reports into. A name that matches no environment creates one",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :environment_id,
                                       description: "The ID of an existing QA Wolf environment whose runs install this build from now on. Cannot be combined with `environment`",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :ephemeral_environment,
                                       description: "When `environment` names no environment yet, create it as a preview environment, such as a pull request's. Ignored for an environment that exists",
                                       optional: true,
                                       default_value: false,
                                       type: Boolean),
          FastlaneCore::ConfigItem.new(key: :base_environment,
                                       description: "The name or alias of the environment a created preview environment copies. Requires `ephemeral_environment`",
                                       optional: true,
                                       type: String),
          FastlaneCore::ConfigItem.new(key: :branch,
                                       description: "The branch the build came from, shown with the build. Defaults to the current git branch; set it to false to send none",
                                       optional: true,
                                       default_value: Actions.git_branch,
                                       type: Object),
          FastlaneCore::ConfigItem.new(key: :sha,
                                       description: "The commit the build came from, shown with the build. Defaults to the current git commit; set it to false to send none",
                                       optional: true,
                                       default_value: Actions.last_git_commit_hash(false),
                                       type: Object)
        ]
      end

      def self.is_supported?(platform)
        [:ios, :android].include?(platform)
      end

      def self.example_code
        [
          'upload_build_to_qawolf(
            environment: "Staging"
          )',
          'upload_build_to_qawolf(
            qawolf_api_key: ENV["QAWOLF_API_KEY"],
            workspace_id: ENV["QAWOLF_WORKSPACE_ID"],
            file_path: "/path_to/app-release.apk",
            environment_id: "<ENVIRONMENT_ID>"
          )',
          'upload_build_to_qawolf(
            environment: "pr-123",
            ephemeral_environment: true,
            base_environment: "Staging"
          )'
        ]
      end
    end
  end
end
