module Api
  module V1
    # What a serializer may know about the caller.
    class Context
      attr_reader :user, :token, :base_url

      def initialize(user:, token:, base_url:)
        @user = user
        @token = token
        @base_url = base_url
        @features = {}
      end

      def signed_in?
        user.present?
      end

      def feature?(name)
        return false unless user
        @features.fetch(name.to_s) { |key| @features[key] = user.has_feature?(key) }
      end

      def routes
        Rails.application.routes.url_helpers
      end

      def site_url(path)
        "#{base_url}#{path}"
      end

      def api_url(path)
        "#{base_url}/api/v1#{path}"
      end
    end
  end
end
