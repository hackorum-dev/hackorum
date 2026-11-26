module Classify
  class CandidateGroups
    CANDIDATE_CAP = 50
    MIN_SIMILARITY = 0.3
    ACTIVE_WINDOW = 365.days

    def initialize(topic)
      @topic = topic
    end

    def call
      ids = (linked_ids + own_ids).uniq
      by_id = FeatureGroup.where(id: ids).index_by(&:id)
      groups = ids.filter_map { |id| by_id[id]&.surviving } + similar + active
      groups.select { |g| g.merged_into_id.nil? }.uniq.first(CANDIDATE_CAP)
    end

    private

    def linked_ids
      FeatureGroupTopic.where(topic_id: TopicLink.where(topic_id: @topic.id).select(:other_topic_id))
                       .where.not(feature_group_id: nil)
                       .group(:feature_group_id)
                       .order(Arel.sql("count(*) DESC"), :feature_group_id)
                       .pluck(:feature_group_id)
    end

    def own_ids
      FeatureGroupTopic.where(topic_id: @topic.id).where.not(feature_group_id: nil)
                       .pluck(:feature_group_id)
    end

    def similar
      FeatureGroup.live
                  .where("similarity(feature_groups.name, ?) >= ?", @topic.title, MIN_SIMILARITY)
                  .order(Arel.sql(FeatureGroup.sanitize_sql_array([ "similarity(feature_groups.name, ?) DESC", @topic.title ])),
                         :id)
                  .limit(CANDIDATE_CAP).to_a
    end

    def active
      FeatureGroup.live.joins(feature_group_topics: :topic)
                  .where(topics: { last_message_at: ACTIVE_WINDOW.ago.. })
                  .group("feature_groups.id")
                  .order(Arel.sql("max(topics.last_message_at) DESC"), "feature_groups.id")
                  .limit(CANDIDATE_CAP).to_a
    end
  end
end
