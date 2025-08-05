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
              sign_bundle(zsign_path, dylib_path, params, bundle_path, bundle_id)
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

      def self.sign_bundle(zsign_path, dylib_path, params, bundle_path, bundle_id)
        UI.message("Signing bundle #{bundle_path} (#{bundle_id})…")
        cmd = [
          zsign_path,
          '-k', params[:private_key_path],
          '-p', params[:password],
          '-m', params[:profile_path],
          '-b', bundle_id || params[:bundle_id],
          '-l', dylib_path,
          bundle_path
        ].map(&:to_s)

        Actions.sh(cmd.shelljoin)
      end

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

          FastlaneCore::ConfigItem.new(key: :profile_path,
                                       description: 'Path to the mobile provisioning profile',
                                       type: String,
                                       verify_block: proc do |value|
                                         UI.user_error!("Could not find mobile provisioning profile at path #{value}") unless File.exist?(value)
                                       end),

          FastlaneCore::ConfigItem.new(key: :bundle_id,
                                       description: 'Bundle identifier to resign with',
                                       type: String),

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
