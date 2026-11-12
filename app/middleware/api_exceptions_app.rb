# frozen_string_literal: true

class ApiExceptionsApp
  API_PATH = %r{\A/api/v1(?=[/.]|\z)}
  CODES = {
    400 => "bad_request",
    404 => "not_found",
    405 => "method_not_allowed",
    406 => "not_acceptable",
    422 => "unprocessable_content",
    500 => "internal_error"
  }.freeze

  def initialize(fallback)
    @fallback = fallback
  end

  def call(env)
    path = env["action_dispatch.original_path"] || env["PATH_INFO"]
    return @fallback.call(env) unless API_PATH.match?(path.to_s.b)

    render(env["PATH_INFO"].to_s.delete_prefix("/").to_i)
  end

  private

  def render(status)
    status = 500 unless Rack::Utils::HTTP_STATUS_CODES.key?(status)
    phrase = Rack::Utils::HTTP_STATUS_CODES[status]
    code = CODES.fetch(status) { phrase.downcase.gsub(/[^a-z]+/, "_") }
    body = { error: { code: code, message: phrase } }.to_json
    headers = {
      "content-type" => "application/json; charset=utf-8",
      "content-length" => body.bytesize.to_s,
      "cache-control" => "no-store"
    }
    [ status, headers, [ body ] ]
  end
end
