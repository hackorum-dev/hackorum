# frozen_string_literal: true

class Admin::BaseController < ApplicationController
  layout "admin"

  before_action :require_admin

  helper_method :active_admin_section

  def active_admin_section
    :dashboard
  end

  private

  def require_admin
    unless current_admin?
      redirect_to root_path, alert: "You do not have permission to access this page"
    end
  end
end
