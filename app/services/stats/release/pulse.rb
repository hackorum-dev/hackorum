module Stats
  class Release
    # The Pulse tab: one grouped query per series and phase window, summed into
    # the Phases buckets. "Committer" is decided per bucket: a person who had
    # committed anything by the end of it.
    class Pulse
      STRIPS = [
        { key: "commits", label: "Commits authored", unit: "commits", split: true },
        { key: "messages", label: "Messages", unit: "mails", split: true },
        { key: "new_threads", label: "New threads", unit: "threads", split: true },
        { key: "patch_submissions", label: "Patch submissions", unit: "mails with a patch", split: true },
        { key: "active_people", label: "Active people", unit: "people", split: true },
        { key: "first_time_posters", label: "First-time posters", unit: "people", split: false },
        { key: "threads_landing", label: "Threads landing their first commit", unit: "threads", split: false }
      ].freeze

      def initialize(release, gran:)
        @release = release
        @scopes = release.scopes
        @phases = Phases.new(release, gran: gran)
      end

      def to_h
        {
          gran: @phases.gran,
          buckets: @phases.buckets,
          windows: @phases.windows.map { |from, to, phase| { from: iso(from), to: iso(to), phase: phase.to_s } },
          bands: @phases.bands.map { |b| { from: b[:from].iso8601, to: b[:to].iso8601, label: b[:label] } },
          events: @phases.events.map { |e| { at: iso(e[:at]), label: e[:label] } },
          strips: STRIPS.map { |strip| strip.merge(send(strip[:key])) }
        }
      end

      private

      def iso(time) = time.utc.iso8601

      def buckets = @phases.buckets

      def bucket_index
        @bucket_index ||= buckets.each_with_index.to_h { |b, i| [ b[:start], i ] }
      end

      def bucket_end(index)
        index + 1 < buckets.size ? buckets[index + 1][:start] : @release.end_at
      end

      def trunc_sql(column)
        Arel.sql("date_trunc('#{@phases.gran}', #{column})")
      end

      def committer_at?(person_id, index)
        first = person_id && @scopes.first_commit_at[person_id]
        return false if first.blank?

        index + 1 < buckets.size ? first < bucket_end(index) : first <= bucket_end(index)
      end

      # rows: [[bucket_time, person_id, count]] -> { committers: [], others: [] }
      def split_rows(rows)
        committers = Array.new(buckets.size, 0)
        others = Array.new(buckets.size, 0)
        rows.each do |time, person_id, count|
          index = bucket_index[time.in_time_zone]
          next unless index

          (committer_at?(person_id, index) ? committers : others)[index] += count.to_i
        end
        { committers: committers, others: others }
      end

      def fill(counts)
        values = Array.new(buckets.size, 0)
        counts.each do |time, count|
          index = bucket_index[time.in_time_zone]
          values[index] += count.to_i if index
        end
        { values: values }
      end

      # the phase rule, applied per window: a relation of messages or topics
      # restricted to release threads outside the middle phase, and without
      # commit notification threads inside it
      def windowed(relation, time_column, thread_column)
        @phases.windows.map do |from, to, phase|
          rel = relation.where(time_column => from...to)
          if phase == :middle
            rel.where.not(thread_column => @scopes.notice_topics.select(:id))
          else
            rel.where(thread_column => @scopes.threads.select(:id))
          end
        end
      end

      def messages_windows
        windowed(Message.all, :created_at, :topic_id)
      end

      # --- series ---------------------------------------------------------

      # a commit with an Author credit is authored by that person, otherwise
      # by the committer; an llm author naming the committer is no credit.
      # One author per commit (parsed first, then lowest id) so the strip adds
      # up to the commit count; People credits every author.
      # An llm or unresolved author gives a nil person, which counts as others.
      def commits
        author_sql = Arel.sql("CASE WHEN author.id IS NULL THEN committer.person_id ELSE author.person_id END")
        rows = @scopes.commits
                      .joins("LEFT JOIN LATERAL (SELECT person_id FROM commit_people cp WHERE cp.commit_id = commits.id AND cp.source = 'parsed' AND cp.role = 'committer' ORDER BY cp.id LIMIT 1) committer ON true")
                      .joins("LEFT JOIN LATERAL (SELECT id, CASE WHEN cp.source = 'parsed' THEN cp.person_id END AS person_id FROM commit_people cp WHERE cp.commit_id = commits.id AND cp.role IN ('author', 'co_author') AND (cp.source = 'parsed' OR (cp.source = 'llm' AND cp.person_id IS DISTINCT FROM committer.person_id)) ORDER BY (cp.source = 'parsed') DESC, cp.id LIMIT 1) author ON true")
                      .group(trunc_sql("commits.committed_at"), author_sql)
                      .pluck(trunc_sql("commits.committed_at"), author_sql, Arel.sql("COUNT(*)"))
        split_rows(rows)
      end

      def messages
        rows = messages_windows.flat_map do |rel|
          rel.group(trunc_sql("messages.created_at"), :sender_person_id)
             .pluck(trunc_sql("messages.created_at"), :sender_person_id, Arel.sql("COUNT(*)"))
        end
        split_rows(rows)
      end

      def new_threads
        rows = windowed(Topic.all, :created_at, :id).flat_map do |rel|
          rel.group(trunc_sql("topics.created_at"), :creator_person_id)
             .pluck(trunc_sql("topics.created_at"), :creator_person_id, Arel.sql("COUNT(*)"))
        end
        split_rows(rows)
      end

      def patch_submissions
        rows = messages_windows.flat_map do |rel|
          rel.where(is_patch_submission: true)
             .group(trunc_sql("messages.created_at"), :sender_person_id)
             .pluck(trunc_sql("messages.created_at"), :sender_person_id, Arel.sql("COUNT(*)"))
        end
        split_rows(rows)
      end

      # [[bucket_time, person_id]] of everyone who wrote in the bucket
      def active_rows
        @active_rows ||= messages_windows.flat_map do |rel|
          rel.distinct.pluck(trunc_sql("messages.created_at"), :sender_person_id)
        end.uniq
      end

      def active_people
        split_rows(active_rows.map { |time, person_id| [ time, person_id, 1 ] })
      end

      # among the bucket's active people, those whose first message ever is
      # in that bucket
      def first_time_posters
        ids = active_rows.map(&:last).uniq
        firsts = Message.where(sender_person_id: ids).group(:sender_person_id).minimum(:created_at)
        counts = active_rows.filter_map do |time, person_id|
          first = firsts[person_id]
          time if first && @phases.truncate(first.in_time_zone) == time.in_time_zone
        end.tally
        fill(counts.to_a)
      end

      # first commit within this release's scope, not the thread's first ever
      def threads_landing
        rows = CommitTopic.where(commit_id: @scopes.commit_ids)
                          .joins(:commit).group(:topic_id).minimum("commits.committed_at")
        fill(rows.values.map { |t| @phases.truncate(t.in_time_zone) }.tally.to_a)
      end
    end
  end
end
