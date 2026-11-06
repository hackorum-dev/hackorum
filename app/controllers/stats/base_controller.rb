module Stats
  class BaseController < ApplicationController
    before_action :require_authentication
    before_action :require_lineage_feature

    private

    # the whole tree rides on the lineage flag while only PG19 has the data
    def require_lineage_feature
      render_404 unless lineage_visible?
    end
  end
end
