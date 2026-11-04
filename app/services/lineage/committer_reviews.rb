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
  end
end
