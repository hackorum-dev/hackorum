module Stats
  class IndexController < BaseController
    def show
      @releases = Stats::Release.available
    end
  end
end
