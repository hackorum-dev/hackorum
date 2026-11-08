module ProfileHelper
  def profile_filter_url(profile_routes, activity_period)
    return profile_routes[:default] if activity_period.nil?

    case activity_period[:type]
    when :day
      profile_routes[:daily].call(activity_period[:date].iso8601)
    when :week
      profile_routes[:weekly].call(activity_period[:year], activity_period[:week])
    when :month
      profile_routes[:monthly].call(activity_period[:year], activity_period[:month])
    when :year
      profile_routes[:contributions].call(activity_period[:year])
    else
      profile_routes[:default]
    end
  end

  def person_profile_routes(email, week_start: nil)
    ws = week_start ? { week_start: week_start } : {}
    {
      default: person_path(email, **ws),
      daily: ->(date) { person_activity_path(email, date, **ws) },
      weekly: ->(year, week) { person_weekly_activity_path(email, year, week, **ws) },
      monthly: ->(year, month) { person_monthly_activity_path(email, year, month, **ws) },
      contributions: ->(year) { person_contributions_path(email, year: year, **ws) }
    }
  end

  def person_commit_profile_routes(email, week_start: nil)
    ws = week_start ? { week_start: week_start } : {}
    {
      default: person_commits_path(email, **ws),
      daily: ->(date) { person_commit_activity_path(email, date, **ws) },
      weekly: ->(year, week) { person_commit_weekly_activity_path(email, year, week, **ws) },
      monthly: ->(year, month) { person_commit_monthly_activity_path(email, year, month, **ws) },
      contributions: ->(year) { person_commit_contributions_path(email, year: year, **ws) }
    }
  end

  def team_commit_profile_routes(name, week_start: nil)
    ws = week_start ? { week_start: week_start } : {}
    {
      default: team_commits_path(name, **ws),
      daily: ->(date) { team_commit_activity_path(name, date, **ws) },
      weekly: ->(year, week) { team_commit_weekly_activity_path(name, year, week, **ws) },
      monthly: ->(year, month) { team_commit_monthly_activity_path(name, year, month, **ws) },
      contributions: ->(year) { team_commit_contributions_path(name, year: year, **ws) }
    }
  end

  COMMIT_ROLE_LABELS = {
    "author" => "Author",
    "committer" => "Committer",
    "reviewer" => "Reviewer",
    "reported_by" => "Reported by",
    "co_author" => "Co-author"
  }.freeze

  # Reuses the message tab's three tag colours rather than inventing five more.
  COMMIT_ROLE_TAG_CLASSES = {
    "author" => "tag-patch",
    "co_author" => "tag-patch",
    "committer" => "tag-started",
    "reviewer" => "tag-replied",
    "reported_by" => "tag-replied"
  }.freeze

  def commit_role_label(role) = COMMIT_ROLE_LABELS.fetch(role, role.to_s.humanize)

  def commit_role_tag_class(role) = COMMIT_ROLE_TAG_CLASSES.fetch(role, "tag-replied")

  def commit_period_heading(activity_period)
    return "Commits" if activity_period.blank?

    case activity_period[:type]
    when :day
      "Commits on #{activity_period[:date].strftime('%B %d, %Y')}"
    when :week
      "Commits in week #{activity_period[:week]} (#{activity_period[:start_date].strftime('%b %d')} - #{activity_period[:end_date].strftime('%b %d, %Y')})"
    when :month
      "Commits in #{Date.new(activity_period[:year], activity_period[:month], 1).strftime('%B %Y')}"
    when :year
      "Commits in #{activity_period[:year]}"
    else
      "Commits"
    end
  end

  def team_profile_routes(name, week_start: nil)
    ws = week_start ? { week_start: week_start } : {}
    {
      default: team_profile_path(name, **ws),
      daily: ->(date) { team_activity_path(name, date, **ws) },
      weekly: ->(year, week) { team_weekly_activity_path(name, year, week, **ws) },
      monthly: ->(year, month) { team_monthly_activity_path(name, year, month, **ws) },
      contributions: ->(year) { team_contributions_path(name, year: year, **ws) }
    }
  end

  def profile_stat_tiles(stats, search_email)
    linkable = search_email.present?

    [
      {
        display: profile_split_count(stats.messages_sent, stats.messages_sent_hidden),
        label: "Messages sent",
        title: profile_hidden_title(stats.messages_sent_hidden)
      },
      {
        display: profile_split_count(stats.threads_started, stats.threads_started_hidden),
        label: "Threads started",
        title: profile_hidden_title(stats.threads_started_hidden),
        query: ("starter:\"#{search_email}\"" if linkable)
      },
      {
        display: profile_split_count(stats.threads_joined, stats.threads_joined_hidden),
        label: "Threads joined",
        title: profile_hidden_title(stats.threads_joined_hidden),
        query: ("from:\"#{search_email}\"" if linkable)
      },
      {
        display: number_with_delimiter(stats.patches_sent),
        label: "Patches sent",
        sub: "across #{pluralize(stats.patch_threads, 'thread')}",
        title: "Threads they sent a patch to, including threads started by other people",
        query: ("has:patch[from:\"#{search_email}\"]" if linkable)
      },
      {
        display: profile_active_span(stats),
        label: "Active",
        sub: profile_active_range(stats)
      }
    ]
  end

  def profile_split_count(shown, hidden)
    return number_with_delimiter(shown) unless hidden.positive?

    "#{number_with_delimiter(shown)}+#{number_with_delimiter(hidden)}"
  end

  def profile_hidden_title(hidden)
    "#{number_with_delimiter(hidden)} more in hidden lists" if hidden.positive?
  end

  def profile_active_span(stats)
    return "-" unless stats.first_message_at

    years = stats.years_active
    years.positive? ? "#{years} yrs" : "< 1 yr"
  end

  def profile_active_range(stats)
    return nil unless stats.first_message_at && stats.last_message_at

    "#{stats.first_message_at.strftime('%b %Y')} - #{stats.last_message_at.strftime('%b %Y')}"
  end

  def profile_thread_lifetime(stats)
    days = stats.median_thread_lifetime_days
    return nil if days.nil?

    profile_duration_label(days)
  end

  def profile_duration_label(days)
    return nil if days.nil?

    return "under a day" if days < 1
    return pluralize(days.round, "day") if days.round < 60

    months = (days / 30.44).round
    return pluralize(months, "month") if months < 18

    years = (days / 365.25).round(1)
    "#{years % 1 == 0 ? years.to_i : years} years"
  end

  # One row per thread, not per superlative: the same thread routinely wins
  # several, and dropping the duplicates hid whole categories.
  def profile_thread_showcases(stats)
    entries = []

    if (topic = stats.longest_running_thread)
      entries << { topic: topic, key: "longest running", meta: profile_duration_label(stats.longest_running_thread_days) }
    end
    if (topic = stats.most_participants_thread)
      entries << { topic: topic, key: "most participants", meta: pluralize(topic.participant_count, "participant") }
    end
    if (topic = stats.most_messages_thread)
      entries << { topic: topic, key: "most messages", meta: pluralize(topic.message_count, "message") }
    end

    entries.group_by { |entry| entry[:topic].id }.values.map do |group|
      {
        topic: group.first[:topic],
        label: group.map { |entry| entry[:key] }.join(" + ").upcase_first,
        meta: group.filter_map { |entry| entry[:meta] }.join(" - ")
      }
    end
  end

  # Inclusive [start, end] dates for the period currently on screen.
  def profile_period_range(activity_period)
    return [ 30.days.ago.beginning_of_day.to_date, Date.current ] if activity_period.nil? || activity_period[:type] == :recent

    case activity_period[:type]
    when :day
      [ activity_period[:date], activity_period[:date] ]
    when :week
      [ activity_period[:start_date], activity_period[:end_date] ]
    when :month
      start_date = Date.new(activity_period[:year], activity_period[:month], 1)
      [ start_date, start_date.end_of_month ]
    else
      [ 30.days.ago.beginning_of_day.to_date, Date.current ]
    end
  end

  # first_after: is >= and first_before: is <, so the upper bound is the day after
  # the last day we want included.
  def profile_started_search_query(email, activity_period)
    return nil if email.blank?

    range_start, range_end = profile_period_range(activity_period)
    return nil unless range_start && range_end

    "starter:\"#{email}\" first_after:#{range_start} first_before:#{range_end + 1}"
  end
end
