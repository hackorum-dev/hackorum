# frozen_string_literal: true

require "csv"
require "set"

module Settings
  class ImportsController < Settings::BaseController
    def show
      @summary = nil
    end

    def create
      uploaded = params[:import_file]
      unless uploaded.respond_to?(:read)
        flash.now[:alert] = "Please choose a CSV file to upload."
        @summary = nil
        return render :show
      end

      @summary = import_csv(uploaded)
      render :show
    rescue CSV::MalformedCSVError => e
      flash.now[:alert] = "Invalid CSV file: #{e.message}"
      @summary = nil
      render :show
    end

    private

    def active_settings_section
      :import
    end

    def import_csv(uploaded)
      content = uploaded.read.to_s
      rows = parse_csv_rows(content)

      result = {
        new_notes: 0,
        replaced_notes: 0,
        marked_read: 0,
        skipped_message_ids: [],
        warnings: []
      }

      read_message_ids = Set.new
      note_builder = NoteBuilder.new(author: current_user)

      rows.each do |message_id_raw, note_mode_raw, note_text_raw|
        message_id = message_id_raw.to_s.strip
        next if message_id.blank?

        message = Message.find_by(message_id: message_id)
        unless message
          result[:skipped_message_ids] << message_id
          next
        end

        if read_message_ids.add?(message.id)
          MessageReadRange.add_range(user: current_user, topic: message.topic, start_id: message.id, end_id: message.id)
          ThreadAwareness.mark_until(user: current_user, topic: message.topic, until_message_id: message.id)
        end

        note_mode = note_mode_raw.to_s.strip.downcase
        next if note_mode.blank? || note_mode == "none"

        note_text = note_text_raw.to_s
        if note_text.strip.blank?
          result[:warnings] << "Message #{message.message_id}: note text missing; skipped note import."
          next
        end

        target_message =
          case note_mode
          when "message"
            message
          when "topic"
            nil
          else
            result[:warnings] << "Message #{message.message_id}: unknown note mode '#{note_mode_raw}'."
            next
          end

        note_body = note_text.sub(/\A!autoimport\s*/i, "").strip
        note_body = "!autoimport #{note_body}".strip

        imported_notes = Note.active
                             .where(author: current_user, topic_id: message.topic_id, message_id: target_message&.id)
                             .where("notes.body LIKE ?", "!autoimport%")
                             .order(:id)

        imported_note = imported_notes.first

        if imported_note
          note_builder.update!(note: imported_note, body: note_body)
          result[:replaced_notes] += 1
        else
          note_builder.create!(topic: message.topic, message: target_message, body: note_body)
          result[:new_notes] += 1
        end

        imported_notes.offset(1).each do |extra|
          extra.transaction do
            extra.update!(deleted_at: Time.current)
            extra.note_mentions.delete_all
            extra.note_tags.delete_all
            extra.activities.update_all(hidden: true)
          end
        end
      rescue NoteBuilder::Error, ActiveRecord::RecordInvalid => e
        result[:warnings] << "Message #{message.message_id}: #{e.message}"
      end

      result[:marked_read] = read_message_ids.size
      result
    end

    def parse_csv_rows(content)
      return [] if content.blank?

      with_headers = CSV.parse(content, headers: true)
      headers = with_headers.headers.compact.map { |h| h.to_s.strip.downcase }

      if headers.include?("message_id")
        with_headers.map do |row|
          [
            row["message_id"],
            row["notemode"] || row["note_mode"],
            row["note"]
          ]
        end
      else
        CSV.parse(content, headers: false).map do |row|
          [row[0], row[1], row[2]]
        end
      end
    end
  end
end
