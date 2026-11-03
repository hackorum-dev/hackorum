module Lineage
  class Sampler
    OLD_UNTIL = Time.zone.parse("2014-01-01")
    OLD_FROM = Time.zone.parse("1998-01-01")

    # -> [[topic, [{ commit:, origin: "trailer", overlap: nil }]]]
    def self.recent(limit:, from:)
      rows = Topic.joins(:commit_topics).merge(CommitTopic.trailer)
                  .where(id: Message.where(is_patch_submission: true).where("created_at >= ?", from)
                                    .group(:topic_id).having("count(*) >= 2").select(:topic_id))
                  .group("topics.id")
                  .select("topics.id, count(distinct commit_topics.commit_id) AS n_commits, " \
                          "(SELECT count(*) FROM messages m WHERE m.topic_id = topics.id AND m.is_patch_submission) AS n_patchsets")
                  .to_a
      rich = rows.select { |r| r.n_commits.to_i >= 2 && r.n_patchsets.to_i >= 3 }.shuffle
      controls = rows.select { |r| r.n_commits.to_i == 1 }.shuffle
      want_rich = (limit * 2 / 3.0).ceil
      picked = rich.first(want_rich)
      picked += controls.first(limit - picked.size)
      picked += (rich - picked).first(limit - picked.size)
      ids = picked.first(limit).map(&:id)
      Topic.where(id: ids).map do |t|
        [ t, CandidateFinder.trailer_commits(t).map { |c| { commit: c, origin: "trailer", overlap: nil } } ]
      end
    end

    # -> [[topic, [{ commit:, origin: "overlap", overlap: {...} }]]]
    def self.old(limit:, from: OLD_FROM, to: OLD_UNTIL)
      finder = CandidateFinder.new
      by_topic = Hash.new { |h, k| h[k] = [] }
      years = (from.year...to.year).to_a
      attempts_per_year = [ (limit * 3.0 / years.size).ceil, 3 ].max

      pools = years.map do |year|
        Commit.where(committed_at: Time.zone.local(year)...Time.zone.local(year + 1))
              .where.not(id: CommitTopic.select(:commit_id))
              .order(Arel.sql("RANDOM()")).limit(attempts_per_year).to_a
      end

      attempts_per_year.times do |round|
        pools.each do |pool|
          commit = pool[round] or next
          finder.overlap_topics(commit).each do |overlap|
            by_topic[overlap[:topic_id]] << { commit: commit, origin: "overlap", overlap: overlap }
          end
          break if by_topic.size >= limit
        end
        break if by_topic.size >= limit
      end

      topics = Topic.where(id: by_topic.keys.first(limit)).index_by(&:id)
      by_topic.first(limit).map { |id, cands| [ topics[id], cands.uniq { |c| c[:commit].id } ] }
    end
  end
end
