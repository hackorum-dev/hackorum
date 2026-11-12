module Api
  # The change feed: the events after a position, oldest first.
  # A position is a feed_events id. Ids are given at insert and seen at
  # commit, so the feed ends at the horizon: the newest row older than
  # HOLD_BACK with no younger row below it. Rows are inserted in a
  # transaction of their own, which commits well within HOLD_BACK.
  # Ages are measured on the clock that stamped created_at, the database's.
  class EventFeed
    class Expired < StandardError; end

    HOLD_BACK = 5.seconds
    RETENTION = 90.days
    DEFAULT_SINCE = "24h".freeze
    CI_RUNS = %w[changed all].freeze
    # changed: without the runs that repeat the verdict the branch had before
    DEFAULT_CI_RUNS = "changed".freeze
    DURATION = /\A(\d{1,6})([mhd])\z/
    UNITS = { "m" => 1.minute, "h" => 1.hour, "d" => 1.day }.freeze
    TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})\z/
    SIGNATURE = Digest::SHA256.hexdigest("events feed_events.id asc").first(8).freeze
    MAX_ID = 2**63 - 1
    MAX_SINCE = 100
    TOPIC_ID = PatchCi::BranchQuery::TOPIC_ID
    SINCE_HELP = "since must be a cursor of this feed, an ISO 8601 timestamp with Z or an offset, " \
                 "or a duration like 90m, 12h, 7d".freeze

    # the start of the statement on the database clock: stable, so an index can be searched with it
    NOW = "(statement_timestamp() AT TIME ZONE 'UTC')".freeze
    CUTOFF = "#{NOW} - interval '#{HOLD_BACK.to_i} seconds'".freeze

    # the record of an event is there, and is one the API shows
    # scalar subqueries: an EXISTS here is hashed, which reads both tables whole for one page
    SUBJECT = <<~SQL.squish.freeze
      (feed_events.event_type <> '#{FeedEvent::PATCHSET_POSTED}' OR messages.is_patch_submission)
      AND (feed_events.event_type NOT IN ('#{FeedEvent::BRANCH_CREATED}', '#{FeedEvent::CI_COMPLETED}')
           OR (SELECT NOT patch_branches.lineage_only FROM patch_branches
               WHERE patch_branches.id = feed_events.patch_branch_id))
    SQL

    # id + 0: the rows asked for are the newest, a scan in id order would read all the others first
    YOUNGEST = "SELECT MIN(id + 0) FROM feed_events WHERE created_at > #{CUTOFF}".freeze
    BOUNDS = <<~SQL.squish.freeze
      SELECT
        (SELECT MAX(id) FROM feed_events
          WHERE created_at <= #{CUTOFF} AND id < COALESCE((#{YOUNGEST}), #{MAX_ID})),
        (SELECT MIN(id) FROM feed_events)
    SQL
    FIRST = "SELECT MIN(id + 0) FROM feed_events WHERE created_at >= %s".freeze
    AGO = "#{NOW} - make_interval(secs => ?)".freeze
    AT = "?::timestamp".freeze

    Page = Struct.new(:events, :next_cursor, :has_more)

    attr_reader :limit

    def self.encode(position)
      Base64.urlsafe_encode64([ SIGNATURE, position ].to_json, padding: false)
    end

    def initialize(since: nil, types: nil, topic: nil, author: nil, list: nil,
                   starred: false, participating: false, user: nil, ci_runs: nil, limit: nil)
      @limit = CursorPaginator.parse_limit(limit)
      @cursor, @from = parse_since(since.presence || DEFAULT_SINCE)
      @relation = filtered(types: types, topic: topic, author: author, list: list,
                           starred: starred, participating: participating, user: user)
      @relation = @relation.where("feed_events.verdict_changed IS NOT FALSE") if parse_ci_runs(ci_runs) == "changed"
    end

    def page
      horizon, oldest, first = bounds
      position = start(horizon, oldest, first)
      return Page.new([], self.class.encode(position), false) if position >= horizon

      rows = @relation.where(id: (position + 1)..horizon).order(:id).limit(limit + 1).to_a
      more = rows.size > limit
      rows = rows.first(limit)
      Page.new(rows, self.class.encode(more ? rows.last.id : horizon), more)
    end

    private

    def parse_since(value)
      raise InvalidParameter, SINCE_HELP if value.length > MAX_SINCE

      if (duration = DURATION.match(value))
        length = duration[1].to_i * UNITS.fetch(duration[2])
        raise InvalidParameter, "since can go back #{RETENTION.in_days.to_i} days at most" if length > RETENTION
        [ nil, [ AGO, length.to_i ] ]
      elsif TIMESTAMP.match?(value)
        from = timestamp(value)
        raise Expired if from < RETENTION.ago
        [ nil, [ AT, from.utc ] ]
      else
        [ decode(value), nil ]
      end
    end

    def timestamp(value)
      Time.iso8601(value)
    rescue ArgumentError
      raise InvalidParameter, SINCE_HELP
    end

    def decode(cursor)
      signature, position, *rest = JSON.parse(Base64.urlsafe_decode64(cursor).force_encoding(Encoding::UTF_8))
      valid = signature == SIGNATURE && rest.empty? && position.is_a?(Integer) && position.between?(0, MAX_ID)
      raise InvalidParameter, SINCE_HELP unless valid

      position
    rescue ArgumentError, TypeError, JSON::ParserError
      raise InvalidParameter, SINCE_HELP
    end

    # [ horizon, oldest id, first id at or after the time asked for ]
    def bounds
      sql = BOUNDS
      sql = "#{sql}, (#{format(FIRST, FeedEvent.sanitize_sql(@from))})" if @from
      horizon, oldest, first = FeedEvent.lease_connection.select_rows(sql, "FeedEvent Bounds").first
      [ horizon || 0, oldest, first ]
    end

    def start(horizon, oldest, first)
      if @cursor
        # position 0 is from a table with nothing to show yet, ids need not start at 1
        raise Expired if @cursor.positive? && oldest && @cursor < oldest - 1
        @cursor
      else
        first ? [ first - 1, horizon ].min : horizon
      end
    end

    def filtered(types:, topic:, author:, list:, starred:, participating:, user:)
      relation = FeedEvent.joins(:message).where(SUBJECT)
                          .select(FeedEvent.arel_table[Arel.star], "messages.topic_id AS current_topic_id")
      relation = relation.where(event_type: parse_types(types)) if types
      relation = relation.where(messages: { topic_id: current_topic(topic) }) if topic
      relation = by_author(relation, author) if author
      relation = list ? on_list(relation, list) : relation.where(messages: { topic_id: Topic.shown_by_default.select(:id) })
      relation = relation.where(messages: { topic_id: TopicStar.where(user_id: user.id).select(:topic_id) }) if starred
      relation = relation.where(messages: { topic_id: participations(user) }) if participating
      relation
    end

    def parse_types(value)
      names = value.split(",", -1)
      unless names.any? && (names - FeedEvent::TYPES).empty?
        raise InvalidParameter, "types must be a comma-separated list of: #{FeedEvent::TYPES.join(', ')}"
      end

      names.uniq
    end

    def parse_ci_runs(value)
      return DEFAULT_CI_RUNS if value.nil?
      raise InvalidParameter, "ci_runs must be one of: #{CI_RUNS.join(', ')}" unless CI_RUNS.include?(value)

      value
    end

    # a merged thread stands for the one that has its messages now
    def current_topic(value)
      raise InvalidParameter, "topic must be a numeric topic id" unless value.match?(TOPIC_ID)

      Topic.find_by(id: value)&.final_topic&.id || value.to_i
    end

    def by_author(relation, email)
      person = Person.find_by_email(email) unless email.include?("\0")
      person ? relation.where(author_person_id: person.id) : relation.none
    end

    def on_list(relation, identifier)
      list = MailingList.find_by(identifier: identifier) unless identifier.include?("\0")
      raise InvalidParameter, "list is not a mailing list identifier" unless list

      relation.where(messages: { topic_id: TopicMailingList.where(mailing_list_id: list.id).select(:topic_id) })
    end

    def participations(user)
      TopicParticipant.where(person_id: user.person_id).select(:topic_id)
    end
  end
end
