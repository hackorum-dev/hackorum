module Api
  module V1
    class NoteSerializer < BaseSerializer
      PRELOAD = [
        :note_tags,
        { author: { person: :default_alias } },
        { last_editor: { person: :default_alias } },
        { note_mentions: :mentionable }
      ].freeze

      def self.brief_list(records, context, **extras)
        preload_unnamed_mentions(records)
        edited = records.empty? ? [] : NoteEdit.where(note_id: records.map(&:id)).distinct.pluck(:note_id)
        super(records, context, edited_ids: edited.to_set, **extras)
      end

      # their label is the display name, which reads the person
      def self.preload_unnamed_mentions(records)
        users = records.flat_map(&:note_mentions).map(&:mentionable)
                       .select { |target| target.is_a?(User) && target.username.blank? && !target.deleted_at }
        return if users.empty?

        ActiveRecord::Associations::Preloader.new(records: users.uniq, associations: { person: :default_alias }).call
      end

      def brief
        {
          id: record.id,
          topic_id: record.topic_id,
          message_id: record.message_id,
          author: user_ref(record.author),
          body: record.body,
          global: record.global,
          tags: record.note_tags.sort_by(&:id).map(&:tag),
          mentions: record.note_mentions.sort_by(&:id).map { |mention| mention_ref(mention) },
          created_at: record.created_at,
          updated_at: record.updated_at,
          edited: edited?,
          last_editor: other_editor && user_ref(other_editor)
        }
      end

      private

      def edited?
        ids = extras[:edited_ids]
        ids ? ids.include?(record.id) : record.note_edits.exists?
      end

      # as on the site: named only when it is not the author
      def other_editor
        record.last_editor if record.last_editor_id != record.author_id
      end

      def user_ref(user)
        { name: helpers.display_name_for_user(user) }
      end

      def mention_ref(mention)
        { type: mention.mentionable_type.downcase, name: helpers.note_mention_label(mention).delete_prefix("@") }
      end
    end
  end
end
