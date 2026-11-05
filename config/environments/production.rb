require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  force_ssl_enabled = ActiveModel::Type::Boolean.new.cast(ENV.fetch("FORCE_SSL", "true"))

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = force_ssl_enabled

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = force_ssl_enabled

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Raise delivery errors in production
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.perform_deliveries = true
  config.action_mailer.delivery_method = :smtp

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = {
    host: ENV.fetch("APP_HOST", "hackorum.dev"),
    protocol: "https"
  }

  # Default from address for all mailers
  config.action_mailer.default_options = {
    from: ENV.fetch("MAIL_FROM", "noreply@hackorum.dev")
  }

  # SMTP: Mailgun on the old deploy, the compose-internal mailserver on the new
  # one. Defaults reproduce the old behavior exactly.
  smtp_choice = lambda do |name, default, allowed|
    value = ENV.fetch(name, default).to_s.strip.downcase
    raise ArgumentError, "#{name} must be one of #{allowed.join(', ')}, got #{value.inspect}" unless allowed.include?(value)
    value
  end
  smtp_auth     = smtp_choice.call("SMTP_AUTHENTICATION", "plain", %w[plain login cram_md5 none])
  smtp_starttls = smtp_choice.call("SMTP_STARTTLS", "auto", %w[auto always none])
  smtp_verify   = smtp_choice.call("SMTP_OPENSSL_VERIFY", "peer", %w[peer none])
  smtp_settings = {
    address: ENV.fetch("SMTP_ADDRESS", "smtp.eu.mailgun.org"),
    port:    ENV.fetch("SMTP_PORT", "587").to_i,
    domain:  ENV.fetch("SMTP_DOMAIN", "hackorum.dev"),
    enable_starttls_auto: smtp_starttls == "auto",
    enable_starttls:      smtp_starttls == "always",
    openssl_verify_mode:  smtp_verify
  }
  unless smtp_auth == "none"
    smtp_settings[:authentication] = smtp_auth.to_sym
    smtp_settings[:user_name]      = ENV["SMTP_USERNAME"]
    smtp_settings[:password]       = ENV["SMTP_PASSWORD"]
  end
  config.action_mailer.smtp_settings = smtp_settings

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Raise PendingMigrationError on page load when migrations are pending.
  config.active_record.migration_error = :page_load

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Active Record encryption keys. Default to credentials (decrypted with
  # RAILS_MASTER_KEY); allow RAILS_AR_ENCRYPTION_* env overrides so a smoke-test
  # boot (e.g. prod-boot CI) can run without baking a master key into the image.
  ar_enc_env = {
    primary_key:         ENV["RAILS_AR_ENCRYPTION_PRIMARY_KEY"],
    deterministic_key:   ENV["RAILS_AR_ENCRYPTION_DETERMINISTIC_KEY"],
    key_derivation_salt: ENV["RAILS_AR_ENCRYPTION_SALT"]
  }
  if ar_enc_env.values.all?(&:present?)
    config.active_record.encryption.primary_key            = ar_enc_env[:primary_key]
    config.active_record.encryption.deterministic_key      = ar_enc_env[:deterministic_key]
    config.active_record.encryption.key_derivation_salt    = ar_enc_env[:key_derivation_salt]
  end

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
