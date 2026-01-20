# frozen_string_literal: true

class Admin::BaseController < ApplicationController
  before_action :require_admin

  private

  def require_admin
    unless current_admin?
      redirect_to root_path, alert: "You do not have permission to access this page"
    end
  end
end
