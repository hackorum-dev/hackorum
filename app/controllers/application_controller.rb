class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  around_action :track_page_load_time
  rescue_from ActiveRecord::RecordNotFound, with: :render_404
  helper_method :current_user, :user_signed_in?, :current_admin?
  helper_method :activity_unread_count
  before_action :authorize_mini_profiler

  private

  def render_404
    render file: Rails.root.join("public", "404.html"), status: :not_found, layout: false
  end

  def current_user
    return @current_user if defined?(@current_user)
    uid = session[:user_id]
    @current_user = uid && User.active.find_by(id: uid)
  end

  def user_signed_in?
    current_user.present?
  end

  def current_admin?
    current_user&.admin?
  end

  def require_authentication
    redirect_to new_session_path, alert: "Please sign in" unless user_signed_in?
  end

  def authorize_mini_profiler
    return unless defined?(Rack::MiniProfiler)
    if Rails.env.development?
      Rack::MiniProfiler.authorize_request
    elsif Rails.env.production? && current_admin?
      Rack::MiniProfiler.authorize_request
    end
  end

  def activity_unread_count
    return 0 unless current_user
    @activity_unread_count ||= Activity.where(user: current_user, hidden: false, read_at: nil).count
  end

  def track_page_load_time
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    begin
      duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000.0

      unless request.path == "/up" || !(request.format.html? || request.format.turbo_stream?)
        PageLoadStat.insert({
          url: request.path,
          controller: controller_name,
          action: action_name,
          render_time: duration_ms.round(1),
          is_turbo: turbo_frame_request? || request.format.turbo_stream?,
          created_at: Time.current
        })
      end
    rescue StandardError
      # Never let logging break a request
    end
  end
end
