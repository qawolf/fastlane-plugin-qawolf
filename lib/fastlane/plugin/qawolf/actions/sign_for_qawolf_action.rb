require 'fastlane/action'
require 'tmpdir'
require 'fileutils'
require 'zip'
require 'shellwords'
require_relative '../helper/resign_helper'

module Fastlane
  module Actions
    class SignForQawolfAction < Action
      # Entry point for the action
      # rubocop:disable Metrics/PerceivedComplexity
      def self.run(params)
        UI.message('Starting resigning process for QA Wolf…')

        version = params[:version] || Fastlane::Helper::ResignHelper::RESIGN_VERSION
        zsign_path, dylib_path = Fastlane::Helper::ResignHelper.ensure_assets(version)

        if params[:debug]
          UI.important('QA Wolf resign debug is enabled. Printing signing assets info…')
          debug_print_credentials(params)
        end

        # Create temp directory for IPA unpacking
        Dir.mktmpdir('qawolf-resign') do |tmp_dir|
          payload_dir = unpack_ipa(params[:file_path], tmp_dir)

          bundles = Fastlane::Helper::ResignHelper.find_bundles(payload_dir)
          extensions, apps = bundles.partition { |path, _| path.end_with?('.appex') }.map(&:to_h)

          UI.message("Found #{apps.size} apps and #{extensions.size} extensions to sign")

          # Sign extensions first
          [extensions, apps].each do |bundle_set|
            bundle_set.each do |bundle_path, bundle_id|
              profiles = params[:provisioning_profile_paths] || {}
              profile_for_bundle = profiles[bundle_id]
              UI.user_error!("No provisioning profile path provided for bundle #{bundle_id}") unless profile_for_bundle
              cert_for_bundle = (params[:certificate_paths] || {})[bundle_id] || params[:certificate_path]
              sign_bundle(zsign_path, dylib_path, params, bundle_path, bundle_id, profile_for_bundle, cert_for_bundle)
            end
          end

          # Repack IPA
          repack_ipa(tmp_dir, params[:output_path])
        end

        UI.success("Successfully resigned IPA saved at #{params[:output_path]}")
        # rubocop:enable Metrics/PerceivedComplexity
      end

      #####################################################
      # @!group Helper methods
      #####################################################

      def self.unpack_ipa(ipa_path, destination)
        UI.message("Unpacking #{ipa_path}…")
        Zip::File.open(ipa_path) do |zip_file|
          zip_file.each do |entry|
            target = File.join(destination, entry.name)
            FileUtils.mkdir_p(File.dirname(target))
            zip_file.extract(entry, target) { true }
          end
        end
        File.join(destination, 'Payload')
      end

      def self.repack_ipa(source_dir, output_path)
        UI.message('Repacking resigned IPA…')
        output_tmp = "#{output_path}.tmp"
        FileUtils.rm_f(output_tmp)
        entries = Dir[File.join(source_dir, '**', '*')]
        Zip::File.open(output_tmp, Zip::File::CREATE) do |zipfile|
          entries.each do |file|
            next if File.directory?(file)

            zip_entry = file.sub(source_dir + File::SEPARATOR, '')
            zipfile.add(zip_entry, file)
          end
        end
        FileUtils.mv(output_tmp, output_path)
      end

      # Extract the bundle's own entitlements and pass them straight to zsign (-e)
      # so we preserve the exact entitlement set. No merging is performed.
      def self.sign_bundle(zsign_path, dylib_path, params, bundle_path, bundle_id, profile_path, certificate_path = nil)
        UI.message("Signing bundle #{bundle_path} (#{bundle_id})…")

        debug_print_profile(profile_path, bundle_id) if params[:debug]

        entitlements_path = extract_entitlements(bundle_path)

        cmd = [
          zsign_path,
          (params[:debug] ? '-d' : nil),
          '-k', params[:private_key_path],
          '-p', params[:password],
          '-m', profile_path,
          ('-c' if certificate_path), certificate_path,
          '-b', bundle_id,
          '-e', entitlements_path,
          '-l', dylib_path,
          bundle_path
        ].compact.map(&:to_s)

        Actions.sh(cmd.shelljoin)
      ensure
        # Clean up temporary entitlements file
        FileUtils.rm_f(entitlements_path) if entitlements_path && File.exist?(entitlements_path)
      end

      #---------------------------------------------------------------
      # Entitlements helpers
      #---------------------------------------------------------------

      # Print information about provided signing materials to help debug
      # rubocop:disable Metrics/PerceivedComplexity
      def self.debug_print_credentials(params)
        pk_path = params[:private_key_path]
        cert_path = params[:certificate_path]

        if pk_path && File.exist?(pk_path)
          UI.message("Private key path: #{pk_path}")
          begin
            if pk_path.downcase.end_with?('.p12', '.pfx')
              # Print basic info about certs embedded in P12 (no keys)
              output = Actions.sh("openssl pkcs12 -info -in #{Shellwords.escape(pk_path)} -passin pass:#{Shellwords.escape(params[:password])} -nokeys 2>/dev/null", log: false)
              count = output.to_s.scan('subject=').size
              UI.message("P12 certificate count: #{count}")
              # Reduce noise; show subjects/issuers/fingerprints if present
              subjects = output.to_s.lines.select { |l| l.include?('subject=') || l.include?('issuer=') }
              UI.message("P12 contains the following subjects/issuers (truncated):\n#{subjects.join}")
            else
              # Non-P12 private key; show key type if possible
              key_info = Actions.sh("openssl pkey -in #{Shellwords.escape(pk_path)} -passin pass:#{Shellwords.escape(params[:password])} -text -noout 2>/dev/null | head -n 1", log: false)
              UI.message("Private key type: #{key_info.to_s.strip}")
            end
          rescue StandardError => e
            UI.important("Failed to inspect private key: #{e.message}")
          end
        else
          UI.important('Private key path does not exist or was not provided')
        end

        # Inspect default certificate, if provided
        if cert_path && File.exist?(cert_path)
          UI.message("Certificate path: #{cert_path}")
          begin
            inform = cert_path.downcase.end_with?('.der', '.cer') ? 'der' : 'pem'
            cert_info = Actions.sh("openssl x509 -in #{Shellwords.escape(cert_path)} -inform #{inform} -noout -subject -issuer -fingerprint -serial 2>/dev/null", log: false)
            UI.message("Certificate info:\n#{cert_info}")
          rescue StandardError => e
            UI.important("Failed to inspect certificate: #{e.message}")
          end
        end
        # rubocop:enable Metrics/PerceivedComplexity
      end

      # Decode provisioning profile and print expected authorities and identifiers
      def self.debug_print_profile(profile_path, bundle_id)
        UI.message("Provisioning profile for #{bundle_id}: #{profile_path}")
        begin
          cms_xml = Actions.sh("/usr/bin/security cms -D -i #{Shellwords.escape(profile_path)}", log: false)
          plist   = CFPropertyList::List.new(data: cms_xml)
          dict    = CFPropertyList.native_types(plist.value)

          ent = dict['Entitlements'] || {}
          app_id = ent['application-identifier']
          team_ids = dict['TeamIdentifier'] || []
          UI.message("Profile AppID: #{app_id}")
          UI.message("Profile TeamIdentifier(s): #{team_ids.join(', ')}")

          dev_certs = dict['DeveloperCertificates'] || []
          UI.message("Profile DeveloperCertificates count: #{dev_certs.size}")

          # Print subject and fingerprint for first few certificates
          require 'tempfile'
          dev_certs.first(3).each_with_index do |data, idx|
            Tempfile.create(["prov_cert_", ".der"]) do |tf|
              tf.binmode
              tf.write(data)
              tf.flush
              info = Actions.sh("openssl x509 -inform der -in #{Shellwords.escape(tf.path)} -noout -subject -fingerprint 2>/dev/null", log: false)
              UI.message("Profile Cert[#{idx}] => #{info.strip}")
            end
          end
        rescue StandardError => e
          UI.important("Failed to inspect provisioning profile #{profile_path}: #{e.message}")
        end
      end

      # Extract entitlements from the existing signed bundle and save them
      # to a temporary plist file which will be provided to zsign.
      # Returns the temp file path. Raises if extraction fails.
      def self.extract_entitlements(bundle_path)
        output = Actions.sh("/usr/bin/codesign -d --entitlements :- #{Shellwords.escape(bundle_path)} 2>/dev/null", log: false)
        if output.to_s.strip.empty?
          UI.user_error!("Failed to extract entitlements from bundle #{bundle_path}; codesign returned empty output")
        end

        require 'tempfile'
        tf = Tempfile.new(['qawolf_entitlements', '.plist'])
        File.write(tf.path, output)
        tf.close
        tf.path
      rescue StandardError => e
        UI.user_error!("Failed to extract entitlements from bundle #{bundle_path}: #{e.message}")
      end

      #####################################################
      # @!group Documentation
      #####################################################

      def self.description
        'Resign an IPA with QA Wolf instrumentation using zsign.'
      end

      # rubocop:disable Metrics/PerceivedComplexity
      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :version,
                                       description: 'qawolf-ios-resign release version to use',
                                       optional: true,
                                       type: String,
                                       default_value: Fastlane::Helper::ResignHelper::RESIGN_VERSION),
          FastlaneCore::ConfigItem.new(key: :debug,
                                       description: 'Enable verbose resign debug (passes -d to zsign and prints signing asset info)',
                                       optional: true,
                                       type: TrueClass,
                                       default_value: false),

          FastlaneCore::ConfigItem.new(key: :private_key_path,
                                       description: 'Path to the private key or P12 file',
                                       type: String,
                                       verify_block: proc do |value|
                                         UI.user_error!("Could not find private key at path #{value}") unless File.exist?(value)
                                       end),

          FastlaneCore::ConfigItem.new(key: :password,
                                       description: 'Password for the private key or P12',
                                       type: String,
                                       sensitive: true,
                                       verify_block: proc do |value|
                                         UI.user_error!('Password must be provided and cannot be empty') if value.to_s.strip.empty?
                                       end),

          FastlaneCore::ConfigItem.new(key: :certificate_path,
                                       description: 'Path to the signing certificate (.pem/.cer) when it is separate from the private key',
                                       optional: true,
                                       type: String,
                                       verify_block: proc do |value|
                                         UI.user_error!("Could not find certificate at path #{value}") unless value.nil? || File.exist?(value)
                                       end),

          FastlaneCore::ConfigItem.new(key: :certificate_paths,
                                       description: 'Hash mapping bundle identifiers to certificate paths',
                                       optional: true,
                                       type: Hash,
                                       default_value: {},
                                       verify_block: proc do |value|
                                         UI.user_error!('certificate_paths must be a Hash') unless value.kind_of?(Hash)
                                         value.each do |bundle_id, path|
                                           UI.user_error!("Could not find certificate at path #{path} for bundle #{bundle_id}") unless File.exist?(path)
                                         end
                                       end),

          FastlaneCore::ConfigItem.new(key: :provisioning_profile_paths,
                                       description: 'Hash mapping bundle identifiers to mobile provisioning profile paths',
                                       type: Hash,
                                       verify_block: proc do |value|
                                         UI.user_error!('provisioning_profile_paths must be a Hash') unless value.kind_of?(Hash)
                                         value.each do |bundle_id, path|
                                           UI.user_error!("Could not find mobile provisioning profile at path #{path} for bundle #{bundle_id}") unless File.exist?(path)
                                         end
                                       end),

          FastlaneCore::ConfigItem.new(key: :file_path,
                                       description: 'Path to the IPA to resign',
                                       type: String,
                                       verify_block: proc do |value|
                                         UI.user_error!("Could not find IPA at path #{value}") unless File.exist?(value)
                                       end),

          FastlaneCore::ConfigItem.new(key: :output_path,
                                       description: 'Destination path for the resigned IPA',
                                       type: String)
        ]
      end
      # rubocop:enable Metrics/PerceivedComplexity

      def self.authors
        ['QA Wolf']
      end

      def self.return_value
        'Path to the resigned IPA file.'
      end

      def self.is_supported?(platform)
        platform == :ios
      end
    end
  end
end
