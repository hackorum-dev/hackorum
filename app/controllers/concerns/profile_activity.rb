module ProfileActivity
  extend ActiveSupport::Concern
  include ProfilePeriodParams

  ALL_ACTIVITY_FILTERS = %w[started_thread replied_own_thread replied_other_thread sent_first_patch sent_followup_patch].freeze

  # Requires from the includer: #activity_person_ids returning a Person id,
  # an array of ids or a Set of ids.

  private

  def person_ids_for_query
    ids = activity_person_ids
    ids.is_a?(Set) ? ids.to_a : ids
  end

  def load_activity_data(period:)
    @week_start_day = parse_week_start_day
    @activity_filters = parse_activity_filters
    @activity_period = period.to_h

    # classify once, derive both the table rows and the summary tally from
    # the same pass - the summary is unfiltered, so its classification is
    # byte-identical to the entries' classification before the filter is applied
    classified_entries = build_activity_entries(scope: messages_scope_for(period))
    @activity_summary = summarize_activity_entries(classified_entries)
    @activity_entries = filter_activity_entries(classified_entries, @activity_filters)

    @contribution_years = contribution_years
    @contribution_year = calendar_year_for(period, @contribution_years)
    @contribution_weeks, @contribution_month_spans = build_contribution_weeks(@contribution_year, filters: @activity_filters)
    @weekday_labels = WeekCalculation.weekday_labels(@week_start_day)
  end

  # The recent window keeps an open upper bound: a message written moments ago
  # must show up without depending on how end_of_day rounds.
  def messages_scope_for(period)
    ids = person_ids_for_query
    return Message.where(sender_person_id: ids, created_at: period.start_date.beginning_of_day..) if period.recent?

    Message.where(sender_person_id: ids, created_at: period.time_range)
  end

  # Any explicit period pins the calendar to its own year. Only the open-ended
  # "recent" default leaves the year free for the year buttons to pick.
  def calendar_year_for(period, years)
    return period.year unless period.recent?

    requested = params[:year].presence&.to_i
    return requested if requested && years.include?(requested)

    years.first || Date.current.year
  end

  # Fully classified, unfiltered entries. Both the table (after filtering,
  # see filter_activity_entries) and the summary (see summarize_activity_entries)
  # are derived from this single pass, so a profile load classifies every
  # message once rather than twice.
  def build_activity_entries(scope:)
    ids = person_ids_for_query
    return [] if ids.blank?

    messages = scope.includes(:topic, :sender, sender_person: :default_alias)
                    .order(created_at: :desc)

    return [] if messages.empty?

    topic_ids = messages.map(&:topic_id).uniq
    first_message_per_topic = Message.where(topic_id: topic_ids).group(:topic_id).minimum(:id)
    first_patch_per_topic = Message.where(topic_id: topic_ids, is_patch_submission: true).group(:topic_id).minimum(:id)
    own_topic_ids = Topic.where(id: topic_ids, creator_person_id: ids).pluck(:id).to_set

    messages.filter_map do |message|
      topic = message.topic
      next unless topic

      activity_types = compute_activity_types(
        message: message,
        topic: topic,
        first_message_per_topic: first_message_per_topic,
        first_patch_per_topic: first_patch_per_topic,
        own_topic_ids: own_topic_ids
      )

      {
        message: message,
        topic: topic,
        sent_at: message.created_at,
        activity_types: activity_types
      }
    end
  end

  def filter_activity_entries(entries, filters)
    filter_symbols = filters&.map(&:to_sym)&.to_set
    return entries if filter_symbols.blank?

    entries.select { |e| (e[:activity_types].to_set & filter_symbols).any? }
  end

  # Deliberately unfiltered: the boxes are a stable frame of reference for the
  # period, so "0 started" reads as "none in this window" rather than "none
  # matching the current filters". The filters still drive the table and the
  # contributions calendar.
  def summarize_activity_entries(entries)
    summary = empty_activity_summary
    replied_other_topic_ids = Set.new

    entries.each do |entry|
      summary[:total] += 1
      entry[:activity_types].each { |type| summary[type] += 1 }
      replied_other_topic_ids << entry[:topic].id if entry[:activity_types].include?(:replied_other_thread)
    end

    summary[:replied_other_topics] = replied_other_topic_ids.size
    summary
  end

  def empty_activity_summary
    {
      total: 0,
      started_thread: 0,
      replied_own_thread: 0,
      replied_other_thread: 0,
      replied_other_topics: 0,
      sent_first_patch: 0,
      sent_followup_patch: 0
    }
  end

  def compute_activity_types(message:, topic:, first_message_per_topic:, first_patch_per_topic:, own_topic_ids:)
    is_first_message = first_message_per_topic[topic.id] == message.id
    is_own_thread = own_topic_ids.include?(topic.id)
    has_patch = message.is_patch_submission?

    activity_types = []

    if is_first_message
      activity_types << :started_thread
    elsif is_own_thread
      activity_types << :replied_own_thread
    else
      activity_types << :replied_other_thread
    end

    if has_patch
      first_patch_id = first_patch_per_topic[topic.id]
      if message.id == first_patch_id
        activity_types << :sent_first_patch
      else
        activity_types << :sent_followup_patch
      end
    end

    activity_types
  end

  def build_contribution_weeks(year, filters: nil)
    ids = person_ids_for_query
    return [ [], [] ] if ids.blank?

    wday_start = @week_start_day || WeekCalculation::DEFAULT_WEEK_START
    start_date, end_date = WeekCalculation.year_weeks_range(year.to_i, wday_start)
    counts = build_filtered_contribution_counts(start_date, end_date, filters)

    ContributionCalendar.build(counts, year, wday_start)
  end

  def build_filtered_contribution_counts(start_date, end_date, filters)
    ids = person_ids_for_query
    filter_symbols = filters&.map(&:to_sym)&.to_set

    if filter_symbols.nil? || filter_symbols.size == ALL_ACTIVITY_FILTERS.size
      return Message.where(sender_person_id: ids, created_at: start_date.beginning_of_day..end_date.end_of_day)
                    .group(Arel.sql("DATE(messages.created_at)"))
                    .count
    end

    messages = Message.where(sender_person_id: ids, created_at: start_date.beginning_of_day..end_date.end_of_day)
                      .includes(:topic)

    return {} if messages.empty?

    topic_ids = messages.map(&:topic_id).uniq
    first_message_per_topic = Message.where(topic_id: topic_ids).group(:topic_id).minimum(:id)
    first_patch_per_topic = Message.where(topic_id: topic_ids, is_patch_submission: true).group(:topic_id).minimum(:id)
    own_topic_ids = Topic.where(id: topic_ids, creator_person_id: ids).pluck(:id).to_set

    counts = Hash.new(0)
    messages.each do |message|
      topic = message.topic
      next unless topic

      activity_types = compute_activity_types(
        message: message,
        topic: topic,
        first_message_per_topic: first_message_per_topic,
        first_patch_per_topic: first_patch_per_topic,
        own_topic_ids: own_topic_ids
      )

      if (activity_types.to_set & filter_symbols).any?
        counts[message.created_at.to_date] += 1
      end
    end

    counts
  end

  def contribution_years
    ids = person_ids_for_query
    return [] if ids.blank?

    Message.where(sender_person_id: ids)
           .distinct
           .pluck(Arel.sql("EXTRACT(YEAR FROM messages.created_at)"))
           .map(&:to_i)
           .sort
           .reverse
  end

  def parse_activity_filters
    filters = params[:filters]
    filters = [ filters ] if filters.is_a?(String)
    return ALL_ACTIVITY_FILTERS.dup unless filters.is_a?(Array) && filters.any?
    filters.select { |f| ALL_ACTIVITY_FILTERS.include?(f) }
  end
end
