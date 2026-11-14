module Stats
  class ListsController < BaseController
    skip_before_action :require_authentication, :require_lineage_feature
    before_action :load_params

    def volume
      @data = Stats::Cache.fetch_lists(:volume, @params.cache_key) { Stats::Lists::Volume.new(@params).to_h }
    end

    def newcomers
      @data = Stats::Cache.fetch_lists(:newcomers, @params.newcomers_cache_key) { Stats::Lists::Newcomers.new(@params).to_h }
    end

    def regulars
      @params = Stats::ListsParams.new(params: params, default_years: 3)
      score = params[:score].to_s.presence_in(Stats::Lists::Monthly::SCORES)
      @at = params[:at].to_s[/\A\d{4}-\d{1,2}\z/]
      @keep_query = score ? { score: score } : {}
      key = @params.regulars_cache_key(score, @at)
      @data = Stats::Cache.fetch_lists(:regulars, key) { Stats::Lists::Regulars.new(@params, score: score, at: @at).to_h }
    end

    private

    def load_params
      @params = Stats::ListsParams.new(params: params)
    end
  end
end
