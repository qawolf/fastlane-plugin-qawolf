# qawolf plugin

[![fastlane Plugin Badge](https://rawcdn.githack.com/fastlane/fastlane/master/fastlane/assets/plugin-badge.svg)](https://rubygems.org/gems/fastlane-plugin-qawolf)

## Getting Started

This project is a [_fastlane_](https://github.com/fastlane/fastlane) plugin. To get started with `fastlane-plugin-qawolf`, add it to your project by running:

```
# Add this to your Gemfile
gem "fastlane-plugin-qawolf", git: "https://github.com/qawolf/fastlane-plugin-qawolf"
```

## About qawolf

Fastlane plugin for QA Wolf integration.

Uploads build artifacts (IPA, APK, or AAB) to QA Wolf storage for automated testing.

## Example

Check out the [example `Fastfile`](fastlane/Fastfile) to see how to use this plugin. Try it by cloning the repo, running `fastlane install_plugins` and `bundle exec fastlane test`.

```ruby
lane :build do
  # option 1: rely on env vars and output from other lanes
  # QAWOLF_API_KEY must be set in the environment
  # expects `gradle` to have set the APK output path
  gradle
  qawolf # alias for upload_to_qawolf

  # option 2: pass in the values directly
  upload_to_qawolf(
    qawolf_api_key: "qawolf_...",
    file_path: "./build/app.apk"
  )
end
```

## Run tests for this plugin

To run both the tests, and code style validation, run

```
rake
```

To automatically fix many of the styling issues, use
```
rubocop -a
```

## Issues and Feedback

For any other issues and feedback about this plugin, please submit it to this repository.

## Troubleshooting

If you have trouble using plugins, check out the [Plugins Troubleshooting](https://docs.fastlane.tools/plugins/plugins-troubleshooting/) guide.

## Using _fastlane_ Plugins

For more information about how the `fastlane` plugin system works, check out the [Plugins documentation](https://docs.fastlane.tools/plugins/create-plugin/).

## About _fastlane_

_fastlane_ is the easiest way to automate beta deployments and releases for your iOS and Android apps. To learn more, check out [fastlane.tools](https://fastlane.tools).
