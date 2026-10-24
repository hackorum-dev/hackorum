class RegistrationsController < ApplicationController
  def new
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

    UserMailer.verification_email(token, raw).deliver_later
    redirect_to root_path, notice: "Verification email sent. Please check your inbox."
  end
end
