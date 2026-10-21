# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require "json"
require "digest"
require "pathname"
require_relative "../lib/qilt/install_payload"

class HomebrewFixtureTest < Minitest::Test
  def test_real_image_check_detects_and_names_a_rewrite_without_running_homebrew
    skip "real Mach-O controls require macOS tools" unless RUBY_PLATFORM.include?("darwin")

    Dir.mktmpdir("qilt-macho-check-") do |dir|
      fixture = Pathname(dir)/"fixture"
      out, err, status = Open3.capture3(RbConfig.ruby, File.expand_path("../scripts/homebrew_fixture.rb", __dir__),
                                      fixture.to_s, "--mach-o")
      assert status.success?, out + err
      positive = (fixture/"tap/Formula/qilt.rb").read
      negative = (fixture/"without-preserve-rpath.rb").read
      assert_equal 1, positive.lines.count("  preserve_rpath\n")
      assert_equal positive.sub("  preserve_rpath\n", ""), negative
      config = JSON.parse((fixture/"candidate.json").read)
      prefix = Pathname(dir)/"keg"
      QiltRelease::InstallPayload.install(
        source: fixture/"tree", prefix: prefix, version: "0.0.0",
        manifest_bytes: (fixture/"qilt-0.0.0-macos-arm64.native-manifest.json").binread,
        tarball_sha256: config.fetch("tarball_sha256"), manifest_sha256: config.fetch("manifest_sha256")
      )
      keg_file = Pathname(dir)/"keg.txt"
      keg_file.write(prefix.to_s + "\n")
      verifier = File.expand_path("../scripts/verify_homebrew_fixture.rb", __dir__)
      result = Pathname(dir)/"preserved.json"
      out, err, status = Open3.capture3(RbConfig.ruby, verifier, fixture.to_s, keg_file.to_s, result.to_s)
      assert status.success?, out + err
      assert_equal true, JSON.parse(result.read).fetch("mach_o_fixture").fetch("bytes_equal")

      image = prefix/"libexec/qilt/0.0.0/libfixture.dylib"
      id = image.to_s
      assert system("/usr/bin/install_name_tool", "-id", id, image.to_s, out: File::NULL, err: File::NULL)
      assert system("/usr/bin/codesign", "--force", "--sign", "-", image.to_s, out: File::NULL, err: File::NULL)
      out, err, status = Open3.capture3(RbConfig.ruby, verifier, fixture.to_s, keg_file.to_s,
                                      (Pathname(dir)/"unexpected.json").to_s)
      refute status.success?, out + err
      assert_includes err, "fixture image changed: libexec/qilt/0.0.0/libfixture.dylib"

      # This test measures the verifier, not Homebrew. Only the disposable CI
      # runner runs brew; the stub here supplies the expected opt path only.
      fake_bin = Pathname(dir)/"bin"
      fake_bin.mkpath
      (fake_bin/"brew").write("#!/bin/sh\n[ \"$*\" = \"--prefix qilt-ai/qilt/qilt\" ] || exit 64\nprintf '%s\\n' '#{prefix}'\n")
      File.chmod(0o755, fake_bin/"brew")
      control = Pathname(dir)/"control.json"
      out, err, status = Open3.capture3({ "PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}" }, RbConfig.ruby, verifier,
                                      fixture.to_s, keg_file.to_s, control.to_s, "rewritten")
      assert status.success?, out + err
      facts = JSON.parse(control.read).fetch("mach_o_fixture")
      assert_equal false, facts.fetch("bytes_equal")
      assert_equal ["libexec/qilt/0.0.0/libfixture.dylib"], facts.fetch("differences")
      assert_equal id, facts.fetch("installed_id")
    end
  end

  def test_fixture_is_separate_from_production_and_never_claims_native_qualification
    Dir.mktmpdir("qilt-fixture-generation-") do |dir|
      root = File.join(dir, "fixture")
      out, err, status = Open3.capture3(RbConfig.ruby, File.expand_path("../scripts/homebrew_fixture.rb", __dir__), root)
      assert status.success?, out + err
      record = JSON.parse(File.read(File.join(root, "FIXTURE.json")))
      assert_equal false, record.fetch("native_image_qualified")
      assert_equal false, record.fetch("public_remote_download_qualified")
      production = File.read(File.join(root, "generated-production-formula.rb"))
      patched = File.read(File.join(root, "tap/Formula/qilt.rb"))
      replacements = record.fetch("url_replacements")
      assert_equal 2, replacements.length
      assert replacements.values.all? { |value| value.start_with?('"file:///') }
      assert_equal replacements.reduce(production) { |text, (source, target)| text.sub(source, target) }, patched
      assert_equal record.fetch("production_formula_sha256"), Digest::SHA256.hexdigest(production)
      stub = File.read(File.join(root, "tree/libexec/qilt/0.0.0/qilt"))
      assert_includes stub, "Fixture only: no native verifier"
      assert_includes stub, "exit 64"
    end
  end
end
