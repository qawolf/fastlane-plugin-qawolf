# qawolf plugin

## Getting Started

This project is a [_fastlane_](https://github.com/fastlane/fastlane) plugin. To get started with `fastlane-plugin-qawolf`, add it to your project by running:

```
# Add this to your Gemfile
gem "fastlane-plugin-qawolf", git: "https://github.com/qawolf/fastlane-plugin-qawolf", tag: "0.3.1"
```

## About qawolf

Fastlane plugin for QA Wolf integration.

Uploads build artifacts (IPA, APK, or AAB) to QA Wolf storage for automated testing. Optionally triggers a test run on QA Wolf.

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

    # Trigger a test run on QA Wolf
    # Optional, only use when deployment triggers are enabled in QA Wolf
    notify_deploy_qawolf(
        # Must be set or available as env var QAWOLF_API_KEY
        qawolf_api_key: "qawolf_...",

        # Optional, but set if requested by the QA Wolf team.
        # This is mostly to help distinguish between multiple apps within the same team/environment.
        executable_environment_key: "RUN_INPUT_PATH",

        # Optional, defaults to the current git branch, if available. Set to false to skip.
        branch: git_branch,

        # URL to your VCS commit URL
        commit_url: "https://github.com/team/repo/commit/ec78d7d81a6a66e9e89fd29f6e0616d5ba09840a",

        # Set to cancel ongoing test runs with the same value
        deduplication_key: "some_idempotent_value",

        # Must be set if configured in the QA Wolf deployment trigger
        deployment_type: "deployment_name",

        # Can be left empty as it's mostly for web tests
        # If set, will be available as `process.env.URL`
        deployment_url: nil,

        # If configured in QA Wolf, set to GitHub or GitLab as needed
        hosting_service: "GitHub",

        # Optional, defaults to current git commit hash if available. Set to false to skip
        sha: last_git_commit[:commit_hash],

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

        # relies on output of the gradle task and env var QAWOLF_API_KEY
        # see example above for options
        upload_to_qawolf
        notify_deploy_qawolf
      end
    end
    ```

7. Grab a team API key from staging by going to the team settings page. You can find it under “API Access”, mouseover the “Encrypted” text to copy the value. Set it as an environment variable as described below. Also set an environment variable to override the base URL to target staging instead of production. You can also target a preview environment if desired.

    ```bash
    # The API key is required to be set
    export QAWOLF_API_KEY="qawolf_..."
    # optionally override the base URL
    export QAWOLF_BASE_URL="https://app.qawolf.com"
    ```

8. Finally, run the command to build the APK and upload it to QA Wolf.

    ```bash
    bundle exec fastlane upload
    ```
