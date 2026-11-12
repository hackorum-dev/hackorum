# frozen_string_literal: true

class ApiDocsController < ApplicationController
  layout "help"

  CHROME = %w[app/views/layouts/application.html.slim app/views/layouts/help.html.slim].freeze

  class << self
    def chrome_digest
      return digest_chrome if Rails.env.development?

      @chrome_digest ||= digest_chrome
    end

    private

    def digest_chrome
      Digest::SHA256.hexdigest(CHROME.map { |path| Rails.root.join(path).read }.join)
    end
  end

  def show
    @reference = Api::Reference.current
    @title = "API reference"
    @outline = outline
    cache_for_guests
  end

  def active_help_section
    "api-reference"
  end

  private

  def outline
    [ { level: 2, title: "Contents", id: "contents" }, { level: 2, title: "Overview", id: "overview" } ] +
      @reference.tags.map { |tag| { level: 2, title: tag.name, id: tag.anchor } } +
      [ { level: 2, title: "Shared responses", id: "responses" }, { level: 2, title: "Schemas", id: "schemas" } ]
  end

  # the layout shows the signed-in user, so only a guest's page is the same for everyone
  def cache_for_guests
    return if user_signed_in? || flash.any?

    request.session_options[:skip] = true
    expires_in 1.hour, public: true
    fresh_when etag: [ @reference.digest, self.class.chrome_digest, view_context.asset_path("application.css") ]
  end
end
