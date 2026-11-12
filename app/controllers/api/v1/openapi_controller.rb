module Api
  module V1
    class OpenapiController < BaseController
      SOURCE = Rails.root.join("docs/api/openapi.yaml")
      GUIDE = Rails.root.join("docs/api/guide.md")

      skip_before_action :authenticate_token
      skip_around_action :with_statement_timeout

      def self.yaml
        return SOURCE.read if Rails.env.development?
        @yaml ||= SOURCE.read
      end

      def self.json
        return YAML.safe_load(yaml).to_json if Rails.env.development?
        @json ||= YAML.safe_load(yaml).to_json
      end

      def self.guide
        return GUIDE.read if Rails.env.development?
        @guide ||= GUIDE.read
      end

      def show
        expires_in 1.hour, public: true
        if params[:format].to_s == "yaml"
          send_data self.class.yaml, type: "application/yaml", disposition: "inline"
        else
          render json: self.class.json
        end
      end

      def guide
        expires_in 1.hour, public: true
        send_data self.class.guide, type: "text/markdown; charset=utf-8", disposition: "inline"
      end
    end
  end
end
