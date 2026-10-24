class SessionsController < ApplicationController
  rate_limit to: 10, within: 3.minutes, only: :create,
    with: -> { redirect_to new_session_path, alert: "Too many attempts. Try again later." }

  DUMMY_DIGEST = BCrypt::Password.create(
    SecureRandom.hex(16),
    cost: ActiveModel::SecurePassword.min_cost ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
  ).to_s

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

    if user.nil? || user.password_digest.blank?
      # same bcrypt cost as a real check, timing must not tell registered emails apart
      BCrypt::Password.new(DUMMY_DIGEST).is_password?(params[:password].to_s)
      flash.now[:alert] = "Invalid email or password"
      render :new, status: :unauthorized
    elsif !user.authenticate(params[:password])
      flash.now[:alert] = "Invalid email or password"
      render :new, status: :unauthorized
    elsif !verified_alias
      flash.now[:alert] = "Please verify your email before signing in."
      render :new, status: :forbidden
    else
      sign_in(user)
      redirect_to root_path, notice: "Signed in successfully"
    end
  end

  def destroy
    reset_session
    redirect_to root_path, notice: "Signed out"
  end
end
