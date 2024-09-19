source('https://rubygems.org')

# Calculates a set of unique abbreviations for a given set of strings
gem 'abbrev', '~> 0.1.2'
# This library provides arbitrary-precision decimal floating-point number class.
gem 'bigdecimal', '~> 3.1', '>= 3.1.8'
# Provides a consistent environment for Ruby projects by tracking and installing exact gem versions.
gem 'bundler', '~> 2.5', '>= 2.5.16'
# Automation tool for mobile developers.
gem 'fastlane', '~> 2.222'
# Provides a simple logging utility for outputting messages.
gem 'logger', '~> 1.6', '>= 1.6.1'
# Mixin to extend objects to be handled like a Mutex.
gem 'mutex_m', '~> 0.2.0'
# Class to build custom data structures, similar to a Hash.
gem 'ostruct', '~> 0.6.0'
# Provides an interactive debugging environment for Ruby.
gem 'pry', '~> 0.14.2'
# A simple task automation tool.
gem 'rake', '~> 13.2', '>= 13.2.1'
# A simple HTTP and REST client for Ruby, inspired by the Sinatra microframework style of specifying actions: get, put, post, delete.
gem 'rest-client', '~> 2.1'
# Behavior-driven testing tool for Ruby.
gem 'rspec', '~> 3.13'
# Formatter for RSpec to generate JUnit compatible reports.
gem 'rspec_junit_formatter', '~> 0.6.0'
# A Ruby static code analyzer and formatter.
gem 'rubocop', '~> 1.66', '>= 1.66.1', require: false
# A collection of RuboCop cops for performance optimizations.
gem 'rubocop-performance', '~> 1.22', '>= 1.22.1', require: false
# A RuboCop extension focused on enforcing tools.
gem 'rubocop-require_tools', '~> 0.1.2', require: false
# Code style checking for RSpec files. A plugin for the RuboCop code style enforcing & linting tool.
gem 'rubocop-rspec', '~> 3.0', '>= 3.0.5', require: false
# SimpleCov is a code coverage analysis tool for Ruby.
gem 'simplecov', '~> 0.22.0'
# WebMock allows stubbing HTTP requests and setting expectations on HTTP requests.
gem 'webmock', '~> 3.23', '>= 3.23.1'

gemspec

plugins_path = File.join(File.dirname(__FILE__), 'fastlane', 'Pluginfile')
eval_gemfile(plugins_path) if File.exist?(plugins_path)
