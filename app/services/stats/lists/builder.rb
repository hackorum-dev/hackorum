module Stats
  module Lists
    # Rebuilds the list stats tables from the messages. Exact per list
    # combination: distinct counts are taken per period and mask, never summed.
    class Builder
      GRANS = %w[week month quarter year].freeze
      TABLES = %w[stats_person_weeks stats_person_firsts stats_list_volume stats_list_messages_by_list stats_newcomers
                  stats_regulars_monthly stats_regulars_totals].freeze

      LOCK_KEY = 7_340_211_001
      MAX_LISTS = 10

      def initialize
        @conn = ActiveRecord::Base.connection
      end

      def run!
        @conn.transaction do
          @conn.execute("SELECT pg_advisory_xact_lock(#{LOCK_KEY})")
          masks = all_masks
          TABLES.each { |t| @conn.execute("DELETE FROM #{t}") }
          next if masks.empty?

          prepare(masks)
          person_weeks
          person_firsts
          GRANS.each do |gran|
            volume(gran)
            messages_by_list(gran)
          end
          newcomers
          regulars
        end
      end

      private

      def all_masks
        bits = MailingList.where.not(stats_bit: nil).pluck(:stats_bit)
        raise ArgumentError, "too many lists for per-combination stats: #{bits.size}" if bits.size > MAX_LISTS

        all = bits.sum { |b| 1 << b }
        (1..all).select { |m| m & ~all == 0 }
      end

      def temp(name, sql)
        @conn.execute("DROP TABLE IF EXISTS #{name}")
        @conn.execute("CREATE TEMP TABLE #{name} ON COMMIT DROP AS #{sql}")
      end

      def prepare(masks)
        temp("sl_masks", "SELECT unnest(ARRAY[#{masks.join(',')}]::int[]) AS mask")
        temp("sl_msg_bits", <<~SQL)
          SELECT mml.message_id, ml.stats_bit AS bit
          FROM message_mailing_lists mml
          JOIN mailing_lists ml ON ml.id = mml.mailing_list_id
          WHERE ml.stats_bit IS NOT NULL
        SQL
        @conn.execute("CREATE INDEX ON sl_msg_bits (message_id)")
        temp("sl_committers", <<~SQL)
          SELECT cp.person_id, min(c.committed_at) AS since
          FROM commit_people cp JOIN commits c ON c.id = cp.commit_id
          WHERE cp.role = 'committer' AND cp.person_id IS NOT NULL
          GROUP BY cp.person_id
        SQL
        temp("sl_contributors", "SELECT DISTINCT person_id FROM contributor_memberships WHERE person_id IS NOT NULL")
        temp("sl_msgs", <<~SQL)
          SELECT x.*,
                 CASE WHEN c.since <= x.created_at THEN 2 WHEN k.person_id IS NOT NULL THEN 1 ELSE 0 END AS cls
          FROM (
            SELECT m.id, m.created_at, m.topic_id, m.sender_person_id AS person_id,
                   m.is_patch_submission AS patch, bit_or(1 << b.bit) AS mask
            FROM messages m JOIN sl_msg_bits b ON b.message_id = m.id
            WHERE m.state = 'sent'
            GROUP BY m.id
          ) x
          LEFT JOIN sl_committers c ON c.person_id = x.person_id
          LEFT JOIN sl_contributors k ON k.person_id = x.person_id
        SQL
        @conn.execute("CREATE INDEX ON sl_msgs (id)")
        @conn.execute("CREATE INDEX ON sl_msgs (person_id, created_at)")
        temp("sl_topic_starts", <<~SQL)
          SELECT DISTINCT ON (topic_id) topic_id, id AS message_id, created_at, person_id, mask
          FROM sl_msgs ORDER BY topic_id, created_at, id
        SQL
        @conn.execute("CREATE INDEX ON sl_topic_starts (message_id)")
        temp("sl_firsts", <<~SQL)
          SELECT DISTINCT ON (person_id) person_id, id AS message_id, created_at AS first_at, mask
          FROM sl_msgs ORDER BY person_id, created_at, id
        SQL
      end

      def person_weeks
        @conn.execute(<<~SQL)
          INSERT INTO stats_person_weeks (week, person_id, list_bit, messages, threads, active_days, patch_mails, threads_started)
          SELECT date_trunc('week', m.created_at)::date, m.person_id, b.bit,
                 count(*), count(DISTINCT m.topic_id), count(DISTINCT m.created_at::date),
                 count(*) FILTER (WHERE m.patch), count(ts.message_id)
          FROM sl_msgs m
          JOIN sl_msg_bits b ON b.message_id = m.id
          LEFT JOIN sl_topic_starts ts ON ts.message_id = m.id
          GROUP BY 1, 2, 3
        SQL
      end

      def person_firsts
        @conn.execute(<<~SQL)
          INSERT INTO stats_person_firsts (person_id, list_bit, first_at, first_message_id)
          SELECT DISTINCT ON (m.person_id, b.bit) m.person_id, b.bit, m.created_at, m.id
          FROM sl_msgs m JOIN sl_msg_bits b ON b.message_id = m.id
          ORDER BY m.person_id, b.bit, m.created_at, m.id
        SQL
        temp("sl_sel_firsts", <<~SQL)
          SELECT f.person_id, s.mask, min(f.first_at) AS first_at
          FROM stats_person_firsts f JOIN sl_masks s ON s.mask & (1 << f.list_bit) <> 0
          GROUP BY 1, 2
        SQL
      end

      def volume(gran)
        g = @conn.quote(gran)
        @conn.execute(<<~SQL)
          WITH msg AS (
            SELECT date_trunc(#{g}, created_at)::date AS p, mask, cls, count(*) AS n FROM sl_msgs GROUP BY 1, 2, 3
          ), ppl AS (
            SELECT date_trunc(#{g}, created_at)::date AS p, person_id, bit_or(mask) AS mask, max(cls) AS cls FROM sl_msgs GROUP BY 1, 2
          ), tpc AS (
            SELECT date_trunc(#{g}, created_at)::date AS p, topic_id, bit_or(mask) AS mask FROM sl_msgs GROUP BY 1, 2
          ), a_msg AS (
            SELECT msg.p, s.mask, sum(n) AS messages,
                   COALESCE(sum(n) FILTER (WHERE cls = 2), 0) AS mc, COALESCE(sum(n) FILTER (WHERE cls = 1), 0) AS mk
            FROM msg JOIN sl_masks s ON s.mask & msg.mask <> 0 GROUP BY 1, 2
          ), a_ppl AS (
            SELECT ppl.p, s.mask, count(*) AS people,
                   count(*) FILTER (WHERE cls = 2) AS pc, count(*) FILTER (WHERE cls = 1) AS pk
            FROM ppl JOIN sl_masks s ON s.mask & ppl.mask <> 0 GROUP BY 1, 2
          ), a_tpc AS (
            SELECT tpc.p, s.mask, count(*) AS n FROM tpc JOIN sl_masks s ON s.mask & tpc.mask <> 0 GROUP BY 1, 2
          ), a_new AS (
            SELECT date_trunc(#{g}, ts.created_at)::date AS p, s.mask, count(*) AS n
            FROM sl_topic_starts ts JOIN sl_masks s ON s.mask & ts.mask <> 0 GROUP BY 1, 2
          ), a_com AS (
            SELECT date_trunc(#{g}, f.first_at)::date AS p, s.mask, count(*) AS n
            FROM sl_firsts f JOIN sl_masks s ON s.mask & f.mask <> 0 GROUP BY 1, 2
          ), a_sel AS (
            SELECT date_trunc(#{g}, first_at)::date AS p, mask, count(*) AS n FROM sl_sel_firsts GROUP BY 1, 2
          )
          INSERT INTO stats_list_volume (gran, period_start, list_mask, messages, messages_committer, messages_contributor,
                                         threads_new, threads_active, people, people_committer, people_contributor,
                                         newcomers_community, newcomers_selection)
          SELECT #{g}, a_msg.p, a_msg.mask, a_msg.messages, a_msg.mc, a_msg.mk,
                 COALESCE(a_new.n, 0), COALESCE(a_tpc.n, 0), COALESCE(a_ppl.people, 0), COALESCE(a_ppl.pc, 0), COALESCE(a_ppl.pk, 0),
                 COALESCE(a_com.n, 0), COALESCE(a_sel.n, 0)
          FROM a_msg
          LEFT JOIN a_ppl USING (p, mask)
          LEFT JOIN a_tpc USING (p, mask)
          LEFT JOIN a_new USING (p, mask)
          LEFT JOIN a_com USING (p, mask)
          LEFT JOIN a_sel USING (p, mask)
        SQL
      end

      def messages_by_list(gran)
        g = @conn.quote(gran)
        @conn.execute(<<~SQL)
          INSERT INTO stats_list_messages_by_list (gran, period_start, list_bit, messages)
          SELECT #{g}, date_trunc(#{g}, m.created_at)::date, b.bit, count(*)
          FROM sl_msgs m JOIN sl_msg_bits b ON b.message_id = m.id
          GROUP BY 2, 3
        SQL
      end

      def newcomers
        @conn.execute(<<~SQL)
          INSERT INTO stats_newcomers (person_id, first_at, first_list_mask, path, came_back,
                                       active_month_offsets, active_months_2y, contributor, committer_at, second_at)
          SELECT f.person_id, f.first_at, f.mask,
                 CASE WHEN bool_or(m.patch) FILTER (WHERE m.created_at < f.first_at + interval '90 days') THEN 'patch'
                      WHEN bool_or(ts.message_id IS NOT NULL) FILTER (WHERE m.created_at < f.first_at + interval '90 days') THEN 'report'
                      ELSE 'discussion' END,
                 bool_or(m.created_at > f.first_at + interval '30 days'),
                 COALESCE(array_agg(DISTINCT o.off ORDER BY o.off) FILTER (WHERE o.off <= 36), '{}')::smallint[],
                 count(DISTINCT o.off) FILTER (WHERE o.off < 24),
                 k.person_id IS NOT NULL AND c.since IS NULL, c.since,
                 min(m.created_at) FILTER (WHERE m.id <> f.message_id)
          FROM sl_firsts f
          JOIN sl_msgs m ON m.person_id = f.person_id
          LEFT JOIN sl_topic_starts ts ON ts.message_id = m.id
          LEFT JOIN sl_committers c ON c.person_id = f.person_id
          LEFT JOIN sl_contributors k ON k.person_id = f.person_id
          CROSS JOIN LATERAL (
            SELECT ((date_part('year', m.created_at) - date_part('year', f.first_at)) * 12
                    + date_part('month', m.created_at) - date_part('month', f.first_at))::int AS off
          ) o
          GROUP BY f.person_id, f.first_at, f.mask, k.person_id, c.since
        SQL
      end

      def regulars
        bits = MailingList.where.not(stats_bit: nil).to_a
        default = bits.select(&:stats_default?).sum { |l| 1 << l.stats_bit }
        all = bits.sum { |l| 1 << l.stats_bit }
        masks = ([ default, all ] + bits.map { |l| 1 << l.stats_bit }).uniq.reject(&:zero?)
        masks.each do |mask|
          temp("sl_sel_months", <<~SQL)
            SELECT date_trunc('month', created_at)::date AS month, person_id,
                   count(*) AS messages, count(DISTINCT topic_id) AS threads, count(DISTINCT created_at::date) AS days
            FROM sl_msgs WHERE mask & #{mask} <> 0 GROUP BY 1, 2
          SQL
          monthly = Monthly.new(source_sql: "SELECT * FROM sl_sel_months", keep: 100)
          @conn.execute("INSERT INTO stats_regulars_monthly (month, person_id, score_messages, score_threads, score_days, " \
                        "rank_messages, rank_threads, rank_days, list_mask) SELECT r.*, #{mask} FROM (#{monthly.rows_sql}) r")
          @conn.execute("INSERT INTO stats_regulars_totals (month, total_messages, total_threads, total_days, list_mask) " \
                        "SELECT t.*, #{mask} FROM (#{monthly.totals_sql}) t")
        end
        reached_top50(default)
      end

      def reached_top50(default)
        @conn.execute(<<~SQL)
          UPDATE stats_newcomers n SET reached_top50_at = (r.first_month + interval '1 month' - interval '1 day')
          FROM (
            SELECT r.person_id, min(r.month) AS first_month
            FROM stats_regulars_monthly r JOIN stats_newcomers n2 ON n2.person_id = r.person_id
            WHERE r.list_mask = #{default} AND least(r.rank_messages, r.rank_threads, r.rank_days) <= 50
              AND r.month <= n2.first_at + interval '2 years'
            GROUP BY r.person_id
          ) r
          WHERE n.person_id = r.person_id
        SQL
      end
    end
  end
end
