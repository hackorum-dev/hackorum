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
  end

  def update
    raw = params[:token]
    token = UserToken.consume!(raw, purpose: "reset_password")
    return redirect_to new_password_path, alert: "Invalid or expired token" unless token

    user = token.user
    if user.update(password: params[:password], password_confirmation: params[:password_confirmation])
      redirect_to new_session_path, notice: "Password updated. Please sign in."
    else
      flash.now[:alert] = "Could not update password."
      render :edit, status: :unprocessable_entity
    end
  end
end
