# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "openssl"
require "uri"

module QiltRelease
  # Diagnostics deliberately contain neither response bodies nor URLs/headers.
  class DownloadRefused < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("Qilt download refused: #{reason}")
    end
  end

  class HTTPS
    def call(uri, headers)
      # Do not inherit a proxy that could receive the private API authorization.
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 15
      http.read_timeout = 60
      http.start do |connection|
        connection.request(Net::HTTP::Get.new(uri.request_uri, headers)) { |response| yield response }
      end
    end
  end

  class PrivateRelease
    API = "https://api.github.com/repos/qilt-ai/qilt-releases"
    DOWNLOAD_HOSTS = %w[api.github.com release-assets.githubusercontent.com objects.githubusercontent.com].freeze
    REDIRECTS = %w[301 302 303 307 308].freeze
    MAX_ASSET = 4 * 1024 * 1024 * 1024
    MAX_METADATA = 1024 * 1024
    MAX_REDIRECTS = 3

    def initialize(version:, token:, transport: HTTPS.new)
      unless version.is_a?(String) && version.bytesize <= 128 &&
             /\A[0-9]+\.[0-9]+\.[0-9]+\z/.match?(version)
        raise DownloadRefused.new(:version_invalid), cause: nil
      end
      unless token.is_a?(String) && token.bytesize.between?(1, 4096) && /\A[\x21-\x7e]+\z/.match?(token)
        raise DownloadRefused.new(:credential_missing_or_invalid), cause: nil
      end
      @version, @token, @transport = version, token, transport
    end

    def inspect
      "#<QiltRelease::PrivateRelease>"
    end

    # The caller supplies the formula's pin and an unpublished temporary stream.
    # Only a verified stream may subsequently become a Homebrew cache entry.
    def download(asset:, sha256:, output:)
      allowed = ["qilt-#{@version}-macos-arm64.tar.gz",
                 "qilt-#{@version}-macos-arm64.native-manifest.json",
                 "qilt-#{@version}-NOTICES.txt"]
      refuse(:asset_invalid) unless allowed.include?(asset)
      refuse(:digest_invalid) unless sha256.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(sha256)
      release = metadata
      candidates = release.fetch("assets").select { |entry| entry.is_a?(Hash) && entry["name"] == asset }
      refuse(:asset_missing_or_ambiguous) unless candidates.length == 1
      selected = candidates.first
      id, size = selected.values_at("id", "size")
      refuse(:asset_metadata_invalid) unless id.is_a?(Integer) && id.positive? &&
                                            size.is_a?(Integer) && size.between?(0, MAX_ASSET)
      # Construct the API path ourselves; never trust a metadata-supplied URL.
      uri = URI("#{API}/releases/assets/#{id}")
      checksum = Digest::SHA256.new
      bytes = 0
      redirects = 0
      loop do
        redirect = nil
        headers = { "Accept" => "application/octet-stream", "User-Agent" => "qilt-homebrew" }
        # Authorization is present on the first fixed API request only.
        headers["Authorization"] = "Bearer #{@token}" if redirects.zero?
        request(uri, headers) do |response|
          if response.code == "200"
            response.read_body do |chunk|
              bytes += chunk.bytesize
              refuse(:asset_size_mismatch) if bytes > size
              checksum.update(chunk)
              output.write(chunk)
            end
          elsif REDIRECTS.include?(response.code)
            refuse(:redirect_limit) if redirects >= MAX_REDIRECTS
            redirect = allowed_redirect(uri, response["location"])
          else
            refuse(http_reason(response.code))
          end
        end
        break unless redirect

        uri = redirect
        redirects += 1
      end
      refuse(:asset_size_mismatch) unless bytes == size
      refuse(:checksum_mismatch) unless checksum.hexdigest == sha256
      bytes
    rescue DownloadRefused => error
      raise error, cause: nil
    rescue StandardError
      # An exception may itself contain a credential or signed redirect URL.
      raise DownloadRefused.new(:download_failed), cause: nil
    end

    private

    def refuse(reason)
      raise DownloadRefused.new(reason), cause: nil
    end

    def request(uri, headers, &block)
      @transport.call(uri, headers, &block)
    rescue DownloadRefused => error
      raise error, cause: nil
    rescue StandardError
      raise DownloadRefused.new(:network_failed), cause: nil
    end

    def metadata
      bytes = +""
      request(URI("#{API}/releases/tags/v#{@version}"),
              "Accept" => "application/vnd.github+json",
              "Authorization" => "Bearer #{@token}", "User-Agent" => "qilt-homebrew") do |response|
        refuse(http_reason(response.code)) unless response.code == "200"
        response.read_body do |chunk|
          refuse(:metadata_too_large) if bytes.bytesize + chunk.bytesize > MAX_METADATA
          bytes << chunk
        end
      end
      value = JSON.parse(bytes)
      unless value.is_a?(Hash) && value["tag_name"] == "v#{@version}" &&
             value["draft"] == false && value["assets"].is_a?(Array)
        refuse(:release_metadata_invalid)
      end
      value
    rescue JSON::ParserError
      refuse(:release_metadata_invalid)
    end

    def allowed_redirect(current, location)
      refuse(:redirect_refused) unless location.is_a?(String) && location.bytesize <= 16_384
      target = URI.join(current.to_s, location)
      unless target.scheme == "https" && target.port == 443 && target.userinfo.nil? &&
             target.fragment.nil? && DOWNLOAD_HOSTS.include?(target.host)
        refuse(:redirect_refused)
      end
      target
    rescue URI::Error
      refuse(:redirect_refused)
    end

    def http_reason(code)
      %w[401 403 404].include?(code) ? :access_unavailable : :http_failed
    end
  end
end
