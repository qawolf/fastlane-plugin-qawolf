require 'webmock/rspec'

describe Fastlane::Actions::NotifyDeployQawolfAction do
  describe "#run" do
    let(:executable_filename) { "file.apk" }
    let(:params) do
      {
        qawolf_api_key: "api_key",
        executable_filename: executable_filename
      }
    end
    let(:deploy_response) do
      {
        results: [{ created_suite_id: "created_suite_id" }]
      }
    end

    before do
      url = URI.join(Fastlane::Helper::QawolfHelper::BASE_URL, Fastlane::Helper::QawolfHelper::WEBHOOK_DEPLOY_SUCCESS_ENDPOINT)

      stub_request(:post, url.to_s)
        .to_return(
          status: 200,
          body: deploy_response.to_json,
          headers: {}
        )
    end

    it "triggers a test run" do
      result = described_class.run(params)
      expect(result).to eq(deploy_response[:results][0][:created_suite_id])
    end

    context "with no run input path set" do
      let(:executable_filename) { nil }

      it "fails when no test run is triggered" do
        expect do
          described_class.run(params)
        end.to raise_error(FastlaneCore::Interface::FastlaneError)
      end
    end

    context "with no results" do
      let(:deploy_response) do
        {
          results: []
        }
      end

      it "fails when no test run is triggered" do
        expect do
          described_class.run(params)
        end.to raise_error(FastlaneCore::Interface::FastlaneError)
      end
    end

    context "with failure reason set" do
      let(:deploy_response) do
        {
          results: [{ failure_reason: "failure_reason" }]
        }
      end

      it "fails when no test run is triggered" do
        expect do
          described_class.run(params)
        end.to raise_error(FastlaneCore::Interface::FastlaneError)
      end
    end
  end
end
