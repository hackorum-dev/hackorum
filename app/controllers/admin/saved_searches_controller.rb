# frozen_string_literal: true

class Admin::SavedSearchesController < Admin::BaseController
  before_action :set_saved_search, only: [:edit, :update, :destroy]

  def active_admin_section
    :saved_searches
  end

  def index
    @tab = params[:tab] || "global"
    @saved_searches = case @tab
    when "user_templates"
      SavedSearch.user_templates.order(:position, :name)
    when "team_templates"
      SavedSearch.team_templates.order(:position, :name)
    else
      SavedSearch.global_searches.order(:position, :name)
    end
  end

  def new
    @saved_search = SavedSearch.new(scope: scope_from_tab)
  end

  def create
    @saved_search = SavedSearch.new(saved_search_params)
    if @saved_search.save
      redirect_to admin_saved_searches_path(tab: tab_from_scope), notice: "Saved search created"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @saved_search.update(saved_search_params)
      redirect_to admin_saved_searches_path(tab: tab_from_scope), notice: "Saved search updated"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    tab = tab_from_scope
    @saved_search.destroy
    redirect_to admin_saved_searches_path(tab: tab), notice: "Saved search deleted"
  end

  private

  def set_saved_search
    @saved_search = SavedSearch.find(params[:id])
  end

  def saved_search_params
    params.require(:saved_search).permit(:name, :query, :scope, :position)
  end

  def scope_from_tab
    case params[:tab]
    when "user_templates" then "user"
    when "team_templates" then "team"
    else "global"
    end
  end

  def tab_from_scope
    case @saved_search.scope
    when "user" then "user_templates"
    when "team" then "team_templates"
    else "global"
    end
  end
end
