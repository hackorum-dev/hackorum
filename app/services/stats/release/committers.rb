module Stats
  class Release
    # The committers of one cycle side by side. Everything is per committer
    # over the scope commits they committed; "for others" is someone else's
    # patch by the authorship rule (CommitterReviewer#others_commit_ids).
    class Committers
      TOP_CHART = 12
      OTHER = "other committers".freeze

      def initialize(release)
        @release = release
        @scopes = release.scopes
        @phases = Phases.new(release, gran: "month")
      end

      def to_h
        rows = build_rows
        { llm: @scopes.llm?, rows: rows, change: change_chart(rows), lines_chart: lines_chart(rows), reviews_chart: reviews_chart(rows),
          monthly: monthly(rows) }
      end

      private

      # commit_id -> committer person_id over the scope
      def committer_of
        @committer_of ||= CommitPerson.parsed.where(commit_id: @scopes.commit_ids, role: CommitPerson::COMMITTER).where.not(person_id: nil)
                                      .pluck(:commit_id, :person_id).to_h
      end

      def commits_of
        @commits_of ||= committer_of.group_by(&:last).transform_values { |pairs| pairs.map(&:first) }
      end

      # commit_id -> [resolved parsed author person ids]
      def authors_of
        @authors_of ||= CommitPerson.parsed.where(commit_id: committer_of.keys, role: %w[author co_author]).where.not(person_id: nil)
                                    .order(:id).pluck(:commit_id, :person_id).group_by(&:first).transform_values { |p| p.map(&:last).uniq }
      end

      # commit_id -> first parsed-or-llm author row by id, parsed preferred;
      # an llm row naming the committer is ignored. Value: resolved parsed
      # person id, or nil (unresolved or llm-only)
      def author_row_of
        @author_row_of ||= CommitPerson.where(source: %w[parsed llm], commit_id: committer_of.keys, role: %w[author co_author])
                                       .order(:id).pluck(:commit_id, :person_id, :source)
                                       .reject { |cid, pid, source| source == "llm" && pid == committer_of[cid] }
                                       .group_by(&:first)
                                       .transform_values { |rows| (rows.find { |r| r[2] == "parsed" } || rows.first).then { |_, pid, src| pid if src == "parsed" } }
      end

      # same rule as Pulse#commits: the first author row, the committer when
      # there is none; nil (nobody) when that row is unresolved or llm-only
      def author_of(cid)
        author_row_of.key?(cid) ? author_row_of[cid] : committer_of[cid]
      end

      def metrics_for(ids)
        @metrics ||= {}
        @metrics[ids] ||= Metrics.new(@scopes, ids)
      end

      def window = @release.start...@release.end_at

      def thread_ids
        @thread_ids ||= @scopes.threads.pluck(:id)
      end

      # [[sender_person_id, topic_id, created_at]] of committers in release threads, in cycle
      def thread_messages
        @thread_messages ||= Message.where(topic_id: thread_ids, sender_person_id: commits_of.keys, created_at: window)
                                    .pluck(:sender_person_id, :topic_id, :created_at)
      end

      def build_rows
        people = ::Person.includes(:default_alias).where(id: commits_of.keys).index_by(&:id)
        by_sender = thread_messages.group_by(&:first)
        msg_counts = by_sender.transform_values(&:size)
        thread_counts = by_sender.transform_values { |rows| rows.map { |r| r[1] }.uniq.size }
        partners = reply_partners(commits_of.keys)
        backported = @scopes.backported_keys.to_set
        keys = Commit.where(id: committer_of.keys).pluck(:id, Arel.sql("COALESCE(cherry_picked_from_sha, sha)")).to_h
        reviewed = reviewed_for_others
        since = @scopes.committer_since
        commits_of.map do |pid, ids|
          m = metrics_for(ids)
          by_others = m.by_others_ids
          added, removed = m.lines
          judged = m.judged_ids.to_set
          { id: pid, name: people[pid].display_name, email: people[pid].default_alias&.email, since: since[pid],
            commits: ids.size, own: ids.size - by_others.size, for_others: by_others.size,
            authors: by_others.flat_map { |id| authors_of.fetch(id, []) }.uniq.size,
            reverts: m.reverts, lines: added + removed, reviewed_for_others: reviewed.fetch(pid, 0),
            judged: judged.size, as_posted: m.verdict_rows.count { |r| judged.include?(r.scope_commit_id) && r.verdict == "as_is" },
            alone: m.alone_ids.size, messages: msg_counts.fetch(pid, 0), threads: thread_counts.fetch(pid, 0),
            people: partners.fetch(pid, []).size, backported: ids.count { |id| backported.include?(keys[id]) } }
        end.sort_by { |r| [ -r[:commits], r[:name] ] }
      end

      # parsed reviewer credits on scope commits the person did not commit
      def reviewed_for_others
        CommitPerson.parsed.where(commit_id: committer_of.keys, role: "reviewer").where.not(person_id: nil)
                    .pluck(:commit_id, :person_id)
                    .reject { |cid, pid| committer_of[cid] == pid }
                    .group_by(&:last).transform_values { |p| p.map(&:first).uniq.size }
      end

      # person_id -> distinct people they replied to or who replied to them
      def reply_partners(person_ids)
        edges = Message.joins("JOIN messages parent ON parent.id = messages.reply_to_id")
                       .where(topic_id: thread_ids, created_at: window)
                       .where("messages.sender_person_id IN (:ids) OR parent.sender_person_id IN (:ids)", ids: person_ids)
                       .pluck(Arel.sql("messages.sender_person_id"), Arel.sql("parent.sender_person_id"))
        partners = Hash.new { |h, k| h[k] = Set.new }
        edges.each do |a, b|
          next if a == b
          partners[a] << b if person_ids.include?(a)
          partners[b] << a if person_ids.include?(b)
        end
        partners.transform_values(&:to_a)
      end

      def pct(part, whole) = whole.zero? ? 0 : (part * 100.0 / whole).round

      # every committer with an assessed commit: the table has no column for
      # the split, so nobody is folded away
      def change_chart(rows)
        top = rows.select { |r| r[:judged].positive? }
        levels = top.map do |r|
          m = metrics_for(commits_of[r[:id]])
          judged = m.judged_ids.to_set
          mine = m.verdict_rows.select { |v| judged.include?(v.scope_commit_id) }
          lv = mine.select { |v| v.verdict == "modified" }.map(&:change_level).tally
          parts = [ r[:as_posted], mine.count { |v| v.verdict == "partial" }, lv.fetch("light", 0), lv.fetch("moderate", 0), lv.fetch("significant", 0) ]
          [ r[:judged], *parts ]
        end
        labels = [ "as posted", "split from a series", "light", "moderate", "significant", "from discussion" ]
        { categories: top.map { |r| r[:name] },
          series: labels.each_with_index.map do |label, i|
            values = levels.map do |j, *parts|
              shown = parts.map { |n| pct(n, j) }
              i < parts.size ? shown[i] : (j.zero? ? 0 : [ 100 - shown.sum, 0 ].max)
            end
            { label: label, values: values, gray: label == "from discussion" }
          end }
      end

      def lines_chart(rows)
        top = rows.first(TOP_CHART)
        own, others = top.map do |r|
          ids = commits_of[r[:id]]
          m = metrics_for(ids)
          by_others = m.by_others_ids
          a, b = Metrics.new(@scopes, ids - by_others).lines
          c, d = Metrics.new(@scopes, by_others).lines
          [ a + b, c + d ]
        end.transpose.presence || [ [], [] ]
        { categories: top.map { |r| r[:name] }, series: [ { label: "own commits", values: own }, { label: "commits for others", values: others } ] }
      end

      def reviews_chart(rows)
        top = rows.sort_by { |r| [ -r[:reviewed_for_others], r[:name] ] }.first(TOP_CHART)
        { categories: top.map { |r| r[:name] }, series: [ { label: "reviews credited on other committers' commits", values: top.map { |r| r[:reviewed_for_others] } } ] }
      end

      # each series ranks and picks its own top committers
      def monthly(rows)
        labels = @phases.buckets.map { |b| b[:label] }
        index = @phases.buckets.each_with_index.to_h { |b, i| [ b[:start], i ] }
        names = rows.to_h { |r| [ r[:id], r[:name] ] }
        build = lambda do |pairs|
          top_ids = pairs.map(&:last).tally.sort_by { |pid, n| [ -n, names[pid].to_s ] }.first(TOP_CHART).map(&:first)
          values = (top_ids + [ :other ]).to_h { |k| [ k, Array.new(labels.size, 0) ] }
          pairs.each do |time, pid|
            i = index[@phases.truncate(time.in_time_zone)] or next
            values[top_ids.include?(pid) ? pid : :other][i] += 1
          end
          top_ids.map { |id| { label: names[id], values: values[id], fold: false } } + [ { label: OTHER, values: values[:other], fold: true } ]
        end
        times = Commit.where(id: committer_of.keys).pluck(:id, :committed_at).to_h
        committed = committer_of.map { |cid, pid| [ times[cid], pid ] }
        authored = committer_of.map { |cid, _| [ times[cid], author_of(cid) ] }.select { |_, pid| commits_of.key?(pid) }
        reviewed = CommitPerson.parsed.where(commit_id: committer_of.keys, role: "reviewer", person_id: commits_of.keys)
                               .pluck(:commit_id, :person_id).reject { |cid, pid| committer_of[cid] == pid }.map { |cid, pid| [ times[cid], pid ] }
        # release-thread messages only, no Pulse phase rule
        messages = thread_messages.map { |pid, _, at| [ at, pid ] }
        { buckets: labels,
          windows: @phases.windows.map { |from, to, phase| { from: from.utc.iso8601, to: to.utc.iso8601, phase: phase.to_s } },
          commits: build.call(committed), authored: build.call(authored), reviewed: build.call(reviewed), messages: build.call(messages) }
      end
    end
  end
end
