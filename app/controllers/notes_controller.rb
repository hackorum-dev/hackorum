# frozen_string_literal: true

class NotesController < ApplicationController
  before_action :require_authentication
  before_action :set_note, only: [:update]

  def new
    topic = Topic.find(params[:topic_id])
    message = resolve_message(topic)
    respond_to do |format|
      format.turbo_stream { render_note_stack_stream(topic:, message:, open_form: true) }
      format.html { redirect_to topic_path(topic, anchor: message ? note_frame_id(message) : "thread-notes") }
    end
  end

  def stack
    topic = Topic.find(params[:topic_id])
    message = resolve_message(topic)
    respond_to do |format|
      format.turbo_stream { render_note_stack_stream(topic:, message:, open_form: false) }
      format.html { redirect_to topic_path(topic, anchor: message ? note_frame_id(message) : "thread-notes") }
    end
  end

  def create
    topic = Topic.find(note_params[:topic_id])
    message = resolve_message(topic)
    note = NoteBuilder.new(author: current_user).create!(topic:, message:, body: note_params[:body])

    respond_to do |format|
      format.html { redirect_to topic_path(topic, anchor: note_anchor(note)), notice: "Note added" }
      format.turbo_stream { render_note_stack_stream(topic:, message:, open_form: false) }
    end
  rescue NoteBuilder::Error, ActiveRecord::RecordInvalid => e
    handle_note_error(topic:, message:, error: e)
  end

  def update
    return if performed?

    NoteBuilder.new(author: current_user).update!(note: @note, body: note_params[:body])

    respond_to do |format|
      format.html { redirect_to topic_path(@note.topic, anchor: note_anchor(@note)), notice: "Note updated" }
      format.turbo_stream { render_note_stack_stream(topic: @note.topic, message: @note.message, open_form: false) }
    end
  rescue NoteBuilder::Error, ActiveRecord::RecordInvalid => e
    handle_note_error(topic: @note.topic, message: @note.message, error: e, note: @note)
  end

  private

  def set_note
    @note = Note.find(params[:id])
    unless @note.author_id == current_user.id
      redirect_back fallback_location: topic_path(@note.topic), alert: "You can only edit your own notes"
      return
    end
  end

  def note_params
    params.require(:note).permit(:body, :topic_id, :message_id)
  end

  def resolve_message(topic)
    msg_id = params[:message_id].presence || params.dig(:note, :message_id)
    return nil if msg_id.blank?
    topic.messages.find_by(id: msg_id)
  end

  def note_anchor(note)
    if note.message_id
      view_context.message_dom_id(note.message)
    else
      "thread-notes"
    end
  end

  def note_frame_id(message)
    message ? "notes-message-#{message.id}" : "thread-notes"
  end

  def note_collection(topic:, message:)
    Note.where(topic:, message:).includes(:author, :note_tags, :note_mentions).order(:created_at)
  end

  def render_note_stack_stream(topic:, message:, open_form:, status: :ok)
    notes = note_collection(topic:, message:)
    render(
      turbo_stream: turbo_stream.replace(
        note_frame_id(message),
        partial: "notes/note_stack",
        locals: { topic:, message:, notes:, open_form: }
      ),
      status: status
    )
  end

  def handle_note_error(topic:, message:, error:, note: nil)
    flash_payload = {
      body: note_params[:body],
      message_id: note_params[:message_id].presence,
      topic_id: note_params[:topic_id],
      note_id: note&.id,
      error: error.message
    }

    respond_to do |format|
      format.html do
        flash[:alert] = error.message
        flash[:note_error] = flash_payload
        redirect_back fallback_location: topic_path(topic)
      end
      format.turbo_stream do
        flash.now[:alert] = error.message
        flash.now[:note_error] = flash_payload
        render_note_stack_stream(topic:, message:, open_form: true, status: :unprocessable_entity)
      end
    end
  end
end
