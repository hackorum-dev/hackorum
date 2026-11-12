module Api
  module V1
    module Me
      class ActivitiesController < BaseController
        before_action :require_token

        query_params :unread, paged: true, on: :index
        cursor_per_caller on: :index

        def index
          activities = current_user.activities.visible
          activities = activities.where(read_at: nil) if unread_param
          rows, next_cursor = paginate(activities, columns: %w[activities.id])
          render_page(ActivitySerializer.brief_list(rows, context), next_cursor)
        end

        private

        def unread_param
          value = string_param(:unread)
          return false if value.nil?
          raise Api::InvalidParameter, "unread must be true" unless value == "true"

          true
        end
      end
    end
  end
end
