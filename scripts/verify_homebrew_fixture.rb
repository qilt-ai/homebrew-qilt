# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"

fixture = Pathname(ARGV.fetch(0)).realpath
keg = Pathname(File.read(ARGV.fetch(1)).strip).realpath
output = Pathname(ARGV.fetch(2))
config = JSON.parse((fixture/"candidate.json").read)
payload = keg/"libexec/qilt/0.0.0"
command = payload/"qilt"
expected_bytes = (fixture/"tree/libexec/qilt/0.0.0/qilt").binread
abort "fixture payload changed" unless command.binread == expected_bytes
abort "fixture payload has unexpected members" unless payload.children.map { |p| p.basename.to_s }.sort == ["qilt"]
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
output.write(JSON.pretty_generate(
  "kind" => "synthetic-homebrew-integration", "fixture_passed" => true,
  "native_image_qualified" => false, "real_authentication_qualified" => false,
  "private_remote_tap_qualified" => false, "tap_source" => "local fixture repository",
  "keg" => keg.to_s, "installed_fixture_sha256" => Digest::SHA256.file(command).hexdigest,
  "original_fixture_sha256" => Digest::SHA256.hexdigest(expected_bytes),
  "fixture_version_exit" => version_status.exitstatus,
  "fixture_native_verification_exit" => verification_status.exitstatus,
  "mach_o_signatures" => "not applicable: inert shell-script fixture",
  "install_record" => record
) + "\n")
