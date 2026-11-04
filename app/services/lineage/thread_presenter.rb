module Lineage
  class ThreadPresenter
    attr_reader :run, :ordinals

    def initialize(topic, ordinals:)
      @topic = topic
      @ordinals = ordinals
      @run = PatchsetRun.current_for(topic.id)
    end

    def self.llm_commit_shas(topic_id)
      Commit.where(id: CommitTopic.llm.where(topic_id: topic_id).select(:commit_id)).pluck(:sha).to_set
    end

    def story = @run&.story

    def lineage_by_message_id
      return {} unless @run

      @lineage_by_message_id ||= @run.lineages.to_h do |l|
        [ l.message_id, { parent_ordinal: l.parent_message_id && @ordinals[l.parent_message_id],
                          step_kind: l.step_kind, confidence: l.confidence, reason: l.reason } ]
      end
    end

    def verdicts
      return [] unless @run

      @verdicts ||= @run.verdicts.includes(:commit).select { |v| shown_on_thread?(v) }.map do |v|
        { sha: v.commit.sha, subject: v.commit.subject, verdict: v.verdict, confidence: v.confidence,
          extra: v.extra, source_message_id: v.source_message_id, source_ordinal: v.source_message_id && @ordinals[v.source_message_id],
          evidence: v.evidence, origin: v.origin, change_level: v.change_level, reviews: v.reviews || [],
          reviewers_final: v.reviewers_final.to_i, reviewers_earlier: v.reviewers_earlier.to_i,
          reviewers_none: v.reviewers_none.to_i,
          reviewers_total: v.reviewers_final.to_i + v.reviewers_earlier.to_i + v.reviewers_none.to_i }
      end
    end

    def verdicts_for_groups(summary)
      by_sha = verdicts.index_by { |v| v[:sha] }
      summary.groups.each_with_object({}) do |group, out|
        shas = [ group[:sha], *summary.member_shas(group) ]
        verdict = by_sha.values_at(*shas).compact.first
        out[group[:sha]] = verdict if verdict
      end
    end

    def shown_on_thread?(verdict)
      verdict.committed? || (verdict.verdict == "undecided" && verdict.origin == "trailer")
    end

    def llm_commit_shas
      @llm_commit_shas ||= self.class.llm_commit_shas(@topic.id)
    end
  end
end
