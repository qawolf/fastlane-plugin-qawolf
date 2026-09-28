describe Fastlane::Helper::QawolfHelper do
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

    it "returns nil when the detected CI system is missing a variable" do
      expect(described_class.detect_provider_deployment_id(github_env.reject { |key, _value| key == "GITHUB_JOB" })).to be_nil
    end

    it "returns nil when no supported CI system is running" do
      expect(described_class.detect_provider_deployment_id({})).to be_nil
    end
  end
end
