module Api
  module V1
    # What a model said about the commits of a thread: how each is linked, and the verdicts.
    class CommitLineageData
      VERDICT_KEYS = %i[verdict confidence change_level origin source_message_id evidence].freeze
      COUNT_KEYS = %i[reviewers_final reviewers_earlier reviewers_none].freeze
      VERDICT_COLUMNS = [ :id, :commit_id, :reviews, *VERDICT_KEYS, *COUNT_KEYS ].freeze
      REVIEW_KEYS = %w[reviewer coverage source note].freeze
      NO_COVERAGE = "none".freeze
      TRAILER = "trailer".freeze
      LLM = "llm".freeze

      # the verdicts a thread shows, as Lineage::ThreadPresenter#shown_on_thread? has it
      def self.shown?(verdict)
        verdict.committed? || (verdict.verdict == "undecided" && verdict.origin == "trailer")
      end

      def initialize(topic, commits)
        @topic = topic
        @commits = commits
      end

      def link_source(group)
        sources = group[:commit_ids].map { |id| commits_by_id.fetch(id).link_source }
        sources.include?(TRAILER) ? TRAILER : LLM
      end

      def verdict(group)
        # of the commit the group is shown as first, then of its backports
        shown, others = group[:commit_ids].partition { |id| commits_by_id.fetch(id).sha == group[:sha] }
        found = verdicts.values_at(*shown, *others).compact.first
        return unless found

        VERDICT_KEYS.index_with { |key| found[key] }
                    .merge(COUNT_KEYS.index_with { |key| found[key].to_i }, reviews: reviews(found))
      end

      private

      def commits_by_id
        @commits_by_id ||= @commits.index_by(&:id)
      end

      # rows as they are stored: one without a reviewer is left out, one without a coverage has none
      def reviews(verdict)
        Array(verdict.reviews).filter_map do |row|
          next unless row.is_a?(Hash) && row["reviewer"].is_a?(String)

          REVIEW_KEYS.index_with { |key| row[key] }.merge("coverage" => row["coverage"].presence || NO_COVERAGE)
        end
      end

      # by commit id: the verdicts of the current run on the commits of the thread
      def verdicts
        @verdicts ||= begin
          run = LineageSerializer.current_run(@topic.id, columns: :id) if @commits.any?
          rows = run ? CommitVerdict.where(patchset_run_id: run.id, commit_id: commits_by_id.keys).select(VERDICT_COLUMNS) : []
          rows.select { |row| self.class.shown?(row) }.index_by(&:commit_id)
        end
      end
    end
  end
end
