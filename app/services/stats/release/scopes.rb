module Stats
  class Release
    # The relations every tab reads from. All of them are ActiveRecord
    # relations or plain ids, so a tab composes its own aggregates on top.
    class Scopes
      NOTICE_LIST = "pgsql-committers".freeze

      def initialize(release)
        @release = release
      end

      # one row per logical change: the canonical member when it is in the
      # branch, else the backport that is (a post-branch fix lands on master
      # as something the branch never sees, and reaches it as a cherry-pick).
      # A group with a member on the previous branch before that release's
      # GA shipped there first and is not counted again here
      def commits
        Commit.from(Arel.sql("(#{representatives_sql}) AS commits"))
      end

      def commit_ids
        commits.select(:id)
      end

      # groups with a member in an earlier stable branch, matched by group key:
      # a post-branch fix is represented by its branch cherry-pick, while the
      # older backports point at the master commit
      def backported_keys
        @backported_keys ||= Commit.where("COALESCE(cherry_picked_from_sha, sha) IN (SELECT COALESCE(cherry_picked_from_sha, sha) FROM (#{representatives_sql}) AS scope)")
                                   .where.not("? = ANY(branches)", @release.branch)
                                   .where("branches && ARRAY[?]::varchar[]", earlier_branches)
                                   .distinct.pluck(Arel.sql("COALESCE(cherry_picked_from_sha, sha)"))
      end

      def backported = backported_keys.size

      def threads
        Topic.where(id: CommitTopic.where(commit_id: commit_ids).select(:topic_id))
      end

      # commit notifications are not discussion
      def notice_topics
        Topic.where(id: TopicMailingList.where(mailing_list_id: MailingList.where(identifier: NOTICE_LIST).select(:id)).select(:topic_id))
      end

      def thread_messages
        Message.where(topic_id: threads.select(:id))
      end

      # the phase rule: outside the middle phase only release threads count
      # callers pass a window inside one phase
      def messages_between(from, to)
        rel = Message.where(created_at: from...to)
        return rel.where.not(topic_id: notice_topics.select(:id)) if middle_phase?(from, to)

        rel.where(topic_id: threads.select(:id))
      end

      # person_id -> time of their first commit as committer, all history:
      # a commit bit is dated, so whether someone counts as a committer
      # depends on when the credit happened
      def first_commit_at
        @first_commit_at ||= CommitPerson.where(role: CommitPerson::COMMITTER).where.not(person_id: nil)
                                         .joins(:commit).group(:person_id).minimum("commits.committed_at")
      end

      def committer_at?(person_id, time)
        first = person_id && first_commit_at[person_id]
        first.present? && first <= time
      end

      # anyone who had committed by the end of the cycle
      def committer_ids
        @committer_ids ||= first_commit_at.select { |_, at| at <= @release.end_at }.keys
      end

      # person_id -> first commit, for those who got the bit inside the cycle
      def committer_since
        @committer_since ||= first_commit_at.select { |_, at| at >= @release.start && at <= @release.end_at }
      end

      def representatives_sql
        conn = Commit.connection
        branch = conn.quote(@release.branch)
        previous = conn.quote(@release.previous_branch)
        ga = @release.ga_at && conn.quote(@release.ga_at.utc.iso8601)
        previous_ga = @release.previous_ga && conn.quote(@release.previous_ga.utc.iso8601)
        <<~SQL.squish
          SELECT DISTINCT ON (COALESCE(cherry_picked_from_sha, sha)) *
          FROM commits
          WHERE #{branch} = ANY(branches)
            AND NOT (#{previous} = ANY(branches))
            AND COALESCE(cherry_picked_from_sha, sha) NOT IN (
              SELECT COALESCE(cherry_picked_from_sha, sha) FROM commits
              WHERE #{previous} = ANY(branches) #{previous_ga ? "AND committed_at <= #{previous_ga}" : ''})
            #{ga ? "AND committed_at <= #{ga}" : ''}
          ORDER BY COALESCE(cherry_picked_from_sha, sha), (cherry_picked_from_sha IS NULL) DESC, committed_at, sha
        SQL
      end

      def verdicts
        @verdicts ||= Verdicts.new(self)
      end

      # share of the commits with a thread that have a verdict; a commit
      # without a thread can never get one
      def llm_coverage
        with_thread = Commit.where(id: CommitTopic.where(commit_id: commit_ids).select(:commit_id)).count
        with_thread.zero? ? 0.0 : verdicts.rows.size.to_f / with_thread
      end

      def llm? = llm_coverage >= Release::LLM_MIN_COVERAGE

      private

      def middle_phase?(from, to)
        ga = @release.previous_ga
        bp = @release.branch_point
        ga.present? && from >= ga && (bp.nil? || to <= bp)
      end

      def earlier_branches
        (Release::FIRST_MAJOR...@release.major).map { |m| "REL_#{m}_STABLE" }
      end
    end
  end
end
