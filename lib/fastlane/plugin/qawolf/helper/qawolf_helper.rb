require 'fastlane_core/ui/ui'
require 'rest-client'
require 'uri'

module Fastlane
  UI = FastlaneCore::UI unless Fastlane.const_defined?(:UI)

  module Helper
    class QawolfHelper
      BASE_URL = "https://app.qawolf.com"
      SIGNED_URL_ENDPOINT = "/api/v0/run-inputs-executables-signed-urls"
      REPORT_DEPLOYMENT_ENDPOINT = "/api/trpc/public.deployment.reportStatus"

      # The CI systems the public QA Wolf CI SDK derives a deployment identity
      # from, in the same order and from the same variables, so a fastlane build
      # and a CI SDK invocation of the same job agree on the deployment.
      CI_SYSTEMS = [
        # GITHUB_RUN_ID is stable across re-runs and GITHUB_RUN_ATTEMPT
        # increments, and both are shared by every job in the workflow, so
        # GITHUB_JOB separates jobs that deploy in parallel.
        { name: "GitHub Actions", active: "GITHUB_ACTIONS", variables: %w[GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_JOB] },
        # Retrying a job keeps the pipeline id and mints a new job id.
        { name: "GitLab CI", active: "GITLAB_CI", variables: %w[CI_PIPELINE_ID CI_JOB_ID] },
        # A rerun keeps the workflow id and allocates a new build number.
        { name: "CircleCI", active: "CIRCLECI", variables: %w[CIRCLE_WORKFLOW_ID CIRCLE_BUILD_NUM] },
        # The build id covers the whole build, so the job id separates the jobs
        # within it and the retry count separates a job's retries.
        { name: "Buildkite", active: "BUILDKITE", variables: %w[BUILDKITE_BUILD_ID BUILDKITE_JOB_ID BUILDKITE_RETRY_COUNT] },
        # BUILD_TAG is `jenkins-${JOB_NAME}-${BUILD_NUMBER}`, and Jenkins
        # allocates a fresh build number for every externally visible re-run.
        { name: "Jenkins", active: "JENKINS_URL", variables: %w[BUILD_TAG] },
        { name: "Jenkins", active: "JENKINS_HOME", variables: %w[BUILD_TAG] },
        # Rerunning a whole pipeline mints a new build number, but rerunning
        # only the failed steps keeps it and increments the step's run number.
        { name: "Bitbucket Pipelines", active: "BITBUCKET_BUILD_NUMBER", variables: %w[BITBUCKET_BUILD_NUMBER BITBUCKET_STEP_UUID BITBUCKET_STEP_RUN_NUMBER] }
      ]

      def self.get_signed_url(qawolf_api_key, qawolf_base_url, filename)
        headers = {
          user_agent: "qawolf_fastlane_plugin",
          authorization: "Bearer #{qawolf_api_key}"
        }

        url = URI.join(qawolf_base_url || BASE_URL, SIGNED_URL_ENDPOINT)
        url.query = URI.encode_www_form({ 'file' => filename })

        response = RestClient.get(url.to_s, headers)

        response_json = JSON.parse(response.to_s)

        return [
          response_json["signedUrl"],
          response_json["playgroundFileLocation"]
        ]
      end

      # Uploads file to QA Wolf
      # Params :
      # +qawolf_api_key+:: QA Wolf API key
      # +qawolf_base_url+:: QA Wolf API base URL
      # +file_path+:: Path to the file to be uploaded.
      # +executable_file_basename+:: Name to use for the uploaded file without extension
      def self.upload_file(qawolf_api_key, qawolf_base_url, file_path, executable_file_basename)
        unless executable_file_basename
          UI.user_error!("`executable_file_basename` is required")
        end

        run_input_path = nil
        File.open(file_path, "rb") do |file_content|
          headers = {
            user_agent: "qawolf_fastlane_plugin",
            content_type: "application/octet-stream"
          }

          uploaded_filename = "#{executable_file_basename}#{File.extname(file_path)}"
          signed_url, run_input_path = get_signed_url(qawolf_api_key, qawolf_base_url, uploaded_filename)

          RestClient.put(signed_url, file_content, headers)
        end
        run_input_path
      rescue RestClient::ExceptionWithResponse => e
        begin
          error_response = e.response.to_s
        rescue StandardError
          error_response = "Internal server error"
        end
        # Give error if upload failed.
        UI.user_error!("App upload failed!!! Reason : #{error_response}")
      rescue StandardError => e
        UI.user_error!("App upload failed!!! Reason : #{e.message}")
      end

      # An identity for the deployment, composed from the CI system's own
      # variables. Nil when no supported CI system is running, or when the one
      # that is did not expose every variable the identity is composed from.
      def self.detect_provider_deployment_id(env)
        system = CI_SYSTEMS.find { |candidate| present?(env[candidate[:active]]) }
        return nil if system.nil?

        values = system[:variables].map { |name| env[name] }
        return nil if values.any? { |value| !present?(value) }

        return values.join("-")
      end

      def self.present?(value)
        value.kind_of?(String) && !value.strip.empty?
      end

      # The `deployment.reportStatus` input, wrapped in the envelope the API
      # reads it from.
      def self.report_deployment_body(options)
        metadata = {
          'commitAuthorName' => options[:commit_author_name],
          'commitMessage' => options[:commit_message],
          'commitSha' => options[:sha],
          'commitUrl' => options[:commit_url],
          'pullRequestNumber' => options[:pull_request_number],
          'ref' => options[:branch],
          'repository' => options[:repository]
        }.compact

        input = {
          'deployTarget' => options[:deploy_target],
          'environment' => options[:environment] ? { 'name' => options[:environment] } : nil,
          'environmentVariables' => options[:environment_variables],
          'metadata' => metadata.empty? ? nil : metadata,
          'providerDeploymentId' => options[:provider_deployment_id],
          'service' => options[:service],
          'status' => options[:status],
          'workspaceId' => options[:workspace_id]
        }.compact

        { 'json' => input }.to_json
      end

      # The reported deployment, as `{ "id", "status", "url" }`.
      def self.parse_report_response(response)
        body = JSON.parse(response.to_s)
        data = body.kind_of?(Hash) ? body.dig('result', 'data') : nil
        # The API wraps a payload that needs it in a `json` envelope.
        payload = data.kind_of?(Hash) && data.key?('json') ? data['json'] : data
        deployment = payload.kind_of?(Hash) ? payload['deployment'] : nil

        unless deployment.kind_of?(Hash) && present?(deployment['id'])
          raise "the response did not contain a deployment"
        end

        return deployment
      end

      # Reports a deployment status to QA Wolf, which evaluates the workspace's
      # triggers and starts runs asynchronously.
      # Params :
      # +qawolf_api_key+:: QA Wolf API key
      # +qawolf_base_url+:: QA Wolf API base URL
      # +options+:: Options hash containing deployment details.
      def self.report_deployment(qawolf_api_key, qawolf_base_url, options)
        headers = {
          authorization: "Bearer #{qawolf_api_key}",
          user_agent: "qawolf_fastlane_plugin",
          content_type: "application/json"
        }

        url = URI.join(qawolf_base_url || BASE_URL, REPORT_DEPLOYMENT_ENDPOINT)

        response = RestClient.post(url.to_s, report_deployment_body(options), headers)

        return parse_report_response(response)
      rescue RestClient::ExceptionWithResponse => e
        begin
          error_response = e.response.to_s
        rescue StandardError
          error_response = "Internal server error"
        end
        # Give error if request failed.
        UI.user_error!("Failed to report deployment!!! Request failed. Reason : #{error_response}")
      rescue StandardError => e
        UI.user_error!("Failed to report deployment!!! Something went wrong. Reason : #{e.message}")
      end
    end
  end
end
