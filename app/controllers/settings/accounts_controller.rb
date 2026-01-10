# frozen_string_literal: true

module Settings
  class AccountsController < Settings::BaseController
    def show
      @aliases = current_user.person&.aliases&.order(:email) || []
      @identities = current_user.identities.order(:provider, :email, :uid)
      @default_alias_id = current_user.person&.default_alias_id
    end

    private

    def active_settings_section
      :account
    end
  end
end
