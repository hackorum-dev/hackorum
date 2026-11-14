module Lineage
  class OtherThreads
    PATCHSET_LIMIT = 20

    def initialize(topic)
      @topic = topic
    end

    # backports: { canonical_id => [Commit] }
    def call(commits, backports: {})
      ids_for = commits.to_h { |c| [ c.id, [ c.id, *Array(backports[c.id]).map(&:id) ] ] }
      all_ids = ids_for.values.flatten
      links = CommitTopic.trailer.joins(:topic).merge(Topic.active)
                         .where(commit_id: all_ids).where.not(topic_id: @topic.id)
                         .pluck(:commit_id, :topic_id)
      topic_ids = links.map(&:last).uniq
      topics = Topic.where(id: topic_ids).index_by(&:id)
      tables = patchset_tables(topic_ids)
      verdicts = current_verdicts(topic_ids, all_ids)
      counts = Message.where(topic_id: topic_ids).group(:topic_id).count
      ids_for.to_h do |id, member_ids|
        others = links.select { |cid, _| member_ids.include?(cid) }.map(&:last).uniq
        entries = ThreadRank.order(others).map do |tid|
          verdict = verdicts[tid]&.values_at(*member_ids)&.compact&.first
          entry(topics[tid], counts.fetch(tid, 0), tables.fetch(tid, []), verdict)
        end
        [ id, entries ]
      end
    end

    private

    def entry(topic, message_count, patchsets, verdict)
      { "topic_id" => topic.id, "title" => topic.title, "message_count" => message_count,
        "patchset_count" => patchsets.size, "patchsets" => patchsets.last(PATCHSET_LIMIT),
        "verdict" => verdict && verdict_hash(verdict) }
    end

    def verdict_hash(v)
      { "verdict" => v.verdict, "source_message_id" => v.source_message_id,
        "source_date" => v.source_message&.created_at&.iso8601, "change_level" => v.change_level,
        "author_name" => v.author_name, "confidence" => v.confidence, "evidence" => v.evidence }
    end

    def patchset_tables(topic_ids)
      Message.where(topic_id: topic_ids, is_patch_submission: true)
             .includes(:sender, :patch_submission_files, sender_person: :default_alias)
             .order(:created_at, :id).group_by(&:topic_id)
             .transform_values { |ms| ms.map { |m| patchset_row(m) } }
    end

    def patchset_row(m)
      { "message_id" => m.id, "date" => m.created_at.iso8601, "sender" => m.sender_display_alias&.name,
        "subjects" => [ m.subject ], "changed_paths" => m.patch_submission_files.map(&:path).sort }
    end

    def current_verdicts(topic_ids, commit_ids)
      runs = PatchsetRun.done.where(topic_id: topic_ids)
                        .select("DISTINCT ON (topic_id) id").order(:topic_id, created_at: :desc, id: :desc)
      CommitVerdict.where(patchset_run_id: runs, commit_id: commit_ids).includes(:source_message)
                   .group_by(&:topic_id).transform_values { |vs| vs.index_by(&:commit_id) }
    end
  end
end
