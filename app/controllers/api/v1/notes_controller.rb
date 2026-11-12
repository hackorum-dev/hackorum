module Api
  module V1
    class NotesController < BaseController
      include TopicLookup

      query_params :message_id, paged: true, on: :index
      cursor_per_caller on: :index

      def index
        topic = find_topic!(params[:id])
        visible = Note.active.visible_to(current_user).where(topic_id: topic.id)
        message_id = message_id_param
        visible = visible.where(message_id: message_id) if message_id
        # by id: the visibility scope is DISTINCT over joins
        notes, next_cursor = paginate(Note.where(id: visible.select(:id)), columns: %w[notes.created_at notes.id],
                                                                           direction: :asc) do |page|
          page.preload(NoteSerializer::PRELOAD)
        end
        render_page(NoteSerializer.brief_list(notes, context), next_cursor)
      end

      private

      def message_id_param
        value = string_param(:message_id)
        return if value.nil?
        raise Api::InvalidParameter, "message_id must be a number" unless value.match?(/\A\d+\z/)

        value
      end
    end
  end
end
