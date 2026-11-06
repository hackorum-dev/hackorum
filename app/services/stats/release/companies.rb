module Stats
  class Release
    # Credits rolled up by the person's affiliation when the commit landed.
    class Companies
      TOP = 5
      TOP_MONTHLY = 10
      OTHER = "other companies".freeze

      Credit = Struct.new(:commit_id, :person_id, :kind, :committed_at, :lines)

      def initialize(release)
        @release = release
        @scopes = release.scopes
        @phases = Phases.new(release, gran: "month")
      end

      def to_h
        rows = company_rows
        { rows: rows, tiles: tiles(rows), monthly: monthly }
      end

      private

      # one Credit per (commit, person, kind): kind is :authored (credited
      # author, else the committer when the commit has no parsed author row
      # and no llm author row naming someone else),
      # :reviewed (parsed reviewer), :committed (the committer of someone
      # else's patch, per CommitterReviewer#others_commit_ids); an unresolved author gets no credit, and the lines of
      # a commit are split between its resolved authors
      def person_credits
        @person_credits ||= begin
          commits = @scopes.commits.pluck(:id, :committed_at, Arel.sql("COALESCE(lines_added, 0) + COALESCE(lines_removed, 0)")).to_h { |id, at, l| [ id, [ at, l ] ] }
          people = CommitPerson.where(commit_id: commits.keys, source: %w[parsed llm])
                               .pluck(:commit_id, :person_id, :role, :source)
          by_commit = people.group_by(&:first)
          others = CommitterReviewer.new(commits.keys).others_commit_ids.to_set
          list = []
          commits.each do |id, (at, lines)|
            rows = by_commit[id] || []
            committer = rows.find { |_, pid, role, src| pid && src == "parsed" && role == CommitPerson::COMMITTER }&.then { |r| r[1] }
            author_rows = rows.select do |_, pid, role, src|
              %w[author co_author].include?(role) && (src == "parsed" || (src == "llm" && (committer.nil? || pid != committer)))
            end
            authors = author_rows.empty? ? [ committer ].compact : author_rows.filter_map { |_, pid, _, src| pid if src == "parsed" }.uniq
            authors.each { |pid| list << Credit.new(id, pid, :authored, at, lines.to_f / authors.size) }
            rows.select { |_, pid, role, src| pid && src == "parsed" && role == "reviewer" }.map { |r| r[1] }.uniq.each { |pid| list << Credit.new(id, pid, :reviewed, at, lines) }
            list << Credit.new(id, committer, :committed, at, lines) if committer && others.include?(id)
          end
          list
        end
      end

      # an authored or reviewed credit counts once per (commit, company)
      def credits
        @credits ||= person_credits.uniq { |c| c.kind == :committed ? c.object_id : [ c.commit_id, company_of(c), c.kind ] }
      end

      def affiliations
        @affiliations ||= Affiliations.new(person_credits.map(&:person_id))
      end

      def company_of(credit)
        Affiliations.label(affiliations.company_for(credit.person_id, credit.committed_at))
      end

      def company_rows
        committers = @scopes.committer_ids.to_set
        people = ::Person.includes(:default_alias).where(id: person_credits.map(&:person_id).uniq).index_by(&:id)
        members = person_credits.group_by { |c| company_of(c) }.transform_values { |list| list.map(&:person_id).uniq }
        groups = credits.group_by { |c| company_of(c) }
        # lines stay per author: every author's share, summed per company
        lines = person_credits.select { |c| c.kind == :authored }.group_by { |c| company_of(c) }.transform_values { |l| l.sum(&:lines).round }
        rows = groups.map do |company, list|
          ids = members[company]
          { company: company,
            people: ids.filter_map { |id| people[id] && { id: id, name: people[id].display_name, email: people[id].default_alias&.email, committer: committers.include?(id) } }
                       .sort_by { |p| p[:name] },
            authored: list.count { |c| c.kind == :authored },
            reviewed: list.count { |c| c.kind == :reviewed },
            committed: list.count { |c| c.kind == :committed },
            lines: lines.fetch(company, 0) }
        end
        known, unknown = rows.partition { |r| r[:company] != Affiliations::UNKNOWN }
        known.sort_by { |r| [ -(r[:authored] + r[:reviewed]), r[:company] ] } + unknown
      end

      def tiles(rows)
        known = rows.reject { |r| r[:company] == Affiliations::UNKNOWN }
        counted = credits.select { |c| c.kind != :committed }
        {
          companies: known.size,
          known_credits: counted.count { |c| company_of(c) != Affiliations::UNKNOWN },
          credits: counted.size,
          top5_authored: known.map { |r| r[:authored] }.max(TOP).sum,
          authored_total: credits.count { |c| c.kind == :authored },
          with_committer: known.count { |r| r[:people].any? { |p| p[:committer] } }
        }
      end

      # each series ranks and picks its own top companies, the rest folded,
      # the unknown bucket last
      def monthly
        labels = @phases.buckets.map { |b| b[:label] }
        index = @phases.buckets.each_with_index.to_h { |b, i| [ b[:start], i ] }
        series = lambda do |kind|
          mine = credits.select { |c| c.kind == kind }
          top = mine.map { |c| company_of(c) }.reject { |c| c == Affiliations::UNKNOWN }.tally
                    .sort_by { |c, n| [ -n, c ] }.first(TOP_MONTHLY).map(&:first)
          groups = top + [ OTHER, Affiliations::UNKNOWN ]
          values = groups.to_h { |g| [ g, Array.new(labels.size, 0) ] }
          mine.each do |c|
            company = company_of(c)
            key = top.include?(company) ? company : (company == Affiliations::UNKNOWN ? company : OTHER)
            i = index[@phases.truncate(c.committed_at.in_time_zone)]
            values[key][i] += 1 if i
          end
          groups.map { |g| { label: g, values: values[g], fold: !top.include?(g) } }
        end
        { buckets: labels,
          windows: @phases.windows.map { |from, to, phase| { from: from.utc.iso8601, to: to.utc.iso8601, phase: phase.to_s } },
          authored: series.call(:authored), reviewed: series.call(:reviewed) }
      end
    end
  end
end
