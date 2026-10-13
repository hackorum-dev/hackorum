# frozen_string_literal: true

class Admin::GlobalTagsController < Admin::BaseController
  before_action :set_global_tag, only: [ :edit, :update, :destroy, :retire, :unretire ]

  def active_admin_section
    :global_tags
  end

  def index
    @global_tags = GlobalTag.order(:name)
    @usage_counts = GlobalTag.usage_counts
  end

  def new
    @global_tag = GlobalTag.new
  end

  def create
    @global_tag = GlobalTag.new(params.require(:global_tag).permit(:name, :description))
    @global_tag.created_by = current_user
    if @global_tag.save
      redirect_to admin_global_tags_path, notice: "Global tag created"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @global_tag.update(params.require(:global_tag).permit(:description))
      redirect_to admin_global_tags_path, notice: "Global tag updated"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @global_tag.destroy
      redirect_to admin_global_tags_path, notice: "Global tag deleted"
    else
      redirect_to admin_global_tags_path, alert: @global_tag.errors.full_messages.to_sentence
    end
  end

  def retire
    @global_tag.retire!
    redirect_to admin_global_tags_path, notice: "Global tag retired"
  end

  def unretire
    @global_tag.unretire!
    redirect_to admin_global_tags_path, notice: "Global tag restored"
  end

  private

  def set_global_tag
    @global_tag = GlobalTag.find(params[:id])
  end
end
