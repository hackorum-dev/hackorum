# milliseconds a statement of an API request may run, 0 for no limit
timeout = Integer(ENV["API_STATEMENT_TIMEOUT_MS"].presence || 5000)
raise ArgumentError, "API_STATEMENT_TIMEOUT_MS must not be negative" if timeout.negative?

Rails.application.config.x.api_statement_timeout_ms = timeout
