$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'simplecov'

# SimpleCov.minimum_coverage 95
SimpleCov.start

require 'webmock/rspec'

# Prevent all network connections
WebMock.disable_net_connect!(allow_localhost: true)

# This module is only used to check the environment is currently a testing env
module SpecHelper
end

require 'fastlane' # to import the Action super class
require 'fastlane/plugin/qawolf' # import the actual plugin

Fastlane.load_actions # load other actions (in case your plugin calls other actions or shared values)
