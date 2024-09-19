lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'fastlane/plugin/qawolf/version'

Gem::Specification.new do |spec|
  spec.name          = 'fastlane-plugin-qawolf'
  spec.version       = Fastlane::Qawolf::VERSION
  spec.author        = 'Simon Ingeson'
  spec.email         = 'simon@qawolf.com'

  spec.summary       = 'Fastlane plugin for QA Wolf integration.'
  spec.homepage      = "https://github.com/qawolf/fastlane-plugin-qawolf"
  spec.license       = "MIT"

  spec.files         = Dir["lib/**/*"] + %w(README.md LICENSE)
  spec.require_paths = ['lib']
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.required_ruby_version = '>= 2.6'

  # Don't add a dependency to fastlane or fastlane_re
  # since this would cause a circular dependency

  spec.add_dependency('rest-client', '~> 2.1')
end
