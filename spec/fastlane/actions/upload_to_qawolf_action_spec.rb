require 'webmock/rspec'

describe Fastlane::Actions::UploadToQawolfAction do
  describe "#run" do
    let(:file_path) { "/fake/file.apk" }
    let(:signed_url_response) do
      {
        signedUrl: "http://signed_url",
        playgroundFileLocation: "playground_file_location"
      }
    end
    let(:params) do
      {
        qawolf_api_key: "api_key",
        file_path: file_path,
        filename: nil
      }
    end

    before do
      allow(File).to receive(:exist?).with(file_path).and_return(true)
      allow(File).to receive(:open).with(file_path, "rb").and_return('empty file')

      url = URI.join(Fastlane::Helper::QawolfHelper::BASE_URL, Fastlane::Helper::QawolfHelper::SIGNED_URL_ENDPOINT)
      url.query = URI.encode_www_form({ 'file' => params[:filename] || File.basename(file_path) })

      stub_request(:get, url.to_s)
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

    it "fails when file does not exist" do
      allow(File).to receive(:exist?).with(file_path).and_return(false)
      expect do
        described_class.run(params)
      end.to raise_error(FastlaneCore::Interface::FastlaneError)
    end

    context "with filename specified" do
      let(:params) do
        {
          qawolf_api_key: "api_key",
          file_path: file_path,
          filename: "custom_filename.apk"
        }
      end

      it "uploads the file with custom filename" do
        result = described_class.run(params)
        expect(result).to eq(signed_url_response[:playgroundFileLocation])
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
