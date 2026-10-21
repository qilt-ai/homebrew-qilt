# frozen_string_literal: true

require "digest"
require "fileutils"
require "find"
require "json"
require "pathname"
require "tempfile"

module QiltRelease
  class InstallRefused < StandardError; end

  # Pre-install archive validation and the fixed keg layout. Installed native
  # verification remains N-2's command, run after Homebrew finishes relocation.
  module InstallPayload
    module_function

    def refuse(reason)
      raise InstallRefused, "Qilt installation refused: #{reason}", cause: nil
    end

    def validate_archive(root, manifest, version)
      refuse(:manifest_schema) unless manifest.is_a?(Hash) &&
                                      manifest["schema"] == "qilt.native-manifest.v1" &&
                                      manifest["members"].is_a?(Array)
      refuse(:manifest_version) unless manifest["run"].is_a?(Hash) && manifest["run"]["version"] == version
      expected = {}
      manifest["members"].each do |row|
        refuse(:member_schema) unless row.is_a?(Hash)
        name = row["path"]
        refuse(:member_path) unless name.is_a?(String) && !name.empty? &&
                                    !name.match?(/[[:cntrl:]\\]/) &&
                                    !Pathname(name).absolute? &&
                                    name.split("/", -1).none? { |part| ["", ".", ".."].include?(part) }
        refuse(:duplicate_member) if expected.key?(name)
        refuse(:member_mode) unless row["mode"].is_a?(String) && /\A[0-7]{4}\z/.match?(row["mode"])
        refuse(:member_mode) if Integer(row["mode"], 8) > 0o777
        refuse(:member_kind) unless %w[file dir symlink].include?(row["kind"])
        expected[name] = row
      end
      payload = "libexec/qilt/#{version}"
      refuse(:payload_root) unless expected.dig(payload, "kind") == "dir"
      refuse(:payload_command) unless expected.dig("#{payload}/qilt", "kind") == "file"
      unless expected.dig("bin/qilt", "kind") == "symlink" &&
             expected.dig("bin/qilt", "target") == "../#{payload}/qilt"
        refuse(:exposed_link)
      end
      expected.each do |name, row|
        refuse(:undeclared_link) if row["kind"] == "symlink" && name != "bin/qilt"
        refuse(:extra_exposed_command) if name.start_with?("bin/") && name != "bin/qilt"
        if name.start_with?("libexec/") &&
           !["libexec/qilt", payload].include?(name) && !name.start_with?("#{payload}/")
          refuse(:unexpected_payload_version)
        end
        refuse(:reserved_member) if [".brew", "INSTALL_RECEIPT.json"].include?(name.split("/").first)
      end
      root = Pathname(root)
      refuse(:archive_root) unless root.directory? && !root.symlink?
      observed = []
      Find.find(root.to_s) do |path|
        next if path == root.to_s

        name = Pathname(path).relative_path_from(root).to_s
        row = expected[name]
        refuse(:unlisted_member) unless row
        info = File.lstat(path)
        refuse(:mode_mismatch) unless format("%04o", info.mode & 0o7777) == row["mode"]
        case row["kind"]
        when "dir"
          refuse(:kind_mismatch) unless info.directory?
        when "file"
          refuse(:kind_mismatch) unless info.file?
          unless row["size"].is_a?(Integer) && row["size"] == info.size &&
                 row["sha256"].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(row["sha256"]) &&
                 Digest::SHA256.file(path).hexdigest == row["sha256"]
            refuse(:file_mismatch)
          end
        when "symlink"
          refuse(:link_mismatch) unless info.symlink? && File.readlink(path) == row["target"]
        end
        observed << name
        Find.prune if info.symlink?
      end
      refuse(:missing_member) unless observed.sort == expected.keys.sort
      expected
    end

    def install(source:, prefix:, version:, manifest_bytes:, tarball_sha256:, manifest_sha256:)
      refuse(:version) unless version.is_a?(String) &&
                              /\A[0-9]+\.[0-9]+\.[0-9]+\z/.match?(version)
      [tarball_sha256, manifest_sha256].each do |value|
        refuse(:digest) unless value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value)
      end
      refuse(:manifest_bytes) unless manifest_bytes.is_a?(String) && manifest_bytes.bytesize <= 16 * 1024 * 1024
      refuse(:manifest_digest) unless Digest::SHA256.hexdigest(manifest_bytes) == manifest_sha256
      manifest = JSON.parse(manifest_bytes)
      source, prefix = Pathname(source), Pathname(prefix)
      rows = validate_archive(source, manifest, version)
      # Refuse before copying anything when an existing keg component would
      # redirect the payload, exposed command or binding outside this keg.
      [prefix, prefix/"bin", prefix/"libexec", prefix/"libexec/qilt"].each do |path|
        refuse(:unsafe_keg_component) if path.symlink? || (path.exist? && !path.directory?)
      end
      relative = "libexec/qilt/#{version}"
      destination = prefix/relative
      refuse(:existing_payload) if destination.exist? || destination.symlink?
      FileUtils.mkdir_p(destination.parent)
      FileUtils.cp_r((source/relative).to_s, destination.to_s, preserve: true)
      File.chmod(Integer(rows.fetch(relative).fetch("mode"), 8), destination)
      FileUtils.mkdir_p(prefix/"bin")
      File.symlink("../#{relative}/qilt", prefix/"bin/qilt")
      # Preserve verified archive-level notices/provenance outside the payload.
      source.children.each do |entry|
        next if %w[bin libexec].include?(entry.basename.to_s)
        refuse(:existing_archive_member) if (prefix/entry.basename).exist? || (prefix/entry.basename).symlink?

        FileUtils.cp_r(entry.to_s, (prefix/entry.basename).to_s, preserve: true)
      end
      manifest_name = "qilt-#{version}-macos-arm64.native-manifest.json"
      record = { "version" => version, "tarball_sha256" => tarball_sha256,
                 "manifest_sha256" => manifest_sha256, "manifest_path" => manifest_name }
      atomic_write(destination.parent/manifest_name, manifest_bytes)
      atomic_write(destination.parent/"#{version}.install.json", JSON.generate(record) + "\n")
      record
    rescue JSON::ParserError
      refuse(:manifest_json)
    end

    def atomic_write(path, bytes)
      refuse(:existing_install_record) if path.exist? || path.symlink?
      Tempfile.create(["qilt-record-", ".tmp"], path.parent.to_s) do |stream|
        stream.binmode
        stream.write(bytes)
        stream.flush
        stream.fsync
        File.chmod(0o644, stream.path)
        File.rename(stream.path, path.to_s)
      end
    end
  end
end


# Generated from the candidate's release pins; no unpinned formula is shipped.
class Qilt < Formula
  desc "Local agent messaging"
  homepage "https://github.com/qilt-ai/qilt-releases"
  RELEASE_VERSION = "0.1.1"
  TARBALL_SHA256 = "37582592114dc30bad0f6dc13409903fdd140c08e940d347df8dddddc0d5d70f"
  MANIFEST_SHA256 = "8c1edc1c27609effacba77dcca6f49f30e0a335bf2ec306ae08fe2a5e7894684"
  MACOS_MINIMUM = "26.0"

  version RELEASE_VERSION
  url "https://github.com/qilt-ai/qilt-releases/releases/download/v#{RELEASE_VERSION}/qilt-#{RELEASE_VERSION}-macos-arm64.tar.gz"
  sha256 TARBALL_SHA256

  depends_on :macos
  depends_on arch: :arm64
  preserve_rpath

  resource "native-manifest" do
    url "https://github.com/qilt-ai/qilt-releases/releases/download/v#{RELEASE_VERSION}/qilt-#{RELEASE_VERSION}-macos-arm64.native-manifest.json"
    sha256 MANIFEST_SHA256
  end

  def install
    if MacOS.version < MacOSVersion.new(MACOS_MINIMUM)
      odie "Qilt requires macOS #{MACOS_MINIMUM} or later"
    end
    manifest_bytes = nil
    resource("native-manifest").stage do
      manifest_bytes = File.binread("qilt-#{RELEASE_VERSION}-macos-arm64.native-manifest.json")
    end
    # Formula#stage adds .brew_home to buildpath. Re-stage the checksum-verified
    # primary resource in a clean directory; do not exempt unlisted members
    # from the archive manifest check.
    resource.stage do
      QiltRelease::InstallPayload.install(
        source: Pathname.pwd, prefix: prefix, version: RELEASE_VERSION,
        manifest_bytes: manifest_bytes, tarball_sha256: TARBALL_SHA256,
        manifest_sha256: MANIFEST_SHA256
      )
    end
  end

  # Homebrew catches post_install exceptions. The qualified installation
  # sequence runs N-2's verifier after brew returns; no hook is credited as it.
  test do
    system bin/"qilt", "--version"
  end
end
