module Topics
  class RelatedThreads
    INLINE = 5

    def initialize(topic)
      @topic = topic
    end

    def any? = entries.any?

    def entries
      @entries ||= begin
        links = TopicLink.where(topic_id: @topic.id).joins(:other_topic).merge(Topic.active).to_a
        by_topic = links.group_by(&:other_topic_id)
        @topic_ids = by_topic.keys
        topics = Topic.where(id: by_topic.keys).index_by(&:id)
        load_change_keys(links.select { |l| l.kind == "commit" }.map(&:ref_id).uniq)
        Lineage::ThreadRank.order(by_topic.keys).map do |tid|
          rows = by_topic[tid]
          commit_ids = rows.select { |r| r.kind == "commit" }.map(&:ref_id).uniq
          keys = commit_ids.filter_map { |c| @key_of[c] }.uniq
          { topic: topics[tid], label: label(rows, keys), role: role(tid, keys), commit_ids: commit_ids, keys: keys }
        end
      end
    end

    # { sha => [{ topic:, verdict: }] } for commit groups shared with other threads
    def also_in(groups)
      entries
      groups.each_with_object({}) do |group, out|
        key = group[:commit_ids].filter_map { |c| @key_of[c] }.first
        next unless key

        others = entries.select { |e| e[:keys].include?(key) }
        next if others.empty?

        out[group[:sha]] = others.map { |e| { topic: e[:topic], verdict: verdicts.dig(e[:topic].id, key) } }
      end
    end

    private

    def label(rows, keys)
      parts = []
      parts << (keys.size == 1 ? "same commit" : "#{keys.size} shared commits") if keys.any?
      mentions = rows.select { |r| r.kind == "mention" }.map(&:direction).uniq
      parts << "mentions" if mentions.include?("out")
      parts << "mentioned in" if mentions.include?("in")
      parts << "same CF entry" if rows.any? { |r| r.kind == "commitfest" }
      parts.join(", ")
    end

    def role(other_id, keys)
      return nil if keys.empty?

      mine = keys.filter_map { |k| verdicts.dig(@topic.id, k) }
      theirs = keys.filter_map { |k| verdicts.dig(other_id, k) }
      committed = ->(vs) { vs.any? { |v| CommitVerdict::COMMITTED.include?(v) } }
      if committed.(mine) && committed.(theirs) then "shared source"
      elsif mine.any? && mine.all?("other_thread") && committed.(theirs) then "patch thread"
      elsif theirs.any? && theirs.all?("other_thread") && committed.(mine) then "report / discussion"
      end
    end

    # one query: linked commits plus their canonical commits
    def load_change_keys(commit_ids)
      @key_of = {}
      return if commit_ids.empty?

      linked = Commit.where(id: commit_ids).pluck(:id, :sha, :cherry_picked_from_sha)
      keys = linked.map { |_, sha, from| from.presence || sha }.uniq
      linked.each { |id, sha, from| @key_of[id] = from.presence || sha }
      Commit.where(sha: keys).where.not(id: commit_ids).pluck(:id, :sha).each { |id, sha| @key_of[id] = sha }
    end

    # { topic_id => { change_key => verdict } } from current runs
    def verdicts
      @verdicts ||= begin
        ids = [ @topic.id, *@topic_ids ].uniq
        runs = PatchsetRun.done.where(topic_id: ids).select("DISTINCT ON (topic_id) id").order(:topic_id, created_at: :desc, id: :desc)
        CommitVerdict.where(patchset_run_id: runs, commit_id: @key_of.keys).pluck(:topic_id, :commit_id, :verdict)
                     .each_with_object(Hash.new { |h, k| h[k] = {} }) { |(t, c, v), h| h[t][@key_of[c]] = v }
      end
    end
  end
end
