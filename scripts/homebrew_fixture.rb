# frozen_string_literal: true

# Generate an inert, explicitly synthetic tap for the disposable macOS runner.
# This does not qualify a native image or the public download endpoint.
require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "pathname"
require "uri"
require_relative "render_formula"

root = Pathname(ARGV.fetch(0)).expand_path
abort "usage: homebrew_fixture.rb OUTPUT [--mach-o]" unless ARGV.length == 1 ||
                                                          (ARGV.length == 2 && ARGV[1] == "--mach-o")
mach_o = ARGV[1] == "--mach-o"
abort "fixture destination already exists" if root.exist?
root.mkpath
tree = root/"tree"
payload = tree/"libexec/qilt/0.0.0"
payload.mkpath
(tree/"bin").mkpath
(payload/"qilt").write(<<~SCRIPT)
  #!/bin/sh
  if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
    echo "Qilt synthetic Homebrew fixture 0.0.0"
    exit 0
  fi
  echo "Fixture only: no native verifier or service is implemented." >&2
  exit 64
SCRIPT
File.chmod(0o755, payload/"qilt")
File.symlink("../libexec/qilt/0.0.0/qilt", tree/"bin/qilt")
(tree/"NOTICES.txt").write("Synthetic fixture; not a release candidate.\n")
image_record = nil
if mach_o
  abort "Mach-O fixture requires macOS" unless RUBY_PLATFORM.include?("darwin")
  source = root/"fixture.c"
  source.write("int qilt_fixture_value(void) { return 7; }\n")
  image = payload/"libfixture.dylib"
  image_id = "@rpath/libfixture.dylib"
  abort "fixture compile failed" unless system("/usr/bin/clang", "-dynamiclib", "-arch", "arm64",
                                               "-Wl,-headerpad_max_install_names", "-Wl,-install_name,#{image_id}",
                                               "-o", image.to_s, source.to_s)
  abort "fixture signing failed" unless system("/usr/bin/codesign", "--force", "--sign", "-", image.to_s)
  abort "fixture signature invalid" unless system("/usr/bin/codesign", "--verify", "--strict", image.to_s)
  ids, err, status = Open3.capture3("/usr/bin/otool", "-D", image.to_s)
  abort "fixture id differs: #{err}" unless status.success? && ids.lines.drop(1).map(&:strip) == [image_id]
  image_record = { "path" => "libexec/qilt/0.0.0/libfixture.dylib", "id" => image_id,
                   "sha256" => Digest::SHA256.file(image).hexdigest }
end
rows = []
Find.find(tree.to_s) do |name|
  next if name == tree.to_s

  info = File.lstat(name)
  row = { "path" => Pathname(name).relative_path_from(tree).to_s, "mode" => format("%04o", info.mode & 0o7777) }
  if info.symlink?
    row.merge!("kind" => "symlink", "target" => File.readlink(name))
  elsif info.directory?
    row["kind"] = "dir"
  else
    row.merge!("kind" => "file", "size" => info.size, "sha256" => Digest::SHA256.file(name).hexdigest)
  end
  rows << row
  Find.prune if info.symlink?
end
archive = root/"qilt-0.0.0-macos-arm64.tar.gz"
abort "fixture archive failed" unless system("tar", "-czf", archive.to_s, "-C", tree.to_s, ".")
manifest = root/"qilt-0.0.0-macos-arm64.native-manifest.json"
manifest.write(JSON.generate("schema" => "qilt.native-manifest.v1", "run" => { "version" => "0.0.0" },
                             "members" => rows.sort_by { |row| row["path"] }))
config = { "version" => "0.0.0", "tarball_sha256" => Digest::SHA256.file(archive).hexdigest,
           "manifest_sha256" => Digest::SHA256.file(manifest).hexdigest, "macos_minimum" => "11.0" }
(root/"candidate.json").write(JSON.generate(config))
tap = root/"tap"
(tap/"Formula").mkpath
production_formula = QiltFormula.render(config)
(root/"generated-production-formula.rb").write(production_formula)

# Only this fixture copy substitutes local URLs. Homebrew's standard download,
# checksum and resource-stage paths remain in use, with no custom transport.
replacements = {}
{
  '"https://github.com/qilt-ai/qilt-releases/releases/download/v#{RELEASE_VERSION}/qilt-#{RELEASE_VERSION}-macos-arm64.tar.gz"' => archive,
  '"https://github.com/qilt-ai/qilt-releases/releases/download/v#{RELEASE_VERSION}/qilt-#{RELEASE_VERSION}-macos-arm64.native-manifest.json"' => manifest
}.each do |source, file|
  abort "public asset URL changed" unless production_formula.scan(Regexp.new(Regexp.escape(source))).length == 1
  encoded = file.to_s.split("/").map { |part| URI.encode_www_form_component(part).gsub("+", "%20") }.join("/")
  replacements[source] = ("file://" + encoded).dump
end
fixture_formula = replacements.reduce(production_formula) { |text, (source, target)| text.sub(source, target) }
(tap/"Formula/qilt.rb").write(fixture_formula)
if mach_o
  declaration = "  preserve_rpath\n"
  abort "fixture needs exactly one preserve_rpath declaration" unless fixture_formula.lines.count(declaration) == 1
  # Both installs use the exact same archive and manifest. This is the sole
  # formula difference in the negative control.
  (root/"without-preserve-rpath.rb").write(fixture_formula.sub(declaration, ""))
end
commands = [
  ["git", "-C", tap.to_s, "init", "-b", "main"],
  ["git", "-C", tap.to_s, "add", "Formula/qilt.rb"],
  ["git", "-C", tap.to_s, "-c", "user.name=Qilt fixture", "-c", "user.email=fixture@example.invalid",
   "commit", "-m", "Synthetic Homebrew integration fixture"]
]
git_env = ENV.keys.grep(/\AGIT_/).each_with_object({}) { |key, env| env[key] = nil }
git_env.merge!("GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1")
commands.each { |command| abort "fixture git failed" unless system(git_env, *command, out: File::NULL) }
(root/"FIXTURE.json").write(JSON.pretty_generate(
  "kind" => "synthetic-homebrew-integration", "native_image_qualified" => false,
  "public_remote_download_qualified" => false, "candidate" => config,
  "url_replacements" => replacements,
  "mach_o_fixture" => image_record,
  "production_formula_sha256" => Digest::SHA256.hexdigest(production_formula),
  "fixture_formula_sha256" => Digest::SHA256.file(tap/"Formula/qilt.rb").hexdigest
) + "\n")
