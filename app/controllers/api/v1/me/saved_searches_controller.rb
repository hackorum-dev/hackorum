module Api
  module V1
    module Me
      class SavedSearchesController < BaseController
        before_action :require_token

        def index
          entries = Api::SavedSearchList.new(current_user).entries
          render_page(SavedSearchSerializer.list(entries, context), nil)
        end
      end
    end
  end
end
