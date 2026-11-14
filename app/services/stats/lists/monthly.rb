module Stats
  module Lists
    # Ranks per-person monthly counts. The source is any SQL with columns
    # month, person_id, messages, threads, days.
    class Monthly
      SCORES = %w[messages threads days].freeze

      def initialize(source_sql:, keep: nil)
        @source_sql = source_sql
        @keep = keep
      end

      # totals: true appends total_* per month, summed before the keep filter
      def rows_sql(totals: false)
        ranks = SCORES.map { |s| "row_number() OVER (PARTITION BY month ORDER BY score_#{s} DESC, person_id) AS rank_#{s}" }
        sums = totals ? SCORES.map { |s| "sum(score_#{s}) OVER (PARTITION BY month) AS total_#{s}" } : []
        cols = %w[month person_id] + SCORES.map { |s| "score_#{s}" } + SCORES.map { |s| "rank_#{s}" }
        cols += SCORES.map { |s| "total_#{s}" } if totals
        filter = @keep ? "WHERE least(#{SCORES.map { |s| "rank_#{s}" }.join(', ')}) <= #{@keep.to_i}" : ""
        <<~SQL
          SELECT #{cols.join(', ')}
          FROM (SELECT *, #{(ranks + sums).join(', ')} FROM (#{scores_sql}) sc) r
          #{filter}
        SQL
      end

      def totals_sql
        "SELECT month, #{SCORES.map { |s| "sum(score_#{s}) AS total_#{s}" }.join(', ')} FROM (#{scores_sql}) sc GROUP BY month"
      end

      private

      def scores_sql
        "SELECT month::date AS month, person_id, #{SCORES.map { |s| "#{s}::float8 AS score_#{s}" }.join(', ')} FROM (#{@source_sql}) s"
      end
    end
  end
end
