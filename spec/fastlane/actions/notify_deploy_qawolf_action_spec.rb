require 'webmock/rspec'
require_relative '../../support/git_repository'

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

    context "with the action's own configuration rather than a hash" do
      let(:config) do
        ENV["QAWOLF_EXECUTABLE_FILENAME"] = "file.apk"
        FastlaneCore::Configuration.create(
          described_class.available_options,
          {
            qawolf_api_key: "api_key",
            workspace_id: "workspace_id",
            environment: "Staging",
            provider_deployment_id: "provider_deployment_id"
          }
        )
      end

      after { ENV.delete("QAWOLF_EXECUTABLE_FILENAME") }

      it "reports the executable upload_to_qawolf set in the environment" do
        described_class.run(config)
        expect(reported_input["environmentVariables"]).to eq("RUN_INPUT_PATH" => "/home/wolf/run-inputs-executables/file.apk")
      end

      it "reports the default status" do
        described_class.run(config)
        expect(reported_input["status"]).to eq("success")
      end
    end

    context "with no merge request number set" do
      let(:params) { super().merge(merge_request_number: nil, repository: "my-group/my-app") }

      it "reports no pull request number" do
        described_class.run(params)
        expect(reported_input["metadata"]).not_to have_key("pullRequestNumber")
      end
    end

    context "with a merge request number of zero" do
      let(:params) { super().merge(merge_request_number: 0, repository: "my-group/my-app") }

      it "reports no pull request number" do
        described_class.run(params)
        expect(reported_input["metadata"]).not_to have_key("pullRequestNumber")
      end
    end

    context "with a commit url that is not an http URL" do
      let(:params) { super().merge(commit_url: "my-org/my-app@abc123") }

      it "fails" do
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError, /commit_url/)
      end
    end

    context "with a GitLab subgroup repository" do
      let(:params) { super().merge(merge_request_number: 7, repository: "my-group/my-subgroup/my-app") }

      it "reports the full path" do
        described_class.run(params)
        expect(reported_input["metadata"]["repository"]).to eq("my-group/my-subgroup/my-app")
      end
    end

    context "with a malformed repository" do
      let(:params) { super().merge(repository: "my-app") }

      it "fails" do
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError, /repository/)
      end
    end

    context "with a repository holding an empty segment" do
      let(:params) { super().merge(repository: "my-org/") }

      it "fails" do
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError, /repository/)
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

    context "with builds and no executable" do
      let(:params) { super().merge(builds: ["abcdefghijklmnopqrstuvwxobld"], executable_filename: nil) }

      it "reports the builds" do
        described_class.run(params)
        expect(reported_input["builds"]).to eq(["abcdefghijklmnopqrstuvwxobld"])
      end

      it "sends no RUN_INPUT_PATH, so runs install the builds" do
        described_class.run(params)
        expect(reported_input).not_to have_key("environmentVariables")
      end

      it "still sends the lane's own variables" do
        described_class.run(params.merge(variables: { FOO: "bar" }))
        expect(reported_input["environmentVariables"]).to eq("FOO" => "bar")
      end
    end

    context "with builds and an executable" do
      let(:params) { super().merge(builds: ["abcdefghijklmnopqrstuvwxobld"]) }

      it "reports both" do
        described_class.run(params)
        expect(reported_input).to include(
          "builds" => ["abcdefghijklmnopqrstuvwxobld"],
          "environmentVariables" => { "RUN_INPUT_PATH" => "/home/wolf/run-inputs-executables/file.apk" }
        )
      end

      it "warns that RUN_INPUT_PATH wins over the builds" do
        allow(Fastlane::UI).to receive(:important)
        described_class.run(params)
        expect(Fastlane::UI).to have_received(:important).with(/RUN_INPUT_PATH wins/)
      end
    end

    context "when upload_build_to_qawolf ran earlier in the lane" do
      let(:params) { super().merge(executable_filename: nil) }

      after { Fastlane::Actions.lane_context.clear }

      it "reports every build the lane uploaded" do
        Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::QAWOLF_BUILD_IDS] = ["abcdefghijklmnopqrstuvwxobld", "zyxwvutsrqponmlkjihgfedcobld"]
        described_class.run(params)
        expect(reported_input["builds"]).to eq(["abcdefghijklmnopqrstuvwxobld", "zyxwvutsrqponmlkjihgfedcobld"])
      end
    end

    context "with an empty `builds` after upload_build_to_qawolf ran" do
      let(:params) { super().merge(builds: []) }

      before { Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::QAWOLF_BUILD_IDS] = ["abcdefghijklmnopqrstuvwxobld"] }
      after { Fastlane::Actions.lane_context.clear }

      it "ships no builds" do
        described_class.run(params)
        expect(reported_input).not_to have_key("builds")
      end

      it "keeps the executable" do
        described_class.run(params)
        expect(reported_input["environmentVariables"]).to have_key("RUN_INPUT_PATH")
      end
    end

    context "with more than 20 builds" do
      let(:params) { super().merge(builds: Array.new(21) { |index| format("%024dobld", index) }) }

      it "fails" do
        expect { described_class.run(params) }.to raise_error(FastlaneCore::Interface::FastlaneError, /20 builds/)
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

    describe "changes" do
      let(:collected_changes) do
        {
          "items" => [
            pull_request,
            { "changedPaths" => ["app/CartView.swift"], "kind" => "commit", "title" => "Show the cart" },
            { "changedPaths" => ["app/Cart.swift"], "kind" => "commit", "title" => "Add the cart model" }
          ]
        }
      end

      def pull_request
        { "kind" => "pull-request", "title" => "Add the cart", "url" => "https://github.com/my-org/my-app/pull/7" }
      end

      def refusal_of(extra_params)
        described_class.run(params.merge(extra_params))
      rescue FastlaneCore::Interface::FastlaneError => e
        e.message
      end

      # Runs the action inside a repository holding a pull request's commits
      # on top of `main`, or inside a shallow clone of it.
      def run_in_repository(extra_params, clone = :full)
        GitRepository.create do |repository, dir|
          repository.commit("Initial commit", "README.md" => "hello")
          repository.git("checkout", "--quiet", "-b", "feature/cart", cwd: repository.path)
          repository.commit("Add the cart model", "app/Cart.swift" => "let secret = \"do-not-send\"")
          repository.commit("Show the cart", "app/CartView.swift" => "struct CartView {}")
          repository.git("clone", "--quiet", "--depth", "1", "file://#{repository.path}", File.join(dir, "shallow")) if clone == :shallow
          return Dir.chdir(clone == :shallow ? File.join(dir, "shallow") : repository.path) { described_class.run(params.merge(extra_params)) }
        end
      end

      it "sends no changes when none of the changes options is set" do
        described_class.run(params.merge(branch: "my-branch", sha: "abc123", repository: "my-org/my-app", pull_request_number: 42))
        expect(reported_input).not_to have_key("changes")
      end

      it "sends changes given by hand" do
        described_class.run(params.merge(changes: { items: [{ kind: "pull-request", title: "Add the cart", url: "https://github.com/my-org/my-app/pull/7" }] }))
        expect(reported_input["changes"]).to eq("items" => [pull_request])
      end

      it "sends no changes when the changes given by hand hold no items and no release notes" do
        described_class.run(params.merge(changes: { items: [], omittedCount: 3 }))
        expect(reported_input).not_to have_key("changes")
      end

      it "refuses changes that carry a diff" do
        expect(refusal_of(changes: { items: [{ kind: "commit", title: "Add the cart", diff: "+ struct Cart {}" }] })).to include("no field for code, diffs or file contents")
      end

      it "refuses collect_changes without changes_since" do
        expect(refusal_of(collect_changes: true)).to include("needs `changes_since`")
      end

      it "adds the commits collected from git after the changes given by hand" do
        run_in_repository(changes: { items: [pull_request] }, collect_changes: true, changes_since: "main")
        expect(reported_input["changes"]).to eq(collected_changes)
      end

      it "sends no file contents" do
        run_in_repository(collect_changes: true, changes_since: "main")
        expect(reported_input.to_json).not_to include("do-not-send")
      end

      it "still reports the deployment when the clone is shallow" do
        allow(Fastlane::UI).to receive(:important)
        expect(run_in_repository({ collect_changes: true, changes_since: "HEAD~1" }, :shallow)).to eq("deployment_id")
      end

      it "sends no changes when the clone is shallow" do
        allow(Fastlane::UI).to receive(:important)
        run_in_repository({ collect_changes: true, changes_since: "HEAD~1" }, :shallow)
        expect(reported_input).not_to have_key("changes")
      end

      it "warns when the clone is shallow" do
        allow(Fastlane::UI).to receive(:important)
        run_in_repository({ collect_changes: true, changes_since: "HEAD~1" }, :shallow)
        expect(Fastlane::UI).to have_received(:important).with(/shallow/)
      end

      it "still sends the changes given by hand when no commits can be collected" do
        allow(Fastlane::UI).to receive(:important)
        run_in_repository(changes: { items: [pull_request] }, collect_changes: true, changes_since: "v9.9.9")
        expect(reported_input["changes"]).to eq("items" => [pull_request])
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
