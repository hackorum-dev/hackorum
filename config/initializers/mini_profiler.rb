# frozen_string_literal: true

Rack::MiniProfiler.config.position = "right"
Rack::MiniProfiler.config.skip_paths ||= []
Rack::MiniProfiler.config.skip_paths += [ "/up" ]
Rack::MiniProfiler.config.enable_hotwire_turbo_drive_support = true

if Rails.env.development?
  Rack::MiniProfiler.config.authorization_mode = :allow_all
else
  # Only allow signed-in admins in production; authorization happens later in ApplicationController.
  Rack::MiniProfiler.config.authorization_mode = :allow_authorized
end
