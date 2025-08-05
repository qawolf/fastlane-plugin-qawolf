require 'fileutils'
require 'open-uri'
require 'fastlane_core/ui/ui'
require 'cfpropertylist'

module Fastlane
  UI = FastlaneCore::UI unless Fastlane.const_defined?(:UI)

  module Helper
    # Helper utilities for downloading QA Wolf resign assets and inspecting IPA bundles
    class ResignHelper
      # Pinned version of qawolf-ios-resign assets unless overridden by user
      RESIGN_VERSION = 'v0.0.3'.freeze

      class << self
        # Returns [zsign_path, instrumentation_dylib_path]
        def ensure_assets(version = nil)
          version ||= RESIGN_VERSION

          arch = host_arch
          base_url = "https://github.com/qawolf/qawolf-ios-resign/releases/download/#{version}/"

          zsign_filename = "zsign-darwin-#{arch}"
          dylib_filename = 'instrumentation.dylib'

          cache_dir = File.expand_path(File.join('~', '.fastlane-plugin-qawolf', version, arch))
          FileUtils.mkdir_p(cache_dir)

          zsign_path = File.join(cache_dir, zsign_filename)
          dylib_path = File.join(cache_dir, dylib_filename)

          download_file(base_url + zsign_filename, zsign_path) unless File.exist?(zsign_path)
          download_file(base_url + dylib_filename, dylib_path) unless File.exist?(dylib_path)

          FileUtils.chmod('+x', zsign_path)

          [zsign_path, dylib_path]
        end

        # Recursively locate .app and .appex bundles and return a hash { path => bundle_id }
        def find_bundles(root_dir)
          bundles = {}
          Dir.glob(File.join(root_dir, '**', '*.{app,appex}')).each do |bundle_path|
            info_plist = File.join(bundle_path, 'Info.plist')
            next unless File.exist?(info_plist)

            bundle_id = parse_bundle_identifier(info_plist)
            bundles[bundle_path] = bundle_id if bundle_id
          end
          bundles
        end

        # Parse Info.plist and return the CFBundleIdentifier
        def parse_bundle_identifier(plist_path)
          plist = CFPropertyList::List.new(file: plist_path)
          data = CFPropertyList.native_types(plist.value)
          data['CFBundleIdentifier']
        rescue StandardError => e
          UI.error("Failed to parse Info.plist at #{plist_path}: #{e.message}")
          nil
        end

        private

        def host_arch
          arch = `uname -m`.strip
          return 'arm64' if arch == 'arm64'
          return 'amd64' if arch == 'x86_64'

          UI.user_error!("Unsupported CPU architecture '#{arch}' for zsign assets")
        end

        # Download file from +url+ to +destination+
        def download_file(url, destination)
          UI.message("Downloading #{url} → #{destination}")
          URI.open(url) do |remote| # rubocop:disable Security/Open
            File.open(destination, 'wb') do |file|
              IO.copy_stream(remote, file)
            end
          end
        rescue OpenURI::HTTPError => e
          UI.user_error!("Failed to download #{url}: #{e.message}")
        end
      end
    end
  end
end
