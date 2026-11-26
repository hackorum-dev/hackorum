module Classify
  module SeedExport
    OPENING_CHARS = 500

    COMMIT_SUBJECTS = 5

    def self.rows(since: nil)
      scope = since ? Scope.topics.where("topics.last_message_at >= ?", since) : Scope.in_window
      Enumerator.new do |y|
        scope.order(:id).find_each do |topic|
          y << row(topic)
        end
      end
    end

    def self.row(topic)
      patches = topic.commitfest_patches.includes(:commitfest_tags).order(:id).to_a
      first = topic.messages.order(:created_at, :id).first
      message_count, first_at, last_at = topic.messages.pick(Arel.sql("count(*)"), Arel.sql("min(messages.created_at)"), Arel.sql("max(messages.created_at)"))
      group = FeatureGroupTopic.where(topic_id: topic.id).includes(:feature_group).first&.feature_group
      {
        topic_id: topic.id,
        title: topic.title,
        cf_name: patches.first&.title,
        cf_topic: patches.map(&:topic).compact.uniq.presence&.join(", "),
        cf_tags: patches.flat_map { |p| p.commitfest_tags.map(&:name) }.uniq.presence&.join(", "),
        opening: MessageBodyText.strip_quotes(first&.body).strip[0, OPENING_CHARS],
        patch_messages: topic.messages.where(is_patch_submission: true).count,
        linked_topic_ids: TopicLink.where(topic_id: topic.id).distinct.order(:other_topic_id).pluck(:other_topic_id),
        message_count: message_count,
        first_at: first_at&.strftime("%Y-%m"),
        last_at: last_at&.strftime("%Y-%m"),
        commit_subjects: commit_subjects(topic),
        current_group: group&.surviving&.name
      }
    end

    def self.commit_subjects(topic)
      Commit.joins(:commit_topics).where(commit_topics: { topic_id: topic.id })
            .order(:committed_at, :id)
            .pluck(Arel.sql("coalesce(commits.cherry_picked_from_sha, commits.sha)"), :subject)
            .uniq(&:first).first(COMMIT_SUBJECTS).map(&:last)
    end
  end
end
