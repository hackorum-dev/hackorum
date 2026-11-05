# frozen_string_literal: true

class Admin::UserFeaturesController < Admin::BaseController
  before_action :set_user

  def active_admin_section
    :users
  end

  def index
    @features = Feature::ALL
    @enrolled = @user.user_features.pluck(:feature).to_set
    @team_sources = TeamFeature.joins(team: :team_members)
                               .where(team_members: { user_id: @user.id })
                               .order("teams.name")
                               .pluck(:feature, "teams.name")
                               .group_by(&:first)
                               .transform_values { |rows| rows.map(&:last) }
  end

  def create
    feature = params[:feature].to_s
    unless Feature.valid?(feature)
      return redirect_to admin_user_features_path(@user), alert: "Unknown feature."
    end

    @user.user_features.find_or_create_by!(feature: feature)
    redirect_to admin_user_features_path(@user), notice: "#{Feature.label(feature)} enabled for #{@user.username || 'user'}."
  end

  def destroy
    feature = params[:name].to_s
    @user.user_features.where(feature: feature).destroy_all
    redirect_to admin_user_features_path(@user), notice: "Feature removed."
  end

  private

  def set_user
    @user = User.find(params[:user_id])
  end
end
