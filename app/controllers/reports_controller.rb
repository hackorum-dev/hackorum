class ReportsController < ApplicationController
  skip_before_action :require_authentication, raise: false

  RANKING_LIMIT = 10
  ACTIVE_THREADS_LIMIT = 10
  NEWCOMERS_LIMIT = 5

  def index
    if params[:year].present?
      year = params[:year].to_i
      period_type = params[:period_type] || "weekly"
      filter = params[:filter].presence

      if period_type == "monthly" && params[:month].present?
        redirect_to monthly_report_path(year: year, month: params[:month].to_i, filter: filter)
      elsif params[:week].present?
        redirect_to weekly_report_path(year: year, week: params[:week].to_i, filter: filter)
      else
        redirect_to weekly_report_path(year: year, week: 1, filter: filter)
      end
    else
      today = Date.current
      redirect_to weekly_report_path(year: today.cwyear, week: today.cweek)
    end
  end

  def show
    @period_type = params[:period_type]
    @filter = params[:filter].to_s.presence_in(%w[all community contributors]) || "all"

    load_period

    cached_data = Rails.cache.fetch(report_cache_key, expires_in: 1.hour) do
      load_stats
      load_rankings
      load_active_threads
      load_new_contributors
      load_notable_threads
      {
        stats: @stats,
        previous_stats: @previous_stats,
        is_current_period: @is_current_period,
        rankings: @rankings,
        active_threads: @active_threads,
        thread_participants: @thread_participants,
        newcomers: @newcomers,
        newcomer_count: @newcomer_count,
        most_active_thread: @most_active_thread,
        most_diverse_thread: @most_diverse_thread,
        longest_thread: @longest_thread
      }
    end

    @stats = cached_data[:stats]
    @previous_stats = cached_data[:previous_stats]
    @is_current_period = cached_data[:is_current_period]
    @rankings = cached_data[:rankings]
    @active_threads = cached_data[:active_threads]
    @thread_participants = cached_data[:thread_participants]
    @newcomers = cached_data[:newcomers]
    @newcomer_count = cached_data[:newcomer_count]
    @most_active_thread = cached_data[:most_active_thread]
    @most_diverse_thread = cached_data[:most_diverse_thread]
    @longest_thread = cached_data[:longest_thread]

    load_navigation_data
  end

  private

  def report_cache_key
    [
      "reports",
      @period_type,
      @year,
      @period_type == "weekly" ? @week : @month,
      @filter
    ].join("/")
  end

  def load_period
    @year = params[:year].to_i
    if @period_type == "weekly"
      @week = params[:week].to_i
      @period_start = Date.commercial(@year, @week, 1)
      @period_end = @period_start + 6.days
    else
      @month = params[:month].to_i
      @period_start = Date.new(@year, @month, 1)
      @period_end = @period_start.end_of_month
    end
    @period_range = @period_start.beginning_of_day..@period_end.end_of_day
  end

  def load_stats
    @is_current_period = current_period?

    if @is_current_period
      @stats = compute_live_stats
    else
      stats_model = @period_type == "weekly" ? StatsWeekly : StatsMonthly
      @stats = stats_model.find_by(interval_start: @period_start)
    end

    if @period_type == "weekly"
      prev_start = @period_start - 7.days
    else
      prev_start = @period_start - 1.month
    end
    stats_model = @period_type == "weekly" ? StatsWeekly : StatsMonthly
    @previous_stats = stats_model.find_by(interval_start: prev_start)
  end

  def current_period?
    today = Date.current
    if @period_type == "weekly"
      @period_start <= today && @period_end >= today
    else
      @period_start.year == today.year && @period_start.month == today.month
    end
  end

  def compute_live_stats
    messages_total = Message.where(created_at: @period_range).count
    participants_active = Message.where(created_at: @period_range).distinct.count(:sender_person_id)
    topics_new = Topic.where(created_at: @period_range).count

    period_person_ids = Message.where(created_at: @period_range).distinct.pluck(:sender_person_id)
    if period_person_ids.empty?
      participants_new = 0
    else
      first_messages = Message
        .where(sender_person_id: period_person_ids)
        .group(:sender_person_id)
        .minimum(:created_at)
      participants_new = first_messages.count { |_, first_at| @period_range.cover?(first_at) }
    end

    Struct.new(:messages_total, :participants_active, :topics_new, :participants_new)
      .new(messages_total, participants_active, topics_new, participants_new)
  end

  def load_rankings
    @rankings = {
      started_thread: ranking_started_thread,
      replied_own_thread: ranking_replied_own_thread,
      replied_other_thread: ranking_replied_other_thread,
      sent_first_patch: ranking_sent_first_patch,
      sent_followup_patch: ranking_sent_followup_patch
    }
  end

  def ranking_started_thread
    scope = Message.where(created_at: @period_range)
      .joins("INNER JOIN (SELECT topic_id, MIN(id) as first_id FROM messages GROUP BY topic_id) first_msgs ON messages.id = first_msgs.first_id")
    scope = apply_contributor_filter(scope, :sender_person_id)

    person_ids_with_counts = scope
      .group(:sender_person_id)
      .order(Arel.sql("COUNT(*) DESC"))
      .limit(RANKING_LIMIT)
      .pluck(:sender_person_id, Arel.sql("COUNT(*)"))

    build_ranking_entries(person_ids_with_counts)
  end

  def ranking_replied_own_thread
    scope = Message.where(created_at: @period_range)
      .joins(:topic)
      .joins("INNER JOIN (SELECT topic_id, MIN(id) as first_id FROM messages GROUP BY topic_id) first_msgs ON messages.topic_id = first_msgs.topic_id")
      .where("messages.id != first_msgs.first_id")
      .where("messages.sender_person_id = topics.creator_person_id")
    scope = apply_contributor_filter(scope, :sender_person_id)

    person_ids_with_counts = scope
      .group(:sender_person_id)
      .order(Arel.sql("COUNT(*) DESC"))
      .limit(RANKING_LIMIT)
      .pluck(:sender_person_id, Arel.sql("COUNT(*)"))

    build_ranking_entries(person_ids_with_counts)
  end

  def ranking_replied_other_thread
    scope = Message.where(created_at: @period_range)
      .joins(:topic)
      .joins("INNER JOIN (SELECT topic_id, MIN(id) as first_id FROM messages GROUP BY topic_id) first_msgs ON messages.topic_id = first_msgs.topic_id")
      .where("messages.id != first_msgs.first_id")
      .where("messages.sender_person_id != topics.creator_person_id")
    scope = apply_contributor_filter(scope, :sender_person_id)

    person_ids_with_counts = scope
      .group(:sender_person_id)
      .order(Arel.sql("COUNT(*) DESC"))
      .limit(RANKING_LIMIT)
      .pluck(:sender_person_id, Arel.sql("COUNT(*)"))

    build_ranking_entries(person_ids_with_counts)
  end

  def ranking_sent_first_patch
    scope = Message.where(created_at: @period_range)
      .joins(:attachments)
      .joins("INNER JOIN (SELECT m.topic_id, MIN(m.id) as first_patch_id FROM messages m INNER JOIN attachments a ON a.message_id = m.id GROUP BY m.topic_id) first_patches ON messages.id = first_patches.first_patch_id")
    scope = apply_contributor_filter(scope, :sender_person_id)

    person_ids_with_counts = scope
      .group(:sender_person_id)
      .order(Arel.sql("COUNT(DISTINCT messages.id) DESC"))
      .limit(RANKING_LIMIT)
      .pluck(:sender_person_id, Arel.sql("COUNT(DISTINCT messages.id)"))

    build_ranking_entries(person_ids_with_counts)
  end

  def ranking_sent_followup_patch
    scope = Message.where(created_at: @period_range)
      .joins(:attachments)
      .joins("INNER JOIN (SELECT m.topic_id, MIN(m.id) as first_patch_id FROM messages m INNER JOIN attachments a ON a.message_id = m.id GROUP BY m.topic_id) first_patches ON messages.topic_id = first_patches.topic_id")
      .where("messages.id != first_patches.first_patch_id")
    scope = apply_contributor_filter(scope, :sender_person_id)

    person_ids_with_counts = scope
      .group(:sender_person_id)
      .order(Arel.sql("COUNT(DISTINCT messages.id) DESC"))
      .limit(RANKING_LIMIT)
      .pluck(:sender_person_id, Arel.sql("COUNT(DISTINCT messages.id)"))

    build_ranking_entries(person_ids_with_counts)
  end

  def build_ranking_entries(person_ids_with_counts)
    return [] if person_ids_with_counts.empty?

    person_ids = person_ids_with_counts.map(&:first)
    people = Person.includes(:default_alias, :contributor_memberships).where(id: person_ids).index_by(&:id)

    person_ids_with_counts.map.with_index do |(person_id, count), index|
      person = people[person_id]
      next unless person

      {
        rank: index + 1,
        person: person,
        count: count
      }
    end.compact
  end

  def load_active_threads
    scope = Topic.joins(:messages)
      .where(messages: { created_at: @period_range })
      .group("topics.id")
      .select(
        "topics.*",
        "COUNT(messages.id) as period_messages",
        "COUNT(DISTINCT messages.sender_person_id) as period_participants",
        "MAX(messages.created_at) as last_activity_at"
      )
      .order("period_messages DESC")
      .limit(ACTIVE_THREADS_LIMIT)

    case @filter
    when "community"
      contributor_ids = contributor_person_ids
      scope = scope.where.not(messages: { sender_person_id: contributor_ids }) if contributor_ids.any?
    when "contributors"
      contributor_ids = contributor_person_ids
      scope = scope.where(messages: { sender_person_id: contributor_ids }) if contributor_ids.any?
    end

    @active_threads = scope.to_a

    if @active_threads.any?
      thread_ids = @active_threads.map(&:id)
      @thread_participants = TopicParticipant
        .where(topic_id: thread_ids)
        .includes(person: :default_alias)
        .group_by(&:topic_id)
    else
      @thread_participants = {}
    end
  end

  def load_new_contributors
    period_person_ids = Message.where(created_at: @period_range).distinct.pluck(:sender_person_id)
    return @newcomers = [], @newcomer_count = 0 if period_person_ids.empty?

    first_messages = Message
      .where(sender_person_id: period_person_ids)
      .group(:sender_person_id)
      .minimum(:created_at)

    newcomer_ids = first_messages.select { |_, first_at| @period_range.cover?(first_at) }.keys
    return @newcomers = [], @newcomer_count = 0 if newcomer_ids.empty?

    @newcomer_count = newcomer_ids.size

    person_ids_with_counts = Message
      .where(sender_person_id: newcomer_ids, created_at: @period_range)
      .group(:sender_person_id)
      .order(Arel.sql("COUNT(*) DESC"))
      .limit(NEWCOMERS_LIMIT)
      .pluck(:sender_person_id, Arel.sql("COUNT(*)"))

    @newcomers = build_ranking_entries(person_ids_with_counts)
  end

  def load_notable_threads
    @most_active_thread = Topic.joins(:messages)
      .where(messages: { created_at: @period_range })
      .group("topics.id")
      .select("topics.*, COUNT(messages.id) as period_messages")
      .order("period_messages DESC")
      .first

    @most_diverse_thread = Topic.joins(:messages)
      .where(messages: { created_at: @period_range })
      .group("topics.id")
      .select("topics.*, COUNT(DISTINCT messages.sender_person_id) as period_participants")
      .order("period_participants DESC")
      .first

    @longest_thread = Topic.joins(:messages)
      .where(messages: { created_at: @period_range })
      .group("topics.id")
      .select(
        "topics.*",
        "COUNT(DISTINCT DATE(messages.created_at)) as active_days"
      )
      .order("active_days DESC")
      .first
  end

  def load_navigation_data
    stats_model = @period_type == "weekly" ? StatsWeekly : StatsMonthly
    @available_years = stats_model.distinct.pluck(Arel.sql("EXTRACT(YEAR FROM interval_start)")).map(&:to_i).sort.reverse
  end

  def apply_contributor_filter(scope, person_column)
    case @filter
    when "community"
      contributor_ids = contributor_person_ids
      scope = scope.where.not(person_column => contributor_ids) if contributor_ids.any?
    when "contributors"
      contributor_ids = contributor_person_ids
      scope = scope.where(person_column => contributor_ids) if contributor_ids.any?
    end
    scope
  end

  def contributor_person_ids
    @contributor_person_ids ||= ContributorMembership.distinct.pluck(:person_id)
  end
end
