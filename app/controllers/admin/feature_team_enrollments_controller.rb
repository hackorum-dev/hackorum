# frozen_string_literal: true

class Admin::FeatureTeamEnrollmentsController < Admin::BaseController
  before_action :set_feature

  def active_admin_section
    :features
  end

  def create
    name = params[:team_name].to_s.strip
    team = Team.find_by("LOWER(name) = LOWER(?)", name)
    if team.nil?
      return redirect_to admin_feature_path(@feature), alert: "No team named '#{name}'."
    end

    team.team_features.find_or_create_by!(feature: @feature)
    redirect_to admin_feature_path(@feature), notice: "Enabled for team #{team.name}."
  end

  def destroy
    team = Team.find(params[:team_id])
    team.team_features.where(feature: @feature).destroy_all
    redirect_to admin_feature_path(@feature), notice: "Removed team enrollment."
  end

  private

  def set_feature
    @feature = params[:feature_name].to_s
    unless Feature.valid?(@feature)
      render plain: "Not found", status: :not_found
    end
  end
end
