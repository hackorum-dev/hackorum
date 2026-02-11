class SessionsController < ApplicationController
  def new
  end

  def create
    email = params[:email].to_s
    normalized_email = begin
      EmailNormalizer.normalize(email)
    rescue StandardError
      nil
    end
    user = normalized_email && Alias.by_email(normalized_email).includes(:user).first&.user
    verified_alias = user&.aliases&.where&.not(verified_at: nil)&.exists?

    if user.nil? || !user.authenticate(params[:password])
      flash.now[:alert] = "Invalid email or password"
      render :new, status: :unauthorized
    elsif !verified_alias
      flash.now[:alert] = "Please verify your email before signing in."
      render :new, status: :forbidden
    else
      reset_session
      session[:user_id] = user.id
      redirect_to root_path, notice: "Signed in successfully"
    end
  end

  def destroy
    reset_session
    redirect_to root_path, notice: "Signed out"
  end
end
