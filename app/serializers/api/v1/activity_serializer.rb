module Api
  module V1
    class ActivitySerializer < BaseSerializer
      MESSAGE_COLUMNS = %i[id topic_id sender_id].freeze
      NOTE_COLUMNS = %i[id topic_id message_id deleted_at].freeze
      TOPIC_COLUMNS = %i[id slug title].freeze

      # Subjects are loaded here, by type and without their text: an entry
      # gets only the subject its user may see.
      def self.brief_list(records, context, **extras)
        ids = records.group_by(&:subject_type).transform_values { |rows| rows.map(&:subject_id).uniq }
        subjects = { "Message" => messages(ids["Message"]), "Note" => visible_notes(ids["Note"], context.user) }
        records.each do |record|
          record.association(:subject).target = subjects.dig(record.subject_type, record.subject_id)
        end
        super(records, context, topics: topics_for(records), **extras)
      end

      def self.messages(ids)
        return {} if ids.blank?

        messages = Message.where(id: ids).select(*MESSAGE_COLUMNS).to_a
        senders = Alias.where(id: messages.map(&:sender_id).uniq).select(:id, :name).index_by(&:id)
        messages.each { |message| message.association(:sender).target = senders[message.sender_id] }
        messages.index_by(&:id)
      end

      def self.visible_notes(ids, user)
        return {} if ids.blank?

        visible = Note.visible_to(user).where(id: ids)
        Note.where(id: visible.select(:id)).select(*NOTE_COLUMNS).index_by(&:id)
      end

      def self.topics_for(records)
        ids = records.filter_map { |record| topic_id(record) }.uniq
        ids.empty? ? {} : Topic.where(id: ids).select(*TOPIC_COLUMNS).index_by(&:id)
      end

      # the subject knows where it is now, the payload where it was
      def self.topic_id(record)
        return record.subject.topic_id if record.subject

        id = record.payload.is_a?(Hash) ? record.payload["topic_id"] : nil
        id if id.is_a?(Integer) && id.bit_length < 64
      end

      def brief
        subject = record.subject
        topic = extras[:topics][self.class.topic_id(record)]
        {
          id: record.id,
          type: record.activity_type,
          created_at: record.created_at,
          read_at: record.read_at,
          topic: topic && topic_ref(topic),
          message_id: subject.is_a?(Message) ? subject.id : subject&.message_id,
          note_id: subject.is_a?(Note) ? subject.id : nil,
          title: helpers.activity_type_label(record)
        }
      end
    end
  end
end
