module Stats
  class TrendsController < BaseController
    def show
      @kind = Stats::Trend.kind_for(params[:segment]) or return render_404
      @title = Stats::Trend::TITLES[@kind]
      @data = Stats::Cache.fetch_trend(@kind) { Stats::Trend.new(@kind).to_h }
      @periods = Stats::Period.kind_class(@kind).available.index_by(&:key)
    end
  end
end
