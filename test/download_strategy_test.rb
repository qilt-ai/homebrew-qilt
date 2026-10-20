# frozen_string_literal: true

require "pathname"
require "tmpdir"
require "fileutils"
require_relative "private_release_test"

# A fixture of the published AbstractFileDownloadStrategy interface. These
# tests qualify our cache logic, not Homebrew's runtime or its locking code.
class AbstractFileDownloadStrategy
  attr_reader :url

  def initialize(url, _name, _version, **meta)
    @url, @cache = url, meta.fetch(:cache)
  end

  def temporary_path
    Pathname("#{cached_location}.incomplete")
  end

  def quiet?
    true
  end

  def create_symlink_to_cached_download(_path); end
end

class DownloadLock
  def initialize(_path); end
  def lock_or_wait(**_options); end
  def unlock(**_options); end
end

class CurlDownloadStrategyError < StandardError; end
$LOADED_FEATURES << "download_strategy.rb"
require_relative "../lib/qilt_private_download_strategy"

class DownloadStrategyTest < Minitest::Test
  def setup
    @root = Pathname(Dir.mktmpdir("qilt-cache-test-"))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def strategy(asset: PrivateReleaseTest::ASSET, sha: PrivateReleaseTest::SHA)
    QiltPrivateReleaseDownloadStrategy.new(
      "#{QiltRelease::PrivateRelease::API}/releases/tags/v0.0.1", "qilt", "0.0.1",
      cache: @root, qilt_version: "0.0.1", qilt_asset: asset, qilt_sha256: sha
    )
  end

  def client
    data = PrivateReleaseTest::DATA
    metadata = JSON.generate("tag_name" => "v0.0.1", "draft" => false,
                             "assets" => [{ "id" => 41, "name" => PrivateReleaseTest::ASSET, "size" => data.bytesize }])
    transport = PrivateReleaseTest::Transport.new(
      PrivateReleaseTest::Response.new("200", metadata, {}),
      PrivateReleaseTest::Response.new("200", data, {})
    )
    QiltRelease::PrivateRelease.new(version: "0.0.1", token: PrivateReleaseTest::TOKEN, transport: transport)
  end

  def test_verified_bytes_are_published_without_a_partial_file
    download = strategy
    download.stub(:build_client, client) { download.fetch }
    assert_equal PrivateReleaseTest::DATA, download.cached_location.binread
    assert_empty Dir[@root.join("downloads/qilt-download-*").to_s]
  end

  def test_checksum_failure_never_publishes_partial_bytes
    download = strategy(sha: "0" * 64)
    failure = assert_raises(CurlDownloadStrategyError) { download.stub(:build_client, client) { download.fetch } }
    assert_includes failure.message, "checksum_mismatch"
    refute download.cached_location.exist?
    assert_empty Dir[@root.join("downloads/qilt-download-*").to_s]
  end

  def test_existing_cache_is_checked_before_any_credential_or_network_use
    download = strategy
    download.cached_location.dirname.mkpath
    download.cached_location.binwrite(PrivateReleaseTest::DATA)
    download.stub(:build_client, -> { flunk "valid cache used credentials" }) { download.fetch }
    download.cached_location.binwrite("tampered")
    assert_raises(CurlDownloadStrategyError) do
      download.stub(:build_client, -> { flunk "bad cache used credentials" }) { download.fetch }
    end
    assert_equal "tampered", download.cached_location.binread
  end

  def test_shared_release_url_cannot_collide_between_assets_or_pins
    archive = strategy.cached_location
    manifest = strategy(asset: "qilt-0.0.1-macos-arm64.native-manifest.json").cached_location
    other_pin = strategy(sha: "0" * 64).cached_location
    refute_equal archive, manifest
    refute_equal archive, other_pin
  end
end
