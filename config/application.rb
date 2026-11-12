require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Hackorum
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    require_relative "../app/middleware/api_exceptions_app"
    config.exceptions_app = ApiExceptionsApp.new(ActionDispatch::PublicExceptions.new(Rails.public_path))

    require_relative "../app/middleware/api_rate_limit_headers"
    config.middleware.insert_before ActionDispatch::ShowExceptions, ApiRateLimitHeaders

    require_relative "../app/middleware/site_method_override"
    config.middleware.swap Rack::MethodOverride, SiteMethodOverride

    require_relative "../app/middleware/pending_migration_catcher"
    initializer "pending_migration_catcher.middleware", after: "active_record.migration_error" do |app|
      if app.config.active_record.migration_error
        app.middleware.insert_before ActiveRecord::Migration::CheckPending, PendingMigrationCatcher
      end
    end
  end
end
