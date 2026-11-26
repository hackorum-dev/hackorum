# frozen_string_literal: true

class Admin::FeatureGroupsController < Admin::BaseController
  before_action :set_group, only: [ :show, :edit, :update, :destroy, :merge, :override_version, :clear_version,
                                    :recompute_versions, :dissolve ]

  def active_admin_section
    :feature_groups
  end

  def index
    @groups = FeatureGroup.live.order(:name)
    if params[:q].present?
      @groups = @groups.where("name ILIKE ?", "%#{FeatureGroup.sanitize_sql_like(params[:q].strip)}%")
    end
    @member_counts = FeatureGroupTopic.where(feature_group_id: @groups.select(:id)).group(:feature_group_id).count
  end

  def show
    @memberships = @group.feature_group_topics.includes(:topic).order(:topic_id)
    @tags = Classify::BotNote.tags_by_topic(@memberships.map(&:topic_id))
    @versions = @group.feature_group_versions.order(:major)
    @version_shas = Commit.where(id: @versions.flat_map(&:commit_ids)).pluck(:id, :sha).to_h
    @version_topics = Topic.where(id: @versions.flat_map(&:topic_ids)).index_by(&:id)
  end

  def duplicates
    @pairs = FeatureGroups::Duplicates.pairs
    @member_counts = FeatureGroupTopic.where(feature_group_id: @pairs.flat_map { |p| [ p[:a].id, p[:b].id ] })
                                      .group(:feature_group_id).count
  end

  def dismiss_pair
    low, high = [ params[:a_id].to_i, params[:b_id].to_i ].minmax
    if low != high && FeatureGroup.where(id: [ low, high ]).count == 2
      FeatureGroupDismissedPair.find_or_create_by!(low_id: low, high_id: high)
    end
    redirect_to duplicates_admin_feature_groups_path, notice: "Pair dismissed"
  rescue ActiveRecord::RecordNotUnique
    redirect_to duplicates_admin_feature_groups_path, notice: "Pair dismissed"
  end

  def edit
  end

  def update
    attrs = params.require(:feature_group).permit(:name, :slug, :summary).merge(source: "human")
    if @group.update(attrs)
      redirect_to admin_feature_group_path(@group), notice: "Group updated"
    else
      render :edit, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    @group.errors.add(:slug, "is already taken")
    render :edit, status: :unprocessable_entity
  end

  def merge
    target = FeatureGroup.find_by(id: params[:target_id])
    if target.nil?
      redirect_to admin_feature_group_path(@group), alert: "Target group not found"
    else
      @group.merge_into!(target)
      FeatureGroups::Versions.refresh_isolated!([ @group.id, @group.surviving.id ])
      redirect_to admin_feature_group_path(@group.surviving), notice: "Group merged"
    end
  rescue ArgumentError => e
    redirect_to admin_feature_group_path(@group), alert: e.message
  end

  def override_version
    major = Integer(params[:major].to_s, 10, exception: false)
    status = params[:status].to_s
    role = params[:role].presence
    unless major&.positive? && FeatureGroupVersion::STATUSES.include?(status) && (role.nil? || FeatureGroupVersion::ROLES.include?(role))
      return redirect_to admin_feature_group_path(@group), alert: "Invalid major, status or role"
    end

    @group.with_lock do
      @group.feature_group_versions.find_or_initialize_by(major: major).update!(status: status, role: role, source: "human")
    end
    redirect_to admin_feature_group_path(@group), notice: "Version #{major} set"
  end

  def clear_version
    @group.feature_group_versions.where(major: params[:major].to_i, source: "human").delete_all
    FeatureGroups::Versions.refresh!([ @group.id ])
    redirect_to admin_feature_group_path(@group), notice: "Override cleared"
  end

  def recompute_versions
    FeatureGroups::Versions.refresh!([ @group.id ])
    redirect_to admin_feature_group_path(@group), notice: "Versions recomputed"
  end

  # bot memberships go, admin ones stay
  def dissolve
    @group.feature_group_topics.where.not(source: "human").delete_all
    FeatureGroups::Versions.refresh_isolated!([ @group.id ])
    redirect_to admin_feature_group_path(@group), notice: "Group dissolved"
  end

  def destroy
    if @group.merged_into_id
      redirect_to admin_feature_group_path(@group), alert: "Merged group keeps its slug redirect"
    elsif @group.feature_group_topics.exists? || FeatureGroup.where(merged_into_id: @group.id).exists?
      redirect_to admin_feature_group_path(@group), alert: "Group still has members or merged groups"
    else
      @group.destroy!
      redirect_to admin_feature_groups_path, notice: "Group deleted"
    end
  end

  private

  def set_group
    @group = FeatureGroup.find(params[:id])
  end
end
