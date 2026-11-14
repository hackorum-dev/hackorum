module Stats
  module Lists
    # one selection over a range, read from the precomputed tables
    class Volume
      TILE_SUMS = %i[messages threads_new newcomers_community newcomers_selection].freeze

      def initialize(params, today: Date.current)
        @params = params
        @today = today
      end

      def to_h
        starts = Periods.starts(gran, @params.from, @params.to)
        rows = StatsListVolume.where(gran: gran, list_mask: @params.mask, period_start: starts.first..starts.last).index_by(&:period_start)
        col = ->(name) { starts.map { |s| rows[s]&.public_send(name) || 0 } }
        { categories: starts.map { |s| Periods.label(gran, s) },
          open: starts.map { |s| Periods.open?(gran, s, @today) },
          tiles: tiles,
          messages: split(col, :messages, :messages_committer, :messages_contributor),
          people: split(col, :people, :people_committer, :people_contributor),
          threads: [ { label: "new", values: col.(:threads_new) }, { label: "active", values: col.(:threads_active) } ],
          newcomers: [ { label: "new to the community", values: col.(:newcomers_community) },
                       { label: "new to these lists", values: col.(:newcomers_selection) } ],
          by_list: by_list(starts) }
      end

      private

      def gran = @params.gran

      def split(col, total, committer, contributor)
        all, c, k = col.(total), col.(committer), col.(contributor)
        [ { label: "committers", values: c },
          { label: "contributors", values: k },
          { label: "others", values: all.each_index.map { |i| all[i] - c[i] - k[i] }, gray: true } ]
      end

      def by_list(starts)
        bits = @params.lists.map(&:stats_bit)
        counts = StatsListMessagesByList.where(gran: gran, list_bit: bits, period_start: starts.first..starts.last)
                                        .pluck(:period_start, :list_bit, :messages)
                                        .each_with_object(Hash.new(0)) { |(p, b, n), h| h[[ p, b ]] = n }
        totals = starts.map { |s| bits.sum { |b| counts[[ s, b ]] } }
        @params.lists.map do |l|
          { label: l.identifier,
            values: starts.each_with_index.map { |s, i| totals[i].zero? ? 0.0 : (counts[[ s, l.stats_bit ]] * 100.0 / totals[i]).round(1) } }
        end
      end

      # month rows are additive; people are distinct over the whole range
      def tiles
        from, to = @params.from, @params.to
        months = (to.year * 12 + to.month) - (from.year * 12 + from.month) + 1
        prev_to = from - 1
        prev_from = prev_to.beginning_of_month.months_ago(months - 1)
        cur, prev = range_sums(from, to), range_sums(prev_from, prev_to)
        cur.to_h { |k, v| [ k, { value: v, change: change(v, prev[k]) } ] }
      end

      def range_sums(from, to)
        sums = StatsListVolume.where(gran: "month", list_mask: @params.mask, period_start: from..to)
                              .pick(*TILE_SUMS.map { |c| Arel.sql("COALESCE(SUM(#{c}), 0)") })
        people = StatsPersonWeek.where(week: from..to).where("(1 << list_bit) & ? <> 0", @params.mask).distinct.count(:person_id)
        TILE_SUMS.zip(sums.map(&:to_i)).to_h.merge(people: people).slice(:messages, :threads_new, :people, :newcomers_community, :newcomers_selection)
      end

      def change(value, previous)
        previous.zero? ? nil : ((value - previous) * 100.0 / previous).round
      end
    end
  end
end
