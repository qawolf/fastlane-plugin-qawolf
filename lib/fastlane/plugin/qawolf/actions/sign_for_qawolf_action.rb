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
      def self.run(params)
        UI.message('Starting resigning process for QA Wolf…')

        version = params[:version] || Fastlane::Helper::ResignHelper::RESIGN_VERSION
        zsign_path, dylib_path = Fastlane::Helper::ResignHelper.ensure_assets(version)

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
              sign_bundle(zsign_path, dylib_path, params, bundle_path, bundle_id, profile_for_bundle)
            end
          end

          # Repack IPA
          repack_ipa(tmp_dir, params[:output_path])
        end

        UI.success("Successfully resigned IPA saved at #{params[:output_path]}")
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

      # Extract entitlements from the original bundle, merge them with the
      # provisioning profile's entitlements (mimicking Xcode's behaviour) and
      # pass the merged file to zsign via the -e flag.
      def self.sign_bundle(zsign_path, dylib_path, params, bundle_path, bundle_id, profile_path)
        UI.message("Signing bundle #{bundle_path} (#{bundle_id})…")

        merged_entitlements_path = merge_entitlements(bundle_path, profile_path)

        cmd = [
          zsign_path,
          '-k', params[:private_key_path],
          '-p', params[:password],
          '-m', profile_path,
          '-b', bundle_id,
          ('-e' if merged_entitlements_path), merged_entitlements_path,
          '-l', dylib_path,
          bundle_path
        ].compact.map(&:to_s)

        Actions.sh(cmd.shelljoin)
      ensure
        # Clean up temp entitlements file if we created one
        FileUtils.rm_f(merged_entitlements_path) if merged_entitlements_path && File.exist?(merged_entitlements_path)
      end

      #---------------------------------------------------------------
      # Entitlements helpers
      #---------------------------------------------------------------

      # Returns path to a temp entitlements plist that is the result of merging
      # the app's own entitlements with those in the provisioning profile.
      # May return nil if we fail to obtain any entitlements (should not happen
      # in normal scenarios).
      def self.merge_entitlements(bundle_path, profile_path)
        app_entitlements     = read_entitlements_from_bundle(bundle_path)
        profile_entitlements = read_entitlements_from_profile(profile_path)

        merged = deep_merge_entitlements(app_entitlements, profile_entitlements)
        return nil if merged.empty?

        require 'tempfile'
        tf = Tempfile.new(['qawolf_entitlements', '.plist'])
        require 'plist'
        File.write(tf.path, merged.to_plist)

        # Validate the generated XML so that zsign receives a proper plist.
        unless system('/usr/bin/plutil', '-lint', tf.path, out: File::NULL)
          UI.user_error!('Generated entitlements plist is invalid XML')
        end

        tf.close
        tf.path
      end

      def self.read_entitlements_from_bundle(bundle_path)
        output = Actions.sh("/usr/bin/codesign -d --entitlements :- #{Shellwords.escape(bundle_path)} 2>/dev/null", log: false)
        return {} if output.to_s.strip.empty?

        plist = CFPropertyList::List.new(data: output)
        CFPropertyList.native_types(plist.value) || {}
      rescue StandardError => e
        UI.important("Failed to read entitlements from bundle #{bundle_path}: #{e.message}")
        {}
      end

      def self.read_entitlements_from_profile(profile_path)
        cms_xml = Actions.sh("/usr/bin/security cms -D -i #{Shellwords.escape(profile_path)}", log: false)
        plist   = CFPropertyList::List.new(data: cms_xml)
        dict    = CFPropertyList.native_types(plist.value)
        dict.fetch('Entitlements', {})
      rescue StandardError => e
        UI.important("Failed to read entitlements from provisioning profile #{profile_path}: #{e.message}")
        {}
      end

      # Simple deep merge: arrays are union-merged, scalars – profile value wins.
      # rubocop:disable Metrics/PerceivedComplexity
      def self.deep_merge_entitlements(app_ent, profile_ent)
        merged = app_ent.dup
        profile_ent.each do |k, v|
          if merged.key?(k)
            if v.kind_of?(Array) && merged[k].kind_of?(Array)
              merged[k] = (merged[k] + v).uniq
            elsif v.kind_of?(Hash) && merged[k].kind_of?(Hash)
              merged[k] = deep_merge_entitlements(merged[k], v)
            elsif v.kind_of?(String) && merged[k].kind_of?(Array)
              # Keep broader array form when profile only has wildcard string
              # or mismatched scalar; Xcode preserves the array.
              # do nothing, keep existing array
            else
              merged[k] = v
            end
          else
            merged[k] = v
          end
        end
        merged
      end
      # rubocop:enable Metrics/PerceivedComplexity

      #####################################################
      # @!group Documentation
      #####################################################

      def self.description
        'Resign an IPA with QA Wolf instrumentation using zsign.'
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :version,
                                       description: 'qawolf-ios-resign release version to use',
                                       optional: true,
                                       type: String,
                                       default_value: Fastlane::Helper::ResignHelper::RESIGN_VERSION),

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
