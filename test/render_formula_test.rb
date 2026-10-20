# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../scripts/render_formula"

class RenderFormulaTest < Minitest::Test
  def candidate
    { "version" => "0.0.1", "tarball_sha256" => "a" * 64,
      "manifest_sha256" => "b" * 64, "macos_minimum" => "26.0" }
  end

  def test_candidate_pins_generate_a_self_contained_syntactically_valid_formula
    text = QiltFormula.render(candidate)
    assert_equal text, QiltFormula.render(candidate)
    assert_includes text, 'TARBALL_SHA256 = "' + "a" * 64 + '"'
    assert_includes text, 'MANIFEST_SHA256 = "' + "b" * 64 + '"'
    assert_includes text, 'MACOS_MINIMUM = "26.0"'
    refute_includes text, "require_relative"
    refute_includes text, "<%="
    Dir.mktmpdir("qilt-render-test-") do |dir|
      path = File.join(dir, "qilt.rb")
      File.write(path, text)
      out, err, status = Open3.capture3(RbConfig.ruby, "-c", path)
      assert status.success?, err
      assert_includes out, "Syntax OK"
    end
  end

  def test_incomplete_unexpected_or_injecting_metadata_cannot_generate_a_formula
    inputs = [nil, {}, candidate.merge("token" => "synthetic-credential"),
              candidate.merge("version" => '0.0.1"; abort "injected'),
              candidate.merge("version" => "0.0.1-rc.1"),
              candidate.merge("manifest_sha256" => nil),
              candidate.merge("macos_minimum" => "26.0\ninjected")]
    inputs.each { |value| assert_raises(ArgumentError) { QiltFormula.render(value) } }
  end

  def test_invalid_candidate_cannot_replace_an_existing_formula
    Dir.mktmpdir("qilt-render-test-") do |dir|
      input, output = File.join(dir, "candidate.json"), File.join(dir, "qilt.rb")
      File.write(input, JSON.generate({}))
      File.write(output, "previous candidate\n")
      assert_raises(ArgumentError) { QiltFormula.write(input, output) }
      assert_equal "previous candidate\n", File.read(output)
      File.write(input, JSON.generate(candidate))
      digest = QiltFormula.write(input, output)
      assert_equal digest, Digest::SHA256.file(output).hexdigest
    end
  end

  def test_late_candidate_update_changes_only_the_four_constant_values
    other = candidate.merge("version" => "1.2.3", "tarball_sha256" => "c" * 64,
                            "manifest_sha256" => "d" * 64, "macos_minimum" => "27.1")
    before, after = [candidate, other].map { |config| QiltFormula.render(config).lines }
    assert_equal before.length, after.length
    changes = before.zip(after).reject { |a, b| a == b }
    assert_equal 4, changes.length
    assert_equal %w[RELEASE_VERSION TARBALL_SHA256 MANIFEST_SHA256 MACOS_MINIMUM],
                 changes.map { |a, _| a.strip.split(" = ").first }
  end
end
