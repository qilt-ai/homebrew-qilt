# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/prepare_candidate"

class PrepareCandidateTest < Minitest::Test
  def setup
    @root = Pathname(Dir.mktmpdir("qilt-candidate-test-"))
    @assets, @output = @root/"assets", @root/"prepared"
    @assets.mkpath
    @manifest_name = "qilt-0.0.1-macos-arm64.native-manifest.json"
    @manifest = { "schema" => "qilt.native-manifest.v1", "run" => { "version" => "0.0.1" },
                  "members" => [], "floor" => { "built_for" => "26.0", "stated" => "11.0" },
                  "results" => { "gate_passed" => true, "closure_passed" => true, "controls_passed" => true },
                  "hosting" => { "rs0_report_recorded" => true } }
    (@assets/"qilt-0.0.1-macos-arm64.tar.gz").write("synthetic bytes, never extracted or executed")
    (@assets/"qilt-0.0.1-NOTICES.txt").write("Synthetic notices")
    reseal
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def reseal
    (@assets/@manifest_name).write(JSON.generate(@manifest))
    names = @assets.children.reject { |p| p.basename.to_s == "SHA256SUMS" }.sort
    (@assets/"SHA256SUMS").write(names.map { |p| "#{Digest::SHA256.file(p).hexdigest}  #{p.basename}\n" }.join)
  end

  def prepare
    QiltCandidate.prepare(assets: @assets, version: "0.0.1", output: @output)
  end

  def refused
    assert_raises(QiltCandidate::Refused) { prepare }
    refute @output.exist?
  end

  def test_measured_floor_and_release_pins_generate_formula_without_running_payload
    record = prepare
    config = JSON.parse((@output/"candidate.json").read)
    assert_equal "26.0", config.fetch("macos_minimum")
    assert_equal Digest::SHA256.file(@assets/@manifest_name).hexdigest, config.fetch("manifest_sha256")
    assert_equal QiltFormula.render(config), (@output/"Formula/qilt.rb").read
    assert_equal Digest::SHA256.file(@output/"Formula/qilt.rb").hexdigest, record.fetch("formula_sha256")
    assert_raises(QiltCandidate::Refused) { prepare }
  end

  def test_mismatched_asset_is_not_rehashed_into_a_new_pin
    (@assets/"qilt-0.0.1-macos-arm64.tar.gz").write("tampered")
    refused
  end

  def test_duplicate_or_traversing_checksum_rows_refuse
    sums = @assets/"SHA256SUMS"
    original = sums.read
    sums.write(original + original.lines.first)
    refused
    sums.write(original.sub(@manifest_name, "../" + @manifest_name))
    refused
  end

  def test_uncleared_builds_and_wrong_versions_refuse_even_with_consistent_checksums
    %w[gate_passed closure_passed controls_passed].each do |key|
      @manifest["results"][key] = false
      reseal
      refused
      @manifest["results"][key] = true
    end
    @manifest["hosting"]["rs0_report_recorded"] = false
    reseal
    refused
    @manifest["hosting"]["rs0_report_recorded"] = true
    @manifest["run"]["version"] = "0.0.2"
    reseal
    refused
  end

  def test_linked_or_extra_assets_refuse
    notices = @assets/"qilt-0.0.1-NOTICES.txt"
    outside = @root/"outside"
    File.rename(notices, outside)
    File.symlink(outside, notices)
    refused
    notices.unlink
    File.rename(outside, notices)
    (@assets/"extra").write("unexpected")
    refused
  end
end
