module Api
  module V1
    class ErrorsController < BaseController
      skip_before_action :check_query_parameters
      skip_around_action :with_statement_timeout

      def not_found
        render_error :not_found, "No such endpoint"
      end
    end
  end
end
