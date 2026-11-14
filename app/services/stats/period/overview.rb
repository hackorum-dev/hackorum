module Stats
  class Period
    # The Overview tab as one hash. Each band is a private method; every
    # number is a query over the period scopes, nothing is read from params.
    class Overview
      include Stats::Numbers

      AGE_BUCKETS = [ [ "under 1 week", 7 ], [ "1 to 4 weeks", 28 ], [ "1 to 3 months", 91 ], [ "3 to 6 months", 182 ],
                      [ "6 to 12 months", 365 ], [ "1 to 2 years", 730 ], [ "over 2 years", nil ] ].freeze
      STEP_THRESHOLDS = [ 1, 10, 50, 100 ].freeze
      PODIUM_SIZE = 6
      VERSION_BUCKETS = [ [ "1", 1 ], [ "2", 2 ], [ "3", 3 ], [ "4", 4 ], [ "5", 5 ], [ "6 to 9", 9 ], [ "10 or more", nil ] ].freeze
      SIZE_BUCKETS = [ [ "under 10 lines", 9 ], [ "10 to 50", 50 ], [ "50 to 200", 200 ], [ "200 to 1,000", 1000 ], [ "over 1,000", nil ] ].freeze

      def initialize(period)
        @period = period
        @scopes = period.scopes
      end

      def to_h
        { llm: scopes.llm?, code: code, discussion: discussion, lineage: lineage, reviews: reviews, podiums: podiums }
      end

      private

      attr_reader :period, :scopes

      def commits = scopes.commits

      def commit_ids = scopes.commit_ids

      def metrics = @metrics ||= Metrics.new(scopes, scopes.commit_ids.pluck(:id))

      # --- code -----------------------------------------------------------

      def code
        strip = committer_strip
        total = commits.count
        top5 = strip.first(5).sum(&:last)
        {
          commits: total,
          backported: scopes.backported,
          reverts: commits.where("subject ILIKE 'Revert%'").count,
          authors: distinct_credits(%w[author co_author]),
          reviewers: distinct_credits(%w[reviewer]),
          files: CommitFile.where(commit_id: commit_ids).distinct.count(:path),
          lines_added: commits.sum(:lines_added),
          lines_removed: commits.sum(:lines_removed),
          committers: { count: strip.size, strip: strip, top5_share: total.zero? ? 0 : (top5 * 100.0 / total).round },
          committer_steps: STEP_THRESHOLDS.to_h { |n| [ "#{n}+", strip.count { |_, c| c >= n } ] },
          commits_by_month: commits_by_month,
          peak: total.zero? ? nil : commits_by_month.max_by(&:last),
          lines_by_month: lines_by_month
        }
      end

      def distinct_credits(roles)
        CommitPerson.parsed.where(commit_id: commit_ids, role: roles)
                    .distinct.count(Arel.sql("COALESCE(person_id::text, lower(raw_email), raw_name)"))
      end

      # [[name, commits]] sorted by commits, name from the committer credit row
      def committer_strip
        @committer_strip ||= begin
          rows = CommitPerson.parsed.where(commit_id: commit_ids, role: CommitPerson::COMMITTER)
                             .group(:person_id, :raw_name).count
          people = ::Person.includes(:default_alias).where(id: rows.keys.map(&:first).compact).index_by(&:id)
          by_person = Hash.new(0)
          names = {}
          rows.each do |(person_id, raw_name), n|
            key = person_id || raw_name
            by_person[key] += n
            names[key] ||= person_id ? people[person_id]&.display_name : raw_name
          end
          by_person.map { |key, n| [ names[key], n ] }.sort_by { |name, n| [ -n, name.to_s ] }
        end
      end

      # first-of-month Dates from the cycle start to its end; date_trunc keys
      # come back as Times, so both sides go through to_date before lookup
      def months
        @months ||= begin
          cursor = period.start.to_date.beginning_of_month
          last = (period.end_at - 1.second).to_date
          list = []
          while cursor <= last
            list << cursor
            cursor = cursor.next_month
          end
          list
        end
      end

      def month_label(date) = date.strftime("%b %Y")

      def commits_by_month
        @commits_by_month ||= begin
          counts = commits.group(Arel.sql("date_trunc('month', committed_at)")).count
                          .transform_keys { |t| t.to_date }
          months.map { |m| [ month_label(m), counts.fetch(m, 0) ] }
        end
      end

      def lines_by_month
        rows = commits.group(Arel.sql("date_trunc('month', committed_at)"))
                      .pluck(Arel.sql("date_trunc('month', committed_at), COALESCE(SUM(lines_added), 0), COALESCE(SUM(lines_removed), 0)"))
                      .to_h { |m, a, r| [ m.to_date, [ a.to_i, r.to_i ] ] }
        months.map { |m| [ month_label(m), rows.fetch(m, [ 0, 0 ]) ] }
      end

      # --- discussion -----------------------------------------------------

      def discussion
        messages = scopes.thread_messages
        threads = scopes.threads.count
        patch_mails = messages.where(is_patch_submission: true).count
        ages = metrics.thread_ages_days
        {
          threads: threads,
          messages: messages.count,
          people: messages.distinct.count(:sender_person_id),
          patch_mails: patch_mails,
          patch_mails_per_thread: threads.zero? ? 0 : (patch_mails.to_f / threads).round(1),
          with_thread: metrics.with_thread,
          age_median_days: median(ages)&.round,
          age_buckets: bucketize(ages, AGE_BUCKETS),
          within_2w: ages.count { |d| d <= 14 },
          over_year: ages.count { |d| d > 365 }
        }
      end

      # --- lineage --------------------------------------------------------

      def lineage
        chain = metrics.chain_lengths
        cf = commitfest_numbers
        {
          covered: metrics.verdict_rows.size,
          verdicts: metrics.verdict_counts,
          change_levels: metrics.change_levels,
          versions: { mean: mean(chain), median: median(chain)&.round, max: chain.max, buckets: bucketize(chain, VERSION_BUCKETS) }
        }.merge(cf)
      end

      # a batch is the commits of one entry pushed within the same clock hour
      def commitfest_numbers
        rows = Commit.where(id: commit_ids)
                     .joins(:commit_topics)
                     .joins("JOIN commitfest_patch_topics cpt ON cpt.topic_id = commit_topics.topic_id")
                     .group("cpt.commitfest_patch_id")
                     .pluck(Arel.sql("cpt.commitfest_patch_id, COUNT(DISTINCT commits.id), COUNT(DISTINCT date_trunc('hour', commits.committed_at))"))
        per_entry = rows.map { |_, n, _| n.to_i }
        batches = rows.map { |_, _, b| b.to_i }
        {
          cf_commits: metrics.cf_commits,
          cf_entries: rows.size,
          commits_per_entry: { mean: mean(per_entry), median: median(per_entry)&.round },
          batches_per_entry: mean(batches),
          one_batch_entries: batches.count(1)
        }
      end

      # --- reviews --------------------------------------------------------

      def reviews
        credited = metrics.credited_counts
        {
          crediting: credited.size,
          per_commit: { mean: mean(credited.values), median: median(credited.values)&.round },
          coverage: metrics.trailer_coverage
        }.merge(by_others_numbers)
      end

      # someone else's patch by the authorship rule
      # (CommitterReviewer#others_commit_ids); its authors split by whether
      # they ever committed
      def by_others_numbers
        ids = metrics.by_others_ids
        alone = metrics.alone_ids
        judged = metrics.judged_ids
        sizes = metrics.sizes
        committer_authored = metrics.committer_authored_ids.size
        {
          by_others: { count: ids.size, committers: committer_authored, non_committers: ids.size - committer_authored },
          alone: { count: alone.size, of: judged.size },
          size: { categories: SIZE_BUCKETS.map(&:first),
                  alone: bucketize(alone.map { |id| sizes[id] }, SIZE_BUCKETS).map(&:last),
                  with_other: bucketize((judged - alone).map { |id| sizes[id] }, SIZE_BUCKETS).map(&:last) }
        }
      end

      # --- podiums --------------------------------------------------------

      def podiums
        { committers: committer_podium, contributors: contributor_podium }
      end

      def committer_podium
        rows = CommitPerson.parsed.where(commit_id: commit_ids, role: CommitPerson::COMMITTER)
                           .where.not(person_id: nil).group(:person_id).count
                           .sort_by { |_, n| -n }.first(PODIUM_SIZE)
        people = ::Person.includes(:default_alias).where(id: rows.map(&:first)).index_by(&:id)
        rows.map { |id, n| person_entry(people[id]).merge(commits: n) }
      end

      # credits earned before the person had the commit bit, if ever
      def contributor_podium
        rows = CommitPerson.parsed.where(commit_id: commit_ids, role: %w[author co_author reviewer]).where.not(person_id: nil)
                           .joins(:commit).distinct
                           .pluck(:person_id, Arel.sql("CASE role WHEN 'reviewer' THEN 'reviewed' ELSE 'authored' END"), :commit_id, Arel.sql("commits.committed_at"))
        scores = Hash.new { |h, k| h[k] = { authored: 0, reviewed: 0 } }
        rows.each { |person_id, kind, _, at| scores[person_id][kind.to_sym] += 1 unless scopes.committer_at?(person_id, at) }
        top = scores.sort_by { |id, s| [ -(s[:authored] + s[:reviewed]), id ] }.first(PODIUM_SIZE)
        people = ::Person.includes(:default_alias).where(id: top.map(&:first)).index_by(&:id)
        top.map { |id, s| person_entry(people[id]).merge(s) }
      end

      def person_entry(person)
        { id: person.id, name: person.display_name, email: person.default_alias&.email }
      end
    end
  end
end
