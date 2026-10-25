require "net/http"
require "json"
require "base64"

module Gmail
  class SendClient
    URL = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"

    def self.send_raw(identity, rfc822_string)
      uri = URI(URL)
      raw = Base64.urlsafe_encode64(rfc822_string)

      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{identity.access_token}"
      req["Content-Type"]  = "application/json"
      req.body = { raw: raw }.to_json

      res =
        begin
          Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
        rescue Net::OpenTimeout, Net::WriteTimeout, SocketError, Errno::ECONNREFUSED,
               Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Errno::ENETUNREACH => e
          raise TransientError, "network error: #{e.class}: #{e.message}"
        rescue Net::ReadTimeout, Errno::ECONNRESET, EOFError, IOError => e
          raise UncertainError, "network error: #{e.class}: #{e.message}"
        end

      case res.code.to_i
      when 200      then JSON.parse(res.body)
      when 401      then raise AuthRevokedError, res.body
      when 403      then raise ScopeError,       res.body
      when 429      then raise TransientError,   res.body
      when 400..499 then raise PermanentError,   res.body
      else               raise TransientError,   res.body
      end
    end
  end
end
