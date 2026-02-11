# frozen_string_literal: true

class MessagesController < ApplicationController
  before_action :require_authentication, only: [ :read ]

  def by_message_id
    raw = params[:message_id].to_s
    decoded = CGI.unescape(raw.gsub("+", "%2B"))
    message = Message.find_by(message_id: decoded)

    if message
      anchor = view_context.message_id_anchor(message) || view_context.message_dom_id(message)
      redirect_to topic_path(message.topic, anchor: anchor)
    else
      render plain: "Message not found", status: :not_found
    end
  end

  def read
    message = Message.find(params[:id])
    MessageReadRange.add_range(user: current_user, topic: message.topic, start_id: message.id, end_id: message.id)
    ThreadAwareness.mark_until(user: current_user, topic: message.topic, until_message_id: message.id)

    respond_to do |format|
      format.json { render json: { status: "ok" } }
      format.html { head :ok }
    end
  end
end
