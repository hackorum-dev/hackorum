class RegistrationsController < ApplicationController
  rate_limit to: 5, within: 1.hour, only: :resend,
    with: -> { redirect_to resend_verification_path, alert: "Too many requests. Try again later." }

  def new
  end

  def resend_form
  end

  def resend
    email = EmailNormalizer.normalize(params[:email])
    pending = email && UserToken.unconsumed
      .where(purpose: "register", email: email)
      .joins(:user).merge(User.unverified.where(deleted_at: nil))
      .order(created_at: :desc).first

    if pending
      user = pending.user
      ttl = user.created_at + User::UNVERIFIED_TTL - Time.current
      if ttl.positive?
        token, raw = UserToken.issue!(purpose: "register", user: user, email: email, ttl: ttl, metadata: pending.metadata)
        UserMailer.verification_email(token, raw).deliver_now
      end
    end

    redirect_to root_path, notice: "If a pending registration exists for that email, a new verification email has been sent."
  end

  def create
    email = EmailNormalizer.normalize(params[:email])
    unless email&.match?(URI::MailTo::EMAIL_REGEXP)
      return redirect_to registration_path, alert: "A valid email is required."
    end

    user = User.new(
      person: Person.new,
      username: params[:username],
      password: params[:password],
      password_confirmation: params[:password_confirmation]
    )
    token = raw = nil

    begin
      ActiveRecord::Base.transaction do
        user.save!(context: :registration)
        token, raw = UserToken.issue!(
          purpose: "register",
          user: user,
          email: email,
          ttl: User::UNVERIFIED_TTL,
          metadata: { name: params[:name].presence }.to_json
        )
      end
    rescue ActiveRecord::RecordInvalid
      return redirect_to registration_path, alert: user.errors.full_messages.to_sentence
    rescue ActiveRecord::RecordNotUnique
      return redirect_to registration_path, alert: "Username is already taken."
    end

    UserMailer.verification_email(token, raw).deliver_now
    redirect_to root_path, notice: "Verification email sent. Please check your inbox."
  end
end
