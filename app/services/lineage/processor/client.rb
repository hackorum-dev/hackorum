require "net/http"
require "json"
require "openssl"
require "uri"
require "securerandom"

module Lineage
  module Processor
    class Client
      Error = Class.new(StandardError)
      Conflict = Class.new(Error)
      Claim = Struct.new(:run_id, :topic_id, :mode, :prompt_version, keyword_init: true)

      TRANSPORT_ERRORS = [
        SystemCallError, Timeout::Error, IOError, SocketError, OpenSSL::SSL::SSLError,
        Net::ProtocolError, JSON::ParserError
      ].freeze

      def initialize(server:, token:, open_timeout: 10, read_timeout: 600)
        @uri = URI.parse(server)
        @token = token
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def claim(worker:, phases: nil)
        req = Net::HTTP::Post.new(path("/claims"), "Content-Type" => "application/json")
        body = { worker: worker }
        body[:phases] = phases if phases&.any?
        req.body = JSON.dump(body)
        res = request(req)
        return nil if res.code == "204"
        check!(res, "201")
        data = parse(res)
        Claim.new(run_id: data["run_id"], topic_id: data["topic_id"], mode: data["mode"], prompt_version: data["prompt_version"])
      end

      # -> path, or nil while the server still builds the bundle
      def download_bundle(run_id, to:)
        part = "#{to}.part"
        pending = false
        guard do
          File.open(part, "wb") do |f|
            http.request(authed(Net::HTTP::Get.new(path("/claims/#{run_id}/bundle")))) do |res|
              pending = res.code == "202"
              next if pending
              check!(res, "200", conflict: %w[404 409])
              res.read_body { |chunk| f.write(chunk) }
            end
          end
        end
        if pending
          File.unlink(part)
          return nil
        end
        File.rename(part, to)
        to
      rescue
        File.unlink(part) if File.exist?(part)
        raise
      end

      def submit_result(run_id, fields, result_path: nil)
        boundary = "lineage-#{SecureRandom.hex(16)}"
        req = Net::HTTP::Post.new(path("/claims/#{run_id}/result"), "Content-Type" => "multipart/form-data; boundary=#{boundary}")
        file = File.binread(result_path) if result_path && File.exist?(result_path)
        req.body = multipart_body(boundary, fields.compact, file)
        res = request(req)
        check!(res, "200", conflict: %w[404 409])
        parse(res)
      end

      def release(run_id)
        res = request(Net::HTTP::Delete.new(path("/claims/#{run_id}")))
        return if %w[204 404 409].include?(res.code)
        check!(res, "204")
      end

      def queue
        res = request(Net::HTTP::Get.new(path("/queue")))
        check!(res, "200")
        parse(res)
      end

      private

      def http
        Net::HTTP.new(@uri.host, @uri.port).tap do |h|
          h.use_ssl = @uri.scheme == "https"
          h.open_timeout = @open_timeout
          h.read_timeout = @read_timeout
        end
      end

      def path(suffix) = "#{@uri.path.chomp('/')}/api/lineage#{suffix}"

      def authed(req)
        req["Authorization"] = "Bearer #{@token}"
        req
      end

      def request(req) = guard { http.request(authed(req)) }

      def parse(res) = guard { JSON.parse(res.body) }

      def multipart_body(boundary, fields, file)
        parts = fields.map do |k, v|
          "Content-Disposition: form-data; name=\"#{k}\"\r\n\r\n#{v}"
        end
        if file
          parts << "Content-Disposition: form-data; name=\"result\"; filename=\"result.json\"\r\n" \
                   "Content-Type: application/json\r\n\r\n#{file}"
        end
        body = parts.map { |p| "--#{boundary}\r\n#{p}\r\n".b }.join
        body + "--#{boundary}--\r\n"
      end

      def guard
        yield
      rescue *TRANSPORT_ERRORS => e
        raise Error, "#{e.class}: #{e.message}"
      end

      def check!(res, code, conflict: %w[409])
        return if res.code == code
        raise Conflict, "#{res.code}: #{res.body.to_s[0, 200]}" if conflict.include?(res.code)
        raise Error, "#{res.code}: #{res.body.to_s[0, 200]}"
      end
    end
  end
end
