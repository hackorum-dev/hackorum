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

  def resolve_commits(tokens)
    tokens = Array(tokens).uniq
    return {} if tokens.empty?

    candidates = Commit.where("left(sha, 8) IN (?)", tokens.map { _1[0, 8] }).pluck(:id, :sha)
    tokens.each_with_object({}) do |token, out|
      hits = candidates.select { |_, sha| sha.start_with?(token) }
      out[token] = hits.first.first if hits.size == 1
    end
  end

  # { commit_id => [change_key, [topic_ids]] } for the whole change of each commit
  def change_topics(commit_ids)
    return {} if commit_ids.empty?

    keys = Commit.where(id: commit_ids).pluck(:id, :sha, :cherry_picked_from_sha)
                 .to_h { |id, sha, from| [ id, from.presence || sha ] }
    members = Commit.where(sha: keys.values.uniq).or(Commit.where(cherry_picked_from_sha: keys.values.uniq))
                    .pluck(:id, :sha, :cherry_picked_from_sha).map { |id, sha, from| [ id, from.presence || sha ] }
    topics = CommitTopic.joins(:topic).merge(Topic.active).where(commit_id: members.map(&:first))
                        .pluck(:commit_id, :topic_id).group_by(&:first)
    by_key = members.group_by(&:last).transform_values { |ms| ms.flat_map { |id, _| (topics[id] || []).map(&:last) }.uniq }
    keys.transform_values { |k| [ k, by_key[k] || [] ] }
  end

  def sync_fixes!(commit_ids)
    ids = Array(commit_ids).uniq
    return if ids.empty?

    TopicLink.transaction do
      TopicLink.where(kind: "fixes", ref_type: "Commit", ref_id: ids).delete_all
      sources = Commit.where(id: ids).where("body ~ '[0-9a-f]{8}'").pluck(:id, :body)
      tokens = sources.to_h { |id, body| [ id, MessageLinks.commit_tokens(body) ] }
      resolved = resolve_commits(tokens.values.flatten)
      next if resolved.empty?

      info = change_topics((ids | resolved.values).uniq)
      own_topics = CommitTopic.joins(:topic).merge(Topic.active).where(commit_id: ids)
                              .pluck(:commit_id, :topic_id).group_by(&:first).transform_values { |v| v.map(&:last) }
      sources.each do |id, _|
        own_key = info.dig(id, 0)
        targets = tokens[id].filter_map { |t| resolved[t] }.flat_map do |cid|
          key, topics = info[cid]
          key == own_key ? [] : topics
        end.uniq
        (own_topics[id] || []).each do |t|
          (targets - [ t ]).each { |o| link!(Topic.new(id: t), Topic.new(id: o), kind: "fixes", ref: Commit.new(id: id), direction: "out") }
        end
      end
    end
  end

  def sync_commitfest!(patch_ids)
    ids = Array(patch_ids).uniq
    return if ids.empty?

    TopicLink.transaction do
      TopicLink.where(kind: "commitfest", ref_type: "CommitfestPatch", ref_id: ids).delete_all
      now = Time.current
      rows = CommitfestPatchTopic.joins(:topic).merge(Topic.active).where(commitfest_patch_id: ids)
                                 .pluck(:commitfest_patch_id, :topic_id).group_by(&:first)
                                 .flat_map do |patch_id, pairs|
        topics = pairs.map(&:last).uniq
        topics.permutation(2).map do |t, o|
          { topic_id: t, other_topic_id: o, kind: "commitfest", direction: "both", ref_type: "CommitfestPatch", ref_id: patch_id, created_at: now }
        end
      end
      TopicLink.insert_all(rows) if rows.any?
    end
  end

  def sync_mentions!(message_ids)
    ids = Array(message_ids).uniq
    return if ids.empty?

    TopicLink.transaction do
      TopicLink.where(kind: "mention", ref_type: "Message", ref_id: ids).delete_all
      sources = Message.joins(:topic).merge(Topic.active).where(id: ids).select(:id, :topic_id, :body).to_a
      wanted = sources.to_h { |m| [ m.id, MessageLinks.message_ids(m.body) ] }
      tokens = sources.to_h { |m| [ m.id, MessageLinks.commit_tokens(m.body) ] }
      all_ids = wanted.values.flatten.uniq
      resolved = resolve_commits(tokens.values.flatten)
      next if all_ids.empty? && resolved.empty?

      owners = all_ids.empty? ? {} : Message.joins(:topic).merge(Topic.active).where(message_id: all_ids)
                      .pluck(:message_id, :topic_id).group_by(&:first).transform_values { |v| v.map(&:last).uniq }
      info = change_topics(resolved.values.uniq)
      sources.each do |m|
        by_hash = tokens[m.id].filter_map { |t| resolved[t] }.flat_map { |cid| info.dig(cid, 1) || [] }
        targets = (wanted[m.id].flat_map { |mid| owners[mid] || [] } + by_hash).uniq - [ m.topic_id ]
        next if targets.empty?

        ref = Message.new(id: m.id)
        targets.each { |t| link!(Topic.new(id: m.topic_id), Topic.new(id: t), kind: "mention", ref: ref, direction: "out") }
      end
    end
  end

  def repoint!(from:, to:)
    from_id = from.respond_to?(:id) ? from.id : from
    to_id = to.respond_to?(:id) ? to.id : to
    scope = TopicLink.where(kind: %w[mention commitfest])
                     .where("topic_id = :t OR other_topic_id = :t", t: from_id)
    rows = scope.map do |l|
      { topic_id: l.topic_id == from_id ? to_id : l.topic_id,
        other_topic_id: l.other_topic_id == from_id ? to_id : l.other_topic_id,
        kind: l.kind, direction: l.direction, ref_type: l.ref_type, ref_id: l.ref_id, created_at: l.created_at }
    end.reject { |r| r[:topic_id] == r[:other_topic_id] }
    TopicLink.transaction do
      scope.delete_all
      TopicLink.insert_all(rows, unique_by: :index_topic_links_unique) if rows.any?
    end
  end
end
