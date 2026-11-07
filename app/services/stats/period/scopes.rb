module Stats
  class Period
    # The relations every tab reads from. All of them are ActiveRecord
    # relations or plain ids, so a tab composes its own aggregates on top.
    class Scopes
      NOTICE_LIST = "pgsql-committers".freeze

      def initialize(period)
        @period = period
      end

      # one row per logical change, by the period's rule
      def commits
        Commit.from(Arel.sql("(#{@period.representatives_sql}) AS commits"))
      end

      def commit_ids
        commits.select(:id)
      end

      def representatives_sql = @period.representatives_sql

      def backported_keys = @period.backported_keys

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

      # the phase rule, per window: outside the middle phase only period
      # threads count, inside it every thread but the commit notices.
      # Callers pass a window inside one phase
      def in_phase(relation, time_column, thread_column, from, to)
        rel = relation.where(time_column => from...to)
        return rel.where.not(thread_column => notice_topics.select(:id)) if @period.phase_at(from) == :middle

        rel.where(thread_column => threads.select(:id))
      end

      def messages_between(from, to) = in_phase(Message.all, :created_at, :topic_id, from, to)

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

      # anyone who had committed by the end of the period
      def committer_ids
        @committer_ids ||= first_commit_at.select { |_, at| at <= @period.end_at }.keys
      end

      # person_id -> first commit, for those who got the bit inside the period
      def committer_since
        @committer_since ||= first_commit_at.select { |_, at| at >= @period.start && at <= @period.end_at }
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

      def llm? = llm_coverage >= Period::LLM_MIN_COVERAGE
    end
  end
end
