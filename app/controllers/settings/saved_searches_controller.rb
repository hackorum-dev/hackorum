# frozen_string_literal: true

module Settings
  class SavedSearchesController < Settings::BaseController
    before_action :set_saved_search, only: [ :edit, :update, :destroy ]
    before_action :set_default_saved_search_id, only: [ :index ]

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
        respond_to do |format|
          format.html { redirect_to settings_saved_searches_path, notice: "Saved search created" }
          format.json { render json: { redirect_url: search_topics_path(saved_search_id: @saved_search.id) } }
        end
      else
        respond_to do |format|
          format.html { render :new, status: :unprocessable_entity }
          format.json { render json: { errors: @saved_search.errors.full_messages }, status: :unprocessable_entity }
        end
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

      referrer = request.referer.to_s
      if referrer.include?("saved_search_id=#{@saved_search.id}")
        render turbo_stream: %(<turbo-stream action="visit" url="#{root_path}"></turbo-stream>)
      else
        redirect_back fallback_location: settings_saved_searches_path, notice: "Saved search deleted"
      end
    end

    private

    def active_settings_section
      :saved_searches
    end

    def set_saved_search
      @saved_search = current_user.saved_searches.find(params[:id])
    end

    def set_default_saved_search_id
      @default_saved_search_id = current_user.default_saved_search_preference&.saved_search_id
    end

    def saved_search_params
      params.require(:saved_search).permit(:name, :query)
    end
  end
end
