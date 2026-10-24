module ProfilePeriodActions
  extend ActiveSupport::Concern
  include ProfilePeriodParams

  included do
    # month 13, week 54 and friends from the url
    rescue_from Date::Error, with: :render_404
  end

  # Requires from the includer: #default_activity_period returning a
  # ProfilePeriod, and #load_activity_data(period:) from whichever activity
  # concern the controller includes. Exactly one of those may be included.

  def contributions
    render_activity_period(default_activity_period)
  end

  def daily_activity
    render_activity_period(ProfilePeriod.day(parse_activity_date))
  end

  def weekly_activity
    render_activity_period(ProfilePeriod.week(params[:year], params[:week], parse_week_start_day))
  end

  def monthly_activity
    render_activity_period(ProfilePeriod.month(params[:year], params[:month]))
  end

  private

  def render_activity_period(period)
    load_activity_data(period: period)
    render :activity
  end
end
