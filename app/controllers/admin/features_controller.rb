# frozen_string_literal: true

class Admin::FeaturesController < Admin::BaseController
  before_action :set_feature, only: [ :show ]

  def active_admin_section
    :features
  end

  def index
    @features = Feature::ALL
    @user_counts = Feature.names.to_h { |name| [ name.to_s, Feature.access_by_user(name).size ] }
    @team_counts = TeamFeature.group(:feature).count
  end

  def show
    @label = Feature.label(@feature)
    @access = Feature.access_by_user(@feature)
    @users = User.where(id: @access.keys)
                 .includes(person: :default_alias)
                 .order(:username)
    @teams = Team.joins(:team_features)
                 .where(team_features: { feature: @feature })
                 .left_joins(:team_members)
                 .group("teams.id")
                 .select("teams.*, COUNT(team_members.id) AS member_count")
                 .order(:name)
  end

  private

  def set_feature
    @feature = params[:name].to_s
    unless Feature.valid?(@feature)
      render plain: "Not found", status: :not_found
    end
  end
end
