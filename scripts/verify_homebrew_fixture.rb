# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"

fixture = Pathname(ARGV.fetch(0)).realpath
keg = Pathname(File.read(ARGV.fetch(1)).strip).realpath
output = Pathname(ARGV.fetch(2))
expectation = ARGV.fetch(3, "preserved")
abort "unknown fixture expectation" unless %w[preserved rewritten].include?(expectation)
config = JSON.parse((fixture/"candidate.json").read)
fixture_record = JSON.parse((fixture/"FIXTURE.json").read)
image_record = fixture_record["mach_o_fixture"]
abort "rewritten control requires a Mach-O fixture" if expectation == "rewritten" && image_record.nil?
payload = keg/"libexec/qilt/0.0.0"
command = payload/"qilt"
expected_bytes = (fixture/"tree/libexec/qilt/0.0.0/qilt").binread
abort "fixture payload changed" unless command.binread == expected_bytes
expected_members = image_record ? %w[libfixture.dylib qilt] : ["qilt"]
abort "fixture payload has unexpected members" unless payload.children.map { |p| p.basename.to_s }.sort == expected_members
abort "fixture payload mode changed" unless (payload.stat.mode & 0o7777) ==
                                           ((fixture/"tree/libexec/qilt/0.0.0").stat.mode & 0o7777)
abort "fixture command mode changed" unless (command.stat.mode & 0o7777) == 0o755
abort "fixture link changed" unless (keg/"bin/qilt").symlink? &&
                                   File.readlink(keg/"bin/qilt") == "../libexec/qilt/0.0.0/qilt"
record_path = payload.parent/"0.0.0.install.json"
record = JSON.parse(record_path.read)
manifest_name = "qilt-0.0.0-macos-arm64.native-manifest.json"
expected_record = { "version" => "0.0.0", "tarball_sha256" => config.fetch("tarball_sha256"),
                    "manifest_sha256" => config.fetch("manifest_sha256"), "manifest_path" => manifest_name }
abort "fixture install record differs from formula pins" unless record == expected_record
abort "fixture delivered manifest changed" unless (payload.parent/manifest_name).binread ==
                                                 (fixture/manifest_name).binread
abort "fixture binding was placed in payload" if (payload/manifest_name).exist? || (payload/"0.0.0.install.json").exist?
version_out, _, version_status = Open3.capture3((keg/"bin/qilt").to_s, "--version")
abort "fixture version command failed" unless version_status.success? &&
                                            version_out.strip == "Qilt synthetic Homebrew fixture 0.0.0"
# A fixture must never masquerade as the installed native verifier.
_, refusal, verification_status = Open3.capture3((keg/"bin/qilt").to_s, "doctor", "--installation")
abort "fixture unexpectedly claimed native verification" unless verification_status.exitstatus == 64 &&
                                                               refusal.include?("Fixture only:")
image_result = nil
if image_record
  relative = image_record.fetch("path")
  abort "unexpected fixture image path" unless relative == "libexec/qilt/0.0.0/libfixture.dylib"
  original = fixture/"tree"/relative
  installed = keg/relative
  original_sha = Digest::SHA256.file(original).hexdigest
  installed_sha = Digest::SHA256.file(installed).hexdigest
  members = JSON.parse((fixture/manifest_name).read).fetch("members")
  image_rows = members.select { |row| row["path"] == relative }
  abort "fixture image is not bound to manifest" unless image_rows.length == 1 &&
                                                       image_rows.first["sha256"] == original_sha &&
                                                       image_record.fetch("sha256") == original_sha
  ids, err, status = Open3.capture3("/usr/bin/otool", "-D", installed.to_s)
  abort "installed fixture id unreadable: #{err}" unless status.success? && ids.lines.drop(1).length == 1
  installed_id = ids.lines.drop(1).first.strip
  _, signature_error, signature_status = Open3.capture3("/usr/bin/codesign", "--verify", "--strict", installed.to_s)
  abort "installed fixture signature invalid: #{signature_error}" unless signature_status.success?
  equal = original.binread == installed.binread
  if expectation == "preserved"
    abort "fixture image changed: #{relative}" unless equal && installed_id == image_record.fetch("id")
  else
    opt, error, status = Open3.capture3("brew", "--prefix", "qilt-ai/qilt/qilt")
    abort "fixture opt prefix unreadable: #{error}" unless status.success? && Pathname(opt.strip).absolute?
    expected_id = (Pathname(opt.strip)/relative).to_s
    abort "negative control did not rewrite #{relative}" unless !equal && installed_id == expected_id
  end
  image_result = { "path" => relative, "expectation" => expectation, "bytes_equal" => equal,
                   "archive_member_sha256" => original_sha, "installed_sha256" => installed_sha,
                   "original_id" => image_record.fetch("id"), "installed_id" => installed_id,
                   "signature_verified" => true, "differences" => equal ? [] : [relative] }
end
output.write(JSON.pretty_generate(
  "kind" => "synthetic-homebrew-integration", "fixture_passed" => true,
  "native_image_qualified" => false, "public_remote_download_qualified" => false,
  "tap_source" => "local fixture repository", "asset_source" => "local file URLs",
  "keg" => keg.to_s, "installed_fixture_sha256" => Digest::SHA256.file(command).hexdigest,
  "original_fixture_sha256" => Digest::SHA256.hexdigest(expected_bytes),
  "fixture_version_exit" => version_status.exitstatus,
  "fixture_native_verification_exit" => verification_status.exitstatus,
  "mach_o_fixture" => image_result,
  "mach_o_signatures" => image_result ? "synthetic dylib verified; product image not qualified" : "not applicable: inert shell-script fixture",
  "install_record" => record
) + "\n")
