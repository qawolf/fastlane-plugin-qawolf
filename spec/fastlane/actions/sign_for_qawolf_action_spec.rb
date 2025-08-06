# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

require 'webmock/rspec'

describe Fastlane::Actions::SignForQawolfAction do
  describe '#run' do
    let(:helper) { Fastlane::Helper::ResignHelper }

    # Provide common stubs to avoid touching the filesystem/network
    before do
      # Skip actual IPA unpacking/packing
      allow(described_class).to receive_messages(unpack_ipa: '/fake/payload', repack_ipa: true)
    end

    def stub_assets(zsign_path, dylib_path)
      allow(helper).to receive(:ensure_assets).and_return([zsign_path, dylib_path])
    end

    def create_tmp_files(dir, names)
      names.each_with_object({}) do |name, acc|
        path = File.join(dir, name)
        File.write(path, name)
        acc[name.to_sym] = path
      end
    end

    it 'uses a single profile for all bundles when no overrides are provided' do
      Dir.mktmpdir do |tmp_dir|
        paths = create_tmp_files(tmp_dir, %w[app.ipa key.p12 default.mobileprovision])
        ipa_path      = paths[:'app.ipa']
        key_path      = paths[:'key.p12']
        default_prof  = paths[:'default.mobileprovision']

        zsign_path = '/fake/cache/zsign'
        dylib_path = '/fake/cache/instrumentation.dylib'
        stub_assets(zsign_path, dylib_path)

        allow(helper).to receive(:find_bundles).and_return({
          '/fake/payload/MyApp.app' => 'com.example.app'
        })

        executed_cmds = []
        allow(Fastlane::Actions).to receive(:sh) do |cmd|
          executed_cmds << cmd
          true
        end

        ff = Fastlane::FastFile.new.parse("lane :test do
          sign_for_qawolf(
            private_key_path: '#{key_path}',
            password:         'secret',
            profile_path:     '#{default_prof}',
            bundle_id:        'com.example.app',
            file_path:        '#{ipa_path}',
            output_path:      '#{tmp_dir}/out.ipa'
          )
        end")

        expect { ff.runner.execute(:test) }.not_to raise_error
        expect(executed_cmds.size).to eq(1)
        expect(executed_cmds.first).to include("-m #{default_prof}")
      end
    end

    it 'uses override profiles for every bundle when provided' do
      Dir.mktmpdir do |tmp_dir|
        paths = create_tmp_files(tmp_dir, %w[app.ipa key.p12 default.mobileprovision app.mobileprovision share.mobileprovision broadcast.mobileprovision])
        ipa_path     = paths[:'app.ipa']
        key_path     = paths[:'key.p12']
        default_prof = paths[:'default.mobileprovision']
        share_prof   = paths[:'share.mobileprovision']
        broadcast_prof = paths[:'broadcast.mobileprovision']

        zsign_path = '/fake/cache/zsign'
        dylib_path = '/fake/cache/instrumentation.dylib'
        stub_assets(zsign_path, dylib_path)

        bundles = {
          '/fake/payload/BroadcastExt.appex' => 'com.example.app.broadcast',
          '/fake/payload/ShareExt.appex'     => 'com.example.app.share',
          '/fake/payload/MyApp.app'          => 'com.example.app'
        }
        allow(helper).to receive(:find_bundles).and_return(bundles)

        executed_cmds = []
        allow(Fastlane::Actions).to receive(:sh) do |cmd|
          executed_cmds << cmd
          true
        end

        ff = Fastlane::FastFile.new.parse("lane :test do
          sign_for_qawolf(
            private_key_path: '#{key_path}',
            password:         'secret',
            profile_path:     '#{default_prof}',
            extension_profile_paths: {
              'com.example.app.broadcast' => '#{broadcast_prof}',
              'com.example.app.share' => '#{share_prof}'
            },
            bundle_id:        'com.example.app',
            file_path:        '#{ipa_path}',
            output_path:      '#{tmp_dir}/out.ipa'
          )
        end")

        expect { ff.runner.execute(:test) }.not_to raise_error

        app_cmd   = executed_cmds.find { |c| c.include?('MyApp.app') }
        share_cmd = executed_cmds.find { |c| c.include?('ShareExt.appex') }
        broadcast_cmd = executed_cmds.find { |c| c.include?('BroadcastExt.appex') }

        expect(app_cmd).to include("-m #{default_prof}")
        expect(share_cmd).to include("-m #{share_prof}")
        expect(broadcast_cmd).to include("-m #{broadcast_prof}")
      end
    end

    it 'falls back to the default profile for bundles without an override' do
      Dir.mktmpdir do |tmp_dir|
        paths = create_tmp_files(tmp_dir, %w[app.ipa key.p12 default.mobileprovision share.mobileprovision broadcast.mobileprovision])
        ipa_path     = paths[:'app.ipa']
        key_path     = paths[:'key.p12']
        default_prof = paths[:'default.mobileprovision']
        share_prof   = paths[:'share.mobileprovision']
        broadcast_prof = paths[:'broadcast.mobileprovision']

        zsign_path = '/fake/cache/zsign'
        dylib_path = '/fake/cache/instrumentation.dylib'
        stub_assets(zsign_path, dylib_path)

        bundles = {
          '/fake/payload/BroadcastExt.appex' => 'com.example.app.broadcast',
          '/fake/payload/ShareExt.appex'     => 'com.example.app.share',
          '/fake/payload/MyApp.app'          => 'com.example.app'
        }
        allow(helper).to receive(:find_bundles).and_return(bundles)

        executed_cmds = []
        allow(Fastlane::Actions).to receive(:sh) do |cmd|
          executed_cmds << cmd
          true
        end

        ff = Fastlane::FastFile.new.parse("lane :test do
          sign_for_qawolf(
            private_key_path: '#{key_path}',
            password:         'secret',
            profile_path:     '#{default_prof}',
            extension_profile_paths: {
              'com.example.app.broadcast' => '#{broadcast_prof}'
            },
            bundle_id:        'com.example.app',
            file_path:        '#{ipa_path}',
            output_path:      '#{tmp_dir}/out.ipa'
          )
        end")

        expect { ff.runner.execute(:test) }.not_to raise_error

        app_cmd   = executed_cmds.find { |c| c.include?('MyApp.app') }
        share_cmd = executed_cmds.find { |c| c.include?('ShareExt.appex') }
        broadcast_cmd = executed_cmds.find { |c| c.include?('BroadcastExt.appex') }

        expect(app_cmd).to include("-m #{default_prof}")
        expect(share_cmd).to include("-m #{default_prof}")
        expect(broadcast_cmd).to include("-m #{broadcast_prof}")
      end
    end
  end
end

# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
