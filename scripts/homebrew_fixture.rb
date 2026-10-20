# frozen_string_literal: true

# Generate an inert, explicitly synthetic tap for the disposable macOS runner.
# This does not qualify a native image, a real credential or the public endpoint.
require "digest"
require "fileutils"
require "find"
require "json"
require "pathname"
require_relative "render_formula"

root = Pathname(ARGV.fetch(0)).expand_path
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
metadata = { "tag_name" => "v0.0.0", "draft" => false,
             "assets" => [archive, manifest].each_with_index.map do |file, index|
               { "id" => index + 1, "name" => file.basename.to_s, "size" => file.size }
             end }
(root/"release.json").write(JSON.generate(metadata))
tap = root/"tap"
(tap/"Formula").mkpath
production_formula = QiltFormula.render(config)
(root/"generated-production-formula.rb").write(production_formula)

# Only this fixture copy replaces the transport. The generated production
# formula is retained separately and has no endpoint override or test mode.
bridge = <<~RUBY
  # SYNTHETIC CI TRANSPORT — never a release formula.
  module QiltRelease
    class HTTPS
      def call(uri, headers)
        raise "fixture credential not received at fetch time" unless headers["Authorization"] == "Bearer synthetic-fixture-token"
        root = Pathname(#{root.to_s.dump})
        name = case uri.path
               when "/repos/qilt-ai/qilt-releases/releases/tags/v0.0.0" then "release.json"
               when "/repos/qilt-ai/qilt-releases/releases/assets/1" then "qilt-0.0.0-macos-arm64.tar.gz"
               when "/repos/qilt-ai/qilt-releases/releases/assets/2" then "qilt-0.0.0-macos-arm64.native-manifest.json"
               else raise "unexpected fixture request"
               end
        response = Struct.new(:code, :body) do
          def [](key); nil; end
          def read_body; yield body; end
        end.new("200", (root/name).binread)
        yield response
      end
    end
  end
RUBY
(tap/"Formula/qilt.rb").write(production_formula + "\n" + bridge)
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
  "real_authentication_qualified" => false, "candidate" => config,
  "production_formula_sha256" => Digest::SHA256.hexdigest(production_formula),
  "fixture_formula_sha256" => Digest::SHA256.file(tap/"Formula/qilt.rb").hexdigest
) + "\n")
