# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require_relative "render_formula"

module QiltCandidate
  class Refused < StandardError; end
  module_function

  def refuse(reason)
    raise Refused, "Candidate preparation refused: #{reason}", cause: nil
  end

  # Consume the publisher's four D-2 assets without extracting or running the
  # native payload. The caller establishes the release record's provenance.
  # No repository or remote state is changed.
  def prepare(assets:, version:, output:)
    refuse(:version) unless version.is_a?(String) && version.bytesize <= 128 &&
                            /\A[0-9]+\.[0-9]+\.[0-9]+\z/.match?(version)
    assets, output = Pathname(assets), Pathname(output)
    refuse(:assets_directory) unless assets.directory? && !assets.symlink?
    refuse(:output_exists) if output.exist? || output.symlink?
    archive_name = "qilt-#{version}-macos-arm64.tar.gz"
    manifest_name = "qilt-#{version}-macos-arm64.native-manifest.json"
    names = [archive_name, manifest_name, "qilt-#{version}-NOTICES.txt"].sort
    refuse(:asset_set) unless assets.children.map { |p| p.basename.to_s }.sort == (names + ["SHA256SUMS"]).sort
    (names + ["SHA256SUMS"]).each do |name|
      path = assets/name
      refuse(:asset_file) unless path.file? && !path.symlink?
    end
    refuse(:checksums_size) if (assets/"SHA256SUMS").size > 4096
    checksums = {}
    (assets/"SHA256SUMS").read.each_line do |line|
      match = /\A([a-f0-9]{64})  ([A-Za-z0-9._-]+)\n?\z/.match(line)
      refuse(:checksums_format) unless match
      name = match[2]
      refuse(:checksums_member) unless names.include?(name) && !checksums.key?(name)
      checksums[name] = match[1]
    end
    refuse(:checksums_members) unless checksums.keys.sort == names
    checksums.each do |name, expected|
      refuse(:checksum_mismatch) unless Digest::SHA256.file(assets/name).hexdigest == expected
    end
    refuse(:manifest_size) if (assets/manifest_name).size > 16 * 1024 * 1024
    manifest = JSON.parse((assets/manifest_name).read)
    refuse(:manifest_schema) unless manifest.is_a?(Hash) &&
                                    manifest["schema"] == "qilt.native-manifest.v1" &&
                                    manifest["members"].is_a?(Array)
    refuse(:manifest_version) unless manifest["run"].is_a?(Hash) && manifest["run"]["version"] == version
    results, hosting, floor = manifest.values_at("results", "hosting", "floor")
    unless results.is_a?(Hash) && results["gate_passed"] == true &&
           results["closure_passed"] == true && results["controls_passed"] == true &&
           hosting.is_a?(Hash) && hosting["rs0_report_recorded"] == true
      refuse(:uncleared_candidate)
    end
    refuse(:manifest_floor) unless floor.is_a?(Hash) && floor["built_for"].is_a?(String)
    config = { "version" => version, "tarball_sha256" => checksums.fetch(archive_name),
               "manifest_sha256" => checksums.fetch(manifest_name), "macos_minimum" => floor.fetch("built_for") }
    # Rendering validates every field before creating the output directory.
    formula = QiltFormula.render(config)
    (output/"Formula").mkpath
    (output/"candidate.json").write(JSON.pretty_generate(config) + "\n")
    (output/"Formula/qilt.rb").write(formula)
    record = { "version" => version, "assets" => checksums,
               "checksums_sha256" => Digest::SHA256.file(assets/"SHA256SUMS").hexdigest,
               "formula_sha256" => Digest::SHA256.hexdigest(formula),
               "native_qualification" => "not performed by preparation",
               "source_provenance" => "caller must bind the supplied assets to the cleared release record" }
    (output/"PREPARATION.json").write(JSON.pretty_generate(record) + "\n")
    record
  rescue JSON::ParserError, ArgumentError
    refuse(:candidate_metadata)
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: ruby scripts/prepare_candidate.rb ASSETS VERSION NEW_OUTPUT" unless ARGV.length == 3
  begin
    record = QiltCandidate.prepare(assets: ARGV[0], version: ARGV[1], output: ARGV[2])
    puts "Formula sha256: #{record.fetch('formula_sha256')}"
  rescue QiltCandidate::Refused => error
    abort error.message
  end
end
