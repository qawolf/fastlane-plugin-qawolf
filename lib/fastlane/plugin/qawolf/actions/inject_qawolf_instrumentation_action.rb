require 'fastlane/action'
require 'fileutils'
require 'tmpdir'
require 'shellwords'
require 'net/http'
require 'openssl'
require 'uri'

module Fastlane
  module Actions
    # Fastlane action that injects QA Wolf's instrumentation.dylib into an IPA
    class InjectQawolfInstrumentationAction < Action
      # Path to the dylib that is shipped inside the gem (see lib/fastlane/plugin/qawolf/assets)
      DYLIB_ASSET_PATH = File.expand_path('../assets/instrumentation.dylib', __dir__).freeze

      OPTOOL_RELEASE_URL = 'https://github.com/alexzielenski/optool/releases/download/0.1/optool.zip'.freeze

      def self.run(params)
        input_ipa = File.expand_path(params[:input])
        output_ipa = File.expand_path(params[:output])

        UI.user_error!("Input IPA not found at '#{input_ipa}'") unless File.exist?(input_ipa)

        Dir.mktmpdir("qawolf_inject_") do |tmp_dir|
          dylib_path = download_dylib(tmp_dir)
          optool_path = download_optool(tmp_dir)

          UI.crash!("Instrumentation dylib not found at '#{dylib_path}'") unless File.exist?(dylib_path)

          # 1. Unzip IPA
          extracted_dir = File.join(tmp_dir, 'extracted')
          FileUtils.mkdir_p(extracted_dir)
          UI.message("🐺 Extracting IPA ...")
          sh("unzip -q #{Shellwords.escape(input_ipa)} -d #{Shellwords.escape(extracted_dir)}")

          # 2. Locate .app bundle and its main executable
          app_dir = Dir.glob(File.join(extracted_dir, 'Payload', '*.app')).first
          UI.user_error!('No .app bundle found inside IPA') if app_dir.nil?

          info_plist = File.join(app_dir, 'Info.plist')
          UI.user_error!("Info.plist not found at #{info_plist}") unless File.exist?(info_plist)
          executable_name = `\"/usr/libexec/PlistBuddy\" -c 'Print :CFBundleExecutable' #{Shellwords.escape(info_plist)}`.strip
          UI.user_error!('Unable to read CFBundleExecutable from Info.plist') if executable_name.empty?

          binary_path = File.join(app_dir, executable_name)
          UI.user_error!("App binary not found at #{binary_path}") unless File.exist?(binary_path)

          # 3. Inject dylib using optool (BSD licensed)
          frameworks_dir = File.join(app_dir, 'Frameworks')
          FileUtils.mkdir_p(frameworks_dir)

          UI.message("🐺 Injecting instrumentation.dylib into #{binary_path} with optool ...")
          sh("#{Shellwords.escape(optool_path)} install -c load -p '@loader_path/Frameworks/#{File.basename(dylib_path)}' -t #{Shellwords.escape(binary_path)}")

          # 4. Copy dylib into Frameworks directory so iOS signs/loads it properly
          FileUtils.cp(dylib_path, File.join(frameworks_dir, File.basename(dylib_path)))

          # 5. Repackage IPA
          Dir.chdir(extracted_dir) do
            UI.message("🐺 Repackaging IPA to #{output_ipa} ...")
            sh("zip -qr #{Shellwords.escape(output_ipa)} Payload")
          end
        end

        UI.success("🐺 Successfully created patched IPA at #{output_ipa}")
        return output_ipa
      end

      #####################################################
      # @!group Documentation
      #####################################################

      def self.description
        'Injects QA Wolf instrumentation.dylib into an IPA using insert_dylib.'
      end

      def self.details
        'Clones the insert_dylib utility, builds it, and uses it to add a LC_LOAD_DYLIB referencing instrumentation.dylib into the main executable of the given IPA.'
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :input,
                                       description: 'Path to the input IPA',
                                       type: String,
                                       optional: false,
                                       verify_block: proc do |value|
                                         UI.user_error!("File not found at path #{value}") unless File.exist?(value)
                                       end),
          FastlaneCore::ConfigItem.new(key: :output,
                                       description: 'Path where the output (patched) IPA should be written',
                                       type: String,
                                       optional: false)
        ]
      end

      def self.example_code
        [
          'inject_qawolf_instrumentation(
            input: "before.ipa",
            output: "output.ipa"
          )'
        ]
      end

      def self.authors
        ['QA Wolf']
      end

      def self.is_supported?(platform)
        platform == :ios
      end

      # Copies the dylib that is bundled with this plugin into +dir+ and returns the copied path.
      # The copy ensures we never mutate the original asset and that downstream tools can treat the
      # file as disposable.
      def self.download_dylib(dir)
        source = DYLIB_ASSET_PATH
        destination = File.join(dir, 'instrumentation.dylib')

        UI.user_error!("Embedded instrumentation.dylib not found at '#{source}'. Make sure the file is included in the gem package.") unless File.exist?(source)

        UI.message("🐺 Copying embedded instrumentation.dylib to #{destination} ...")
        FileUtils.cp(source, destination)

        destination
      end

      def self.download_optool(dir)
        destination_zip = File.join(dir, 'optool.zip')
        destination_extracted = File.join(dir, 'optool_extract')
        UI.message("🐺 Downloading optool from #{OPTOOL_RELEASE_URL} ...")
        content = fetch_https_with_redirect(OPTOOL_RELEASE_URL)
        File.binwrite(destination_zip, content)

        FileUtils.mkdir_p(destination_extracted)
        sh("unzip -q #{Shellwords.escape(destination_zip)} -d #{Shellwords.escape(destination_extracted)}")
        optool_bin = Dir.glob(File.join(destination_extracted, '**', 'optool')).first
        UI.user_error!('Failed to extract optool binary') if optool_bin.nil?
        FileUtils.chmod('+x', optool_bin)
        optool_bin
      end

      # Net::HTTP + OpenSSL can fail to GitHub with "unable to get certificate CRL" when CRL
      # distribution points are unreachable; we still verify the chain and hostname, but allow that
      # single verification error (same practical posture as common TLS stacks without strict CRL).
      def self.apply_github_download_ssl(http)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.verify_callback = lambda do |preverify_ok, store_context|
          preverify_ok || store_context.error == OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL
        end
        http
      end

      def self.fetch_https_with_redirect(url, limit = 5)
        raise 'Too many HTTP redirects' if limit.zero?

        uri = URI.parse(url)
        http = apply_github_download_ssl(Net::HTTP.new(uri.host, uri.port))
        response = http.start { |h| h.request(Net::HTTP::Get.new(uri)) }

        case response
        when Net::HTTPSuccess
          response.body
        when Net::HTTPRedirection
          location = response['location']
          UI.message("🐺 Redirected to #{location}")
          next_uri = URI.join(uri, location)
          fetch_https_with_redirect(next_uri.to_s, limit - 1)
        else
          UI.user_error!("Failed to download optool (HTTP #{response.code})")
        end
      end

      def self.default_dylib_path
        nil # method retained for compatibility, but currently unused
      end
    end
  end
end
