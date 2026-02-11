# frozen_string_literal: true

module WeekCalculation
  WEEKDAY_NAMES = %w[Sun Mon Tue Wed Thu Fri Sat].freeze
  DEFAULT_WEEK_START = 1 # Monday (matches Date#wday: 0=Sun, 1=Mon, ..., 6=Sat)

  DAY_NAMES = {
    "sunday" => 0, "sun" => 0,
    "monday" => 1, "mon" => 1,
    "tuesday" => 2, "tue" => 2,
    "wednesday" => 3, "wed" => 3,
    "thursday" => 4, "thu" => 4,
    "friday" => 5, "fri" => 5,
    "saturday" => 6, "sat" => 6
  }.freeze

  # Parse a week_start parameter string to a wday integer (0-6).
  # Returns DEFAULT_WEEK_START for blank/unrecognized values.
  def self.parse_week_start(param)
    return DEFAULT_WEEK_START if param.blank?
    DAY_NAMES[param.to_s.downcase] || DEFAULT_WEEK_START
  end

  # Returns the param string for a wday integer, or nil if it's the default.
  def self.week_start_param(wday_start)
    return nil if wday_start == DEFAULT_WEEK_START
    WEEKDAY_NAMES[wday_start]&.downcase
  end

  # Returns the start (first day) of the week containing the given date.
  def self.week_start_for(date, wday_start = DEFAULT_WEEK_START)
    offset = (date.wday - wday_start) % 7
    date - offset
  end

  # Returns [start_date, end_date] covering all full weeks that overlap the given year.
  def self.year_weeks_range(year, wday_start = DEFAULT_WEEK_START)
    jan1 = Date.new(year, 1, 1)
    dec31 = Date.new(year, 12, 31)
    start_date = week_start_for(jan1, wday_start)
    end_date = week_start_for(dec31, wday_start) + 6
    [ start_date, end_date ]
  end

  # Returns the 1-based week number for a date within a year's week grid.
  def self.week_number(date, year, wday_start = DEFAULT_WEEK_START)
    year_start = year_weeks_range(year, wday_start).first
    ((date - year_start).to_i / 7) + 1
  end

  # Returns the start date for a given year and week number.
  def self.week_start_date(year, week, wday_start = DEFAULT_WEEK_START)
    year_start = year_weeks_range(year, wday_start).first
    year_start + (week - 1) * 7
  end

  # Returns weekday label strings in display order starting from wday_start.
  def self.weekday_labels(wday_start = DEFAULT_WEEK_START)
    7.times.map { |i| WEEKDAY_NAMES[(wday_start + i) % 7] }
  end
end
