describe Fastlane::Helper::QawolfHelper do
  describe "#signed_url_endpoint" do
    it "names only the file when no workspace is given" do
      url = described_class.signed_url_endpoint(nil, "my app.apk")
      expect(url.to_s).to eq("https://app.qawolf.com/api/v0/run-inputs-executables-signed-urls?file=my+app.apk")
    end

    it "names the workspace when one is given" do
      url = described_class.signed_url_endpoint(nil, "my_app.apk", "workspace&1")
      expect(url.query).to eq("file=my_app.apk&workspaceId=workspace%261")
    end

    it "leaves out an empty workspace" do
      url = described_class.signed_url_endpoint(nil, "my_app.apk", " ")
      expect(url.query).to eq("file=my_app.apk")
    end
  end

  describe "#report_error_message" do
    it "reads the message and the event id" do
      body = { error: { json: { code: "BAD_REQUEST", message: "Number must be greater than 0", data: { eventId: "evt_1" } } } }.to_json
      expect(described_class.report_error_message(body)).to eq("Number must be greater than 0 (Event ID: evt_1)")
    end

    it "reads a message sent without an event id" do
      body = { error: { message: "Unauthorized" } }.to_json
      expect(described_class.report_error_message(body)).to eq("Unauthorized")
    end

    it "falls back to the body it cannot read" do
      expect(described_class.report_error_message("upstream timeout")).to eq("upstream timeout")
    end
  end

  describe "#request_build_upload" do
    let(:url) { "https://app.qawolf.com/api/trpc/public.build.requestUpload" }
    let(:upload) do
      {
        "buildId" => "abcdefghijklmnopqrstuvwxobld",
        "expiresAt" => "2026-10-26T20:00:00.000Z",
        "uploadHeaders" => { "Content-Type" => "application/octet-stream" },
        "uploadUrl" => "https://storage.example.com/upload"
      }
    end

    it "asks for an upload URL and answers the API's payload" do
      stub_request(:post, url)
        .with(body: { json: { fileName: "app.apk", fileSizeBytes: 42, workspaceId: "workspace_1" } }.to_json, headers: { "Authorization" => "Bearer api_key" })
        .to_return(status: 200, body: { result: { data: { json: upload } } }.to_json)

      expect(described_class.request_build_upload("api_key", nil, file_name: "app.apk", file_size_bytes: 42, workspace_id: "workspace_1")).to eq(upload)
    end

    it "leaves out a missing workspace" do
      stub = stub_request(:post, url)
             .with(body: { json: { fileName: "app.apk", fileSizeBytes: 42 } }.to_json)
             .to_return(status: 200, body: { result: { data: { json: upload } } }.to_json)

      described_class.request_build_upload("api_key", nil, file_name: "app.apk", file_size_bytes: 42, workspace_id: nil)
      expect(stub).to have_been_requested
    end

    it "fails with the refusal and its event id" do
      refusal = { error: { json: { message: "Builds are not enabled for this workspace.", data: { eventId: "evt_1" } } } }
      stub_request(:post, url).to_return(status: 403, body: refusal.to_json)

      expect do
        described_class.request_build_upload("api_key", nil, file_name: "app.apk", file_size_bytes: 42, workspace_id: nil)
      end.to raise_error(FastlaneCore::Interface::FastlaneError, /upload URL.*Builds are not enabled for this workspace\. \(Event ID: evt_1\)/)
    end

    it "fails with the timeout when QA Wolf does not answer in time" do
      stub_request(:post, url).to_timeout

      expect do
        described_class.request_build_upload("api_key", nil, file_name: "app.apk", file_size_bytes: 42, workspace_id: nil)
      end.to raise_error(FastlaneCore::Interface::FastlaneError, /Failed to get an upload URL: .*[Tt]imed out/)
    end
  end

  describe "#put_build_file" do
    let(:upload_url) { "https://storage.example.com/upload" }
    let(:upload_headers) { { "Content-Type" => "application/octet-stream", "x-goog-if-generation-match" => "0" } }

    def with_build_file
      Dir.mktmpdir do |directory|
        file_path = File.join(directory, "app.apk")
        File.write(file_path, "apk bytes")
        yield(file_path)
      end
    end

    it "sends the file's bytes with the upload headers" do
      stub = stub_request(:put, upload_url).with(body: "apk bytes", headers: upload_headers).to_return(status: 200)

      with_build_file { |file_path| described_class.put_build_file(upload_url, upload_headers, file_path) }
      expect(stub).to have_been_requested
    end

    it "fails with the status storage refused with" do
      stub_request(:put, upload_url).to_return(status: 412, body: "<Error>Precondition failed</Error>")

      expect do
        with_build_file { |file_path| described_class.put_build_file(upload_url, upload_headers, file_path) }
      end.to raise_error(FastlaneCore::Interface::FastlaneError, /upload the build file.*412/)
    end

    it "fails with the timeout when storage does not answer in time" do
      stub_request(:put, upload_url).to_timeout

      expect do
        with_build_file { |file_path| described_class.put_build_file(upload_url, upload_headers, file_path) }
      end.to raise_error(FastlaneCore::Interface::FastlaneError, /Failed to upload the build file: .*[Tt]imed out/)
    end
  end

  describe "#create_build" do
    let(:url) { "https://app.qawolf.com/api/trpc/public.build.create" }
    let(:build) { { "id" => "abcdefghijklmnopqrstuvwxobld", "appId" => "com.example.app", "platform" => "android" } }
    let(:input) { { "buildId" => "abcdefghijklmnopqrstuvwxobld", "environment" => { "name" => "Staging" } } }

    it "creates the build and answers it" do
      stub_request(:post, url)
        .with(body: { json: input }.to_json)
        .to_return(status: 200, body: { result: { data: { json: { build: build } } } }.to_json)

      expect(described_class.create_build("api_key", nil, input)).to eq(build)
    end

    it "fails with the refusal" do
      stub_request(:post, url).to_return(status: 400, body: { error: { json: { message: "The file isn't an app." } } }.to_json)

      expect do
        described_class.create_build("api_key", nil, input)
      end.to raise_error(FastlaneCore::Interface::FastlaneError, /create the build.*The file isn't an app\./)
    end
  end

  describe "#detect_provider_deployment_id" do
    let(:github_env) do
      {
        "GITHUB_ACTIONS" => "true",
        "GITHUB_RUN_ID" => "18273645",
        "GITHUB_RUN_ATTEMPT" => "2",
        "GITHUB_JOB" => "deploy"
      }
    end
    let(:gitlab_env) do
      {
        "GITLAB_CI" => "true",
        "CI_PIPELINE_ID" => "555",
        "CI_JOB_ID" => "777"
      }
    end

    it "composes the GitHub Actions run, attempt and job" do
      expect(described_class.detect_provider_deployment_id(github_env)).to eq("18273645-2-deploy")
    end

    it "composes the GitLab pipeline and job" do
      expect(described_class.detect_provider_deployment_id(gitlab_env)).to eq("555-777")
    end

    it "composes the Bitrise build slug" do
      expect(described_class.detect_provider_deployment_id({ "BITRISE_IO" => "true", "BITRISE_BUILD_SLUG" => "b3e1" })).to eq("b3e1")
    end

    it "composes the Azure Pipelines build and job" do
      expect(described_class.detect_provider_deployment_id({ "TF_BUILD" => "True", "BUILD_BUILDID" => "412", "SYSTEM_JOBID" => "a-b-c" })).to eq("412-a-b-c")
    end

    it "returns nil when the detected CI system is missing a variable" do
      expect(described_class.detect_provider_deployment_id(github_env.reject { |key, _value| key == "GITHUB_JOB" })).to be_nil
    end

    it "returns nil when no supported CI system is running" do
      expect(described_class.detect_provider_deployment_id({})).to be_nil
    end

    it "appends a discriminator after a colon" do
      expect(described_class.detect_provider_deployment_id(github_env, "ios")).to eq("18273645-2-deploy:ios")
    end

    it "gives the legs of one matrix job their own identifiers" do
      ios = described_class.detect_provider_deployment_id(github_env, "ios")
      android = described_class.detect_provider_deployment_id(github_env, "android")
      expect(ios).not_to eq(android)
    end

    it "leaves the identifier unchanged when the discriminator is empty" do
      expect(described_class.detect_provider_deployment_id(github_env, " ")).to eq("18273645-2-deploy")
    end
  end
end
