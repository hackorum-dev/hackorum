module Stats
  class Period
    # One committed verdict per scope commit, taken from each thread's current
    # run. Verdicts match by backport group: a post-branch fix is in scope as
    # its branch cherry-pick, while the LLM judged the master commit.
    class Verdicts
      Row = Struct.new(:id, :scope_commit_id, :verdict, :change_level, :source_message_id, :reviews)
      CURRENT_RUNS_SQL = "SELECT DISTINCT ON (topic_id) id FROM patchset_runs WHERE status = 'done' ORDER BY topic_id, created_at DESC, id DESC".freeze
      CHAIN_SQL = <<~SQL.squish.freeze
        WITH RECURSIVE chain AS (
          SELECT v.id AS verdict_id, l.patchset_run_id, l.parent_message_id, 1 AS depth
          FROM commit_verdicts v
          JOIN patchset_lineages l ON l.patchset_run_id = v.patchset_run_id AND l.message_id = v.source_message_id
          WHERE v.id IN (:verdict_ids)
          UNION ALL
          SELECT chain.verdict_id, l.patchset_run_id, l.parent_message_id, chain.depth + 1
          FROM chain
          JOIN patchset_lineages l ON l.patchset_run_id = chain.patchset_run_id AND l.message_id = chain.parent_message_id
          WHERE chain.depth < 200
        )
        SELECT verdict_id, MAX(depth) FROM chain GROUP BY verdict_id
      SQL

      def initialize(scopes)
        @scopes = scopes
      end

      # scope_commit_id is the scope row the verdict stands for; the most
      # confident verdict wins when a commit sits in several threads
      def relation
        @relation ||= begin
          sub = CommitVerdict.joins("JOIN commits c ON c.id = commit_verdicts.commit_id")
                             .joins("JOIN (#{@scopes.representatives_sql}) r ON COALESCE(r.cherry_picked_from_sha, r.sha) = COALESCE(c.cherry_picked_from_sha, c.sha)")
                             .where("commit_verdicts.patchset_run_id IN (#{CURRENT_RUNS_SQL})")
                             .where(verdict: CommitVerdict::COMMITTED)
                             .select("DISTINCT ON (r.id) commit_verdicts.*, r.id AS scope_commit_id")
                             .order("r.id, commit_verdicts.confidence DESC, commit_verdicts.id")
          # OFFSET 0 fences the subquery: a scope_commit_id filter otherwise gets
          # pushed inside the DISTINCT ON and the planner misestimates it
          CommitVerdict.from(Arel.sql("(#{sub.to_sql} OFFSET 0) AS commit_verdicts"))
        end
      end

      # loaded once; the bands count in Ruby instead of re-running the subquery
      def rows
        @rows ||= relation.pluck(:id, :scope_commit_id, :verdict, :change_level, :source_message_id, :reviews)
                          .map { |values| Row.new(*values).tap { |r| r.reviews = Array(r.reviews) } }
      end

      # versions posted before the committed one, following parent links of
      # the run that produced the verdict
      def chain_lengths_for(verdict_ids)
        return [] if verdict_ids.empty?

        sql = ActiveRecord::Base.sanitize_sql_array([ CHAIN_SQL, { verdict_ids: verdict_ids } ])
        CommitVerdict.connection.select_rows(sql).map { |_, depth| depth.to_i }
      end
    end
  end
end
