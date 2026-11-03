module ProfileCommitActivity
  extend ActiveSupport::Concern
  include ProfilePeriodParams

  # Requires from the includer: #activity_person_ids - see PersonProfileScope.

  private

  def load_activity_data(period:)
    @week_start_day = parse_week_start_day
    @commit_roles = parse_commit_roles
    @activity_period = period.to_h

    activity = CommitActivity.new(
      person_ids: commit_activity_person_ids,
      year: period.year,
      roles: @commit_roles,
      sources: commit_credit_sources,
      wday_start: @week_start_day
    )

    @commit_summary = activity.summary_in(period.range)
    @commit_rows = activity.detail_rows_in(period.range)

    @contribution_years = commit_activity_years
    @contribution_year = period.year
    @contribution_weeks, @contribution_month_spans =
      ContributionCalendar.build(activity.daily_counts, @contribution_year, @week_start_day)
    @weekday_labels = WeekCalculation.weekday_labels(@week_start_day)
  end

  def default_activity_period
    ProfilePeriod.year(selected_commit_year)
  end

  def selected_commit_year
    years = commit_activity_years
    requested = params[:year].presence&.to_i
    return requested if requested && years.include?(requested)

    years.first || Date.current.year
  end

  def commit_activity_years
    @commit_activity_years ||= CommitActivity.available_years(commit_activity_person_ids, sources: commit_credit_sources)
  end

  def commit_activity_person_ids
    ids = activity_person_ids
    ids.is_a?(Set) ? ids.to_a : Array(ids)
  end

  # Unchecking every box sends no roles[] at all, which reads as "no filter" -
  # the same convention the message tab's filters[] uses.
  def parse_commit_roles
    return CommitActivity::ROLES.dup if params[:roles].blank?

    Array(params[:roles]).select { |role| CommitActivity::ROLES.include?(role) }
  end
end
