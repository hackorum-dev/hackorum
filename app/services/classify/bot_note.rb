module Classify
  class BotNote
    ORDER = KIND_TAGS + SIZE_TAGS + [ ENHANCEMENT_TAG ] + OUTCOME_TAGS

    def self.tags_by_topic(topic_ids)
      bot_id = User.where(username: Classify::BOT_USERNAME).pick(:id)
      return {} unless bot_id

      rows = NoteTag.joins(:note)
                    .merge(Note.global_visible.where(author_id: bot_id, topic_id: topic_ids))
                    .order("notes.id", "note_tags.id")
                    .pluck("notes.topic_id", "note_tags.tag")
      rows.each_with_object({}) { |(topic_id, tag), h| (h[topic_id] ||= []) << tag }
    end

    def initialize(topic)
      @topic = topic
    end

    def note
      Note.where(topic: @topic, global: true, author_id: bot.id).order(:id).last
    end

    def locked?
      current = note
      return false unless current
      current.deleted_at.present? || (current.last_editor_id.present? && current.last_editor_id != bot.id)
    end

    def tags
      current = note
      return [] unless current
      current.note_tags.order(:id).pluck(:tag)
    end

    def write!(new_tags)
      return :locked if locked?

      sorted = new_tags.uniq.sort_by { |t| ORDER.index(t) || ORDER.size }
      body = (%w[@global] + sorted.map { |t| "##{t}" }).join(" ")
      builder = NoteBuilder.new(author: bot)
      current = note
      if current.nil?
        builder.create!(topic: @topic, body:)
        :created
      elsif tags == sorted
        :unchanged
      else
        builder.update!(note: current, body:)
        :updated
      end
    end

    private

    def bot
      @bot ||= Classify.bot_user
    end
  end
end
