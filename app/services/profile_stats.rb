# frozen_string_literal: true

class ProfileStats
  # Discussion: trailer linking commits to threads barely existed before this.
  # Threads older than this can basically never land, so the ratio excludes them.
  COMMIT_LINK_ERA_START = Date.new(2017, 1, 1)

  # Profile breakdown drops tested_by: barely used, clutters the band.
  # The commit sidebar keeps showing it via CommitPerson::DISPLAY_ORDER.
  PROFILE_ROLE_ORDER = (CommitPerson::DISPLAY_ORDER - %w[tested_by]).freeze

  LANDED_ROLES = %w[author committer].freeze

  STARTED_THREAD_STATS_SQL = <<~SQL.squish
    SELECT
      COUNT(*) FILTER (WHERE NOT topics.hidden_by_default) AS started,
      COUNT(*) FILTER (WHERE topics.hidden_by_default) AS started_hidden,
      COUNT(*) FILTER (WHERE NOT topics.hidden_by_default AND topics.message_count = 1) AS no_reply,
      percentile_cont(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (COALESCE(topics.last_message_at, topics.created_at) - topics.created_at))
      ) FILTER (WHERE NOT topics.hidden_by_default) AS median_lifetime_seconds
    FROM topics
    WHERE topics.creator_person_id IN (:ids)
  SQL

  DEFAULT_SOURCES = %w[parsed].freeze

  def initialize(person_ids, sources: DEFAULT_SOURCES)
    @person_ids = Array(person_ids)
    @sources = Array(sources)
  end

  def messages_sent        = message_totals[:count]
  def messages_sent_hidden = message_totals[:hidden]
  def first_message_at     = message_totals[:first_at]
  def last_message_at      = message_totals[:last_at]

  def years_active
    return 0 unless first_message_at

    ((last_message_at - first_message_at) / 1.year).floor
  end

  def threads_joined        = thread_participation[false]
  def threads_joined_hidden = thread_participation[true]

  def patches_sent = patch_counts[0]

  def patch_threads = patch_counts[1]

  # Denominator for the landed ratio only: patch_threads above stays all-time.
  def patch_threads_since_era = patch_counts[2]

  def landed_patch_threads
    @landed_patch_threads ||=
      if patch_threads_since_era.zero?
        0
      else
        CommitTopic.trailer.where(topic_id: patch_message_scope.select(:topic_id))
                   .joins(:topic)
                   .joins(commit: :commit_people)
                   .where(commit_people: { person_id: @person_ids, role: LANDED_ROLES, source: @sources })
                   .where(topics: { created_at: COMMIT_LINK_ERA_START.. })
                   .distinct
                   .count(:topic_id)
      end
  end

  def landed_patch_rate
    return 0 if patch_threads_since_era.zero?

    (landed_patch_threads * 100.0 / patch_threads_since_era).round
  end

  # Distinct commits, not the sum of the roles: one commit routinely credits the
  # same person as both author and committer, and a team can have several members
  # on one commit. The role numbers below can and do sum to more than this.
  #
  # Master only: a change backported to N stable branches is N extra commit rows
  # for the same change, which would otherwise inflate this by N. See
  # backport_credits for a separate count of the backports themselves.
  def commit_credits_total
    @commit_credits_total ||=
      if @person_ids.empty?
        0
      else
        CommitPerson.where(source: @sources).joins(:commit).merge(Commit.on_master)
                    .where(person_id: @person_ids).distinct.count(:commit_id)
      end
  end

  def commit_credits_by_role
    @commit_credits_by_role ||= begin
      counts = @person_ids.empty? ? {} : CommitPerson.where(source: @sources).joins(:commit).merge(Commit.on_master)
                                                      .where(person_id: @person_ids).group(:role).count
      PROFILE_ROLE_ORDER.index_with { |role| counts[role].to_i }
    end
  end

  def committer_reviewer_credits
    @committer_reviewer_credits ||=
      if @person_ids.empty? || !@sources.include?(CommitterReviewer::SOURCE)
        0
      else
        CommitPerson.committer_sourced.joins(:commit).merge(Commit.on_master)
                    .where(person_id: @person_ids, role: "reviewer").distinct.count(:commit_id)
      end
  end

  # Backported commits credited as author only - not reviews or any other role.
  def backport_credits
    @backport_credits ||=
      if @person_ids.empty?
        0
      else
        CommitPerson.where(source: @sources).joins(:commit).merge(Commit.backports)
                    .where(person_id: @person_ids, role: "author").distinct.count(:commit_id)
      end
  end

  def threads_started        = started_thread_stats[:started]
  def threads_started_hidden = started_thread_stats[:started_hidden]

  def threads_without_reply = started_thread_stats[:no_reply]

  def median_thread_lifetime_days
    seconds = started_thread_stats[:median_lifetime_seconds]
    return nil if seconds.nil?

    (seconds / 1.day).round(2)
  end

  def longest_running_thread
    return @longest_running_thread if defined?(@longest_running_thread)

    @longest_running_thread = started_topics
      .order(Arel.sql("COALESCE(topics.last_message_at, topics.created_at) - topics.created_at DESC, topics.id ASC"))
      .first
  end

  def longest_running_thread_days
    topic = longest_running_thread
    return nil unless topic

    ((topic.last_message_at || topic.created_at) - topic.created_at) / 1.day
  end

  def most_participants_thread
    return @most_participants_thread if defined?(@most_participants_thread)

    @most_participants_thread = started_topics.order(participant_count: :desc, id: :asc).first
  end

  def most_messages_thread
    return @most_messages_thread if defined?(@most_messages_thread)

    @most_messages_thread = started_topics.order(message_count: :desc, id: :asc).first
  end

  private

  def started_thread_stats
    @started_thread_stats ||=
      if @person_ids.empty?
        { started: 0, started_hidden: 0, no_reply: 0, median_lifetime_seconds: nil }
      else
        sql = ActiveRecord::Base.sanitize_sql_array([ STARTED_THREAD_STATS_SQL, { ids: @person_ids } ])
        row = ActiveRecord::Base.connection.select_one(sql)
        {
          started: row["started"].to_i,
          started_hidden: row["started_hidden"].to_i,
          no_reply: row["no_reply"].to_i,
          median_lifetime_seconds: row["median_lifetime_seconds"]&.to_f
        }
      end
  end

  def started_topics
    return Topic.none if @person_ids.empty?

    Topic.where(creator_person_id: @person_ids).shown_by_default
         .select(:id, :title, :created_at, :last_message_at, :participant_count, :message_count)
  end

  def thread_participation
    @thread_participation ||=
      if @person_ids.empty?
        Hash.new(0)
      else
        Hash.new(0).merge(
          TopicParticipant.joins(:topic).where(person_id: @person_ids)
                          .group("topics.hidden_by_default").distinct.count(:topic_id)
        )
      end
  end

  def message_totals
    @message_totals ||=
      if @person_ids.empty?
        { count: 0, hidden: 0, first_at: nil, last_at: nil }
      else
        count, hidden, first_at, last_at = Message.joins(:topic).where(sender_person_id: @person_ids)
          .pick(Arel.sql("COUNT(*) FILTER (WHERE NOT topics.hidden_by_default), " \
                         "COUNT(*) FILTER (WHERE topics.hidden_by_default), " \
                         "MIN(messages.created_at), MAX(messages.created_at)"))
        { count: count, hidden: hidden, first_at: first_at, last_at: last_at }
      end
  end

  def patch_message_scope
    Message.where(sender_person_id: @person_ids, is_patch_submission: true)
  end

  def patch_counts
    @patch_counts ||=
      if @person_ids.empty?
        [ 0, 0, 0 ]
      else
        sql = ActiveRecord::Base.sanitize_sql_array([
          "COUNT(*), COUNT(DISTINCT messages.topic_id), " \
          "COUNT(DISTINCT messages.topic_id) FILTER (WHERE topics.created_at >= ?)",
          COMMIT_LINK_ERA_START
        ])
        patch_message_scope.joins(:topic).pick(Arel.sql(sql))
      end
  end
end
