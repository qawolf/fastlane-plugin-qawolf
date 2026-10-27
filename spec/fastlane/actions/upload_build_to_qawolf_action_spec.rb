require 'tmpdir'
require 'webmock/rspec'

describe Fastlane::Actions::UploadBuildToQawolfAction do
  def build_id
    "abcdefghijklmnopqrstuvwxobld"
  end

  def upload_url
    "https://storage.example.com/upload"
  end

  def upload_headers
    { "Content-Type" => "application/octet-stream", "x-goog-if-generation-match" => "0" }
  end

  def build
    {
      "id" => build_id,
      "appId" => "com.example.app",
      "buildNumber" => "42",
      "platform" => "android",
      "url" => "https://app.qawolf.com/builds",
      "version" => "1.2.3"
    }
  end

  def write_file(name, contents)
    path = File.join(directory, name)
    File.write(path, contents)
    path
  end

  let(:directory) { Dir.mktmpdir }
  let(:file_path) { write_file("app-release.apk", "apk bytes") }
  let(:params) do
    {
      qawolf_api_key: "api_key",
      workspace_id: "workspace_id",
      file_path: file_path,
      environment: "Staging",
      branch: "main",
      sha: "abc123"
    }
  end

  def endpoint(path)
    URI.join(Fastlane::Helper::QawolfHelper::BASE_URL, path).to_s
  end

  def request_upload_url
    endpoint(Fastlane::Helper::QawolfHelper::REQUEST_BUILD_UPLOAD_ENDPOINT)
  end

  def create_url
    endpoint(Fastlane::Helper::QawolfHelper::CREATE_BUILD_ENDPOINT)
  end

  # The input the action sent to an endpoint, unwrapped from its envelope.
  def sent_input(url)
    request = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.find { |signature| signature.uri.path == URI(url).path }
    JSON.parse(request.body)["json"]
  end

  def run_with_stubs(run_params)
    stub_request(:post, request_upload_url).to_return(
      status: 200,
      body: { result: { data: { json: { buildId: build_id, expiresAt: "2026-10-26T20:00:00.000Z", uploadHeaders: upload_headers, uploadUrl: upload_url } } } }.to_json
    )
    stub_request(:put, upload_url).to_return(status: 200)
    stub_request(:post, create_url).to_return(status: 200, body: { result: { data: { json: { build: build } } } }.to_json)

    described_class.run(run_params)
  end

  after do
    FileUtils.remove_entry(directory)
    Fastlane::Actions.lane_context.clear
    ENV.delete("QAWOLF_BUILD_ID")
  end

  describe "#run" do
    it "returns the created build" do
      expect(run_with_stubs(params)).to eq(build)
    end

    it "asks for an upload URL for the file's name and size" do
      run_with_stubs(params)
      expect(sent_input(request_upload_url)).to eq("fileName" => "app-release.apk", "fileSizeBytes" => 9, "workspaceId" => "workspace_id")
    end

    it "uploads the file's bytes with the upload headers" do
      run_with_stubs(params)
      expect(a_request(:put, upload_url).with(body: "apk bytes", headers: upload_headers)).to have_been_made
    end

    it "creates the build in the environment, with its branch and commit" do
      run_with_stubs(params)
      expect(sent_input(create_url)).to eq(
        "branch" => "main", "buildId" => build_id, "commitSha" => "abc123", "environment" => { "name" => "Staging" }, "workspaceId" => "workspace_id"
      )
    end

    it "sets QAWOLF_BUILD_ID in the environment" do
      run_with_stubs(params)
      expect(ENV.fetch("QAWOLF_BUILD_ID", nil)).to eq(build_id)
    end

    it "sets QAWOLF_BUILD_ID in the lane context" do
      run_with_stubs(params)
      expect(Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::QAWOLF_BUILD_ID]).to eq(build_id)
    end

    it "collects every build the lane uploads in QAWOLF_BUILD_IDS" do
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::QAWOLF_BUILD_IDS] = ["zyxwvutsrqponmlkjihgfedcobld"]
      run_with_stubs(params)
      expect(Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::QAWOLF_BUILD_IDS]).to eq(["zyxwvutsrqponmlkjihgfedcobld", build_id])
    end

    context "with a Linux Electron build" do
      let(:file_path) { write_file("my-app_1.0.0_amd64.deb", "deb bytes") }

      it "uploads it" do
        run_with_stubs(params)
        expect(sent_input(request_upload_url)["fileName"]).to eq("my-app_1.0.0_amd64.deb")
      end
    end

    context "with spaces in the file name" do
      let(:file_path) { write_file("My App.ipa", "ipa bytes") }

      it "replaces them with dashes" do
        run_with_stubs(params)
        expect(sent_input(request_upload_url)["fileName"]).to eq("My-App.ipa")
      end
    end

    context "with branch and sha set to false" do
      let(:params) { super().merge(branch: false, sha: false) }

      it "sends neither" do
        run_with_stubs(params)
        expect(sent_input(create_url).keys).to contain_exactly("buildId", "environment", "workspaceId")
      end
    end

    context "with an environment id" do
      let(:params) { super().merge(environment: nil, environment_id: "env_1") }

      it "creates the build in that environment" do
        run_with_stubs(params)
        expect(sent_input(create_url)["environment"]).to eq("id" => "env_1")
      end
    end

    context "with an ephemeral environment and its base" do
      let(:params) { super().merge(environment: "pr-123", ephemeral_environment: true, base_environment: "Staging") }

      it "asks for a preview environment copied from the base" do
        run_with_stubs(params)
        expect(sent_input(create_url)["environment"]).to eq("name" => "pr-123", "ephemeral" => true, "baseEphemeralEnvironment" => "Staging")
      end
    end

    context "with no environment" do
      let(:params) { super().merge(environment: nil) }

      it "creates the build outside any environment" do
        run_with_stubs(params)
        expect(sent_input(create_url)).not_to have_key("environment")
      end
    end

    context "with the action's own configuration rather than a hash" do
      let(:config) do
        FastlaneCore::Configuration.create(
          described_class.available_options,
          { qawolf_api_key: "api_key", file_path: file_path }
        )
      end

      after do
        ENV.delete("QAWOLF_ENVIRONMENT")
        ENV.delete("QAWOLF_WORKSPACE_ID")
      end

      it "reads the environment and workspace from QAWOLF_ENVIRONMENT and QAWOLF_WORKSPACE_ID" do
        ENV["QAWOLF_ENVIRONMENT"] = "Staging"
        ENV["QAWOLF_WORKSPACE_ID"] = "workspace_from_env"
        run_with_stubs(config)
        expect(sent_input(create_url)).to include("environment" => { "name" => "Staging" }, "workspaceId" => "workspace_from_env")
      end

      it "prefers an environment id to QAWOLF_ENVIRONMENT" do
        ENV["QAWOLF_ENVIRONMENT"] = "Staging"
        config[:environment_id] = "env_1"
        run_with_stubs(config)
        expect(sent_input(create_url)["environment"]).to eq("id" => "env_1")
      end
    end

    context "with no file_path, after gradle built an apk" do
      let(:params) { super().merge(file_path: nil) }

      it "uploads the apk" do
        Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::GRADLE_APK_OUTPUT_PATH] = file_path
        run_with_stubs(params)
        expect(sent_input(request_upload_url)["fileName"]).to eq("app-release.apk")
      end
    end

    describe "checks before uploading" do
      # Each case's overrides are built inside the example, where it can write files.
      {
        "no file_path" => [-> { { file_path: nil } }, /file_path/],
        "a missing file" => [-> { { file_path: "/does/not/exist.apk" } }, /No file found/],
        "an unsupported file extension" => [-> { { file_path: write_file("app.zip", "zip bytes") } }, /\.apk, \.aab, \.ipa, \.deb or \.rpm/],
        "a file name QA Wolf can't store" => [-> { { file_path: write_file("app(1).apk", "apk bytes") } }, /letters, digits/],
        "an empty file" => [-> { { file_path: write_file("app.apk", "") } }, /empty/],
        "both environment and environment_id" => [-> { { environment_id: "env_1" } }, /environment_id/],
        "base_environment without ephemeral_environment" => [-> { { base_environment: "Staging" } }, /base_environment.*ephemeral_environment/],
        "ephemeral_environment with environment_id" => [-> { { environment: nil, environment_id: "env_1", ephemeral_environment: true } }, /ephemeral_environment.*environment\b/],
        "ephemeral_environment without an environment" => [-> { { environment: nil, ephemeral_environment: true } }, /ephemeral_environment.*environment\b/]
      }.each do |situation, (overrides, message)|
        it "fails with #{situation}, sending nothing", :aggregate_failures do
          expect { described_class.run(params.merge(instance_exec(&overrides))) }.to raise_error(FastlaneCore::Interface::FastlaneError, message)
          expect(a_request(:any, /.*/)).not_to have_been_made
        end
      end

      it "fails with a file over 500 MB, sending nothing", :aggregate_failures do
        allow(File).to receive(:size).and_call_original
        allow(File).to receive(:size).with(file_path).and_return((500 * 1024 * 1024) + 1)
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError, /500 MB/)
        expect(a_request(:any, /.*/)).not_to have_been_made
      end
    end
  end
end
