# frozen_string_literal: true

module Settings
  class ApiTokensController < Settings::BaseController
    EXPIRY_DAYS = { "30" => 30, "90" => 90, "365" => 365 }.freeze

    def index
      load_tokens
    end

    def create
      unless valid_expiry?
        return redirect_to settings_api_tokens_path, alert: "Unknown expiry."
      end

      current_user.with_lock do
        if current_user.api_tokens.active.count < ApiToken::MAX_PER_USER
          @token, @raw_token = ApiToken.issue!(user: current_user, name: params[:name].to_s.strip, expires_at: expires_at)
        end
      end
      return redirect_to settings_api_tokens_path, alert: "Too many tokens. Revoke one first." unless @token

      load_tokens
      # the raw value is on this page only, keep it out of caches
      response.headers["Cache-Control"] = "no-store"
      render :index
    rescue ActiveRecord::RecordInvalid => e
      redirect_to settings_api_tokens_path, alert: e.record.errors.full_messages.to_sentence
    end

    def destroy
      current_user.api_tokens.where(revoked_at: nil).find(params[:id]).revoke!
      redirect_to settings_api_tokens_path, notice: "Token revoked."
    end

    private

    def valid_expiry?
      params[:expires_in].blank? || EXPIRY_DAYS.key?(params[:expires_in].to_s)
    end

    def expires_at
      days = EXPIRY_DAYS[params[:expires_in].to_s]
      days&.days&.from_now
    end

    def load_tokens
      @tokens = current_user.api_tokens.where(revoked_at: nil).order(created_at: :desc)
    end

    def active_settings_section
      :api_tokens
    end
  end
end
