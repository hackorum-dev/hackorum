module Stats
  module Lists
    class Regulars
      SCORES = Monthly::SCORES
      HEAT_TOP = 20
      HEAT_ROWS = 80
      TABLE_TOP = 20
      BUMP_TOP = 10
      BUMP_WINDOW = 3
      BUMP_LINES = 60
      BUMP_PINNED = 10
      BANDS = [ [ 5, 4 ], [ 10, 3 ], [ 20, 2 ], [ 50, 1 ] ].freeze

      def initialize(params, score: nil, at: nil, today: Date.current)
        @params = params
        @score = score.to_s.presence_in(SCORES) || "threads"
        @today = today
        @months = Periods.starts("month", params.from, params.to)
        clamp_to_built
        @at = parse_at(at) || default_at
      end

      def to_h
        rows = load_rows
        by_month = rows.group_by { |r| r[:month] }
        people = people_info(rows.map { |r| r[:person_id] }.uniq)
        tbl = table(by_month, people)
        { score: @score, approximate: !precomputed?, months: @months.map { |m| m.strftime("%Y-%m") }, at: @at.strftime("%Y-%m"),
          heatmap: heatmap(by_month, people), table: tbl, bump: bump(by_month, people, tbl.map { |r| r[:person_id] }),
          concentration: concentration(by_month) }
      end

      private

      # the month in progress has too few days to rank by raw counts
      def default_at = @months.reverse.find { |m| m < @today.beginning_of_month } || @months.last

      def rank_key = :"rank_#{@score}"
      def score_key = :"score_#{@score}"

      def parse_at(value)
        m = value.to_s.match(/\A(\d{4})-(\d{1,2})\z/) or return nil
        d = Date.new(m[1].to_i, m[2].to_i, 1)
        @months.include?(d) ? d : nil
      rescue Date::Error
        nil
      end

      # spark of the first month reaches 23 months back; covers the year-ago rank too
      def load_from = (@months.first || @params.from) << 23

      # the builder lags the calendar: never show months it has not written
      def clamp_to_built
        return unless precomputed?

        last = StatsRegularsMonthly.where(list_mask: @params.mask).maximum(:month)&.to_date
        return unless last

        kept = @months.select { |m| m <= last }
        @months = kept.empty? ? [ last ] : kept
      end

      def precomputed?
        @precomputed = StatsRegularsMonthly.where(list_mask: @params.mask).exists? if @precomputed.nil?
        @precomputed
      end

      def load_rows
        return [] if @months.empty?

        raw = if precomputed?
          StatsRegularsMonthly.where(list_mask: @params.mask, month: load_from..@months.last)
                              .pluck(:month, :person_id, *SCORES.map { |s| :"score_#{s}" }, *SCORES.map { |s| :"rank_#{s}" })
        else
          on_the_fly
        end
        raw.map do |month, person_id, *vals|
          { month: month.to_date, person_id: person_id.to_i }
            .merge(SCORES.each_with_index.to_h { |s, i| [ :"score_#{s}", vals[i].to_f ] })
            .merge(SCORES.each_with_index.to_h { |s, i| [ :"rank_#{s}", vals[i + 3].to_i ] })
        end
      end

      def on_the_fly
        conn = ActiveRecord::Base.connection
        src = <<~SQL
          SELECT date_trunc('month', week)::date AS month, person_id, sum(messages) AS messages, sum(threads) AS threads, sum(days) AS days
          FROM (
            SELECT week, person_id, sum(messages) AS messages, sum(threads) AS threads, least(sum(active_days), 7) AS days
            FROM stats_person_weeks
            WHERE (1 << list_bit) & #{@params.mask.to_i} <> 0 AND week >= #{conn.quote(load_from)} AND week < #{conn.quote(@months.last >> 1)}
            GROUP BY week, person_id
          ) w
          GROUP BY 1, 2
        SQL
        rows = conn.select_rows(Monthly.new(source_sql: src, keep: 100).rows_sql(totals: true))
        idx = 2 + 2 * SCORES.size + SCORES.index(@score)
        in_range = @months.to_set
        @totals = rows.each_with_object({}) do |r, h|
          m = r[0].to_date
          h[m] = r[idx].to_f if in_range.include?(m)
        end
        rows
      end

      def totals
        @totals ||= if precomputed?
          StatsRegularsTotal.where(list_mask: @params.mask, month: @months.first..@months.last).pluck(:month, :"total_#{@score}").to_h
        else
          {}
        end
      end

      def people_info(ids)
        firsts = CommitPerson.where(role: CommitPerson::COMMITTER, person_id: ids).joins(:commit).group(:person_id).minimum("commits.committed_at")
        contributors = ContributorMembership.where(person_id: ids).distinct.pluck(:person_id).to_set
        Person.where(id: ids).includes(:default_alias).to_h do |p|
          [ p.id, { name: p.display_name, email: p.default_alias&.email, committer_since: firsts[p.id], contributor: contributors.include?(p.id) } ]
        end
      end

      def in_range(by_month) = @months.map { |m| [ m, by_month.fetch(m, []) ] }

      def heatmap(by_month, people)
        first_seen = {}
        best = Hash.new(Float::INFINITY)
        in_range(by_month).each_with_index do |(_, rows), x|
          rows.each do |r|
            next unless r[rank_key] <= HEAT_TOP

            first_seen[r[:person_id]] ||= x
            best[r[:person_id]] = [ best[r[:person_id]], r[rank_key] ].min
          end
        end
        capped = first_seen.size > HEAT_ROWS
        ids = capped ? first_seen.keys.sort_by { |id| [ best[id], first_seen[id] ] }.first(HEAT_ROWS) : first_seen.keys
        order = ids.sort_by { |id| [ first_seen[id], best[id] ] }
        y_index = order.each_with_index.to_h
        cells = []
        in_range(by_month).each_with_index do |(_, rows), x|
          rows.each do |r|
            y = y_index[r[:person_id]] or next
            band = BANDS.find { |limit, _| r[rank_key] <= limit }&.last or next
            cells << [ x, y, band, r[rank_key], r[score_key].round ]
          end
        end
        { x: @months.map { |m| m.strftime("%Y-%m") }, y: order.map { |id| people.dig(id, :name) || "?" }, cells: cells, capped: capped }
      end

      def table(by_month, people)
        year_ago = by_month.fetch(@at << 12, []).to_h { |r| [ r[:person_id], r[rank_key] ] }
        spark_months = (0..23).map { |i| @at << (23 - i) }
        scores = by_month.slice(*spark_months).transform_values { |rows| rows.to_h { |r| [ r[:person_id], r[score_key] ] } }
        month_end = @at.end_of_month.end_of_day
        by_month.fetch(@at, []).select { |r| r[rank_key] <= TABLE_TOP }.sort_by { |r| r[rank_key] }.map do |r|
          info = people.fetch(r[:person_id], {})
          tag = if info[:committer_since] && info[:committer_since] <= month_end
            "committer"
          elsif info[:contributor]
            "contributor"
          end
          { rank: r[rank_key], person_id: r[:person_id], name: info[:name], email: info[:email], tag: tag,
            score: r[score_key].round, spark: spark_months.map { |m| scores.dig(m, r[:person_id])&.round || 0 },
            year_ago: year_ago[r[:person_id]] }
        end
      end

      # everyone who was in the rolling top 10 at some point, the end month's
      # top 20 (named on the right) and the table's people, so a click on a
      # row always has a line to color
      def bump(by_month, people, table_ids)
        return nil if (@params.to - @params.from) > 3 * 366

        months = @months.select { |m| m <= default_at }
        ranks = rolling_ranks(by_month, months)
        best = Hash.new(Float::INFINITY)
        ranks.each_value { |rs| rs.each { |id, r| best[id] = r if r < best[id] } }
        last_top = ranks.fetch(months.last, {}).select { |_, r| r <= HEAT_TOP }.keys
        ids = (best.select { |_, r| r <= BUMP_TOP }.keys | table_ids | last_top).sort_by { |id| [ best[id], id ] }.first(BUMP_LINES)
        lines = ids.filter_map do |id|
          values = months.map { |m| v = ranks.dig(m, id); v && v <= HEAT_TOP ? v : nil }
          next unless values.any?

          best_at = values.each_index.min_by { |j| [ values[j] || Float::INFINITY, j ] }
          { id: id, label: people.dig(id, :name) || "?", values: values, best: values[best_at], best_at: months[best_at].strftime("%Y-%m") }
        end
        pinned = ranks.fetch(months.last, {}).select { |_, r| r <= BUMP_PINNED }.sort_by(&:last).map(&:first)
        { window: BUMP_WINDOW, top: BUMP_TOP, categories: months.map { |m| m.strftime("%Y-%m") }, lines: lines, pinned: pinned }
      end

      # rank by the score summed over the month and the BUMP_WINDOW - 1 before it
      def rolling_ranks(by_month, months)
        months.to_h do |m|
          sums = Hash.new(0.0)
          (0...BUMP_WINDOW).each { |i| by_month.fetch(m << i, []).each { |r| sums[r[:person_id]] += r[score_key] } }
          [ m, sums.sort_by { |id, v| [ -v, id ] }.each_with_index.to_h { |(id, _), i| [ id, i + 1 ] } ]
        end
      end

      def concentration(by_month)
        series = { "top 10" => [], "11-50" => [], "everyone else" => [] }
        @months.each do |m|
          rows = by_month.fetch(m, [])
          total = totals[m].to_f
          top10 = rows.select { |r| r[rank_key] <= 10 }.sum { |r| r[score_key] }
          top50 = rows.select { |r| r[rank_key] <= 50 }.sum { |r| r[score_key] }
          pct = ->(v) { total.zero? ? 0.0 : (v * 100 / total).round(1) }
          series["top 10"] << pct.(top10)
          series["11-50"] << pct.(top50 - top10)
          series["everyone else"] << (total.zero? ? 0.0 : (100 - pct.(top10) - pct.(top50 - top10)).round(1))
        end
        { categories: @months.map { |m| m.strftime("%Y-%m") },
          series: series.map { |label, values| { label: label, values: values, gray: label == "everyone else" } } }
      end
    end
  end
end
