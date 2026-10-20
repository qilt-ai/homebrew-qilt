# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/qilt/install_payload"

class InstallPayloadTest < Minitest::Test
  V = "0.0.1"

  def setup
    @temp = Pathname(Dir.mktmpdir("qilt-install-test-"))
    @source, @prefix = @temp/"source", @temp/"keg"
    FileUtils.mkdir_p(@source/"libexec/qilt/#{V}")
    FileUtils.mkdir_p(@source/"bin")
    (@source/"libexec/qilt/#{V}/qilt").write("synthetic native image, never executed\n")
    File.chmod(0o755, @source/"libexec/qilt/#{V}/qilt")
    File.symlink("../libexec/qilt/#{V}/qilt", @source/"bin/qilt")
    (@source/"NOTICES.txt").write("Synthetic notices\n")
    @members = []
    Find.find(@source.to_s) do |name|
      next if name == @source.to_s

      info = File.lstat(name)
      row = { "path" => Pathname(name).relative_path_from(@source).to_s,
              "mode" => format("%04o", info.mode & 0o7777) }
      if info.symlink?
        row.merge!("kind" => "symlink", "target" => File.readlink(name))
      elsif info.directory?
        row["kind"] = "dir"
      else
        row.merge!("kind" => "file", "size" => info.size, "sha256" => Digest::SHA256.file(name).hexdigest)
      end
      @members << row
      Find.prune if info.symlink?
    end
  end

  def teardown
    FileUtils.remove_entry(@temp)
  end

  def manifest
    JSON.generate("schema" => "qilt.native-manifest.v1", "run" => { "version" => V },
                  "members" => @members.sort_by { |row| row["path"] })
  end

  def install(bytes = manifest, pin = Digest::SHA256.hexdigest(bytes))
    QiltRelease::InstallPayload.install(source: @source, prefix: @prefix, version: V,
                                       manifest_bytes: bytes, manifest_sha256: pin, tarball_sha256: "a" * 64)
  end

  def refused(reason)
    error = assert_raises(QiltRelease::InstallRefused) { yield }
    assert_includes error.message, reason.to_s
    refute @prefix.exist?, "invalid input wrote into the keg"
  end

  def test_installs_exact_payload_and_retains_binding_outside_it
    bytes = manifest
    record = install(bytes)
    payload = @prefix/"libexec/qilt/#{V}"
    assert_equal (@source/"libexec/qilt/#{V}/qilt").binread, (payload/"qilt").binread
    assert_equal 0o755, (payload/"qilt").stat.mode & 0o7777
    assert_equal "../libexec/qilt/#{V}/qilt", File.readlink(@prefix/"bin/qilt")
    manifest_path = payload.parent/record.fetch("manifest_path")
    assert_equal bytes, manifest_path.binread
    assert_equal Digest::SHA256.hexdigest(bytes), record.fetch("manifest_sha256")
    assert_equal %w[manifest_path manifest_sha256 tarball_sha256 version], record.keys.sort
    assert_equal record, JSON.parse((payload.parent/"#{V}.install.json").read)
    refute (payload/record.fetch("manifest_path")).exist?
    refute (payload/"#{V}.install.json").exist?
    assert_equal "Synthetic notices\n", (@prefix/"NOTICES.txt").read
  end

  def test_changed_manifest_cannot_supply_its_own_expected_digest
    refused(:manifest_digest) { install(manifest, "0" * 64) }
  end

  def test_manifest_build_version_must_match_even_when_member_paths_match
    value = JSON.parse(manifest)
    value["run"]["version"] = "9.9.9"
    refused(:manifest_version) { install(JSON.generate(value)) }
  end

  def test_changed_payload_bytes_refuse_before_install
    (@source/"libexec/qilt/#{V}/qilt").write("changed")
    refused(:file_mismatch) { install }
  end

  def test_changed_payload_mode_refuses_before_install
    File.chmod(0o644, @source/"libexec/qilt/#{V}/qilt")
    refused(:mode_mismatch) { install }
  end

  def test_extra_and_missing_members_refuse
    (@source/"extra").write("unlisted")
    refused(:unlisted_member) { install }
    (@source/"extra").unlink
    (@source/"NOTICES.txt").unlink
    refused(:missing_member) { install }
  end

  def test_duplicate_and_unsafe_member_paths_refuse
    @members << @members.first.dup
    refused(:duplicate_member) { install }
    @members.pop
    @members.first["path"] = "../outside"
    refused(:member_path) { install }
  end

  def test_payload_symlink_never_reads_an_external_file
    command = @source/"libexec/qilt/#{V}/qilt"
    command.unlink
    File.symlink("/not-a-real-fixture-target", command)
    error = assert_raises(QiltRelease::InstallRefused) { install }
    assert_match(/(?:mode|kind)_mismatch/, error.message)
    refute @prefix.exist?
  end

  def test_exposed_link_must_name_the_declared_version
    link = @members.find { |row| row["path"] == "bin/qilt" }
    link["target"] = "../libexec/qilt/9.9.9/qilt"
    refused(:exposed_link) { install }
  end

  def test_reserved_homebrew_records_cannot_be_imported
    @members << { "path" => "INSTALL_RECEIPT.json", "kind" => "file", "mode" => "0644",
                  "size" => 0, "sha256" => Digest::SHA256.hexdigest("") }
    refused(:reserved_member) { install }
  end

  def test_symlinked_keg_components_cannot_redirect_an_install
    outside = @temp/"outside"
    outside.mkpath
    (outside/"canary").write("unchanged")
    ["", "bin", "libexec", "libexec/qilt"].each do |relative|
      @prefix = @temp/("keg-" + relative.tr("/", "-"))
      link = relative.empty? ? @prefix : @prefix/relative
      link.parent.mkpath
      File.symlink(outside, link)
      error = assert_raises(QiltRelease::InstallRefused) { install }
      assert_includes error.message, "unsafe_keg_component"
      assert_equal ["canary"], outside.children.map { |p| p.basename.to_s }
      assert_equal "unchanged", (outside/"canary").read
    end
  end
end
