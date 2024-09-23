require 'fastlane_core/ui/ui'
require 'rest-client'
require 'uri'

module Fastlane
  UI = FastlaneCore::UI unless Fastlane.const_defined?(:UI)

  module Helper
    class QawolfHelper
      BASE_URL = "https://app.qawolf.com"
      SIGNED_URL_ENDPOINT = "/api/v0/run-inputs-executables-signed-urls"

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

      # Uploads file to BrowserStack
      # Params :
      # +qawolf_api_key+:: QA Wolf API key
      # +qawolf_base_url+:: QA Wolf API base URL
      # +file_path+:: Path to the file to be uploaded.
      # +filename+:: Optional filename to use instead of the file's basename.
      def self.upload_file(qawolf_api_key, qawolf_base_url, file_path, filename = nil)
        file_content = File.open(file_path, "rb")

        headers = {
          user_agent: "qawolf_fastlane_plugin",
          content_type: "application/octet-stream"
        }

        signed_url, playground_file_location = get_signed_url(qawolf_api_key, qawolf_base_url, filename || File.basename(file_path))

        RestClient.put(signed_url, file_content, headers)

        return playground_file_location
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
    end
  end
end
