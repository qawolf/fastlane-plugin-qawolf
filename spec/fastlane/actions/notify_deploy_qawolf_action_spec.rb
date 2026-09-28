require 'webmock/rspec'

describe Fastlane::Actions::NotifyDeployQawolfAction do
  let(:runs_url) { "https://app.qawolf.com/environments/env_id/runs" }
  let(:deployment) { { id: "deployment_id", status: "success", url: runs_url } }
  let(:params) do
    {
      qawolf_api_key: "api_key",
      workspace_id: "workspace_id",
      environment: "Staging",
      executable_filename: "file.apk",
      executable_environment_key: "RUN_INPUT_PATH",
      provider_deployment_id: "provider_deployment_id"
    }
  end

  def report_url
    URI.join(
      Fastlane::Helper::QawolfHelper::BASE_URL,
      Fastlane::Helper::QawolfHelper::REPORT_DEPLOYMENT_ENDPOINT
    ).to_s
  end

  before do
    stub_request(:post, report_url)
      .to_return(
        status: 200,
        body: { result: { data: { json: { deployment: deployment } } } }.to_json,
        headers: {}
      )
  end

  # The input the action sent, unwrapped from the envelope the API reads it from.
  def reported_input
    request = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.first
    JSON.parse(request.body)["json"]
  end

  describe "#run" do
    let(:required_input) do
      {
        "environment" => { "name" => "Staging" },
        "environmentVariables" => { "RUN_INPUT_PATH" => "/home/wolf/run-inputs-executables/file.apk" },
        "providerDeploymentId" => "provider_deployment_id",
        "status" => "success",
        "workspaceId" => "workspace_id"
      }
    end

    it "returns the reported deployment id" do
      expect(described_class.run(params)).to eq("deployment_id")
    end

    it "sends only the required fields when nothing else is given" do
      described_class.run(params)
      expect(reported_input).to eq(required_input)
    end

    it "sets QAWOLF_DEPLOYMENT_ID in the environment" do
      described_class.run(params)
      expect(ENV.fetch("QAWOLF_DEPLOYMENT_ID", nil)).to eq("deployment_id")
    end

    it "sets QAWOLF_DEPLOYMENT_ID in the lane context" do
      described_class.run(params)
      expect(Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::QAWOLF_DEPLOYMENT_ID]).to eq("deployment_id")
    end

    it "sets the environment runs URL in the environment" do
      described_class.run(params)
      expect(ENV.fetch("QAWOLF_ENVIRONMENT_RUNS_URL", nil)).to eq(runs_url)
    end

    it "sets the environment runs URL in the lane context" do
      described_class.run(params)
      expect(Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::QAWOLF_ENVIRONMENT_RUNS_URL]).to eq(runs_url)
    end

    context "with every optional field given" do
      let(:params) do
        super().merge(
          branch: "my-branch",
          commit_author_name: "Ada Lovelace",
          commit_message: "Fix the checkout",
          commit_url: "https://github.com/my-org/my-app/commit/abc123",
          deploy_target: "https://staging.example.com",
          pull_request_number: 42,
          repository: "my-org/my-app",
          service: "checkout-api",
          sha: "abc123",
          status: "pending",
          variables: { FOO: "bar" }
        )
      end
      let(:expected_input) do
        {
          "deployTarget" => "https://staging.example.com",
          "environment" => { "name" => "Staging" },
          "environmentVariables" => {
            "FOO" => "bar",
            "RUN_INPUT_PATH" => "/home/wolf/run-inputs-executables/file.apk"
          },
          "metadata" => {
            "commitAuthorName" => "Ada Lovelace",
            "commitMessage" => "Fix the checkout",
            "commitSha" => "abc123",
            "commitUrl" => "https://github.com/my-org/my-app/commit/abc123",
            "pullRequestNumber" => 42,
            "ref" => "my-branch",
            "repository" => "my-org/my-app"
          },
          "providerDeploymentId" => "provider_deployment_id",
          "service" => "checkout-api",
          "status" => "pending",
          "workspaceId" => "workspace_id"
        }
      end

      it "sends them all" do
        described_class.run(params)
        expect(reported_input).to eq(expected_input)
      end
    end

    context "with a GitLab merge request number" do
      let(:params) { super().merge(merge_request_number: 7, repository: "my-group/my-app") }

      it "reports it through the pull request field" do
        described_class.run(params)
        expect(reported_input["metadata"]).to eq("pullRequestNumber" => 7, "repository" => "my-group/my-app")
      end
    end

    context "with no provider deployment id given" do
      let(:params) { super().merge(provider_deployment_id: nil) }

      it "derives it from the CI environment" do
        allow(Fastlane::Helper::QawolfHelper).to receive(:detect_provider_deployment_id).and_return("18273645-2-deploy")
        described_class.run(params)
        expect(reported_input["providerDeploymentId"]).to eq("18273645-2-deploy")
      end

      it "generates one when no CI system is detected" do
        allow(Fastlane::Helper::QawolfHelper).to receive(:detect_provider_deployment_id).and_return(nil)
        described_class.run(params)
        expect(reported_input["providerDeploymentId"]).to start_with("fastlane-")
      end

      it "separates a build matrix's legs with the discriminator" do
        allow(Fastlane::Helper::QawolfHelper).to receive(:detect_provider_deployment_id).with(ENV, "ios").and_return("18273645-2-deploy:ios")
        described_class.run(params.merge(provider_deployment_discriminator: "ios"))
        expect(reported_input["providerDeploymentId"]).to eq("18273645-2-deploy:ios")
      end
    end

    context "with both a provider deployment id and a discriminator" do
      let(:params) { super().merge(provider_deployment_discriminator: "ios") }

      it "fails" do
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError, /provider_deployment_discriminator/)
      end
    end

    context "with no run input path set" do
      let(:params) { super().merge(executable_filename: nil) }

      it "fails" do
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError)
      end
    end

    context "with no workspace id" do
      let(:params) { super().merge(workspace_id: nil) }

      it "fails" do
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError, /workspace_id/)
      end
    end

    context "with no environment" do
      let(:params) { super().merge(environment: nil) }

      it "fails" do
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError, /environment/)
      end
    end

    context "with a request number but no repository" do
      let(:params) { super().merge(pull_request_number: 42) }

      it "fails" do
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError, /repository/)
      end
    end

    context "with a deploy target that is not an http URL" do
      let(:params) { super().merge(deploy_target: "myapp://staging") }

      it "fails" do
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError, /deploy_target/)
      end
    end

    context "with an unknown status" do
      let(:params) { super().merge(status: "deployed") }

      it "fails" do
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError, /status/)
      end
    end

    context "with a response that carries no deployment" do
      let(:deployment) { nil }

      it "fails" do
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError)
      end
    end

    describe "removed options" do
      {
        deployment_type: /environment/,
        deduplication_key: /provider_deployment_id/,
        deployment_url: /deploy_target/,
        hosting_service: /repository/,
        repository_name: /repository/,
        repository_owner: /repository/,
        repository_namespace: /repository/
      }.each do |option, expected_message|
        it "fails with a message pointing at the replacement for #{option}" do
          expect do
            described_class.run(params.merge(option => "some_value"))
          end.to raise_error(FastlaneCore::Interface::FastlaneError, expected_message)
        end
      end
    end
  end
end
