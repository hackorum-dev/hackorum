module Stats
  class IndexController < BaseController
    def show
      @releases = Stats::Period::Release.available
      @years = Stats::Period::Year.available
      @cycles = Stats::Period::Cycle.available
    end
  end
end
