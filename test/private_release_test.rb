# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/qilt/private_release"

class PrivateReleaseTest < Minitest::Test
  VERSION = "0.0.1"
  ASSET = "qilt-#{VERSION}-macos-arm64.tar.gz"
  TOKEN = "synthetic-read-only-token"
  DATA = "synthetic compiled archive".freeze
  SHA = Digest::SHA256.hexdigest(DATA)

  Response = Struct.new(:code, :body, :headers) do
    def [](name)
      (headers || {})[name]
    end

    def read_body
      body.to_s.bytes.each_slice(3) { |chunk| yield chunk.pack("C*") }
    end
  end

  class Transport
    attr_reader :requests

    def initialize(*responses)
      @responses, @requests = responses, []
    end

    def call(uri, headers)
      @requests << [uri.to_s, headers.dup]
      response = @responses.shift
      raise response if response.is_a?(Exception)
      raise "unexpected synthetic request" unless response

      yield response
    end
  end

  def metadata(**changes)
    value = { "tag_name" => "v#{VERSION}", "draft" => false,
              "assets" => [{ "id" => 41, "name" => ASSET, "size" => DATA.bytesize }] }
    changes.each { |key, item| value[key.to_s] = item }
    Response.new("200", JSON.generate(value), {})
  end

  def download(transport, sha: SHA)
    output = StringIO.new
    count = QiltRelease::PrivateRelease.new(version: VERSION, token: TOKEN, transport: transport)
                                      .download(asset: ASSET, sha256: sha, output: output)
    [count, output.string]
  end

  def refused(reason)
    failure = assert_raises(QiltRelease::DownloadRefused) { yield }
    assert_equal reason, failure.reason
    assert_nil failure.cause
    refute_includes failure.full_message, TOKEN
    failure
  end

  def test_exact_asset_is_streamed_and_verified
    transport = Transport.new(metadata, Response.new("200", DATA, {}))
    assert_equal [DATA.bytesize, DATA], download(transport)
    assert_equal "#{QiltRelease::PrivateRelease::API}/releases/assets/41", transport.requests.last.first
    assert_equal "Bearer #{TOKEN}", transport.requests.last.last["Authorization"]
  end

  def test_redirect_keeps_auth_only_on_initial_api_request_and_never_prints_signed_url
    signed = "https://release-assets.githubusercontent.com/private/asset?signature=synthetic-secret"
    transport = Transport.new(metadata, Response.new("302", "", { "location" => signed }),
                              Response.new("200", DATA, {}))
    out, err = capture_io { assert_equal [DATA.bytesize, DATA], download(transport) }
    assert_equal "", out
    assert_equal "", err
    assert_equal signed, transport.requests.last.first
    refute transport.requests.last.last.key?("Authorization")
    assert_equal "application/octet-stream", transport.requests.last.last["Accept"]
  end

  def test_same_host_redirect_does_not_forward_authorization_either
    transport = Transport.new(metadata, Response.new("307", "", { "location" => "/redirected-asset" }),
                              Response.new("200", DATA, {}))
    download(transport)
    refute transport.requests.last.last.key?("Authorization")
  end

  def test_expired_or_missing_repository_access_is_closed_without_echoing_body
    %w[401 403 404].each do |code|
      transport = Transport.new(Response.new(code, "private #{TOKEN}", {}))
      out, err = capture_io { refused(:access_unavailable) { download(transport) } }
      assert_equal "", out + err
      assert_equal 1, transport.requests.length
    end
  end

  def test_asset_access_expiry_is_not_treated_as_a_redirect_or_success
    transport = Transport.new(metadata, Response.new("403", TOKEN, {}))
    refused(:access_unavailable) { download(transport) }
    assert_equal 2, transport.requests.length
  end

  def test_unsafe_redirects_are_refused_before_a_request_leaves
    ["http://release-assets.githubusercontent.com/a",
     "https://unrelated.invalid/a",
     "https://user:password@release-assets.githubusercontent.com/a",
     "https://release-assets.githubusercontent.com:444/a",
     "https://release-assets.githubusercontent.com/a#fragment",
     "https://release-assets.githubusercontent.com.evil.invalid/a"].each do |location|
      transport = Transport.new(metadata, Response.new("302", "", { "location" => location }))
      refused(:redirect_refused) { download(transport) }
      assert_equal 2, transport.requests.length
    end
  end

  def test_redirect_loop_is_bounded
    response = Response.new("302", "", { "location" => "https://objects.githubusercontent.com/a" })
    transport = Transport.new(metadata, *Array.new(4, response))
    refused(:redirect_limit) { download(transport) }
    assert_equal 5, transport.requests.length
  end

  def test_release_metadata_never_redirects_with_a_credential
    transport = Transport.new(Response.new("302", "", { "location" => "https://unrelated.invalid/a" }))
    refused(:http_failed) { download(transport) }
    assert_equal 1, transport.requests.length
  end

  def test_downloaded_bytes_must_match_formula_pin
    transport = Transport.new(metadata, Response.new("200", DATA, {}))
    refused(:checksum_mismatch) { download(transport, sha: "0" * 64) }
  end

  def test_truncated_and_oversized_bodies_are_refused
    [DATA[0...-1], DATA + "extra"].each do |body|
      refused(:asset_size_mismatch) { download(Transport.new(metadata, Response.new("200", body, {}))) }
    end
  end

  def test_wrong_tag_draft_and_ambiguous_asset_are_refused
    refused(:release_metadata_invalid) { download(Transport.new(metadata(tag_name: "v9.9.9"))) }
    refused(:release_metadata_invalid) { download(Transport.new(metadata(draft: true))) }
    asset = { "id" => 41, "name" => ASSET, "size" => DATA.bytesize }
    refused(:asset_missing_or_ambiguous) { download(Transport.new(metadata(assets: [asset, asset]))) }
  end

  def test_metadata_supplied_url_cannot_choose_the_download_host
    asset = { "id" => 41, "name" => ASSET, "size" => DATA.bytesize, "url" => "https://unrelated.invalid/" }
    transport = Transport.new(metadata(assets: [asset]), Response.new("200", DATA, {}))
    download(transport)
    assert_equal "#{QiltRelease::PrivateRelease::API}/releases/assets/41", transport.requests.last.first
  end

  def test_missing_or_header_injecting_credential_never_reaches_transport
    [nil, "", "a\nAuthorization: injected", "a b", "\x00"].each do |token|
      transport = Transport.new
      refused(:credential_missing_or_invalid) do
        QiltRelease::PrivateRelease.new(version: VERSION, token: token, transport: transport)
      end
      assert_empty transport.requests
    end
  end

  def test_network_exception_is_sanitized_including_its_cause
    secret_url = "https://release-assets.githubusercontent.com/a?signature=do-not-print"
    failure = refused(:network_failed) do
      download(Transport.new(RuntimeError.new("#{TOKEN} #{secret_url}")))
    end
    refute_includes failure.full_message, secret_url
  end

  def test_inspection_cannot_echo_the_credential
    client = QiltRelease::PrivateRelease.new(version: VERSION, token: TOKEN, transport: Transport.new)
    refute_includes client.inspect, TOKEN
  end
end
