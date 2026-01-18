module ReportsHelper
  def period_title(period_type, year, week: nil, month: nil)
    if period_type == "weekly"
      start_date = Date.commercial(year, week, 1)
      end_date = start_date + 6.days
      "Week #{week}, #{year}"
    else
      Date.new(year, month, 1).strftime("%B %Y")
    end
  end

  def period_subtitle(period_type, year, week: nil, month: nil)
    if period_type == "weekly"
      start_date = Date.commercial(year, week, 1)
      end_date = start_date + 6.days
      "#{start_date.strftime('%b %d')} - #{end_date.strftime('%b %d, %Y')}"
    else
      start_date = Date.new(year, month, 1)
      end_date = start_date.end_of_month
      "#{start_date.strftime('%b %d')} - #{end_date.strftime('%b %d, %Y')}"
    end
  end

  def previous_report_path(period_type, year, week: nil, month: nil)
    if period_type == "weekly"
      prev_date = Date.commercial(year, week, 1) - 7.days
      weekly_report_path(year: prev_date.cwyear, week: prev_date.cweek, filter: params[:filter])
    else
      prev_date = Date.new(year, month, 1) - 1.month
      monthly_report_path(year: prev_date.year, month: prev_date.month, filter: params[:filter])
    end
  end

  def next_report_path(period_type, year, week: nil, month: nil)
    if period_type == "weekly"
      next_date = Date.commercial(year, week, 1) + 7.days
      weekly_report_path(year: next_date.cwyear, week: next_date.cweek, filter: params[:filter])
    else
      next_date = Date.new(year, month, 1) + 1.month
      monthly_report_path(year: next_date.year, month: next_date.month, filter: params[:filter])
    end
  end

  def is_current_or_future_period?(period_type, year, week: nil, month: nil)
    today = Date.current
    if period_type == "weekly"
      period_start = Date.commercial(year, week, 1)
      period_start >= today.beginning_of_week
    else
      period_start = Date.new(year, month, 1)
      period_start >= today.beginning_of_month
    end
  end

  def filter_path(filter_value)
    if @period_type == "weekly"
      weekly_report_path(year: @year, week: @week, filter: filter_value == "all" ? nil : filter_value)
    else
      monthly_report_path(year: @year, month: @month, filter: filter_value == "all" ? nil : filter_value)
    end
  end

  def toggle_period_type_path
    if @period_type == "weekly"
      monthly_report_path(year: @period_start.year, month: @period_start.month, filter: params[:filter])
    else
      weekly_report_path(year: @period_start.cwyear, week: @period_start.cweek, filter: params[:filter])
    end
  end

  def stat_change(current, previous)
    return nil unless current && previous && previous > 0

    change = ((current - previous).to_f / previous * 100).round
    { value: change, direction: change >= 0 ? "up" : "down" }
  end

  def stat_change_class(change)
    return "" unless change
    change[:direction] == "up" ? "stat-change-positive" : "stat-change-negative"
  end

  def stat_change_text(change)
    return "" unless change
    sign = change[:value] >= 0 ? "+" : ""
    "#{sign}#{change[:value]}%"
  end

  def contributor_status_badge(person)
    return nil unless person.respond_to?(:contributor_type)
    contributor_type = person.contributor_type
    return nil unless contributor_type

    case contributor_type
    when "core_team"
      content_tag(:span, "Core Team", class: "contributor-badge contributor-badge-core-team")
    when "committer"
      content_tag(:span, "Committer", class: "contributor-badge contributor-badge-committer")
    when "major_contributor"
      content_tag(:span, "Major Contributor", class: "contributor-badge contributor-badge-major")
    when "significant_contributor"
      content_tag(:span, "Significant Contributor", class: "contributor-badge contributor-badge-significant")
    end
  end

  def ranking_tabs
    [
      { key: "started_thread", label: "Started Thread" },
      { key: "replied_own_thread", label: "Replied Own" },
      { key: "replied_other_thread", label: "Replied Other" },
      { key: "sent_first_patch", label: "First Patch" },
      { key: "sent_followup_patch", label: "Followup Patch" }
    ]
  end

  def jump_to_path(year, period)
    if @period_type == "weekly"
      weekly_report_path(year: year, week: period, filter: params[:filter])
    else
      monthly_report_path(year: year, month: period, filter: params[:filter])
    end
  end

  def weeks_in_year(year)
    Date.new(year, 12, 28).cweek
  end
end
