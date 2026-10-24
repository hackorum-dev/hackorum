class PasswordsController < ApplicationController
  def new
  end

  def create
    email = EmailNormalizer.normalize(params[:email])
    # Only allow reset if email belongs to an active user with verified alias
    user = Alias.by_email(email).includes(:user).map(&:user).compact.uniq.select { |u| u.deleted_at.nil? }.first
    if user
      token, raw = UserToken.issue!(purpose: "reset_password", user: user, email: email, ttl: 30.minutes)
      UserMailer.password_reset(token, raw).deliver_later
    end
    redirect_to new_session_path, notice: "If your email exists, a reset link has been sent."
  end

  def edit
    @raw = params[:token]
    unless UserToken.find_usable(@raw, purpose: "reset_password")
      redirect_to new_password_path, alert: "Invalid or expired token"
    end
  end

  def update
    @raw = params[:token]
    token = UserToken.find_usable(@raw, purpose: "reset_password")
    return redirect_to new_password_path, alert: "Invalid or expired token" unless token

    user = token.user
    user.assign_attributes(password: params[:password], password_confirmation: params[:password_confirmation])
    updated = false
    ActiveRecord::Base.transaction do
      token.consume!
      updated = user.save(context: :password_change)
      raise ActiveRecord::Rollback unless updated
    end

    if updated
      redirect_to new_session_path, notice: "Password updated. Please sign in."
    else
      flash.now[:alert] = user.errors.full_messages.to_sentence.presence || "Could not update password."
      render :edit, status: :unprocessable_content
    end
  rescue UserToken::AlreadyConsumed
    redirect_to new_password_path, alert: "Invalid or expired token"
  end
end
