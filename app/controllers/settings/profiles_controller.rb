# frozen_string_literal: true

module Settings
  class ProfilesController < Settings::BaseController
    def show
    end

    private

    def active_settings_section
      :profile
    end
  end
end
