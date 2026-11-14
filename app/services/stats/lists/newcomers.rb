module Stats
  module Lists
    class Newcomers
      PATHS = { "patch" => "sent a patch", "report" => "started a thread", "discussion" => "only replied" }.freeze
      RETENTION_MONTHS = 36
      HIGHLIGHT = 4
      RISERS = 20

      def initialize(params, today: Date.current)
        @params = params
        @today = today
        @gran = (params.to - params.from) > 10 * 366 ? "year" : "quarter"
      end

      def to_h
        rows = load
        starts = Periods.starts(@gran, @params.from, @params.to)
        groups = rows.group_by { |r| Periods.truncate(@gran, r[:first_at].to_date) }
        { cohorts: starts.map { |s| Periods.label(@gran, s) }, gran: @gran,
          tiles: tiles(rows), retention: retention(starts, groups), outcomes: outcomes(starts, groups),
          paths: paths(starts, groups), path_table: path_table(rows), risers: risers }
      end

      private

      COLS = %i[person_id first_at first_list_mask path came_back active_month_offsets active_months_2y reached_top50_at contributor committer_at second_at].freeze

      def scope
        StatsNewcomer.where(first_at: @params.from.beginning_of_day..@params.to.end_of_day)
                     .where("first_list_mask & ? <> 0", @params.mask)
      end

      def load = scope.pluck(*COLS).map { |v| COLS.zip(v).to_h }

      def pct(part, whole) = whole.zero? ? 0.0 : (part * 100.0 / whole).round(1)

      def active?(r) = r[:active_months_2y] >= 6

      def tiles(rows)
        days = rows.filter_map { |r| r[:second_at] && (r[:second_at] - r[:first_at]) / 1.day }.sort
        median = days.empty? ? nil : (days.size.odd? ? days[days.size / 2] : (days[days.size / 2 - 1] + days[days.size / 2]) / 2).round
        { newcomers: rows.size, came_back: pct(rows.count { |r| r[:came_back] }, rows.size),
          became_active: pct(rows.count { |r| active?(r) }, rows.size),
          top50: pct(rows.count { |r| r[:reached_top50_at] }, rows.size), median_days_to_second: median }
      end

      def cohort_end(start) = Periods.step(@gran, start) - 1

      def retention(starts, groups)
        lines = starts.filter_map do |s|
          rows = groups[s] or next
          values = (1..RETENTION_MONTHS).map do |k|
            (cohort_end(s) >> k) > @today ? nil : pct(rows.count { |r| r[:active_month_offsets].include?(k) }, rows.size)
          end
          { label: Periods.label(@gran, s), values: values } if values.any?
        end
        lines.each_with_index { |l, i| l[:gray] = i < lines.size - HIGHLIGHT }
        { categories: (1..RETENTION_MONTHS).map(&:to_s), lines: lines }
      end

      def outcomes(starts, groups)
        metric = lambda do |&test|
          starts.map { |s| (rows = groups[s]) ? pct(rows.count(&test), rows.size) : nil }
        end
        { categories: starts.map { |s| Periods.label(@gran, s) },
          open: starts.map { |s| (cohort_end(s) >> 24) > @today },
          lines: [ { label: "came back", values: metric.call { |r| r[:came_back] } },
                   { label: "active at 12 months", values: metric.call { |r| r[:active_month_offsets].include?(12) } },
                   { label: "became active", values: metric.call { |r| active?(r) } },
                   { label: "reached top 50", values: metric.call { |r| r[:reached_top50_at] } },
                   { label: "contributor or committer", values: metric.call { |r| r[:contributor] || r[:committer_at] } } ] }
      end

      def paths(starts, groups)
        { categories: starts.map { |s| Periods.label(@gran, s) }, unit: "%", bars: true,
          series: PATHS.map { |key, label| { label: label, values: starts.map { |s| (rows = groups[s]) ? pct(rows.count { |r| r[:path] == key }, rows.size) : 0.0 } } } }
      end

      def path_table(rows)
        PATHS.map do |key, label|
          sub = rows.select { |r| r[:path] == key }
          { label: label, size: sub.size, came_back: pct(sub.count { |r| r[:came_back] }, sub.size),
            became_active: pct(sub.count { |r| active?(r) }, sub.size), top50: pct(sub.count { |r| r[:reached_top50_at] }, sub.size) }
        end
      end

      def risers
        from = (@params.to << 12) + 1
        rows = StatsNewcomer.where(first_at: from.beginning_of_day..@params.to.end_of_day).where("first_list_mask & ? <> 0", @params.mask)
                            .where.not(reached_top50_at: nil).pluck(:person_id, :first_at, :first_list_mask, :path, :reached_top50_at)
                            .sort_by { |_, f, _, _, t| t - f }.first(RISERS)
        return [] if rows.empty?

        ids = rows.map(&:first)
        people = Person.where(id: ids).includes(:default_alias).index_by(&:id)
        lists = @params.all_lists
        months = (0..11).map { |i| @params.to.beginning_of_month << (11 - i) }
        counts = StatsPersonWeek.where(person_id: ids, week: months.first..@params.to.end_of_month)
                                .where("(1 << list_bit) & ? <> 0", @params.mask)
                                .group(:person_id, Arel.sql("date_trunc('month', week)::date")).sum(:messages)
        rows.map do |id, first_at, mask, path, reached|
          p = people[id]
          { name: p&.display_name, email: p&.default_alias&.email, first_at: first_at.to_date,
            lists: lists.select { |l| mask & (1 << l.stats_bit) != 0 }.map(&:identifier),
            path: PATHS[path], weeks_to_top50: [ ((reached - first_at) / 1.week).ceil, 0 ].max,
            spark: months.map { |m| counts[[ id, m ]] || 0 } }
        end
      end
    end
  end
end
