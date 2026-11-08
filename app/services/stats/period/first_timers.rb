module Stats
  class Period
    # People whose first author, co-author or reviewer credit in all history
    # is a change of this period. Matched by backport group, so a person has
    # one home even where release windows overlap
    class FirstTimers
      ROLES = %w[author co_author reviewer].freeze

      def initialize(period)
        @period = period
      end

      def count
        keys = @period.scopes.commits.select(Arel.sql("COALESCE(cherry_picked_from_sha, sha)"))
        firsts = CommitPerson.parsed.where(role: ROLES).where.not(person_id: nil).joins(:commit)
                             .select(Arel.sql("DISTINCT ON (commit_people.person_id) commit_people.person_id, " \
                                              "COALESCE(commits.cherry_picked_from_sha, commits.sha) AS group_key"))
                             .order(Arel.sql("commit_people.person_id, commits.committed_at, commits.id"))
        CommitPerson.from(firsts, :firsts).where("firsts.group_key IN (#{keys.to_sql})").count
      end
    end
  end
end
