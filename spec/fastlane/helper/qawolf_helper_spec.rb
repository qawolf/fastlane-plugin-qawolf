describe Fastlane::Helper::QawolfHelper do
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
