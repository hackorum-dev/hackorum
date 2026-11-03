module PatchBranches
  class CandidateSelector
    def initialize(from:, to:)
      @from = from
      @to = to
    end

    # range filter hits the latest patch, not any patch in the topic
    def candidates(limit: nil, sample: nil)
      raise ArgumentError, "limit and sample are exclusive" if limit && sample

      latest = Message
        .select("DISTINCT ON (topic_id) *")
        .where(is_patch_submission: true)
        .order(:topic_id, created_at: :desc, id: :desc)

      scope = Message
        .from(latest, "messages")
        .where(created_at: @from...@to)
        .where.not(topic_id: CommitTopic.trailer.select(:topic_id))
        .where(topic_id: Topic.active.select(:id))

      scope = sample ? scope.order(Arel.sql("RANDOM()")) : scope.order(created_at: :desc, id: :desc)
      scope = scope.limit(sample || limit) if sample || limit
      scope
    end

    def self.for_topic(topic_id)
      Message.where(topic_id: topic_id, is_patch_submission: true)
             .order(created_at: :desc, id: :desc)
             .limit(1)
    end
  end
end
