module Stats
  # Every period of one kind side by side, oldest first. Each point is a
  # number from that period's cached Overview, the same one the period page
  # shows (open periods may lag it by the cache TTL).
  class Trend
    SEGMENTS = { "releases" => "release", "years" => "year", "cycles" => "cycle" }.freeze
    TITLES = { "release" => "Release over release", "year" => "Year over year", "cycle" => "Cycle over cycle" }.freeze

    def self.kind_for(segment) = SEGMENTS[segment.to_s]

    attr_reader :kind

    def initialize(kind)
      @kind = kind.to_s
    end

    def periods = @periods ||= Period.kind_class(kind).available.reverse

    def to_h
      @rows = periods.map { |p| [ p, overview_for(p) ] }
      @first_timers = periods.map { |p| first_timers_for(p) }
      llm_first = @rows.find { |_, o| o[:llm] }
      { kind: kind,
        periods: periods.map { |p| { key: p.key, label: p.label, open: p.open? } },
        shifts: shifts, volume: volume, llm: llm,
        llm_from: llm_first&.first&.label }
    end

    def overview_for(period)
      Stats::Cache.fetch(period, :overview) { Period::Overview.new(period).to_h }
    end

    def first_timers_for(period)
      Stats::Cache.fetch(period, :first_timers) { Period::FirstTimers.new(period).count }
    end

    private

    def shifts
      [ share("non_committer_authored", "Written by non-committers",
              "changes by authors who were not committers by the end of the period") { |o| [ o.dig(:reviews, :by_others, :non_committers), o.dig(:code, :commits) ] },
        line("top5_share", "Top 5 committers", "%", "share of all commits made by the five busiest committers") { |o| o.dig(:code, :committers, :top5_share) },
        share("with_thread", "Commits with a thread", "linked to a mailing list discussion") { |o| [ o.dig(:discussion, :with_thread), o.dig(:code, :commits) ] },
        share("reviewer_credited", "Commits crediting a reviewer", "at least one Reviewed-by credit") { |o| [ o.dig(:reviews, :crediting), o.dig(:code, :commits) ] },
        share("commitfest", "Commits with a Commitfest entry", "the thread has a Commitfest entry") { |o| [ o.dig(:lineage, :cf_commits), o.dig(:code, :commits) ] },
        line("thread_age_median", "Thread to commit", "days", "median days from the first message of the thread to the commit") { |o| o.dig(:discussion, :age_median_days) },
        series("committing_core", "Committing core", "", "committers with 10 or more commits, and all who committed",
               [ [ "10+ commits", ->(o) { o.dig(:code, :committer_steps, "10+") } ], [ "all committers", ->(o) { o.dig(:code, :committers, :count) } ] ],
               partial: true),
        series("first_timers", "First-time contributors", "", "people whose first author or reviewer credit is in the period; credit trailers start in 2017, so the first points run high",
               [ [ "people", nil ] ], partial: true, values: @first_timers) ]
    end

    def volume
      [ [ "commits", "Commits", ->(o) { o.dig(:code, :commits) } ],
        [ "lines", "Lines changed", ->(o) { lines_changed(o) } ],
        [ "threads", "Threads", ->(o) { o.dig(:discussion, :threads) } ],
        [ "messages", "Messages", ->(o) { o.dig(:discussion, :messages) } ],
        [ "posters", "People on the lists", ->(o) { o.dig(:discussion, :people) } ],
        [ "patch_mails", "Patch mails", ->(o) { o.dig(:discussion, :patch_mails) } ],
        [ "authors", "Authors", ->(o) { o.dig(:code, :authors) } ],
        [ "reviewers", "Reviewers", ->(o) { o.dig(:code, :reviewers) } ],
        [ "committers", "Committers", ->(o) { o.dig(:code, :committers, :count) } ],
        [ "cf_entries", "Commitfest entries", ->(o) { o.dig(:lineage, :cf_entries) } ] ]
        .map { |key, label, read| series(key, label, "", nil, [ [ label, read ] ], partial: true) }
    end

    def llm
      [ share("as_posted", "Committed as posted", "of the changes the LLM matched to a thread", llm: true) { |o| [ o.dig(:lineage, :verdicts, :as_is), o.dig(:lineage, :covered) ] },
        share("from_discussion", "Written from the discussion", "no posted patch matches the commit", llm: true) { |o| [ o.dig(:lineage, :verdicts, :from_discussion), o.dig(:lineage, :covered) ] },
        line("versions_median", "Patch versions", "", "median versions posted before the commit", llm: true) { |o| o.dig(:lineage, :versions, :median) },
        share("committed_alone", "Committed with no other reviewer", "of others' patches the LLM judged", llm: true) { |o| [ o.dig(:reviews, :alone, :count), o.dig(:reviews, :alone, :of) ] } ]
    end

    # nil until the line counts are backfilled
    def lines_changed(overview)
      sum = overview.dig(:code, :lines_added).to_i + overview.dig(:code, :lines_removed).to_i
      sum.zero? ? nil : sum
    end

    def share(key, label, hint, llm: false, &read)
      line(key, label, "%", hint, llm: llm) do |o|
        part, whole = read.call(o)
        whole.to_i.zero? ? nil : (part.to_f * 100 / whole).round(1)
      end
    end

    def line(key, label, unit, hint, llm: false, &read)
      series(key, label, unit, hint, [ [ label, read ] ], llm: llm)
    end

    # lines: [[label, ->(overview) { value }]]; values: precomputed, one per period
    def series(key, label, unit, hint, lines, llm: false, partial: false, values: nil)
      built = lines.map do |line_label, read|
        vals = values || @rows.map { |_, o| llm && !o[:llm] ? nil : read.call(o) }
        { label: line_label, values: vals }
      end
      { key: key, label: label, unit: unit, hint: hint, partial: partial, lines: built, headline: headline(built.first[:values]) }
    end

    # first and last value of the closed periods, when there are two
    def headline(values)
      closed = periods.each_index.select { |i| !periods[i].open? && !values[i].nil? }
      return nil if closed.size < 2

      first, last = closed.first, closed.last
      { from: values[first], from_label: periods[first].label, to: values[last], to_label: periods[last].label }
    end
  end
end
