#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/environment"

class StatsAggregator
  BUCKETS = [
    { label: "0-1", max: 1 },
    { label: "2-7", max: 7 },
    { label: "8-30", max: 30 },
    { label: "31-90", max: 90 },
    { label: "91-180", max: 180 },
    { label: "181-365", max: 365 },
    { label: "365+", max: nil }
  ].freeze

  def initialize(granularity:, start_date:, end_date:)
    @granularity = granularity
    @start_date = start_date
    @end_date = end_date
    @conn = ActiveRecord::Base.connection
    @prepared = false
    @interval_expr = interval_expr_for(@granularity)
  end

  def run!
    prepare_temp_tables
    prepare_interval_tables
    upsert_interval_stats
    upsert_longevity_histogram
  end

  private

  def intervals
    dates = []
    cursor = @start_date
    while cursor <= @end_date
      case @granularity
      when :daily
        interval_start = cursor
        interval_end = cursor
        cursor += 1.day
      when :weekly
        interval_start = cursor.beginning_of_week(:monday)
        interval_end = interval_start.end_of_week(:monday)
        cursor = interval_end + 1.day
      when :monthly
        interval_start = cursor.beginning_of_month
        interval_end = cursor.end_of_month
        cursor = interval_end + 1.day
      else
        raise ArgumentError, "unknown granularity: #{@granularity}"
      end
      dates << { start: interval_start, end: interval_end }
    end
    dates.uniq { |interval| interval[:start] }
  end

  def stats_model
    case @granularity
    when :daily then StatsDaily
    when :weekly then StatsWeekly
    when :monthly then StatsMonthly
    else raise ArgumentError, "unknown granularity: #{@granularity}"
    end
  end

  def prepare_temp_tables
    return if @prepared

    @conn.execute("DROP TABLE IF EXISTS tmp_messages")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_messages AS
      SELECT messages.id AS message_id,
             messages.created_at,
             messages.topic_id,
             aliases.person_id
      FROM messages
      INNER JOIN aliases ON aliases.id = messages.sender_id
    SQL
    @conn.execute("CREATE INDEX tmp_messages_created_at_idx ON tmp_messages (created_at)")
    @conn.execute("CREATE INDEX tmp_messages_person_id_idx ON tmp_messages (person_id)")
    @conn.execute("CREATE INDEX tmp_messages_topic_id_idx ON tmp_messages (topic_id)")

    @conn.execute("DROP TABLE IF EXISTS tmp_firsts")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_firsts AS
      SELECT person_id, MIN(created_at) AS first_at
      FROM tmp_messages
      GROUP BY person_id
    SQL
    @conn.execute("CREATE INDEX tmp_firsts_person_id_idx ON tmp_firsts (person_id)")
    @conn.execute("CREATE INDEX tmp_firsts_first_at_idx ON tmp_firsts (first_at)")

    @conn.execute("DROP TABLE IF EXISTS tmp_message_counts")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_message_counts AS
      SELECT person_id, COUNT(*) AS message_count
      FROM tmp_messages
      GROUP BY person_id
    SQL
    @conn.execute("CREATE INDEX tmp_message_counts_person_id_idx ON tmp_message_counts (person_id)")

    @conn.execute("DROP TABLE IF EXISTS tmp_person_lifetimes")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_person_lifetimes AS
      SELECT person_id,
             MIN(created_at) AS first_at,
             EXTRACT(EPOCH FROM (MAX(created_at) - MIN(created_at))) / 86400.0 AS lifetime_days
      FROM tmp_messages
      GROUP BY person_id
    SQL
    @conn.execute("CREATE INDEX tmp_person_lifetimes_first_at_idx ON tmp_person_lifetimes (first_at)")

    @conn.execute("DROP TABLE IF EXISTS tmp_memberships")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_memberships AS
      SELECT contributor_memberships.person_id,
             BOOL_OR(contributor_memberships.contributor_type = 'committer') AS is_committer,
             TRUE AS is_contributor
      FROM contributor_memberships
      GROUP BY contributor_memberships.person_id
    SQL
    @conn.execute("CREATE INDEX tmp_memberships_person_id_idx ON tmp_memberships (person_id)")

    @conn.execute("DROP TABLE IF EXISTS tmp_topic_starters")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_topic_starters AS
      SELECT DISTINCT ON (topic_id)
        topic_id,
        person_id AS starter_person_id
      FROM tmp_messages
      ORDER BY topic_id, created_at ASC, message_id ASC
    SQL
    @conn.execute("CREATE INDEX tmp_topic_starters_topic_id_idx ON tmp_topic_starters (topic_id)")

    @conn.execute("DROP TABLE IF EXISTS tmp_topics_with_attachments")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_topics_with_attachments AS
      SELECT DISTINCT messages.topic_id
      FROM attachments
      INNER JOIN messages ON messages.id = attachments.message_id
    SQL
    @conn.execute("CREATE INDEX tmp_topics_with_attachments_topic_id_idx ON tmp_topics_with_attachments (topic_id)")

    @conn.execute("DROP TABLE IF EXISTS tmp_topic_message_totals")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_topic_message_totals AS
      SELECT topic_id, COUNT(*) AS total_messages
      FROM tmp_messages
      GROUP BY topic_id
    SQL
    @conn.execute("CREATE INDEX tmp_topic_message_totals_topic_id_idx ON tmp_topic_message_totals (topic_id)")

    @conn.execute("DROP TABLE IF EXISTS tmp_topic_longevity")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_topic_longevity AS
      SELECT topic_id,
             EXTRACT(EPOCH FROM (MAX(created_at) - MIN(created_at))) / 86400.0 AS longevity_days
      FROM tmp_messages
      GROUP BY topic_id
    SQL
    @conn.execute("CREATE INDEX tmp_topic_longevity_topic_id_idx ON tmp_topic_longevity (topic_id)")

    @conn.execute("DROP TABLE IF EXISTS tmp_topics_with_contributor")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_topics_with_contributor AS
      SELECT DISTINCT tm.topic_id
      FROM tmp_messages tm
      INNER JOIN tmp_memberships mm ON mm.person_id = tm.person_id
    SQL
    @conn.execute("CREATE INDEX tmp_topics_with_contributor_topic_id_idx ON tmp_topics_with_contributor (topic_id)")

    @conn.execute("DROP TABLE IF EXISTS tmp_commitfest_topics")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_commitfest_topics AS
      SELECT DISTINCT topic_id
      FROM commitfest_patch_topics
    SQL
    @conn.execute("CREATE INDEX tmp_commitfest_topics_topic_id_idx ON tmp_commitfest_topics (topic_id)")

    @conn.execute("DROP TABLE IF EXISTS tmp_commitfest_status")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_commitfest_status AS
      WITH latest_cf AS (
        SELECT cpt.topic_id, MAX(cf.end_date) AS max_end
        FROM commitfest_patch_topics cpt
        JOIN commitfest_patches cp ON cp.id = cpt.commitfest_patch_id
        JOIN commitfest_patch_commitfests pcc ON pcc.commitfest_patch_id = cp.id
        JOIN commitfests cf ON cf.id = pcc.commitfest_id
        GROUP BY cpt.topic_id
      ),
      latest_statuses AS (
        SELECT cpt.topic_id, pcc.status
        FROM commitfest_patch_topics cpt
        JOIN commitfest_patches cp ON cp.id = cpt.commitfest_patch_id
        JOIN commitfest_patch_commitfests pcc ON pcc.commitfest_patch_id = cp.id
        JOIN commitfests cf ON cf.id = pcc.commitfest_id
        JOIN latest_cf lc ON lc.topic_id = cpt.topic_id AND lc.max_end = cf.end_date
      )
      SELECT topic_id,
             BOOL_OR(status = 'Committed') AS committed,
             BOOL_OR(status IN ('Rejected', 'Withdrawn', 'Returned with feedback')) AS abandoned,
             BOOL_OR(status IN ('Needs review', 'Waiting on Author', 'Ready for Committer', 'Moved to different CF')) AS in_progress
      FROM latest_statuses
      GROUP BY topic_id
    SQL
    @conn.execute("CREATE INDEX tmp_commitfest_status_topic_id_idx ON tmp_commitfest_status (topic_id)")

    @prepared = true
  end

  def prepare_interval_tables
    start_stamp = @start_date.beginning_of_day.to_fs(:db)
    end_stamp = @end_date.end_of_day.to_fs(:db)

    @conn.execute("DROP TABLE IF EXISTS tmp_intervals")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_intervals (
        interval_start date PRIMARY KEY,
        interval_end date NOT NULL
      )
    SQL
    interval_rows = intervals.map do |interval|
      "('#{interval[:start].to_fs(:db)}', '#{interval[:end].to_fs(:db)}')"
    end
    @conn.execute(<<~SQL.squish)
      INSERT INTO tmp_intervals (interval_start, interval_end)
      VALUES #{interval_rows.join(', ')}
    SQL

    @conn.execute("DROP TABLE IF EXISTS tmp_interval_messages")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_interval_messages AS
      SELECT tm.*,
             #{@interval_expr} AS interval_start
      FROM tmp_messages tm
      WHERE created_at BETWEEN '#{start_stamp}' AND '#{end_stamp}'
    SQL
    @conn.execute("CREATE INDEX tmp_interval_messages_person_id_idx ON tmp_interval_messages (person_id)")
    @conn.execute("CREATE INDEX tmp_interval_messages_topic_id_idx ON tmp_interval_messages (topic_id)")
    @conn.execute("CREATE INDEX tmp_interval_messages_interval_start_idx ON tmp_interval_messages (interval_start)")

    @conn.execute("DROP TABLE IF EXISTS tmp_interval_new_users")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_interval_new_users AS
      SELECT tf.person_id,
             tf.first_at,
             #{@interval_expr.gsub("created_at", "tf.first_at")} AS interval_start
      FROM tmp_firsts tf
      WHERE first_at BETWEEN '#{start_stamp}' AND '#{end_stamp}'
    SQL
    @conn.execute("CREATE INDEX tmp_interval_new_users_person_id_idx ON tmp_interval_new_users (person_id)")
    @conn.execute("CREATE INDEX tmp_interval_new_users_interval_start_idx ON tmp_interval_new_users (interval_start)")

    @conn.execute("DROP TABLE IF EXISTS tmp_interval_topics")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_interval_topics AS
      SELECT topics.id,
             #{@interval_expr.gsub("created_at", "topics.created_at")} AS interval_start
      FROM topics
      WHERE created_at BETWEEN '#{start_stamp}' AND '#{end_stamp}'
    SQL
    @conn.execute("CREATE INDEX tmp_interval_topics_id_idx ON tmp_interval_topics (id)")
    @conn.execute("CREATE INDEX tmp_interval_topics_interval_start_idx ON tmp_interval_topics (interval_start)")

    @conn.execute("DROP TABLE IF EXISTS tmp_interval_topic_activity")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_interval_topic_activity AS
      SELECT DISTINCT interval_start, topic_id
      FROM tmp_interval_messages
    SQL
    @conn.execute("CREATE INDEX tmp_interval_topic_activity_id_idx ON tmp_interval_topic_activity (topic_id)")
    @conn.execute("CREATE INDEX tmp_interval_topic_activity_interval_start_idx ON tmp_interval_topic_activity (interval_start)")

    @conn.execute("DROP TABLE IF EXISTS tmp_interval_retained_365")
    @conn.execute(<<~SQL.squish)
      CREATE TEMP TABLE tmp_interval_retained_365 AS
      SELECT niu.person_id, niu.first_at, niu.interval_start
      FROM tmp_interval_new_users niu
      WHERE EXISTS (
        SELECT 1
        FROM tmp_messages tm
        WHERE tm.person_id = niu.person_id
          AND tm.created_at >= niu.first_at + interval '365 days'
      )
    SQL
    @conn.execute("CREATE INDEX tmp_interval_retained_365_person_id_idx ON tmp_interval_retained_365 (person_id)")
    @conn.execute("CREATE INDEX tmp_interval_retained_365_interval_start_idx ON tmp_interval_retained_365 (interval_start)")
  end

  def interval_expr_for(granularity)
    case granularity
    when :daily
      "date_trunc('day', created_at)::date"
    when :weekly
      "date_trunc('week', created_at)::date"
    when :monthly
      "date_trunc('month', created_at)::date"
    else
      raise ArgumentError, "unknown granularity: #{granularity}"
    end
  end

  def hist_model
    case @granularity
    when :daily then StatsLongevityDaily
    when :weekly then StatsLongevityWeekly
    when :monthly then StatsLongevityMonthly
    else raise ArgumentError, "unknown granularity: #{@granularity}"
    end
  end

  def upsert_interval_stats
    today_stamp = Date.current.end_of_day.to_fs(:db)
    rows = @conn.select_all(<<~SQL.squish)
      WITH messages_by_interval AS (
        SELECT interval_start,
               COUNT(*) AS messages_total,
               COUNT(DISTINCT person_id) AS participants_active
        FROM tmp_interval_messages
        GROUP BY interval_start
      ),
      participants_committers AS (
        SELECT interval_start, COUNT(DISTINCT tm.person_id) AS participants_active_committers
        FROM tmp_interval_messages tm
        INNER JOIN tmp_memberships mm ON mm.person_id = tm.person_id
        WHERE mm.is_committer
        GROUP BY interval_start
      ),
      participants_contributors AS (
        SELECT interval_start, COUNT(DISTINCT tm.person_id) AS participants_active_contributors
        FROM tmp_interval_messages tm
        INNER JOIN tmp_memberships mm ON mm.person_id = tm.person_id
        WHERE mm.is_contributor
        GROUP BY interval_start
      ),
      messages_committers AS (
        SELECT interval_start, COUNT(DISTINCT tm.message_id) AS messages_committers
        FROM tmp_interval_messages tm
        INNER JOIN tmp_memberships mm ON mm.person_id = tm.person_id
        WHERE mm.is_committer
        GROUP BY interval_start
      ),
      messages_contributors AS (
        SELECT interval_start, COUNT(DISTINCT tm.message_id) AS messages_contributors
        FROM tmp_interval_messages tm
        INNER JOIN tmp_memberships mm ON mm.person_id = tm.person_id
        WHERE mm.is_contributor
        GROUP BY interval_start
      ),
      participants_new AS (
        SELECT interval_start, COUNT(*) AS participants_new
        FROM tmp_interval_new_users
        GROUP BY interval_start
      ),
      messages_new_participants AS (
        SELECT tm.interval_start, COUNT(*) AS messages_new_participants
        FROM tmp_interval_messages tm
        INNER JOIN tmp_interval_new_users nu
          ON nu.person_id = tm.person_id AND nu.interval_start = tm.interval_start
        GROUP BY tm.interval_start
      ),
      new_users_replied AS (
        SELECT tm.interval_start, COUNT(DISTINCT tm.person_id) AS new_users_replied_to_others
        FROM tmp_interval_messages tm
        INNER JOIN tmp_interval_new_users nu
          ON nu.person_id = tm.person_id AND nu.interval_start = tm.interval_start
        INNER JOIN tmp_topic_starters ts ON ts.topic_id = tm.topic_id
        WHERE ts.starter_person_id <> tm.person_id
        GROUP BY tm.interval_start
      ),
      participants_new_lifetime AS (
        SELECT niu.interval_start,
               COALESCE(AVG(pl.lifetime_days), 0) AS new_participants_lifetime_avg_days,
               COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY pl.lifetime_days), 0) AS new_participants_lifetime_median_days,
               COALESCE(MAX(pl.lifetime_days), 0) AS new_participants_lifetime_max_days
        FROM tmp_interval_new_users niu
        INNER JOIN tmp_person_lifetimes pl ON pl.person_id = niu.person_id
        GROUP BY niu.interval_start
      ),
      new_participants_daily_avg AS (
        SELECT niu.interval_start,
               COALESCE(AVG(
                 COALESCE(mc.message_count, 0)::float /
                 GREATEST(EXTRACT(EPOCH FROM ('#{today_stamp}'::timestamp - niu.first_at)) / 86400.0, 1)
               ), 0) AS new_participants_daily_avg_messages
        FROM tmp_interval_new_users niu
        LEFT JOIN tmp_message_counts mc ON mc.person_id = niu.person_id
        GROUP BY niu.interval_start
      ),
      retained_365 AS (
        SELECT interval_start, COUNT(*) AS retained_365_participants
        FROM tmp_interval_retained_365
        GROUP BY interval_start
      ),
      retained_365_lifetime AS (
        SELECT tr.interval_start,
               COALESCE(AVG(pl.lifetime_days), 0) AS retained_365_lifetime_avg_days,
               COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY pl.lifetime_days), 0) AS retained_365_lifetime_median_days
        FROM tmp_interval_retained_365 tr
        INNER JOIN tmp_person_lifetimes pl ON pl.person_id = tr.person_id
        GROUP BY tr.interval_start
      ),
      retained_365_daily_avg AS (
        SELECT tr.interval_start,
               COALESCE(AVG(
                 COALESCE(mc.message_count, 0)::float /
                 GREATEST(EXTRACT(EPOCH FROM ('#{today_stamp}'::timestamp - tr.first_at)) / 86400.0, 1)
               ), 0) AS retained_365_daily_avg_messages
        FROM tmp_interval_retained_365 tr
        LEFT JOIN tmp_message_counts mc ON mc.person_id = tr.person_id
        GROUP BY tr.interval_start
      ),
      topics_new AS (
        SELECT interval_start, COUNT(*) AS topics_new
        FROM tmp_interval_topics
        GROUP BY interval_start
      ),
      topics_active AS (
        SELECT interval_start, COUNT(DISTINCT topic_id) AS topics_active
        FROM tmp_interval_messages
        GROUP BY interval_start
      ),
      topics_new_by_new_participants AS (
        SELECT tin.interval_start, COUNT(DISTINCT tin.id) AS topics_new_by_new_participants
        FROM tmp_interval_topics tin
        INNER JOIN tmp_topic_starters ts ON ts.topic_id = tin.id
        INNER JOIN tmp_interval_new_users nu
          ON nu.person_id = ts.starter_person_id AND nu.interval_start = tin.interval_start
        GROUP BY tin.interval_start
      ),
      topics_new_by_new_users AS (
        SELECT tin.interval_start, COUNT(DISTINCT tin.id) AS topics_new_by_new_users
        FROM tmp_interval_topics tin
        INNER JOIN tmp_topic_starters ts ON ts.topic_id = tin.id
        INNER JOIN tmp_interval_new_users nu
          ON nu.person_id = ts.starter_person_id AND nu.interval_start = tin.interval_start
        GROUP BY tin.interval_start
      ),
      topics_new_with_attachments_by_new_users AS (
        SELECT tin.interval_start, COUNT(DISTINCT tin.id) AS topics_new_with_attachments_by_new_users
        FROM tmp_interval_topics tin
        INNER JOIN tmp_topic_starters ts ON ts.topic_id = tin.id
        INNER JOIN tmp_interval_new_users nu
          ON nu.person_id = ts.starter_person_id AND nu.interval_start = tin.interval_start
        INNER JOIN tmp_topics_with_attachments twa ON twa.topic_id = tin.id
        GROUP BY tin.interval_start
      ),
      topics_new_with_contributor_activity AS (
        SELECT tin.interval_start, COUNT(DISTINCT tin.id) AS topics_new_with_contributor_activity
        FROM tmp_interval_topics tin
        INNER JOIN tmp_topics_with_contributor tc ON tc.topic_id = tin.id
        GROUP BY tin.interval_start
      ),
      topics_with_attachments AS (
        SELECT tin.interval_start, COUNT(DISTINCT tin.id) AS topics_with_attachments
        FROM tmp_interval_topics tin
        INNER JOIN tmp_topics_with_attachments twa ON twa.topic_id = tin.id
        GROUP BY tin.interval_start
      ),
      topics_with_commitfest AS (
        SELECT tin.interval_start, COUNT(DISTINCT tin.id) AS topics_with_commitfest
        FROM tmp_interval_topics tin
        INNER JOIN tmp_commitfest_topics tct ON tct.topic_id = tin.id
        GROUP BY tin.interval_start
      ),
      commitfest_status AS (
        SELECT tin.interval_start,
               COALESCE(SUM(CASE WHEN tcs.committed THEN 1 ELSE 0 END), 0) AS topics_new_commitfest_committed,
               COALESCE(SUM(CASE WHEN NOT tcs.committed AND tcs.abandoned THEN 1 ELSE 0 END), 0) AS topics_new_commitfest_abandoned,
               COALESCE(SUM(CASE WHEN NOT tcs.committed AND NOT tcs.abandoned AND tcs.in_progress THEN 1 ELSE 0 END), 0) AS topics_new_commitfest_in_progress
        FROM tmp_interval_topics tin
        INNER JOIN tmp_commitfest_status tcs ON tcs.topic_id = tin.id
        GROUP BY tin.interval_start
      ),
      topic_message_counts AS (
        SELECT interval_start, topic_id, COUNT(*) AS cnt
        FROM tmp_interval_messages
        GROUP BY interval_start, topic_id
      ),
      topics_messages_stats AS (
        SELECT interval_start,
               COALESCE(AVG(cnt), 0) AS topics_messages_avg,
               COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cnt), 0) AS topics_messages_median,
               COALESCE(MAX(cnt), 0) AS topics_messages_max
        FROM topic_message_counts
        GROUP BY interval_start
      ),
      topics_created_messages_stats AS (
        SELECT tin.interval_start,
               COALESCE(AVG(COALESCE(tmt.total_messages, 0)), 0) AS topics_created_messages_avg,
               COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY COALESCE(tmt.total_messages, 0)), 0) AS topics_created_messages_median,
               COALESCE(MAX(COALESCE(tmt.total_messages, 0)), 0) AS topics_created_messages_max
        FROM tmp_interval_topics tin
        LEFT JOIN tmp_topic_message_totals tmt ON tmt.topic_id = tin.id
        GROUP BY tin.interval_start
      ),
      topic_longevity_stats AS (
        SELECT ita.interval_start,
               COALESCE(AVG(tl.longevity_days), 0) AS topic_longevity_avg_days,
               COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tl.longevity_days), 0) AS topic_longevity_median_days,
               COALESCE(MAX(tl.longevity_days), 0) AS topic_longevity_max_days
        FROM tmp_interval_topic_activity ita
        INNER JOIN tmp_topic_longevity tl ON tl.topic_id = ita.topic_id
        GROUP BY ita.interval_start
      )
      SELECT
        ti.interval_start,
        ti.interval_end,
        COALESCE(mbi.participants_active, 0) AS participants_active,
        COALESCE(pc.participants_active_committers, 0) AS participants_active_committers,
        COALESCE(pco.participants_active_contributors, 0) AS participants_active_contributors,
        COALESCE(pn.participants_new, 0) AS participants_new,
        COALESCE(pnl.new_participants_lifetime_avg_days, 0) AS new_participants_lifetime_avg_days,
        COALESCE(pnl.new_participants_lifetime_median_days, 0) AS new_participants_lifetime_median_days,
        COALESCE(pnl.new_participants_lifetime_max_days, 0) AS new_participants_lifetime_max_days,
        COALESCE(npd.new_participants_daily_avg_messages, 0) AS new_participants_daily_avg_messages,
        COALESCE(r365.retained_365_participants, 0) AS retained_365_participants,
        COALESCE(r365l.retained_365_lifetime_avg_days, 0) AS retained_365_lifetime_avg_days,
        COALESCE(r365l.retained_365_lifetime_median_days, 0) AS retained_365_lifetime_median_days,
        COALESCE(r365d.retained_365_daily_avg_messages, 0) AS retained_365_daily_avg_messages,
        COALESCE(nur.new_users_replied_to_others, 0) AS new_users_replied_to_others,
        COALESCE(tn.topics_new, 0) AS topics_new,
        COALESCE(ta.topics_active, 0) AS topics_active,
        COALESCE(tnnp.topics_new_by_new_participants, 0) AS topics_new_by_new_participants,
        COALESCE(tnnu.topics_new_by_new_users, 0) AS topics_new_by_new_users,
        COALESCE(tnau.topics_new_with_attachments_by_new_users, 0) AS topics_new_with_attachments_by_new_users,
        COALESCE(tncon.topics_new_with_contributor_activity, 0) AS topics_new_with_contributor_activity,
        GREATEST(COALESCE(tn.topics_new, 0) - COALESCE(tncon.topics_new_with_contributor_activity, 0), 0) AS topics_new_without_contributor_activity,
        GREATEST(COALESCE(tn.topics_new, 0) - COALESCE(twa.topics_with_attachments, 0), 0) AS topics_new_no_attachments,
        GREATEST(COALESCE(twa.topics_with_attachments, 0) - COALESCE(twc.topics_with_commitfest, 0), 0) AS topics_new_with_attachments_no_commitfest,
        COALESCE(cs.topics_new_commitfest_abandoned, 0) AS topics_new_commitfest_abandoned,
        COALESCE(cs.topics_new_commitfest_committed, 0) AS topics_new_commitfest_committed,
        COALESCE(cs.topics_new_commitfest_in_progress, 0) AS topics_new_commitfest_in_progress,
        COALESCE(mbi.messages_total, 0) AS messages_total,
        COALESCE(mc.messages_committers, 0) AS messages_committers,
        COALESCE(mco.messages_contributors, 0) AS messages_contributors,
        COALESCE(mnp.messages_new_participants, 0) AS messages_new_participants,
        COALESCE(tms.topics_messages_avg, 0) AS topics_messages_avg,
        COALESCE(tms.topics_messages_median, 0) AS topics_messages_median,
        COALESCE(tms.topics_messages_max, 0) AS topics_messages_max,
        COALESCE(tcms.topics_created_messages_avg, 0) AS topics_created_messages_avg,
        COALESCE(tcms.topics_created_messages_median, 0) AS topics_created_messages_median,
        COALESCE(tcms.topics_created_messages_max, 0) AS topics_created_messages_max,
        COALESCE(tls.topic_longevity_avg_days, 0) AS topic_longevity_avg_days,
        COALESCE(tls.topic_longevity_median_days, 0) AS topic_longevity_median_days,
        COALESCE(tls.topic_longevity_max_days, 0) AS topic_longevity_max_days
      FROM tmp_intervals ti
      LEFT JOIN messages_by_interval mbi ON mbi.interval_start = ti.interval_start
      LEFT JOIN participants_committers pc ON pc.interval_start = ti.interval_start
      LEFT JOIN participants_contributors pco ON pco.interval_start = ti.interval_start
      LEFT JOIN messages_committers mc ON mc.interval_start = ti.interval_start
      LEFT JOIN messages_contributors mco ON mco.interval_start = ti.interval_start
      LEFT JOIN participants_new pn ON pn.interval_start = ti.interval_start
      LEFT JOIN messages_new_participants mnp ON mnp.interval_start = ti.interval_start
      LEFT JOIN new_users_replied nur ON nur.interval_start = ti.interval_start
      LEFT JOIN participants_new_lifetime pnl ON pnl.interval_start = ti.interval_start
      LEFT JOIN new_participants_daily_avg npd ON npd.interval_start = ti.interval_start
      LEFT JOIN retained_365 r365 ON r365.interval_start = ti.interval_start
      LEFT JOIN retained_365_lifetime r365l ON r365l.interval_start = ti.interval_start
      LEFT JOIN retained_365_daily_avg r365d ON r365d.interval_start = ti.interval_start
      LEFT JOIN topics_new tn ON tn.interval_start = ti.interval_start
      LEFT JOIN topics_active ta ON ta.interval_start = ti.interval_start
      LEFT JOIN topics_new_by_new_participants tnnp ON tnnp.interval_start = ti.interval_start
      LEFT JOIN topics_new_by_new_users tnnu ON tnnu.interval_start = ti.interval_start
      LEFT JOIN topics_new_with_attachments_by_new_users tnau ON tnau.interval_start = ti.interval_start
      LEFT JOIN topics_new_with_contributor_activity tncon ON tncon.interval_start = ti.interval_start
      LEFT JOIN topics_with_attachments twa ON twa.interval_start = ti.interval_start
      LEFT JOIN topics_with_commitfest twc ON twc.interval_start = ti.interval_start
      LEFT JOIN commitfest_status cs ON cs.interval_start = ti.interval_start
      LEFT JOIN topics_messages_stats tms ON tms.interval_start = ti.interval_start
      LEFT JOIN topics_created_messages_stats tcms ON tcms.interval_start = ti.interval_start
      LEFT JOIN topic_longevity_stats tls ON tls.interval_start = ti.interval_start
      ORDER BY ti.interval_start
    SQL

    @conn.execute(<<~SQL.squish)
      DELETE FROM #{stats_model.table_name}
      WHERE interval_start IN (SELECT interval_start FROM tmp_intervals)
    SQL
    now = Time.current
    payload = rows.map { |row| row.transform_keys(&:to_sym).merge(created_at: now, updated_at: now) }
    stats_model.insert_all!(payload) unless payload.empty?
  end

  def upsert_longevity_histogram
    bucket_values = BUCKETS.map { |entry| "('#{entry[:label]}')" }.join(", ")
    rows = @conn.select_all(<<~SQL.squish)
      WITH buckets(bucket) AS (
        VALUES #{bucket_values}
      ),
      topic_buckets AS (
        SELECT ita.interval_start,
               CASE
                 WHEN tl.longevity_days <= 1 THEN '0-1'
                 WHEN tl.longevity_days <= 7 THEN '2-7'
                 WHEN tl.longevity_days <= 30 THEN '8-30'
                 WHEN tl.longevity_days <= 90 THEN '31-90'
                 WHEN tl.longevity_days <= 180 THEN '91-180'
                 WHEN tl.longevity_days <= 365 THEN '181-365'
                 ELSE '365+'
               END AS bucket
        FROM tmp_interval_topic_activity ita
        INNER JOIN tmp_topic_longevity tl ON tl.topic_id = ita.topic_id
      ),
      counts AS (
        SELECT interval_start, bucket, COUNT(*) AS count
        FROM topic_buckets
        GROUP BY interval_start, bucket
      )
      SELECT
        ti.interval_start,
        ti.interval_end,
        b.bucket,
        COALESCE(c.count, 0) AS count
      FROM tmp_intervals ti
      CROSS JOIN buckets b
      LEFT JOIN counts c
        ON c.interval_start = ti.interval_start
       AND c.bucket = b.bucket
      ORDER BY ti.interval_start, b.bucket
    SQL

    @conn.execute(<<~SQL.squish)
      DELETE FROM #{hist_model.table_name}
      WHERE interval_start IN (SELECT interval_start FROM tmp_intervals)
    SQL
    now = Time.current
    payload = rows.map { |row| row.transform_keys(&:to_sym).merge(created_at: now, updated_at: now) }
    hist_model.insert_all!(payload) unless payload.empty?
  end
end

class RetentionAggregator
  PERIOD_MONTHS = [ 1, 3 ].freeze
  HORIZON_MONTHS = [ 3, 6, 12, 18, 24, 30, 36, 48, 60 ].freeze
  SEGMENTS = [
    { key: "all", reply_filter: false },
    { key: "replied_to_others", reply_filter: true }
  ].freeze

  def initialize(start_date:, end_date:)
    @start_date = start_date.beginning_of_month
    @end_date = end_date.beginning_of_month
    @conn = ActiveRecord::Base.connection
  end

  def run!
    cohort_start = @start_date.to_fs(:db)
    cohort_end = @end_date.to_fs(:db)
    puts "Computing monthly/quarterly retention cohorts from #{cohort_start} to #{cohort_end}..."

    PERIOD_MONTHS.each do |period|
      SEGMENTS.each do |segment|
        StatsRetentionMonthly.where(
          period_months: period,
          segment: segment[:key],
          cohort_start: @start_date..@end_date
        ).delete_all
        StatsRetentionMilestone.where(
          period_months: period,
          segment: segment[:key],
          cohort_start: @start_date..@end_date
        ).delete_all
        rows = @conn.select_all(<<~SQL.squish)
          WITH firsts AS (
            SELECT aliases.person_id, date_trunc('month', MIN(messages.created_at))::date AS cohort_start
            FROM messages
            INNER JOIN aliases ON aliases.id = messages.sender_id
            GROUP BY aliases.person_id
          ),
          cohort_bucketed AS (
            SELECT
              person_id,
              cohort_start,
              CASE
                WHEN #{period} = 3 THEN date_trunc('quarter', cohort_start)::date
                ELSE cohort_start
              END AS cohort_start_bucket
            FROM firsts
          ),
          topic_starters AS (
            SELECT DISTINCT ON (messages.topic_id)
              messages.topic_id,
              aliases.person_id AS starter_person_id
            FROM messages
            INNER JOIN aliases ON aliases.id = messages.sender_id
            ORDER BY messages.topic_id, messages.created_at ASC, messages.id ASC
          ),
          eligible_users AS (
            SELECT DISTINCT cb.person_id, cb.cohort_start_bucket
            FROM cohort_bucketed cb
            #{segment[:reply_filter] ? <<~SQL.squish : ""}
              INNER JOIN aliases a ON a.person_id = cb.person_id
              INNER JOIN messages m ON m.sender_id = a.id
              INNER JOIN topic_starters ts ON ts.topic_id = m.topic_id
              WHERE m.created_at >= cb.cohort_start_bucket
                AND m.created_at < (cb.cohort_start_bucket + interval '#{period} months')
                AND ts.starter_person_id <> cb.person_id
            SQL
            #{segment[:reply_filter] ? "" : "WHERE cb.cohort_start_bucket IS NOT NULL"}
          ),
          cohort_sizes AS (
            SELECT cohort_start_bucket, COUNT(*) AS cohort_size
            FROM eligible_users
            GROUP BY cohort_start_bucket
          ),
          messages_by_month AS (
            SELECT eu.person_id,
                   eu.cohort_start_bucket,
                   date_trunc('month', m.created_at)::date AS msg_month
            FROM messages m
            INNER JOIN aliases a ON a.id = m.sender_id
            INNER JOIN eligible_users eu ON eu.person_id = a.person_id
          ),
          per_person_month AS (
            SELECT
              cohort_start_bucket AS cohort_start,
              (
                (date_part('year', msg_month) - date_part('year', cohort_start_bucket)) * 12 +
                (date_part('month', msg_month) - date_part('month', cohort_start_bucket))
              )::int AS months_since,
              person_id,
              COUNT(*) AS message_count
            FROM messages_by_month
            GROUP BY cohort_start_bucket, months_since, person_id
          ),
          bucketed AS (
            SELECT
              cohort_start,
              (months_since / #{period}) * #{period} AS months_since_bucket,
              person_id,
              SUM(message_count) AS message_count
            FROM per_person_month
            GROUP BY cohort_start, months_since_bucket, person_id
          ),
          aggregated AS (
            SELECT
              cohort_start,
              months_since_bucket AS months_since,
              COUNT(*) AS active_users,
              SUM(message_count) AS total_messages
            FROM bucketed
            GROUP BY cohort_start, months_since
          )
          SELECT
            aggregated.cohort_start,
            aggregated.months_since,
            cohort_sizes.cohort_size,
            aggregated.active_users,
            CASE
              WHEN aggregated.active_users > 0 THEN aggregated.total_messages::float / aggregated.active_users
              ELSE 0
            END AS avg_messages_per_active_user
          FROM aggregated
          INNER JOIN cohort_sizes ON cohort_sizes.cohort_start_bucket = aggregated.cohort_start
          WHERE aggregated.cohort_start BETWEEN '#{cohort_start}' AND '#{cohort_end}'
          ORDER BY aggregated.cohort_start, aggregated.months_since
        SQL

        next if rows.empty?

        now = Time.current
        payload = rows.map do |row|
          {
            cohort_start: row["cohort_start"],
            months_since: row["months_since"].to_i,
            period_months: period,
            segment: segment[:key],
            cohort_size: row["cohort_size"].to_i,
            active_users: row["active_users"].to_i,
            avg_messages_per_active_user: row["avg_messages_per_active_user"].to_f,
            created_at: now,
            updated_at: now
          }
        end
        StatsRetentionMonthly.insert_all!(payload)

        milestone_rows = @conn.select_all(<<~SQL.squish)
          WITH horizons AS (
            #{HORIZON_MONTHS.map { |month| "SELECT #{month} AS horizon_months" }.join(" UNION ALL ")}
          ),
          firsts AS (
            SELECT aliases.person_id, date_trunc('month', MIN(messages.created_at))::date AS cohort_start
            FROM messages
            INNER JOIN aliases ON aliases.id = messages.sender_id
            GROUP BY aliases.person_id
          ),
          cohort_bucketed AS (
            SELECT
              person_id,
              cohort_start,
              CASE
                WHEN #{period} = 3 THEN date_trunc('quarter', cohort_start)::date
                ELSE cohort_start
              END AS cohort_start_bucket
            FROM firsts
          ),
          topic_starters AS (
            SELECT DISTINCT ON (messages.topic_id)
              messages.topic_id,
              aliases.person_id AS starter_person_id
            FROM messages
            INNER JOIN aliases ON aliases.id = messages.sender_id
            ORDER BY messages.topic_id, messages.created_at ASC, messages.id ASC
          ),
          eligible_users AS (
            SELECT DISTINCT cb.person_id, cb.cohort_start_bucket
            FROM cohort_bucketed cb
            #{segment[:reply_filter] ? <<~SQL.squish : ""}
              INNER JOIN aliases a ON a.person_id = cb.person_id
              INNER JOIN messages m ON m.sender_id = a.id
              INNER JOIN topic_starters ts ON ts.topic_id = m.topic_id
              WHERE m.created_at >= cb.cohort_start_bucket
                AND m.created_at < (cb.cohort_start_bucket + interval '#{period} months')
                AND ts.starter_person_id <> cb.person_id
            SQL
            #{segment[:reply_filter] ? "" : "WHERE cb.cohort_start_bucket IS NOT NULL"}
          ),
          cohort_sizes AS (
            SELECT cohort_start_bucket, COUNT(*) AS cohort_size
            FROM eligible_users
            GROUP BY cohort_start_bucket
          ),
          messages_by_month AS (
            SELECT eu.person_id,
                   eu.cohort_start_bucket,
                   date_trunc('month', m.created_at)::date AS msg_month
            FROM messages m
            INNER JOIN aliases a ON a.id = m.sender_id
            INNER JOIN eligible_users eu ON eu.person_id = a.person_id
          ),
          per_person_month AS (
            SELECT
              cohort_start_bucket AS cohort_start,
              (
                (date_part('year', msg_month) - date_part('year', cohort_start_bucket)) * 12 +
                (date_part('month', msg_month) - date_part('month', cohort_start_bucket))
              )::int AS months_since,
              person_id
            FROM messages_by_month
            GROUP BY cohort_start_bucket, months_since, person_id
          ),
          max_activity AS (
            SELECT cohort_start, person_id, MAX(months_since) AS max_months
            FROM per_person_month
            GROUP BY cohort_start, person_id
          )
          SELECT
            cohort_sizes.cohort_start_bucket AS cohort_start,
            horizons.horizon_months,
            cohort_sizes.cohort_size,
            SUM(CASE WHEN max_activity.max_months >= horizons.horizon_months THEN 1 ELSE 0 END) AS retained_users
          FROM cohort_sizes
          LEFT JOIN max_activity ON max_activity.cohort_start = cohort_sizes.cohort_start_bucket
          CROSS JOIN horizons
          WHERE cohort_sizes.cohort_start_bucket BETWEEN '#{cohort_start}' AND '#{cohort_end}'
          GROUP BY cohort_sizes.cohort_start_bucket, horizons.horizon_months, cohort_sizes.cohort_size
          ORDER BY cohort_sizes.cohort_start_bucket, horizons.horizon_months
        SQL

        next if milestone_rows.empty?

        milestone_payload = milestone_rows.map do |row|
          {
            cohort_start: row["cohort_start"],
            horizon_months: row["horizon_months"].to_i,
            period_months: period,
            segment: segment[:key],
            cohort_size: row["cohort_size"].to_i,
            retained_users: row["retained_users"].to_i,
            created_at: now,
            updated_at: now
          }
        end
        StatsRetentionMilestone.insert_all!(milestone_payload)
      end
    end
  end
end

def parse_date(value)
  Date.iso8601(value)
rescue ArgumentError
  nil
end

granularity_arg = ARGV.first
granularity = granularity_arg&.to_sym || :all
from_date = parse_date(ENV["FROM"])
to_date = parse_date(ENV["TO"])

first_message = Message.minimum(:created_at)&.to_date
raise "No messages found" unless first_message

range_start = from_date || first_message
range_end = to_date || Date.current

granularities = case granularity
when :all then [ :daily, :weekly, :monthly ]
when :daily, :weekly, :monthly then [ granularity ]
else
                  raise "Usage: ruby script/build_stats.rb [daily|weekly|monthly|all]"
end

granularities.each do |gran|
  puts "Computing #{gran} stats from #{range_start} to #{range_end}..."
  StatsAggregator.new(granularity: gran, start_date: range_start, end_date: range_end).run!
end

RetentionAggregator.new(start_date: range_start, end_date: range_end).run!
