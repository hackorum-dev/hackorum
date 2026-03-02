# frozen_string_literal: true

module Settings
  class SavedSearchPreferencesController < Settings::BaseController
    def create
      saved_search = SavedSearch.find(params[:saved_search_id])
      hidden = ActiveModel::Type::Boolean.new.cast(params[:hidden])

      pref = SavedSearchPreference.find_or_initialize_by(
        saved_search: saved_search,
        user: current_user
      )
      pref.hidden = hidden
      pref.save!

      redirect_back fallback_location: settings_saved_searches_path, notice: hidden ? "Search hidden" : "Search shown"
    end
  end
end
