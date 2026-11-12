module Api
  module V1
    class PeopleController < BaseController
      query_params paged: true, on: %i[topics patchsets]

      def show
        person = Person.preload(PersonSerializer::PRELOAD).find(find_person!.id)
        render json: PersonSerializer.new(person, context).full
      end

      def topics
        relation = TopicParticipant.where(person_id: find_person!.id).joins(:topic).merge(listed_topics)
        rows, next_cursor = paginate(relation,
                                     columns: %w[topic_participants.last_message_at topic_participants.id]) do |page|
          page.preload(topic: TopicSerializer::PRELOAD)
        end
        render_page(TopicSerializer.participation_list(rows, context), next_cursor)
      end

      def patchsets
        relation = Message.where(sender_person_id: find_person!.id, is_patch_submission: true)
                          .joins(:topic).merge(listed_topics)
        messages, next_cursor = paginate(relation, columns: %w[messages.created_at messages.id]) do |page|
          PatchsetSerializer.load(page)
        end
        render_page(PatchsetSerializer.brief_list(messages, context), next_cursor)
      end

      private

      def find_person!
        Person.find_by_email(path_param(:email)) || raise(ActiveRecord::RecordNotFound)
      end

      def listed_topics
        Topic.active.shown_by_default
      end
    end
  end
end
