# frozen_string_literal: true

module Settings
  class SavedSearchesController < Settings::BaseController
    before_action :set_saved_search, only: [:edit, :update, :destroy]

    def index
      @saved_searches = current_user.saved_searches.order(:position, :name)
      @system_searches = SavedSearch.user_templates.order(:position, :name)
      @global_searches = SavedSearch.scope_global.order(:position, :name)
      @hidden_ids = SavedSearchPreference
        .where(user: current_user, hidden: true)
        .pluck(:saved_search_id)
        .to_set
    end

    def new
      @saved_search = current_user.saved_searches.build(scope: "user")
    end

    def create
      @saved_search = current_user.saved_searches.build(saved_search_params)
      @saved_search.scope = "user"
      if @saved_search.save
        redirect_to settings_saved_searches_path, notice: "Saved search created"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @saved_search.update(saved_search_params)
        redirect_to settings_saved_searches_path, notice: "Saved search updated"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @saved_search.destroy
      redirect_to settings_saved_searches_path, notice: "Saved search deleted"
    end

    private

    def active_settings_section
      :saved_searches
    end

    def set_saved_search
      @saved_search = current_user.saved_searches.find(params[:id])
    end

    def saved_search_params
      params.require(:saved_search).permit(:name, :query)
    end
  end
end
