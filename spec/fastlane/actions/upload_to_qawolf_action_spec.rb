require 'webmock/rspec'

describe Fastlane::Actions::UploadToQawolfAction do
  describe "#run" do
    let(:file_path) { "/fake/file.apk" }
    let(:signed_url_response) do
      {
        signedUrl: "http://signed_url",
        playgroundFileLocation: "run_input_path"
      }
    end
    let(:params) do
      {
        qawolf_api_key: "api_key",
        file_path: file_path,
        executable_file_basename: "my_app"
      }
    end

    before do
      allow(File).to receive(:exist?).with(file_path).and_return(true)
      allow(File).to receive(:open).with(file_path, "rb").and_yield('empty file')

      url = URI.join(Fastlane::Helper::QawolfHelper::BASE_URL, Fastlane::Helper::QawolfHelper::SIGNED_URL_ENDPOINT)

      stub_request(:get, url.to_s)
        .with(query: hash_including({}))
        .to_return(
          status: 200,
          body: signed_url_response.to_json,
          headers: {}
        )

      stub_request(:put, signed_url_response[:signedUrl])
        .to_return(status: 200, body: "", headers: {})
    end

    it "uploads the file" do
      result = described_class.run(params)
      expect(result).to eq(signed_url_response[:playgroundFileLocation])
    end

    it "requests the upload URL without a workspace" do
      described_class.run(params)
      expect(a_request(:get, /run-inputs-executables-signed-urls/).with(query: { "file" => "my_app.apk" })).to have_been_made
    end

    context "with a workspace id" do
      let(:params) do
        {
          qawolf_api_key: "api_key",
          file_path: file_path,
          executable_file_basename: "my_app",
          workspace_id: "workspace_1"
        }
      end

      it "requests the upload URL for that workspace" do
        described_class.run(params)
        expect(a_request(:get, /run-inputs-executables-signed-urls/).with(query: { "file" => "my_app.apk", "workspaceId" => "workspace_1" })).to have_been_made
      end
    end

    context "with the workspace id from QAWOLF_WORKSPACE_ID" do
      let(:config) do
        FastlaneCore::Configuration.create(
          described_class.available_options,
          { qawolf_api_key: "api_key", file_path: file_path, executable_file_basename: "my_app" }
        )
      end

      before { ENV["QAWOLF_WORKSPACE_ID"] = "workspace_from_env" }
      after { ENV.delete("QAWOLF_WORKSPACE_ID") }

      it "requests the upload URL for that workspace" do
        described_class.run(config)
        expect(a_request(:get, /run-inputs-executables-signed-urls/).with(query: { "file" => "my_app.apk", "workspaceId" => "workspace_from_env" })).to have_been_made
      end
    end

    context "with the qawolf alias and QAWOLF_WORKSPACE_ID" do
      let(:alias_config) do
        FastlaneCore::Configuration.create(
          Fastlane::Actions::QawolfAction.available_options,
          { qawolf_api_key: "api_key", file_path: file_path, executable_file_basename: "my_app" }
        )
      end

      before { ENV["QAWOLF_WORKSPACE_ID"] = "workspace_from_env" }
      after { ENV.delete("QAWOLF_WORKSPACE_ID") }

      it "requests the upload URL for that workspace" do
        Fastlane::Actions::QawolfAction.run(alias_config)
        expect(a_request(:get, /run-inputs-executables-signed-urls/).with(query: { "file" => "my_app.apk", "workspaceId" => "workspace_from_env" })).to have_been_made
      end
    end

    it "fails when file does not exist" do
      allow(File).to receive(:exist?).with(file_path).and_return(false)
      expect do
        described_class.run(params)
      end.to raise_error(FastlaneCore::Interface::FastlaneError)
    end

    context "with no executable_file_basename specified" do
      let(:params) do
        {
          qawolf_api_key: "api_key",
          file_path: file_path,
          executable_file_basename: nil
        }
      end

      it "fails to upload" do
        expect do
          described_class.run(params)
        end.to raise_error(FastlaneCore::Interface::FastlaneError)
      end
    end

    context "with unexpected file extension" do
      let(:file_path) { "/fake/file.txt" }

      it "fails when file extension is not supported" do
        expect do
          described_class.run(params)
        end.to raise_error(FastlaneCore::Interface::FastlaneError)
      end
    end

    context "with no file_path specified" do
      let(:params) do
        {
          qawolf_api_key: "api_key"
        }
      end

      it "fails when file_path is not specified" do
        expect do
          described_class.run(params)
        end.to raise_error(FastlaneCore::Interface::FastlaneError)
      end
    end
  end
end
