module Api
  module V1
    class BaseController < ActionController::API
      RESOURCE_ERRORS = [ PG::InsufficientResources, PG::StatementTooComplex ].freeze
      AUTHOR_LIMIT = 254
      PAGING = %w[limit cursor].freeze
      # they do not change which rows a list has
      CURSOR_FREE = %w[limit cursor body].freeze
      INTERNAL_PATH_PARAMS = %i[controller action format].freeze
      NAME_LIMIT = 100
      LOCK_TIMEOUT_MS = 2000
      LENGTH = /\A\d+\z/
      BODY_LIMIT = ActiveSupport::NumberHelper.number_to_human_size(Api::RequestBody::MAX_BYTES).freeze

      class_attribute :allowed_query_params, instance_writer: false, default: {}.freeze
      class_attribute :caller_bound_actions, instance_writer: false, default: [].freeze
      class_attribute :request_bodies, instance_writer: false, default: {}.freeze

      # a body is read as it was sent
      wrap_parameters format: []

      # an action without a declaration takes no query parameters
      def self.query_params(*names, on:, paged: false)
        allowed = (names.map(&:to_s) + (paged ? PAGING : [])).freeze
        self.allowed_query_params = allowed_query_params.merge(Array(on).to_h { |action| [ action.to_s, allowed ] }).freeze
      end

      # lists whose rows depend on the caller: a cursor then belongs to that user
      def self.cursor_per_caller(on:)
        self.caller_bound_actions = (caller_bound_actions + Array(on).map(&:to_s)).freeze
      end

      # the fields of the JSON body an action takes, see Api::RequestBody
      def self.request_body(on:, **fields)
        self.request_bodies = request_bodies.merge(on.to_s => Api::RequestBody.new(**fields)).freeze
      end

      # the token touch stays outside the transaction: it is kept when the action fails
      before_action :check_body_size
      before_action :authenticate_token
      before_action :check_query_parameters
      around_action :with_statement_timeout

      rescue_from ActiveRecord::StatementInvalid do |e|
        raise e unless RESOURCE_ERRORS.any? { |kind| e.cause.is_a?(kind) }
        render_too_expensive
      end

      rescue_from ActiveRecord::QueryCanceled do
        render_too_expensive
      end

      rescue_from ActiveRecord::LockWaitTimeout do
        render_error :conflict, "The draft is busy, try again"
      end

      rescue_from ActiveRecord::RecordNotFound do
        render_error :not_found, "Not found"
      end

      rescue_from ActionController::ParameterMissing do |e|
        render_error :bad_request, e.message
      end

      rescue_from Api::CursorPaginator::InvalidCursor do |e|
        render_error :invalid_cursor, e.message
      end

      rescue_from Api::CursorPaginator::InvalidLimit do |e|
        render_error :invalid_limit, e.message
      end

      rescue_from Api::InvalidParameter do |e|
        render_error :invalid_parameter, e.message
      end

      rescue_from Api::RequestBody::Invalid do |e|
        render_error :invalid_body, e.message
      end

      rescue_from Api::RequestBody::UnsupportedMediaType do
        render_error :unsupported_media_type, "The body must be sent with Content-Type: application/json"
      end

      private

      # ahead of the callbacks: the instrumentation around them parses the body
      def process_action(*)
        @body_too_large = body_too_large?
        # never parsed
        request.request_parameters = {} if @body_too_large || request.media_type != Api::RequestBody::MEDIA_TYPE
        super
      end

      def body_too_large?
        limit = Api::RequestBody::MAX_BYTES
        length = request.get_header("CONTENT_LENGTH").to_s
        return length.to_i > limit if LENGTH.match?(length) && !request.has_header?("HTTP_TRANSFER_ENCODING")

        # no length to believe: read as far as the limit, and keep what was read as the body
        read = request.body_stream&.read(limit + 1).to_s
        return true if read.bytesize > limit

        request.set_header("RAW_POST_DATA", read)
        request.set_header("CONTENT_LENGTH", read.bytesize.to_s) unless LENGTH.match?(length)
        false
      end

      def check_body_size
        render_error :payload_too_large, "The request body is too large, at most #{BODY_LIMIT}" if @body_too_large
      end

      attr_reader :current_token

      def current_user
        current_token&.user
      end

      def context
        @context ||= Context.new(user: current_user, token: current_token, base_url: site_base_url)
      end

      def authenticate_token
        result = Api::RequestToken.resolve(request.env)
        if result.state == :invalid
          response.headers["WWW-Authenticate"] = "Bearer"
          return render_error(:invalid_token, "Invalid, expired or revoked token")
        end
        @current_token = result.token
        current_token&.touch_last_used!
      end

      def check_query_parameters
        given = request.query_parameters
        unknown = given.keys - allowed_query_params.fetch(action_name, [])
        blank = given.find { |_, value| value.is_a?(String) && value.blank? }&.first
        if unknown.any?
          render_error :invalid_parameter, "unknown parameter: #{unknown.first.first(NAME_LIMIT)}"
        elsif blank
          render_error :invalid_parameter, "#{blank} must not be blank"
        end
      end

      def with_statement_timeout
        ActiveRecord::Base.transaction(requires_new: true) do
          timeout = Integer(Rails.configuration.x.api_statement_timeout_ms)
          ActiveRecord::Base.lease_connection.execute("SET LOCAL statement_timeout = #{timeout}")
          yield
          # an error answer keeps nothing of what the action wrote
          raise ActiveRecord::Rollback if response.status >= 400
        end
      end

      # a wait for a row lock ends early, and as its own error
      def with_lock_timeout
        ActiveRecord::Base.lease_connection.execute("SET LOCAL lock_timeout = #{LOCK_TIMEOUT_MS}")
        yield
      end

      def body_fields
        @body_fields ||= request_bodies.fetch(action_name).parse(request)
      end

      def render_too_expensive
        render_error :query_too_expensive, "The query is too expensive to run, narrow it down"
      end

      def require_token
        return if current_token
        response.headers["WWW-Authenticate"] = "Bearer"
        render_error :token_required, "This endpoint needs a token"
      end

      def site_base_url
        host = ENV["APP_HOST"].presence || ("hackorum.dev" if Rails.env.production?)
        host ? "https://#{host}" : request.base_url
      end

      def paginate(relation, columns:, direction: :desc, not_null: nil, &preload)
        Api::CursorPaginator.new(relation, columns: columns, direction: direction, not_null: not_null,
                                 limit: params[:limit], cursor: params[:cursor], scope: cursor_scope).page(&preload)
      end

      # what a cursor belongs to: the action, its path, its filters as they were sent, the user where declared
      def cursor_scope
        path = request.path_parameters.except(*INTERNAL_PATH_PARAMS).sort
        query = request.query_parameters.except(*CURSOR_FREE).sort
        scope = [ controller_path, action_name, path, query ]
        scope << current_user.id if current_user && caller_bound_actions.include?(action_name)
        scope.to_json
      end

      def render_page(records, next_cursor, **extra, &serialize)
        render json: { data: serialize ? records.map(&serialize) : records, next_cursor: next_cursor, **extra }
      end

      def string_param(name, max: nil)
        value = params[name]
        return value if value.nil?
        raise Api::InvalidParameter, "#{name} must be a single value" unless value.is_a?(String)
        raise Api::InvalidParameter, "#{name} has a NUL byte" if value.include?("\0")
        raise Api::InvalidParameter, "#{name} is too long, at most #{max} characters" if max && value.length > max

        value
      end

      def author_param
        string_param(:author, max: AUTHOR_LIMIT)
      end

      # a path segment that cannot name anything is a 404
      def path_param(name)
        string_param(name).to_s
      rescue Api::InvalidParameter
        raise ActiveRecord::RecordNotFound
      end

      def render_error(code, message)
        render json: { error: { code: code.to_s, message: message } }, status: Api::ErrorCodes::STATUSES.fetch(code.to_s)
      end
    end
  end
end
