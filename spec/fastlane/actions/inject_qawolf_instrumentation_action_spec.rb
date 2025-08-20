require 'tmpdir'

describe Fastlane::Actions::InjectQawolfInstrumentationAction do
  describe "#run" do
    let(:tmp_root) { Dir.mktmpdir("qawolf_inject_spec_") }
    let(:input_ipa) { File.join(tmp_root, 'before.ipa') }
    let(:output_ipa) { File.join(tmp_root, 'after.ipa') }

    before do
      # Prepare a dummy IPA file so existence check passes
      File.write(input_ipa, '')

      # Stub heavy network/file operations
      allow(described_class).to receive(:sh) # no-op for unzip/zip/optool

      # Stub dylib download to produce a real (empty) file so File.exist? passes
      allow(described_class).to receive(:download_dylib) do |dir|
        dylib_path = File.join(dir, 'instrumentation.dylib')
        File.write(dylib_path, '')
        dylib_path
      end

      # Stub optool download to produce a fake executable path
      allow(described_class).to receive(:download_optool) do |dir|
        optool_path = File.join(dir, 'optool')
        File.write(optool_path, '')
        FileUtils.chmod('+x', optool_path)
        optool_path
      end

      # Stub `PlistBuddy` invocation used to read CFBundleExecutable
      # Since PlistBuddy is the only backtick command in the action, stub it directly
      allow(described_class).to receive(:`).and_return("TestBinary\n")

      # Stub app bundle lookup to a deterministic dummy path and create required files
      dummy_app_dir = File.join('/tmp', 'app', 'Test.app')
      FileUtils.mkdir_p(dummy_app_dir)
      File.write(File.join(dummy_app_dir, 'Info.plist'), "<plist><dict><key>CFBundleExecutable</key><string>TestBinary</string></dict></plist>")
      File.write(File.join(dummy_app_dir, 'TestBinary'), '')
      allow(Dir).to receive(:glob).and_wrap_original do |method, pattern|
        if pattern.to_s.end_with?('Payload/*.app')
          [dummy_app_dir]
        else
          method.call(pattern)
        end
      end
    end

    after do
      FileUtils.rm_rf(tmp_root)
    end

    it "returns the output IPA path when successful" do
      result = described_class.run(input: input_ipa, output: output_ipa)
      expect(result).to eq(File.expand_path(output_ipa))
    end

    it "fails when the input IPA does not exist" do
      expect do
        described_class.run(input: '/non/existent/file.ipa', output: output_ipa)
      end.to raise_error(FastlaneCore::Interface::FastlaneError)
    end
  end
end
