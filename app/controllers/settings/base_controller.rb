# frozen_string_literal: true

module Settings
  class BaseController < ApplicationController
    before_action :require_authentication
    layout "settings"

    helper_method :active_settings_section

    private

    def active_settings_section
      :account
    end
  end
end
