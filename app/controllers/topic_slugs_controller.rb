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
        streams = [ turbo_stream.replace(helpers.dom_id(@topic, :slug_sidebar), partial: "topics/sidebar/short_link", locals: { topic: @topic }) ]
        image = saved && PatchCi::TopicStatus.new(topic: @topic).image_run
        if image
          streams << turbo_stream.replace(helpers.dom_id(@topic, :docker_button), partial: "topics/sidebar/docker_button", locals: { topic: @topic, image: image })
        end
        render turbo_stream: streams, status: saved ? :ok : :unprocessable_content
      end
      format.html do
        flash[:alert] = @topic.errors.full_messages_for(:slug).to_sentence unless saved
        redirect_to topic_path(@topic)
      end
    end
  end
end
