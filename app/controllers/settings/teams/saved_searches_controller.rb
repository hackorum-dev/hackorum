# frozen_string_literal: true

module Settings
  module Teams
    class SavedSearchesController < Settings::BaseController
      before_action :set_team
      before_action :require_team_member!
      before_action :set_saved_search, only: [:edit, :update, :destroy]
      before_action :require_team_admin!, only: [:new, :create, :edit, :update, :destroy]

      def index
        @saved_searches = @team.saved_searches.order(:position, :name)
        @system_searches = SavedSearch.team_templates.order(:position, :name)
        @hidden_ids = SavedSearchPreference
          .where(user: current_user, hidden: true)
          .pluck(:saved_search_id)
          .to_set
      end

      def new
        @saved_search = @team.saved_searches.build(scope: "team")
      end

      def create
        @saved_search = @team.saved_searches.build(saved_search_params)
        @saved_search.scope = "team"
        if @saved_search.save
          redirect_to settings_team_saved_searches_path(@team), notice: "Saved search created"
        else
          render :new, status: :unprocessable_entity
        end
      end

      def edit
      end

      def update
        if @saved_search.update(saved_search_params)
          redirect_to settings_team_saved_searches_path(@team), notice: "Saved search updated"
        else
          render :edit, status: :unprocessable_entity
        end
      end

      def destroy
        @saved_search.destroy
        redirect_to settings_team_saved_searches_path(@team), notice: "Saved search deleted"
      end

      private

      def active_settings_section
        :teams
      end

      def set_team
        @team = Team.find(params[:team_id])
      end

      def set_saved_search
        @saved_search = @team.saved_searches.find(params[:id])
      end

      def require_team_member!
        unless user_signed_in? && @team.member?(current_user)
          render file: Rails.root.join("public/404.html"), status: :not_found, layout: false
        end
      end

      def require_team_admin!
        unless @team.admin?(current_user)
          redirect_to settings_team_saved_searches_path(@team), alert: "Admins only"
        end
      end

      def saved_search_params
        params.require(:saved_search).permit(:name, :query)
      end
    end
  end
end
