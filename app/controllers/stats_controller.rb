class StatsController < ApplicationController
  skip_before_action :require_authentication, raise: false

  def show
  end

  def data
    granularity = params[:granularity].to_s.presence_in(%w[day week month]) || "week"
    range_param = params[:range].to_s.presence_in(%w[last_30 last_90 last_365 last_3650 after_2000 all_time custom]) || "last_90"
    end_date = Date.current
    start_date =
      if range_param == "custom"
        parse_date(params[:from]) || end_date - 89.days
      elsif range_param == "after_2000"
        Date.new(2000, 1, 1)
      elsif range_param == "all_time"
        stats_model, = models_for(granularity)
        stats_model.minimum(:interval_start) || end_date - 89.days
      else
        range_days = range_param.delete_prefix("last_").to_i
        end_date - (range_days - 1).days
      end
    end_date = parse_date(params[:to]) || end_date if range_param == "custom"

    stats_model, hist_model = models_for(granularity)

    intervals = stats_model.where(interval_start: start_date..end_date).order(:interval_start)
    histogram = hist_model.where(interval_start: start_date..end_date).order(:interval_start, :bucket)
    retention_period = params[:retention_granularity].to_s == "quarter" ? 3 : 1
    retention_segment = params[:retention_segment].to_s == "replied_to_others" ? "replied_to_others" : "all"
    retention = StatsRetentionMonthly
      .where(
        period_months: retention_period,
        segment: retention_segment,
        cohort_start: start_date.beginning_of_month..end_date.beginning_of_month
      )
      .order(:cohort_start, :months_since)
    retention_milestones = StatsRetentionMilestone
      .where(
        period_months: retention_period,
        segment: retention_segment,
        cohort_start: start_date.beginning_of_month..end_date.beginning_of_month
      )
      .order(:cohort_start, :horizon_months)

    render json: {
      granularity: granularity,
      range: range_param,
      from: start_date,
      to: end_date,
      intervals: intervals.as_json(except: [ :id, :created_at, :updated_at ]),
      longevity_histogram: histogram.as_json(except: [ :id, :created_at, :updated_at ]),
      retention_heatmap: retention.as_json(except: [ :id, :created_at, :updated_at ]),
      retention_milestones: retention_milestones.as_json(except: [ :id, :created_at, :updated_at ])
    }
  end

  private

  def models_for(granularity)
    case granularity
    when "day"
      [ StatsDaily, StatsLongevityDaily ]
    when "week"
      [ StatsWeekly, StatsLongevityWeekly ]
    when "month"
      [ StatsMonthly, StatsLongevityMonthly ]
    else
      [ StatsWeekly, StatsLongevityWeekly ]
    end
  end

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
end
