# frozen_string_literal: true

require "download_strategy"
require "digest"
require "tempfile"
require "timeout"
require_relative "qilt/private_release"

# Homebrew integration. PrivateRelease owns the HTTP boundary; no inherited
# downloader resolves or prints a signed redirect, or receives an access token.
class QiltPrivateReleaseDownloadStrategy < AbstractFileDownloadStrategy
  def initialize(url, name, version, **meta)
    super
    @qilt_version = meta.fetch(:qilt_version)
    @qilt_asset = meta.fetch(:qilt_asset)
    @qilt_sha256 = meta.fetch(:qilt_sha256)
    expected = ["qilt-#{@qilt_version}-macos-arm64.tar.gz",
                "qilt-#{@qilt_version}-macos-arm64.native-manifest.json"]
    valid_version = @qilt_version.is_a?(String) && @qilt_version.bytesize <= 128 &&
                    /\A[0-9]+\.[0-9]+\.[0-9]+\z/.match?(@qilt_version)
    unless valid_version && expected.include?(@qilt_asset) &&
           @qilt_sha256.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(@qilt_sha256) &&
           url == "#{QiltRelease::PrivateRelease::API}/releases/tags/v#{@qilt_version}"
      raise CurlDownloadStrategyError, "Qilt download metadata is invalid", cause: nil
    end
  rescue KeyError
    raise CurlDownloadStrategyError, "Qilt download metadata is incomplete", cause: nil
  end

  def cached_location
    # Two assets share a release endpoint; their cache identities must differ.
    @cached_location ||= @cache/"downloads/#{Digest::SHA256.hexdigest("#{url}\0#{@qilt_asset}\0#{@qilt_sha256}")}--#{@qilt_asset}"
  end

  def fetch(timeout: nil)
    cached_location.dirname.mkpath
    lock = DownloadLock.new(temporary_path)
    begin
      lock.lock_or_wait(quiet: quiet?, timeout: timeout)
      if cached_location.exist? || cached_location.symlink?
        unless cached_location.file? && !cached_location.symlink? &&
               Digest::SHA256.file(cached_location).hexdigest == @qilt_sha256
          raise QiltRelease::DownloadRefused.new(:cached_checksum_mismatch), cause: nil
        end
        return
      end
      # Read only the installer's own scoped token, at the network boundary.
      # The formula, URL, metadata, cache filename and output never contain it.
      client = build_client
      Tempfile.create(["qilt-download-", ".part"], cached_location.dirname.to_s) do |stream|
        stream.binmode
        Timeout.timeout(timeout || 1800) do
          client.download(asset: @qilt_asset, sha256: @qilt_sha256, output: stream)
        end
        stream.flush
        stream.fsync
        # Publish only complete, verified bytes; failure leaves no cache entry.
        File.rename(stream.path, cached_location.to_s)
      end
      create_symlink_to_cached_download(cached_location)
    ensure
      lock.unlock(unlink: true)
    end
  rescue QiltRelease::DownloadRefused => error
    raise CurlDownloadStrategyError, error.message, cause: nil
  rescue Timeout::Error
    raise CurlDownloadStrategyError, "Qilt download refused: timeout", cause: nil
  end

  private

  def build_client
    QiltRelease::PrivateRelease.new(version: @qilt_version, token: ENV["HOMEBREW_QILT_TOKEN"])
  end
end
