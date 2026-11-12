module Api
  # Every error code the API answers with, and its HTTP status.
  module ErrorCodes
    STATUSES = {
      "bad_request" => 400,
      "invalid_parameter" => 400,
      "invalid_query" => 400,
      "invalid_cursor" => 400,
      "invalid_limit" => 400,
      "query_too_expensive" => 400,
      "token_required" => 401,
      "invalid_token" => 401,
      "feature_required" => 403,
      "no_send_identity" => 403,
      "not_found" => 404,
      "method_not_allowed" => 405,
      "not_acceptable" => 406,
      "conflict" => 409,
      "cursor_expired" => 410,
      "payload_too_large" => 413,
      "unsupported_media_type" => 415,
      "invalid_body" => 422,
      "draft_limit" => 422,
      "unprocessable_content" => 422,
      "rate_limited" => 429,
      "internal_error" => 500
    }.freeze
  end
end
