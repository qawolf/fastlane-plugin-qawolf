# rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations

require 'webmock/rspec'

describe Fastlane::Actions::SignForQawolfAction do
  describe '#run' do
    let(:helper) { Fastlane::Helper::ResignHelper }

    it 'downloads and uses zsign and instrumentation.dylib' do
      Dir.mktmpdir do |tmp_dir|
        ipa_path = File.join(tmp_dir, 'app.ipa')
        File.write(ipa_path, 'dummy')

        key_path = File.join(tmp_dir, 'key.p12')
        prof_path = File.join(tmp_dir, 'profile.mobileprovision')
        File.write(key_path, 'key')
        File.write(prof_path, 'profile')

        zsign_path = '/fake/cache/zsign-darwin-arm64'
        dylib_path = '/fake/cache/instrumentation.dylib'

        # Mock ensure_assets to return fake paths and verify downloads
        downloads_performed = []
        allow(helper).to receive(:ensure_assets) do |version|
          downloads_performed << "zsign-darwin-arm64 from v#{version || 'v0.0.3'}"
          downloads_performed << "instrumentation.dylib from v#{version || 'v0.0.3'}"
          [zsign_path, dylib_path]
        end

        # Mock bundle finding and other internals
        allow(helper).to receive(:find_bundles).and_return({
          '/fake/payload/MyApp.app' => 'com.example.app'
        })
        allow(described_class).to receive_messages(unpack_ipa: '/fake/payload', repack_ipa: true)

        # Capture zsign command
        executed_command = nil
        allow(Fastlane::Actions).to receive(:sh) do |cmd|
          executed_command = cmd
          true
        end

        # Run action
        ff = Fastlane::FastFile.new.parse("lane :test do
          sign_for_qawolf(
            private_key_path: '#{key_path}',
            password:         'secret',
            profile_path:     '#{prof_path}',
            bundle_id:        'com.example.app',
            file_path:        '#{ipa_path}',
            output_path:      '#{tmp_dir}/out.ipa'
          )
        end")

        expect { ff.runner.execute(:test) }.not_to raise_error

        # Verify downloads were requested
        expect(helper).to have_received(:ensure_assets).with('v0.0.3')

        # Verify zsign command with correct parameters
        expected_command = [
          zsign_path, '-k', key_path, '-p', 'secret', '-m', prof_path,
          '-b', 'com.example.app', '-l', dylib_path, '/fake/payload/MyApp.app'
        ].shelljoin

        expect(executed_command).to eq(expected_command)
      end
    end
  end
end
# rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
