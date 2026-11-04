module Lineage
  # a committer credited as reviewer reviewed the version they committed, no
  # matter what the thread shows
  module CommitterReviews
    NOTE = "committed the patch".freeze

    module_function

    def name(row) = row.raw_name.presence || row.person&.default_alias&.name

    # trailer reviewer names that belong to a committer of these commits, matched
    # by person when resolved and by name otherwise
    def names(commits, people)
      rows = people.select { |r| r.source == "parsed" }
      committers = rows.select { |r| r.role == CommitPerson::COMMITTER }
      persons = committers.filter_map(&:person_id).to_set
      keys = (commits.map(&:committer_name) + committers.map { |r| name(r) }).compact.map { |n| n.strip.downcase }.to_set
      rows.select { |r| r.role == "reviewer" }
          .select { |r| persons.include?(r.person_id) || keys.include?(name(r).to_s.strip.downcase) }
          .map { |r| name(r) }.compact.uniq
    end

    def apply(rows, names, source_message_id)
      keys = names.map { |n| n.strip.downcase }.to_set
      rows.map do |row|
        next row if row["coverage"] == "final" || !keys.include?(row["reviewer"].to_s.strip.downcase)

        row.merge("coverage" => "final",
                  "reviewed_message_ids" => (Array(row["reviewed_message_ids"]) + [ source_message_id ].compact).uniq,
                  "note" => [ NOTE, row["note"].presence ].compact.join("; "))
      end
    end

    def counts(rows)
      by = rows.group_by { |r| r["coverage"] }.transform_values(&:size)
      { reviewers_final: by.fetch("final", 0), reviewers_earlier: by.fetch("earlier", 0), reviewers_none: by.fetch("none", 0) }
    end

    # mirrors the committer reviewer row (commit_people source committer) into
    # committed verdicts; returns the verdicts that need it, writing when asked
    def mirror(verdicts, write: true)
      verdicts = verdicts.to_a
      implied = CommitPerson.committer_sourced.where(commit_id: verdicts.map(&:commit_id))
                            .includes(person: :default_alias).index_by(&:commit_id)
      verdicts.select do |verdict|
        row = implied[verdict.commit_id]
        next false unless row && CommitVerdict::COMMITTED.include?(verdict.verdict)

        reviewer = name(row)
        next false if reviewer.blank? || Array(verdict.reviews).any? { |r| r["reviewer"].to_s.casecmp?(reviewer) }

        if write
          rows = Array(verdict.reviews) + [ { "reviewer" => reviewer, "reviewed_message_ids" => [ verdict.source_message_id ].compact,
                                              "coverage" => "final", "note" => NOTE, "source" => CommitterReviewer::SOURCE } ]
          verdict.update!(reviews: rows, **counts(rows))
        end
        true
      end
    end
  end
end
