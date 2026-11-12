# frozen_string_literal: true

class ActivitiesController < ApplicationController
  before_action :require_authentication

  def index
    @search_query = params[:q].to_s.strip
    @activities = base_scope
                    .then { |scope| apply_query(scope) }
                    .includes(subject: [ :topic, { message: :sender } ])
                    .order(created_at: :desc)
                    .limit(100)
    @visible_note_ids = visible_note_ids(@activities)
    @unread_count = base_scope.unread.count
  end

  def mark_all_read
    base_scope.unread.update_all(read_at: Time.current)
    redirect_to activities_path, notice: "Marked all as read"
  end

  def read
    activity = base_scope.find(params[:id])
    related_activities = base_scope.where(subject: activity.subject)
    related_activities.mark_all_as_read!
    subject = activity.subject
    if subject.is_a?(Note) && !Note.active.visible_to(current_user).exists?(id: subject.id)
      return redirect_to activities_path, notice: "This note is no longer available."
    end

    redirect_to path_for_subject(subject)
  end

  private

  def path_for_subject(subject)
    case subject
    when Note
      topic_path(subject.topic, anchor: subject.message_id ? helpers.message_dom_id(subject.message) : "thread-notes")
    when Message
      topic_path(subject.topic, anchor: helpers.message_dom_id(subject))
    else
      activities_path
    end
  end

  def visible_note_ids(activities)
    ids = activities.select { |activity| activity.subject_type == "Note" }.map(&:subject_id)
    return Set.new if ids.empty?

    Note.active.visible_to(current_user).where(id: ids).pluck(:id).to_set
  end

  def base_scope
    current_user.activities.visible
  end

  def apply_query(scope)
    return scope if @search_query.blank?

    note_query = scope.joins("INNER JOIN notes ON notes.id = activities.subject_id AND activities.subject_type = 'Note'")
                      .where("notes.body ILIKE ?", "%#{@search_query}%")
                      .where(notes: { id: Note.active.visible_to(current_user).select(:id) })

    message_query = scope.joins("INNER JOIN messages ON messages.id = activities.subject_id AND activities.subject_type = 'Message'")
                         .where("messages.body ILIKE ? OR messages.subject ILIKE ?", "%#{@search_query}%", "%#{@search_query}%")

    Activity.from("(#{note_query.to_sql} UNION #{message_query.to_sql}) AS activities")
  end
end
