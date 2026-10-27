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
      REQUEST_BUILD_UPLOAD_ENDPOINT = "/api/trpc/public.build.requestUpload"
      CREATE_BUILD_ENDPOINT = "/api/trpc/public.build.create"
      # Matches the QA Wolf CI SDK: a 500 MB build on a slow connection outlasts
      # RestClient's default timeout.
      BUILD_UPLOAD_TIMEOUT_SECONDS = 30 * 60

      # Mirrors the QA Wolf CI SDK, so a fastlane build and an SDK call in the
      # same job agree on the deployment. Bitrise and Azure Pipelines are
      # fastlane-only additions.
      CI_SYSTEMS = [
        # The run id is stable across re-runs and the attempt increments, and
        # both are shared by every job, so the job name separates the jobs.
        { name: "GitHub Actions", active: "GITHUB_ACTIONS", variables: %w[GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_JOB] },
        # Retrying a job keeps the pipeline id and mints a new job id.
        { name: "GitLab CI", active: "GITLAB_CI", variables: %w[CI_PIPELINE_ID CI_JOB_ID] },
        # A rerun keeps the workflow id and allocates a new build number.
        { name: "CircleCI", active: "CIRCLECI", variables: %w[CIRCLE_WORKFLOW_ID CIRCLE_BUILD_NUM] },
        # Build id covers the whole build; job id separates jobs, retry count separates retries.
        { name: "Buildkite", active: "BUILDKITE", variables: %w[BUILDKITE_BUILD_ID BUILDKITE_JOB_ID BUILDKITE_RETRY_COUNT] },
        # BUILD_TAG is `jenkins-${JOB_NAME}-${BUILD_NUMBER}`, and Jenkins
        # allocates a fresh build number for every visible re-run.
        { name: "Jenkins", active: "JENKINS_URL", variables: %w[BUILD_TAG] },
        { name: "Jenkins", active: "JENKINS_HOME", variables: %w[BUILD_TAG] },
        # Rerunning a whole pipeline mints a new build number, but rerunning
        # only the failed steps keeps it and increments the step's run number.
        { name: "Bitbucket Pipelines", active: "BITBUCKET_BUILD_NUMBER", variables: %w[BITBUCKET_BUILD_NUMBER BITBUCKET_STEP_UUID BITBUCKET_STEP_RUN_NUMBER] },
        # The build slug identifies one build run; a rebuild gets a new slug.
        { name: "Bitrise", active: "BITRISE_IO", variables: %w[BITRISE_BUILD_SLUG] },
        # The job id is unique per job attempt, but only within its pipeline,
        # so the build id qualifies it.
        { name: "Azure Pipelines", active: "TF_BUILD", variables: %w[BUILD_BUILDID SYSTEM_JOBID] }
      ]

      # The upload URL for an executable. An organization or user API key
      # reaches several workspaces, so it names one with `workspace_id`; a
      # team API key implies its workspace and needs none.
      def self.signed_url_endpoint(qawolf_base_url, filename, workspace_id = nil)
        url = URI.join(qawolf_base_url || BASE_URL, SIGNED_URL_ENDPOINT)
        query = { 'file' => filename }
        query['workspaceId'] = workspace_id if present?(workspace_id)
        url.query = URI.encode_www_form(query)
        return url
      end

      def self.get_signed_url(qawolf_api_key, qawolf_base_url, filename, workspace_id = nil)
        headers = {
          user_agent: "qawolf_fastlane_plugin",
          authorization: "Bearer #{qawolf_api_key}"
        }

        url = signed_url_endpoint(qawolf_base_url, filename, workspace_id)

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
      # +workspace_id+:: QA Wolf workspace to upload into, for organization and user API keys
      def self.upload_file(qawolf_api_key, qawolf_base_url, file_path, executable_file_basename, workspace_id = nil)
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
          signed_url, run_input_path = get_signed_url(qawolf_api_key, qawolf_base_url, uploaded_filename, workspace_id)

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
      # variables, with `discriminator` appended after a colon when given. Nil
      # when no supported CI system is running, or when the one that is did not
      # expose every variable the identity is composed from.
      def self.detect_provider_deployment_id(env, discriminator = nil)
        system = CI_SYSTEMS.find { |candidate| present?(env[candidate[:active]]) }
        return nil if system.nil?

        values = system[:variables].map { |name| env[name] }
        return nil if values.any? { |value| !present?(value) }

        composed = values.join("-")
        # A colon separates the discriminator because a job id can itself
        # contain a hyphen, so joining with one would let job "deploy-web"
        # collide with job "deploy" discriminated by "web".
        return present?(discriminator) ? "#{composed}:#{discriminator}" : composed
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
          'builds' => options[:builds],
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

      # The payload of a successful public API call, unwrapped from its envelope.
      def self.parse_result(response)
        body = JSON.parse(response.to_s)
        data = body.kind_of?(Hash) ? body.dig('result', 'data') : nil
        # The API wraps a payload that needs it in a `json` envelope.
        return data.kind_of?(Hash) && data.key?('json') ? data['json'] : data
      end

      # The reported deployment, as `{ "id", "status", "url" }`.
      def self.parse_report_response(response)
        payload = parse_result(response)
        deployment = payload.kind_of?(Hash) ? payload['deployment'] : nil

        unless deployment.kind_of?(Hash) && present?(deployment['id'])
          raise "the response did not contain a deployment"
        end

        return deployment
      end

      # The error the API refused with, unwrapped from the `json` envelope when
      # it has one. Nil for a body that carries no error, such as a proxy's.
      def self.report_error(response)
        body = JSON.parse(response.to_s)
        error = body.kind_of?(Hash) ? body['error'] : nil
        return nil unless error.kind_of?(Hash)

        return error['json'].kind_of?(Hash) ? error['json'] : error
      rescue StandardError
        return nil
      end

      # A refusal from the API, as one sentence plus the event id to quote to
      # QA Wolf support.
      def self.report_error_message(response)
        error = report_error(response)
        return response.to_s if error.nil?

        data = error['data']
        event_id = data.kind_of?(Hash) ? data['eventId'] : nil
        message = present?(error['message']) ? error['message'] : response.to_s

        return present?(event_id) ? "#{message} (Event ID: #{event_id})" : message
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
          error_response = report_error_message(e.response)
        rescue StandardError
          error_response = "Internal server error"
        end
        UI.user_error!("🐺 QA Wolf refused the deployment report: #{error_response}")
      rescue StandardError => e
        UI.user_error!("🐺 Failed to report the deployment to QA Wolf: #{e.message}")
      end

      # Asks QA Wolf for a URL to upload a build file to, as
      # `{ "buildId", "expiresAt", "uploadHeaders", "uploadUrl" }`.
      def self.request_build_upload(qawolf_api_key, qawolf_base_url, file_name:, file_size_bytes:, workspace_id:)
        input = { 'fileName' => file_name, 'fileSizeBytes' => file_size_bytes, 'workspaceId' => workspace_id }.compact
        upload = call_public_api(qawolf_api_key, qawolf_base_url, REQUEST_BUILD_UPLOAD_ENDPOINT, input, "get an upload URL")

        unless upload.kind_of?(Hash) && present?(upload['buildId']) && present?(upload['uploadUrl'])
          UI.user_error!("🐺 QA Wolf answered without an upload URL.")
        end

        return upload
      end

      # Streams the build file to the upload URL. The URL is signed for
      # `upload_headers`, so they are sent exactly as given.
      def self.put_build_file(upload_url, upload_headers, file_path)
        File.open(file_path, "rb") do |file|
          RestClient::Request.execute(
            method: :put,
            url: upload_url,
            payload: file,
            headers: upload_headers || {},
            timeout: BUILD_UPLOAD_TIMEOUT_SECONDS
          )
        end
      rescue RestClient::ExceptionWithResponse => e
        reason = e.response.nil? ? e.message : "storage refused it with HTTP status #{e.http_code}."
        UI.user_error!("🐺 Failed to upload the build file: #{reason}")
      rescue StandardError => e
        UI.user_error!("🐺 Failed to upload the build file: #{e.message}")
      end

      # Creates a build from an uploaded file, and answers the build.
      def self.create_build(qawolf_api_key, qawolf_base_url, input)
        payload = call_public_api(qawolf_api_key, qawolf_base_url, CREATE_BUILD_ENDPOINT, input, "create the build")
        build = payload.kind_of?(Hash) ? payload['build'] : nil

        UI.user_error!("🐺 QA Wolf answered without a build.") unless build.kind_of?(Hash) && present?(build['id'])

        return build
      end

      # Posts `input` to a public API procedure and answers its payload.
      # `step` names what the call does, for the error a refusal fails with.
      def self.call_public_api(qawolf_api_key, qawolf_base_url, endpoint, input, step)
        headers = {
          authorization: "Bearer #{qawolf_api_key}",
          user_agent: "qawolf_fastlane_plugin",
          content_type: "application/json"
        }
        url = URI.join(qawolf_base_url || BASE_URL, endpoint)

        response = RestClient.post(url.to_s, { 'json' => input }.to_json, headers)

        return parse_result(response)
      rescue RestClient::ExceptionWithResponse => e
        # Timeouts are ExceptionWithResponse too, but carry no response.
        UI.user_error!("🐺 Failed to #{step}: #{e.message}") if e.response.nil?

        begin
          error_response = report_error_message(e.response)
        rescue StandardError
          error_response = "Internal server error"
        end
        UI.user_error!("🐺 QA Wolf refused to #{step}: #{error_response}")
      rescue StandardError => e
        UI.user_error!("🐺 Failed to #{step}: #{e.message}")
      end
    end
  end
end
