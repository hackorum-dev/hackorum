module Stats
  class Period
    # One person inside one period: the Overview numbers over their commits,
    # pills against the period-wide values, who they worked with, a pulse.
    class Person
      include Stats::Numbers

      PULSE_STRIPS = [
        { key: "commits", label: "Commits", unit: "commits", split: false },
        { key: "messages", label: "Messages", unit: "mails", split: false },
        { key: "patch_mails", label: "Patch mails", unit: "mails with a patch", split: false },
        { key: "threads_active", label: "Threads active in", unit: "threads", split: false }
      ].freeze
      TOP = 5

      def initialize(period, person, overview:)
        @period = period
        @person = person
        @overview = overview
        @scopes = period.scopes
        @phases = Phases.new(period, gran: "week")
      end

      def to_h
        { llm: @scopes.llm?, person: person_h, code: code, discussion: discussion, lineage: lineage, reviews: reviews, worked_with: worked_with, pulse: pulse }
      end

      private

      def pid = @person.id

      def committer? = @scopes.committer_ids.include?(pid)

      def scope_ids = @scope_ids ||= @scopes.commit_ids.pluck(:id)

      # scope commits they committed
      def committed_ids
        @committed_ids ||= CommitPerson.parsed.where(commit_id: scope_ids, role: CommitPerson::COMMITTER, person_id: pid).distinct.pluck(:commit_id)
      end

      # own: committed, not somebody else's patch (complement of by_others_ids)
      def own_ids = @own_ids ||= committed_ids - Metrics.new(@scopes, committed_ids).by_others_ids

      # authorship rule: parsed author credit, plus own commits
      def authored_ids
        @authored_ids ||= begin
          credited = CommitPerson.parsed.where(commit_id: scope_ids, role: %w[author co_author], person_id: pid).distinct.pluck(:commit_id)
          (credited + own_ids).uniq
        end
      end

      # the commits the lineage and review bands are about
      def subject_ids = committer? ? committed_ids : authored_ids

      def metrics = @metrics ||= Metrics.new(@scopes, subject_ids)

      def others_metrics = @others_metrics ||= Metrics.new(@scopes, metrics.by_others_ids)

      def pill(value, release, better) = { value: value, release: release, better: better }

      def pct(part, whole) = whole.zero? ? 0 : (part * 100.0 / whole).round

      def person_h
        { id: pid, name: @person.display_name, email: @person.default_alias&.email, committer: committer?, committer_since: @scopes.committer_since[pid],
          company: (Affiliations.new([ pid ]).company_for(pid, @period.end_at) if @period.companies?) }
      end

      def rank_of(counts, id)
        order = counts.sort_by { |k, v| [ -v, k ] }.map(&:first)
        i = order.index(id)
        { rank: i && i + 1, of: order.size }
      end

      def code
        total = @overview[:code][:commits]
        added, removed = metrics.lines
        if committer?
          committer_counts = CommitPerson.parsed.where(commit_id: scope_ids, role: CommitPerson::COMMITTER).where.not(person_id: nil).group(:person_id).distinct.count(:commit_id)
          lines_counts = CommitPerson.parsed.where(commit_id: scope_ids, role: CommitPerson::COMMITTER).where.not(person_id: nil).joins(:commit)
                                     .group(:person_id).sum(Arel.sql("COALESCE(commits.lines_added, 0) + COALESCE(commits.lines_removed, 0)"))
          by_others = metrics.by_others_ids
          own = own_ids.size
          release_own = total - @overview[:reviews][:by_others][:count]
          {
            reviewed_for_others: reviewed_for_others_count,
            commits: { value: committed_ids.size }.merge(rank_of(committer_counts, pid)),
            own: { value: own, share: pct(own, committed_ids.size), release: pct(release_own, total), better: nil },
            for_others: { value: by_others.size, authors: CommitPerson.parsed.where(commit_id: by_others, role: %w[author co_author]).where.not(person_id: [ nil, pid ]).distinct.count(:person_id) },
            reverts: { value: metrics.reverts, share: pct(metrics.reverts, committed_ids.size), release: pct(@overview[:code][:reverts], total), better: "down" },
            lines: { added: added, removed: removed }.merge(rank_of(lines_counts, pid))
          }
        else
          author_counts = author_pairs.reject { |_, id| id.nil? }.group_by(&:last).transform_values(&:size)
          { authored: { value: authored_ids.size }.merge(rank_of(author_counts, pid)),
            reviewed: { value: CommitPerson.parsed.where(commit_id: scope_ids, role: "reviewer", person_id: pid).distinct.count(:commit_id) } }
        end
      end

      # [[commit_id, author_person_id]], same rule as People#authored_pairs
      def author_pairs
        @scopes.commits
          .joins("LEFT JOIN LATERAL (SELECT person_id FROM commit_people cp WHERE cp.commit_id = commits.id AND cp.source = 'parsed' AND cp.role = 'committer' ORDER BY cp.id LIMIT 1) committer ON true")
          .joins("LEFT JOIN LATERAL (SELECT EXISTS (SELECT 1 FROM commit_people cp WHERE cp.commit_id = commits.id AND cp.role IN ('author', 'co_author') AND (cp.source = 'parsed' OR (cp.source = 'llm' AND cp.person_id IS DISTINCT FROM committer.person_id))) AS v) has_author ON true")
          .joins("LEFT JOIN commit_people author ON author.commit_id = commits.id AND author.source = 'parsed' AND author.role IN ('author', 'co_author')")
          .pluck(Arel.sql("commits.id"), Arel.sql("CASE WHEN has_author.v THEN author.person_id ELSE committer.person_id END"))
          .uniq
      end

      def reviewed_for_others_count
        CommitPerson.parsed.where(commit_id: scope_ids - committed_ids, role: "reviewer", person_id: pid).distinct.count(:commit_id)
      end

      def thread_ids = @scopes.threads.select(:id)

      def window = @period.start...@period.end_at

      # started in the period, not a commit notification, not landed in the
      # previous major before its GA (release only)
      def cycle_topics
        topics = Topic.where(created_at: window).where.not(id: @scopes.notice_topics.select(:id))
        previous = @period.previous_landed_topics
        previous ? topics.where.not(id: previous) : topics
      end

      def discussion
        messages = Message.where(topic_id: thread_ids, created_at: window)
        counts = messages.where.not(sender_person_id: nil).group(:sender_person_id).count
        own_messages = counts.fetch(pid, 0)
        started = cycle_topics.where(creator_person_id: pid).pluck(:id, :created_at)
        landed = CommitTopic.where(topic_id: started.map(&:first), commit_id: scope_ids).distinct.pluck(:topic_id).to_set
        after = @period.branch_point ? started.select { |_, at| at >= @period.branch_point } : []
        release_started = cycle_topics.count
        release_landed = cycle_topics.where(id: @scopes.threads.select(:id)).count
        ages = metrics.thread_ages_days
        chain = metrics.chain_lengths
        partners = reply_partners(messages)
        committers = @scopes.committer_ids.to_set
        {
          messages: { value: own_messages }.merge(rank_of(counts, pid)),
          threads_started: { value: started.size, landed: landed.size, landed_share: pct(landed.size, started.size),
                             release: pct(release_landed, release_started), better: nil },
          started_after_branch: { value: after.size, landed: after.count { |id, _| landed.include?(id) } },
          people_talked_to: { value: partners.size, committers: partners.count { |id| committers.include?(id) }, others: partners.count { |id| !committers.include?(id) } },
          thread_age: pill(median(ages)&.round, @overview[:discussion][:age_median_days], nil),
          versions: pill(chain.empty? ? nil : mean(chain), @overview[:lineage][:versions][:mean], nil),
          cf_share: { value: pct(metrics.cf_commits, subject_ids.size), count: metrics.cf_commits, of: subject_ids.size,
                      release: pct(@overview[:lineage][:cf_commits], @overview[:code][:commits]), better: nil }
        }
      end

      def reply_partners(messages)
        edges = messages.joins("JOIN messages parent ON parent.id = messages.reply_to_id")
                        .where("messages.sender_person_id = :id OR parent.sender_person_id = :id", id: pid)
                        .pluck(Arel.sql("messages.sender_person_id"), Arel.sql("parent.sender_person_id"))
        edges.flatten.uniq - [ pid ]
      end

      def lineage
        m = committer? ? others_metrics : metrics
        { verdicts: m.verdict_counts, change_levels: m.change_levels, of: m.verdict_rows.size }
      end

      def reviews
        credited = metrics.credited_counts
        rel = @overview[:reviews]
        out = {
          crediting: { value: pct(credited.size, subject_ids.size), count: credited.size, of: subject_ids.size,
                       release: pct(rel[:crediting], @overview[:code][:commits]), better: "up" },
          coverage: metrics.trailer_coverage,
          per_commit: pill(mean(credited.values), rel[:per_commit][:mean], "up")
        }
        if committer?
          out[:alone] = { value: pct(others_metrics.alone_ids.size, others_metrics.judged_ids.size), count: others_metrics.alone_ids.size,
                          of: others_metrics.judged_ids.size, release: pct(rel[:alone][:count], rel[:alone][:of]), better: "down" }
        end
        out
      end

      # [[person_id, count]] -> { top: [{id, name, email, count}], rest: { people, count, share } }
      def top_list(pairs)
        total = pairs.sum(&:last)
        sorted = pairs.sort_by { |id, n| [ -n, id ] }
        top = sorted.first(TOP)
        people = ::Person.includes(:default_alias).where(id: top.map(&:first)).index_by(&:id)
        rest = sorted.drop(TOP)
        { top: top.map { |id, n| { id: id, name: people[id]&.display_name, email: people[id]&.default_alias&.email, count: n } },
          rest: { people: rest.size, count: rest.sum(&:last), share: pct(rest.sum(&:last), total) } }
      end

      def worked_with
        reviewed_by = CommitPerson.parsed.where(commit_id: subject_ids, role: "reviewer").where.not(person_id: [ nil, pid ]).group(:person_id).distinct.count(:commit_id).to_a
        reviewed = CommitPerson.parsed.where(commit_id: scope_ids - committed_ids, role: "reviewer", person_id: pid).pluck(:commit_id)
        reviewed_committers = CommitPerson.parsed.where(commit_id: reviewed, role: CommitPerson::COMMITTER).where.not(person_id: nil).group(:person_id).distinct.count(:commit_id).to_a
        if committer?
          committed_for = CommitPerson.parsed.where(commit_id: metrics.by_others_ids, role: %w[author co_author]).where.not(person_id: [ nil, pid ]).group(:person_id).distinct.count(:commit_id).to_a
          { committed_for: top_list(committed_for), reviewed_by: top_list(reviewed_by), reviewed: top_list(reviewed_committers) }
        else
          committed_by = CommitPerson.parsed.where(commit_id: authored_ids, role: CommitPerson::COMMITTER).where.not(person_id: [ nil, pid ]).group(:person_id).distinct.count(:commit_id).to_a
          { committed_by: top_list(committed_by), reviewed_by: top_list(reviewed_by), reviewed: top_list(reviewed_committers) }
        end
      end

      def pulse
        buckets = @phases.buckets
        index = buckets.each_with_index.to_h { |b, i| [ b[:start], i ] }
        fill = lambda do |times|
          values = Array.new(buckets.size, 0)
          times.each { |t| i = index[@phases.truncate(t.in_time_zone)] and values[i] += 1 }
          values
        end
        # messages and patch mails: release-thread messages only, no Pulse
        # phase rule, like the Committers monthly chart
        own = Message.where(topic_id: thread_ids, sender_person_id: pid, created_at: window)
        strips = {
          "commits" => fill.call(Commit.where(id: subject_ids).pluck(:committed_at)),
          "messages" => fill.call(own.pluck(:created_at)),
          "patch_mails" => fill.call(own.where(is_patch_submission: true).pluck(:created_at)),
          "threads_active" => fill.call(own.group(:topic_id, Arel.sql("date_trunc('week', created_at)")).pluck(Arel.sql("MIN(created_at)")))
        }
        { gran: "week", buckets: buckets,
          windows: @phases.windows.map { |from, to, phase| { from: from.utc.iso8601, to: to.utc.iso8601, phase: phase.to_s } },
          bands: @phases.bands.map { |b| { from: b[:from].iso8601, to: b[:to].iso8601, label: b[:label] } },
          events: @phases.events.map { |e| { at: e[:at].utc.iso8601, label: e[:label] } },
          strips: PULSE_STRIPS.map { |s| s.merge(values: strips[s[:key]]) } }
      end
    end
  end
end
