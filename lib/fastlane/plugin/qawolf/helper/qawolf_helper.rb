require 'fastlane_core/ui/ui'
require 'rest-client'
require 'uri'

module Fastlane
  UI = FastlaneCore::UI unless Fastlane.const_defined?(:UI)

  module Helper
    class QawolfHelper
      BASE_URL = "https://app.qawolf.com"
      SIGNED_URL_ENDPOINT = "/api/v0/run-inputs-executables-signed-urls"
      WEBHOOK_DEPLOY_SUCCESS_ENDPOINT = "/api/webhooks/deploy_success"

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

        file_content = File.open(file_path, "rb")

        headers = {
          user_agent: "qawolf_fastlane_plugin",
          content_type: "application/octet-stream"
        }

        uploaded_filename = "#{executable_file_basename}#{File.extname(file_path)}"
        signed_url, run_input_path = get_signed_url(qawolf_api_key, qawolf_base_url, uploaded_filename)

        RestClient.put(signed_url, file_content, headers)

        return run_input_path
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

      def self.notify_deploy_body(options)
        {
          'branch' => options[:branch],
          'commit_url' => options[:commit_url],
          'deduplication_key' => options[:deduplication_key],
          'deployment_type' => options[:deployment_type],
          'deployment_url' => options[:deployment_url],
          'hosting_service' => options[:hosting_service],
          'sha' => options[:sha],
          'variables' => options[:variables]
        }.to_json
      end

      def self.process_notify_response(response)
        response_json = JSON.parse(response.to_s)

        results = response_json["results"]

        failed_trigger = get_failed_trigger(results)
        success_trigger = get_success_trigger(results)

        if failed_trigger.nil? && success_trigger.nil?
          raise "no matched trigger, reach out to QA Wolf support"
        elsif failed_trigger.nil? == false
          raise failed_trigger["failure_reason"]
        end

        return success_trigger["created_suite_id"] || success_trigger["duplicate_suite_id"]
      end

      def self.get_failed_trigger(results)
        results.find { |result| result["failure_reason"].nil? == false }
      end

      def self.get_success_trigger(results)
        results.find { |result| result["created_suite_id"].nil? == false || result["duplicate_suite_id"].nil? == false }
      end

      # Triggers QA Wolf deploy success webhook to start test runs.
      # Params :
      # +qawolf_api_key+:: QA Wolf API key
      # +qawolf_base_url+:: QA Wolf API base URL
      # +options+:: Options hash containing deployment details.
      def self.notify_deploy(qawolf_api_key, qawolf_base_url, options)
        headers = {
          authorization: "Bearer #{qawolf_api_key}",
          user_agent: "qawolf_fastlane_plugin",
          content_type: "application/json"
        }

        url = URI.join(qawolf_base_url || BASE_URL, WEBHOOK_DEPLOY_SUCCESS_ENDPOINT)

        response = RestClient.post(url.to_s, notify_deploy_body(options), headers)

        return process_notify_response(response)
      rescue RestClient::ExceptionWithResponse => e
        begin
          error_response = e.response.to_s
        rescue StandardError
          error_response = "Internal server error"
        end
        # Give error if request failed.
        UI.user_error!("Failed to notify deploy!!! Request failed. Reason : #{error_response}")
      rescue StandardError => e
        UI.user_error!("Failed to notify deploy!!! Something went wrong. Reason : #{e.message}")
      end
    end
  end
end
