# frozen_string_literal: true

require "digest"
require "erb"
require "fileutils"
require "json"
require "pathname"
require "tempfile"

module QiltFormula
  ROOT = Pathname(__dir__).parent
  FIELDS = %w[version tarball_sha256 manifest_sha256 macos_minimum].freeze

  def self.render(config)
    raise ArgumentError, "candidate fields invalid" unless config.is_a?(Hash) && config.keys.sort == FIELDS.sort

    release_version = config.fetch("version")
    tarball_sha256 = config.fetch("tarball_sha256")
    manifest_sha256 = config.fetch("manifest_sha256")
    macos_minimum = config.fetch("macos_minimum")
    unless release_version.is_a?(String) && release_version.bytesize <= 128 &&
           /\A[0-9]+\.[0-9]+\.[0-9]+\z/.match?(release_version)
      raise ArgumentError, "candidate version invalid"
    end
    [tarball_sha256, manifest_sha256].each do |value|
      raise ArgumentError, "candidate digest invalid" unless value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value)
    end
    unless macos_minimum.is_a?(String) && /\A[0-9]{2}(?:\.[0-9]{1,2}){1,2}\z/.match?(macos_minimum)
      raise ArgumentError, "candidate macOS floor invalid"
    end
    # An installed formula may be read from K/.brew, outside the tap. Embed the
    # tested helpers so that it never depends on a relative tap file there.
    helpers = %w[lib/qilt/private_release.rb lib/qilt/install_payload.rb
                 lib/qilt_private_download_strategy.rb].map do |name|
      source = (ROOT/name).read
      if name.end_with?("qilt_private_download_strategy.rb")
        line = "require_relative \"qilt/private_release\"\n"
        raise "helper import changed" unless source.scan(line).length == 1

        source = source.sub(line, "")
      end
      source
    end.join("\n")
    literal = ->(value) { value.dump }
    ERB.new((ROOT/"templates/qilt.rb.erb").read, trim_mode: "-").result(binding)
  end

  def self.write(config_path, output_path)
    output = Pathname(output_path)
    bytes = render(JSON.parse(File.read(config_path)))
    FileUtils.mkdir_p(output.parent)
    Tempfile.create(["qilt-formula-", ".tmp"], output.parent.to_s) do |file|
      file.write(bytes)
      file.flush
      file.fsync
      File.chmod(0o644, file.path)
      File.rename(file.path, output.to_s)
    end
    Digest::SHA256.hexdigest(bytes)
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: ruby scripts/render_formula.rb CANDIDATE.json Formula/qilt.rb" unless ARGV.length == 2
  begin
    puts "Formula sha256: #{QiltFormula.write(*ARGV)}"
  rescue ArgumentError, JSON::ParserError
    abort "Candidate metadata refused; formula was not written."
  end
end
