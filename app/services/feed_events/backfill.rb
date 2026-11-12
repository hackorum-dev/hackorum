module FeedEvents
  # Adds the events the feed lacks, from the records, each at the time it
  # happened. When the ids then do not follow created_at, every row gets a
  # new id above the old ones in that order, so a position handed out
  # before answers 410. A run that died part way is finished by the next one.
  class Backfill
    MAX_DAYS = Api::EventFeed::RETENTION.in_days.to_i
    SLICE = 1.day

    Result = Struct.new(:from, :to, :added, :renumbered, :dry_run, keyword_init: true)

    COLUMNS = "event_type, occurred_at, created_at, message_id, patch_branch_id, patch_ci_run_id, " \
              "author_person_id, first_run, previous_status, verdict_changed".freeze
    TERMINAL = PatchCiRun::TERMINAL_STATUSES.map { |status| "'#{status}'" }.join(", ").freeze

    # finished runs with the verdict of the one before them on the branch, as the recorder reads it
    RUNS = <<~SQL.squish.freeze
      SELECT id, patch_branch_id, status, COALESCE(completed_at, updated_at) AS at,
             ROW_NUMBER() OVER branch = 1 AS first_run, LAG(status) OVER branch AS previous_status
      FROM patch_ci_runs
      WHERE status IN (#{TERMINAL})
      WINDOW branch AS (PARTITION BY patch_branch_id ORDER BY created_at, id)
    SQL

    MISSING = <<~SQL.squish.freeze
      SELECT '#{FeedEvent::MESSAGE_RECEIVED}' AS event_type, 0 AS step, m.created_at AS at, m.id AS source_id,
             m.id AS message_id, NULL::bigint AS patch_branch_id, NULL::bigint AS patch_ci_run_id,
             m.sender_person_id AS author_person_id, NULL::boolean AS first_run, NULL::varchar AS previous_status,
             NULL::boolean AS verdict_changed
      FROM messages m
      WHERE m.created_at >= :from AND m.created_at < :to
        AND NOT EXISTS (SELECT 1 FROM feed_events f
                        WHERE f.message_id = m.id AND f.event_type = '#{FeedEvent::MESSAGE_RECEIVED}'
                          AND f.patch_branch_id IS NULL AND f.patch_ci_run_id IS NULL)
      UNION ALL
      SELECT '#{FeedEvent::PATCHSET_POSTED}', 1, m.created_at, m.id, m.id, NULL, NULL, m.sender_person_id,
             NULL, NULL, NULL
      FROM messages m
      WHERE m.is_patch_submission AND m.created_at >= :from AND m.created_at < :to
        AND NOT EXISTS (SELECT 1 FROM feed_events f
                        WHERE f.message_id = m.id AND f.event_type = '#{FeedEvent::PATCHSET_POSTED}'
                          AND f.patch_branch_id IS NULL AND f.patch_ci_run_id IS NULL)
      UNION ALL
      SELECT '#{FeedEvent::BRANCH_CREATED}', 2, b.created_at, b.id, m.id, b.id, NULL, m.sender_person_id,
             NULL, NULL, NULL
      FROM patch_branches b
      JOIN messages m ON m.id = b.message_id
      WHERE NOT b.lineage_only AND b.created_at >= :from AND b.created_at < :to
        AND NOT EXISTS (SELECT 1 FROM feed_events f
                        WHERE f.patch_branch_id = b.id AND f.event_type = '#{FeedEvent::BRANCH_CREATED}'
                          AND f.patch_ci_run_id IS NULL)
      UNION ALL
      SELECT '#{FeedEvent::CI_COMPLETED}', 3, r.at, r.id, m.id, b.id, r.id, m.sender_person_id,
             r.first_run, r.previous_status, r.previous_status IS DISTINCT FROM r.status
      FROM (#{RUNS}) r
      JOIN patch_branches b ON b.id = r.patch_branch_id
      JOIN messages m ON m.id = b.message_id
      WHERE r.at >= :from AND r.at < :to
        AND NOT EXISTS (SELECT 1 FROM feed_events f
                        WHERE f.patch_ci_run_id = r.id AND f.event_type = '#{FeedEvent::CI_COMPLETED}')
    SQL

    COUNT = "SELECT event_type, COUNT(*), MIN(at) FROM (#{MISSING}) missing GROUP BY event_type".freeze

    INSERT = <<~SQL.squish.freeze
      WITH added AS (
        INSERT INTO feed_events (#{COLUMNS})
        SELECT event_type, at, at, message_id, patch_branch_id, patch_ci_run_id, author_person_id,
               first_run, previous_status, verdict_changed
        FROM (#{MISSING}) missing
        ORDER BY at, step, source_id
        ON CONFLICT DO NOTHING
        RETURNING event_type
      )
      SELECT event_type, COUNT(*) FROM added GROUP BY event_type
    SQL

    SEQUENCE = "pg_get_serial_sequence('feed_events', 'id')".freeze

    OUT_OF_ORDER = <<~SQL.squish.freeze
      SELECT EXISTS (
        SELECT 1 FROM (SELECT created_at, LAG(created_at) OVER (ORDER BY id) AS before FROM feed_events) ordered
        WHERE created_at < before
      )
    SQL

    # the new ids are all above the old ones: no row takes an id another still has
    RENUMBER = <<~SQL.squish.freeze
      UPDATE feed_events SET id = :base + ordered.position
      FROM (SELECT id, ROW_NUMBER() OVER (ORDER BY created_at, id) AS position FROM feed_events) ordered
      WHERE feed_events.id = ordered.id
    SQL

    def initialize(days: MAX_DAYS, dry_run: false, now: Time.current)
      raise ArgumentError, "days must be between 1 and #{MAX_DAYS}" unless days.is_a?(Integer) && days.between?(1, MAX_DAYS)

      @now = now
      @from = now - days.days
      @dry_run = dry_run
    end

    def call(&progress)
      added, renumbered = @dry_run ? preview : [ insert(&progress), renumber ]
      Result.new(from: @from, to: @now, added: added, renumbered: renumbered, dry_run: @dry_run)
    end

    private

    def insert
      total = Hash.new(0)
      slices do |start, finish|
        counts = rows(INSERT, start, finish).to_h
        total.merge!(counts) { |_, sum, count| sum + count }
        yield start, counts if block_given?
      end
      total.to_h
    end

    def renumber
      FeedEvent.transaction do
        connection.execute("LOCK TABLE feed_events IN SHARE ROW EXCLUSIVE MODE")
        next 0 unless connection.select_value(OUT_OF_ORDER)

        # one id stays unused: the position just below the first row has to expire with the others
        base = connection.select_value("SELECT nextval(#{SEQUENCE})")
        moved = connection.exec_update(FeedEvent.sanitize_sql([ RENUMBER, { base: base } ]), "FeedEvent Renumber")
        connection.select_value("SELECT setval(#{SEQUENCE}, #{base + moved})") if moved.positive?
        moved
      end
    end

    # [ what a run would add, how many rows it would renumber ]
    def preview
      missing = rows(COUNT, @from, @now)
      added = missing.to_h { |type, count, _| [ type, count ] }
      earliest = missing.filter_map(&:last).min
      newest = FeedEvent.maximum(:created_at)
      disorder = connection.select_value(OUT_OF_ORDER) || (earliest && newest && earliest < newest)
      [ added, disorder ? FeedEvent.count + added.values.sum : 0 ]
    end

    def slices
      from = @from
      while from < @now
        finish = [ from + SLICE, @now ].min
        yield from, finish
        from = finish
      end
    end

    def rows(sql, from, to)
      connection.select_rows(FeedEvent.sanitize_sql([ sql, { from: from, to: to } ]), "FeedEvent Backfill")
    end

    def connection
      FeedEvent.lease_connection
    end
  end
end
