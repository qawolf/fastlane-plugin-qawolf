# qawolf plugin

## Getting Started

This project is a [_fastlane_](https://github.com/fastlane/fastlane) plugin. To get started with `fastlane-plugin-qawolf`, add it to your project by running:

```
# Add this to your Gemfile
gem "fastlane-plugin-qawolf", git: "https://github.com/qawolf/fastlane-plugin-qawolf", tag: "1.0.0"
```

## About qawolf

Fastlane plugin for QA Wolf integration.

Uploads build artifacts (IPA, APK, or AAB) to QA Wolf storage for automated testing, and reports the deployment to QA Wolf so your triggers start the matching runs.

## Example

Check out the [example `Fastfile`](fastlane/Fastfile) to see how to use this plugin. Try it by cloning the repo, running `fastlane install_plugins` and `bundle exec fastlane test`.

```ruby
lane :build do
    # It's recommended to only trigger builds with a clean git status.
    # See https://docs.fastlane.tools/actions/#source-control for other source control actions
    ensure_git_status_clean

    # Build your app (Android or iOS, but not both in the same lane!)
    # Check Fastlane's docs for alternative build methods. Your use case may vary.
    # Android (APK/AAB)
    gradle(
        # these options are not strictly required as below
        # reach out to QA Wolf to verify the built APK/AAB works
        task: "assemble",
        build_type: "Release",
    )
    # iOS (IPA)
    build_app(
        # these options are not strictly required as below
        # reach out to QA Wolf to verify the built IPA works
        scheme: "Release",
        export_method: "release-testing",
    )

    # Inject QA Wolf instrumentation (Optional and iOS only)
    # Use https://docs.fastlane.tools/actions/resign/ to resign the IPA file before uploading.
    inject_qawolf_instrumentation(
        input: "./build/app.ipa",
        output: "./build/app_instrumented.ipa"
    )

    # Upload the artifact to QA Wolf
    upload_to_qawolf(
        # Must be set or available as env var QAWOLF_API_KEY
        qawolf_api_key: "qawolf_...",

        # Must be set to guarantee the uploaded file is replaced.
        # Typically, this should include a git branch name or a QA Wolf environment name.
        # Reach out to QA Wolf if you're unsure.
        # Do NOT include a file extension, it'll be appended based on the build output file.
        executable_file_basename: "calculator_app_staging",

        # Only set this if you have not built the artifact in the same lane,
        # e.g. via gradle or xcodebuild, check official Fastlane docs for details.
        # file_path: "./build/app-bundle.apk",
        # file_path: "./build/app.ipa",
    )

    # Report the deployment to QA Wolf, which starts the runs your triggers match
    notify_deploy_qawolf(
        # Must be set or available as env var QAWOLF_API_KEY
        qawolf_api_key: "qawolf_...",

        # Required. The workspace to report into, also readable from QAWOLF_WORKSPACE_ID.
        # Call `whoami` in the QA Wolf API with your API key to find it, or ask
        # your QA Wolf representative.
        workspace_id: ENV.fetch("QAWOLF_WORKSPACE_ID", nil),

        # Required. The name or alias of an EXISTING QA Wolf environment.
        # A value that matches no environment creates a new one, so check it first.
        environment: "Staging",

        # Optional, but set if requested by the QA Wolf team.
        # This is mostly to help distinguish between multiple apps within the same team/environment.
        executable_environment_key: "RUN_INPUT_PATH",

        # Optional, defaults to an id derived from your CI system's environment variables.
        # Set it to control which reports share a deployment.
        # provider_deployment_id: "my-build-42",

        # Optional. Required when one CI job deploys more than once at a time,
        # e.g. a matrix over iOS and Android: it separates the legs' deployments.
        # provider_deployment_discriminator: "ios",

        # Optional, defaults to the current git branch, if available. Set to false to skip.
        branch: git_branch,

        # URL to your VCS commit URL
        commit_url: "https://github.com/team/repo/commit/ec78d7d81a6a66e9e89fd29f6e0616d5ba09840a",

        # Optional, defaults to current git commit hash if available. Set to false to skip
        sha: last_git_commit[:commit_hash],

        # Optional. The http(s) URL the deployment serves. Mostly for web apps,
        # but REQUIRED if `environment` names an environment that does not exist yet.
        # deploy_target: "https://staging.example.com",

        # Optional. Which app was deployed, when several deploy into one environment
        # service: "mobile-ios",

        # Optional. Defaults to "success", which is the status that evaluates triggers
        # status: "success",

        # Additional hash of key-value pairs to set as environment variables for test runs
        variables: {
          FOO: "bar"
        },

        # Only set this if your lane does not include `upload_to_qawolf`
        # executable_filename: "calculator_app_staging.apk",
        # executable_filename: "calculator_app_staging.ipa",
    )
end
```

The call returns the deployment id, and also sets it as `QAWOLF_DEPLOYMENT_ID`
in `ENV` and in the lane context. Runs start asynchronously afterwards, so no
run id comes back.

## `notify_deploy_qawolf` options

| Option | Required | Description |
| --- | --- | --- |
| `qawolf_api_key` | yes | Your QA Wolf API key. Also read from `QAWOLF_API_KEY`. |
| `workspace_id` | yes | The workspace to report into, from `whoami` in the QA Wolf API. Also read from `QAWOLF_WORKSPACE_ID`. Required even with a team API key. |
| `environment` | yes | The name or alias of the QA Wolf environment. Also read from `QAWOLF_ENVIRONMENT`. **A value that matches no environment creates one.** |
| `provider_deployment_id` | no | Your identifier for this deployment. Defaults to one derived from the CI system's variables, and to a generated one when no CI system is detected. |
| `provider_deployment_discriminator` | no | Appended to the derived identifier to separate deployments one CI job makes at the same time, such as the legs of a build matrix. |
| `status` | no | `pending`, `success`, `failure` or `inactive`. Defaults to `success`, the only status that evaluates triggers. |
| `deploy_target` | no | The http(s) URL the deployment serves. Required when `environment` names no existing environment. |
| `service` | no | Which application was deployed, when several deploy into one environment. |
| `executable_environment_key` | no | The env var the uploaded executable's path is exposed under. Defaults to `RUN_INPUT_PATH`. |
| `executable_filename` | no | Set by `upload_to_qawolf`; set it yourself only when that action did not run in this lane. |
| `branch` | no | Defaults to the current git branch. `false` sends nothing. |
| `sha` | no | Defaults to the current git commit hash. `false` sends nothing. |
| `commit_url` | no | An http(s) link to the deployed commit, for when QA Wolf cannot resolve the commit itself. |
| `commit_message` | no | The deployed commit's message. |
| `commit_author_name` | no | The deployed commit's author. |
| `repository` | no | The repository's full path, e.g. `my-org/my-app`, or `my-group/my-subgroup/my-app` for a GitLab project in a subgroup. Required with a PR/MR number. |
| `pull_request_number` | no | The GitHub pull request number. Requires `repository`. A build outside a pull request reports none. |
| `merge_request_number` | no | The GitLab merge request number. Requires `repository`. |
| `variables` | no | Key-value pairs exposed as `process.env` in the runs this deployment requests. |
| `qawolf_base_url` | no | Override the QA Wolf base URL. Also read from `QAWOLF_BASE_URL`. |

### `provider_deployment_id`

A deployment is identified by `provider_deployment_id`, and only a deployment's
**first** `success` report evaluates triggers. Two builds must therefore never
report under the same identifier, or the second one starts nothing.

The plugin derives the identifier from the CI system it detects — GitHub
Actions, GitLab CI, CircleCI, Buildkite, Jenkins, Bitbucket Pipelines, Bitrise
or Azure Pipelines — using the variables that distinguish a job and an attempt
from its siblings. On any other CI system, Xcode Cloud included, it generates a
random identifier and says so; set `provider_deployment_id` there yourself.

### Build matrices

The derived identifier is distinct per job definition and per attempt, and no
CI system exposes which leg of a matrix is running. A matrix over iOS and
Android therefore derives **the same identifier for both legs**: reporting into
one environment, the second leg starts no runs and the lane still goes green;
reporting into two environments, the second leg fails.

Pass `provider_deployment_discriminator` for every job that deploys more than
once at a time — a build matrix, a loop over environments — and the legs get
their own deployments:

```ruby
notify_deploy_qawolf(
    environment: "Staging",
    # In GitHub Actions, from a `strategy.matrix` value
    provider_deployment_discriminator: ENV.fetch("PLATFORM", nil),
)
```

### Reporting `pending` and then `success`

Two `notify_deploy_qawolf` calls only update one deployment when they report
the same identifier. A derived identifier is the same in both calls of one CI
job, but a generated one is not, so on an unsupported CI system pass
`provider_deployment_id` explicitly to both calls, or the `pending` report
never resolves and the `success` report becomes a second deployment.

## Upgrading from 0.x

**Before upgrading, make sure your workspace has current ("global") triggers
for this deployment.** Version 1.0.0 reports to an API that only current
triggers evaluate. Reporting into a workspace where nothing matches records the
deployment, starts no runs, and still **succeeds** — your lane goes green while
nothing is tested. Confirm the triggers with your QA Wolf representative first.

Then, in your `notify_deploy_qawolf` call:

1. Add `workspace_id`.
2. Replace `deployment_type` with `environment`, and **check the value**: it
   must be the name or an alias of an environment that already exists.
   Reporting a name that matches nothing creates a new environment, which no
   trigger is attached to. The old `deployment_type` value is not carried
   across; passing it now fails.
3. Remove `deduplication_key`. Set `provider_deployment_id` instead if you need
   control over which reports share a deployment.
4. Rename `deployment_url` to `deploy_target`, and make sure it is an http or
   https URL. Drop it if you were passing `nil`.
5. Replace `hosting_service`, `repository_name`, `repository_owner` and
   `repository_namespace` with a single `repository`, e.g.
   `repository: "my-org/my-app"`.
6. Replace any use of `QAWOLF_RUN_ID` with `QAWOLF_DEPLOYMENT_ID`. It holds a
   deployment id, not a run id: runs start asynchronously after the report, so
   the call cannot return one.

See [CHANGELOG.md](CHANGELOG.md) for the full list.

## PR/MR testing

> ⚠️ PR/MR testing must be activated by QA Wolf before it will have any effect. Please reach out to your QA Wolf representative to enable this feature.

When PR/MR testing is enabled, QA Wolf posts test results as a comment directly on the pull or merge request that triggered the build. This lets developers see test outcomes without leaving their code review workflow.

To enable PR Testing, pass the PR/MR number together with the repository details that identify where the code lives. QA Wolf uses these to locate the correct integration and post the comment.

### GitHub

```ruby
notify_deploy_qawolf(
    qawolf_api_key: ENV.fetch("QAWOLF_API_KEY", nil),
    workspace_id: ENV.fetch("QAWOLF_WORKSPACE_ID", nil),
    environment: "Staging",

    # The repository where QA Wolf should post the PR comment, as its full path
    repository: "my-org/my-app",

    # The pull request number. GitHub Actions has no variable for it, so pass it
    # into the job yourself, e.g. `env: PR_NUMBER: ${{ github.event.pull_request.number }}`.
    # It is empty on a build that is not a pull request, and no number is then reported.
    pull_request_number: ENV.fetch("PR_NUMBER", nil).to_i,

    branch: git_branch,
    sha: last_git_commit[:commit_hash],
)
```

### GitLab

```ruby
notify_deploy_qawolf(
    qawolf_api_key: ENV.fetch("QAWOLF_API_KEY", nil),
    workspace_id: ENV.fetch("QAWOLF_WORKSPACE_ID", nil),
    environment: "Staging",

    # The repository where QA Wolf should post the MR comment, as the project's full path
    repository: "my-group/my-app",

    # The merge request number. GitLab sets it on merge request pipelines only,
    # and no number is reported on a branch pipeline, where it is unset.
    merge_request_number: ENV.fetch("CI_MERGE_REQUEST_IID", nil).to_i,

    branch: git_branch,
    sha: last_git_commit[:commit_hash],
)
```

## Injecting instrumentation into an iOS IPA

If you are using `Allowlisted devices` feature of QA Wolf, inject QA Wolf iOS instrumentation so that QA Wolf platform
can intercept iOS system calls in the physical devices and provide test data.

```ruby
inject_qawolf_instrumentation(
  input: "./build/MyApp.ipa",              # path to the IPA produced by build_app
  output: "./build/MyApp_instrumented.ipa" # where to write the patched IPA
)
```

The output IPA doesn't have a valid signature so sign it again before uploading. Check https://docs.fastlane.tools/actions/resign/

## Run tests for this plugin

To run both the tests, and code style validation, run

```
bundle exec rake
```

To automatically fix many of the styling issues, use

```
bundle exec rubocop -A
```

## Issues and Feedback

For any other issues and feedback about this plugin, please submit it to this repository.

## Troubleshooting

If you have trouble using plugins, check out the [Plugins Troubleshooting](https://docs.fastlane.tools/plugins/plugins-troubleshooting/) guide.

## Using _fastlane_ Plugins

For more information about how the `fastlane` plugin system works, check out the [Plugins documentation](https://docs.fastlane.tools/plugins/create-plugin/).

## About _fastlane_

_fastlane_ is the easiest way to automate beta deployments and releases for your iOS and Android apps. To learn more, check out [fastlane.tools](https://fastlane.tools).

## Local development

The instructions below are for maintainers of this plugin.

### Setup

1. Clone the repository and cd into the directory

   ```bash
   git clone git@github.com:qawolf/fastlane-plugin-qawolf.git
   cd fastlane-plugin-qawolf
   ```

2. Install a modern version of Ruby. By default macOS ships with v2.x. I recommend using `asdf` to install the version defined in `.tool-versions` .
   1. [Install asdf](https://asdf-vm.com/guide/getting-started.html)

      ```bash
      # requires that git, curl, and coreutils are installed on macOS
      git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.1
      # ensure asdf is loaded into PATH (also add this to your .zshrc file)
      . "$HOME/.asdf/asdf.sh”
      ```

   2. [Install the asdf Ruby plugin](https://github.com/asdf-vm/asdf-ruby)

      ```bash
      asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git
      ```

   3. Install the specified version of Ruby

      ```bash
      # must be run inside the plugin root folder
      asdf install
      # confirm the ruby version
      ruby --version # <- should print a version matching .tool-versions
      ```

3. Install dependencies with the bundler CLI

   ```bash
   bundle install # may need to run `gem install bundler` first
   ```

4. Confirm unit tests are passing (this suite will mock API calls and the file system)

   ```bash
   bundle exec rake
   ```

### Use the plugin in an Android project

1. Create a new or use an existing Android project.
2. Open the directory of the project in a terminal.
3. [Setup a Gemfile and install fastlane](https://docs.fastlane.tools)

   ```bash
   # create Gemfile
   cat <<EOF >> ./Gemfile
   source "https://rubygems.org"

   gem "fastlane"
   EOF

   # install deps
   bundle update
   ```

4. Setup fastlane config

   ```bash
   bundle exec fastlane init
   ```

5. [While the Android setup guide can be useful](https://docs.fastlane.tools/getting-started/android/setup/), we only care about uploading the APK to our QA Wolf platform. So the next step is to build and install our plugin. **Make sure you update the path to the plugin!**

   ```bash
   # in the plugin root directory
   gem build fastlane-plugin-qawolf.gemspec # <- outputs a *.gem file

   # in the Android project root directory
   echo 'gem "fastlane-plugin-qawolf", path: "~/path/to/fastlane-plugin-qawolf"' >> Gemfile
   bundle install
   ```

6. Time to update the `./fastlane/Fastlane` file in the Android project.

   ```ruby

   default_platform(:android)

   platform :android do
     desc "Upload to QA Wolf"
     lane :upload do
       # builds an unsigned APK by default
       # in a real setup you will need to create a signed APK (or AAB) to use it in QA Wolf
       gradle(task: "clean assembleRelease")

       # relies on output of the gradle task and env vars QAWOLF_API_KEY,
       # QAWOLF_WORKSPACE_ID and QAWOLF_ENVIRONMENT
       # see example above for options
       upload_to_qawolf
       notify_deploy_qawolf
     end
   end
   ```

7. Grab a team API key from the team settings page. You can find it under “API Access”, mouseover the “Encrypted” text to copy the value. Set it as an environment variable, together with the workspace to report into.

   ```bash
   # The API key and the workspace are required to be set
   export QAWOLF_API_KEY="qawolf_..."
   export QAWOLF_WORKSPACE_ID="..."
   # the environment can be passed as an option instead
   export QAWOLF_ENVIRONMENT="Staging"
   # optionally override the base URL
   export QAWOLF_BASE_URL="https://app.qawolf.com"
   ```

8. Finally, run the command to build the APK and upload it to QA Wolf.

   ```bash
   bundle exec fastlane upload
   ```
