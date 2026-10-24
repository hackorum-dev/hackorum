class TopicSlugsController < ApplicationController
  before_action :require_authentication
  before_action :set_topic

  def update
    @topic.slug = params.require(:topic).permit(:slug)[:slug]
    save_and_respond
  end

  def destroy
    @topic.slug = nil
    save_and_respond
  end

  private

  def set_topic
    @topic = Topic.find(params[:topic_id])
    return redirect_to(topic_path(@topic.final_topic)) if @topic.merged?
    head :forbidden unless @topic.slug_editable_by?(current_user)
  end

  def save_and_respond
    saved = begin
      @topic.save
    rescue ActiveRecord::RecordNotUnique
      @topic.errors.add(:slug, :taken, message: "has already been taken")
      false
    end

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          helpers.dom_id(@topic, :slug_sidebar),
          partial: "topics/slug_sidebar",
          locals: { topic: @topic, ci_status: PatchCi::TopicStatus.new(topic: @topic) }
        ), status: saved ? :ok : :unprocessable_content
      end
      format.html do
        flash[:alert] = @topic.errors.full_messages_for(:slug).to_sentence unless saved
        redirect_to topic_path(@topic)
      end
    end
  end
end
