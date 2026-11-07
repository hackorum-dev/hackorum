module Stats
  class Period
    # One row per person credited on a scope commit. Authorship follows the
    # commit rule: a credited author, else the committer.
    class People
      def initialize(period)
        @period = period
        @scopes = period.scopes
      end

      def to_h
        rows = build_rows
        { rows: rows,
          totals: { authors: rows.count { |r| r[:authored].positive? }, reviewers: rows.count { |r| r[:reviewed].positive? }, people: rows.size } }
      end

      private

      def commit_ids = @scopes.commit_ids

      # [[commit_id, author_person_id]]; the committer only when the commit
      # has no parsed author row and no llm author other than the committer.
      # Only parsed resolved authors get a credit, anything else gives nil
      def authored_pairs
        @authored_pairs ||= @scopes.commits
          .joins("LEFT JOIN LATERAL (SELECT person_id FROM commit_people cp WHERE cp.commit_id = commits.id AND cp.source = 'parsed' AND cp.role = 'committer' ORDER BY cp.id LIMIT 1) committer ON true")
          .joins("LEFT JOIN LATERAL (SELECT EXISTS (SELECT 1 FROM commit_people cp WHERE cp.commit_id = commits.id AND cp.role IN ('author', 'co_author') AND (cp.source = 'parsed' OR (cp.source = 'llm' AND cp.person_id IS DISTINCT FROM committer.person_id))) AS v) has_author ON true")
          .joins("LEFT JOIN commit_people author ON author.commit_id = commits.id AND author.source = 'parsed' AND author.role IN ('author', 'co_author')")
          .pluck(Arel.sql("commits.id"), Arel.sql("CASE WHEN has_author.v THEN author.person_id ELSE committer.person_id END"))
          .uniq
      end

      def build_rows
        authored = authored_pairs.group_by(&:last).transform_values { |pairs| pairs.map(&:first).uniq.size }
        reviewed = CommitPerson.parsed.where(commit_id: commit_ids, role: "reviewer").where.not(person_id: nil)
                               .group(:person_id).distinct.count(:commit_id)
        committed = CommitPerson.parsed.where(commit_id: commit_ids, role: CommitPerson::COMMITTER).where.not(person_id: nil)
                                .group(:person_id).distinct.count(:commit_id)
        ids = (authored.keys + reviewed.keys + committed.keys).compact.uniq
        mail = Message.where(topic_id: @scopes.threads.select(:id), sender_person_id: ids).group(:sender_person_id)
                      .pluck(:sender_person_id, Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT topic_id)"))
                      .to_h { |id, n, t| [ id, [ n, t ] ] }
        affiliations = Affiliations.new(@period.companies? ? ids : [])
        committers = @scopes.committer_ids.to_set
        since = @scopes.committer_since
        people = ::Person.includes(:default_alias).where(id: ids).index_by(&:id)
        ids.filter_map do |id|
          person = people[id] or next
          { id: id, name: person.display_name, email: person.default_alias&.email,
            company: affiliations.company_for(id, @period.end_at), committer: committers.include?(id), committer_since: since[id],
            authored: authored.fetch(id, 0), reviewed: reviewed.fetch(id, 0), committed: committed.fetch(id, 0),
            messages: mail.dig(id, 0) || 0, threads: mail.dig(id, 1) || 0 }
        end
      end
    end
  end
end
