module TopicLinks
  module_function

  def link!(a, b, kind:, ref:, direction:)
    now = Time.current
    rows = [ [ a.id, b.id, direction ], [ b.id, a.id, TopicLink::MIRROR.fetch(direction) ] ].map do |t, o, d|
      { topic_id: t, other_topic_id: o, kind: kind, direction: d, ref_type: ref.class.base_class.name, ref_id: ref.id, created_at: now }
    end
    TopicLink.insert_all(rows, unique_by: :index_topic_links_unique)
  end

  def sync_commits!(commit_ids)
    ids = Array(commit_ids).uniq
    return if ids.empty?

    TopicLink.transaction do
      TopicLink.where(kind: "commit", ref_type: "Commit", ref_id: ids).delete_all
      now = Time.current
      rows = CommitTopic.joins(:topic).merge(Topic.active).where(commit_id: ids)
                        .pluck(:commit_id, :topic_id).group_by(&:first)
                        .flat_map do |commit_id, pairs|
        topics = pairs.map(&:last).uniq
        topics.permutation(2).map do |t, o|
          { topic_id: t, other_topic_id: o, kind: "commit", direction: "both", ref_type: "Commit", ref_id: commit_id, created_at: now }
        end
      end
      TopicLink.insert_all(rows) if rows.any?
    end
  end
end
