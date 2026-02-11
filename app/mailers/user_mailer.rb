class UserMailer < ApplicationMailer
  def verification_email(token, raw)
    @token_url = verification_url(token: raw)
    mail to: token.email, subject: "Verify your email"
  end

  def password_reset(token, raw)
    @token_url = edit_password_url(token: raw)
    mail to: token.email, subject: "Reset your password"
  end
end
