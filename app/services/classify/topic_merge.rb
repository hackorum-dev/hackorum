module Classify
  module TopicMerge
    def self.bot_note_ids(topic)
      bot = User.find_by(username: BOT_USERNAME)
      return [] unless bot

      Note.where(topic_id: topic.id, global: true, author_id: bot.id).pluck(:id)
    end

    def self.call(source:, target:, source_bot_note_ids: [])
      if source_bot_note_ids.any? && target_has_other_bot_note?(target, source_bot_note_ids)
        Note.where(id: source_bot_note_ids).destroy_all
      end

      theirs = FeatureGroupTopic.find_by(topic_id: source.id)
      return unless theirs

      ours = FeatureGroupTopic.find_by(topic_id: target.id)
      if ours
        theirs.destroy!
      else
        theirs.update!(topic_id: target.id)
      end
      # runs after the commit links moved
      FeatureGroups::Versions.refresh_isolated!([ theirs.feature_group_id, ours&.feature_group_id ].compact)
    end

    def self.target_has_other_bot_note?(target, moved_ids)
      Note.where(topic_id: target.id, global: true, author_id: Classify.bot_user.id)
          .where.not(id: moved_ids).exists?
    end
  end
end
