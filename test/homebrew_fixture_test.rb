# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require "json"
require "digest"
require "pathname"

class HomebrewFixtureTest < Minitest::Test
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
