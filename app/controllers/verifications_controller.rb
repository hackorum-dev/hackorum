class VerificationsController < ApplicationController
  # GET /verify?token=...
  def show
    raw = params[:token].to_s
    token = UserToken.consume!(raw)
    return redirect_to root_path, alert: 'Invalid or expired token' unless token

    case token.purpose
    when 'register'
      handle_register(token)
    when 'add_alias'
      handle_add_alias(token)
    when 'reset_password'
      redirect_to edit_password_path(token: raw)
    else
      redirect_to root_path, alert: 'Invalid token purpose'
    end
  end

  private

  def handle_register(token)
    existing_aliases = Alias.by_email(token.email)
    if existing_aliases.where.not(user_id: nil).exists?
      return redirect_to new_session_path, alert: 'This email is already claimed. Please sign in.'
    end

    user = User.new
    metadata = JSON.parse(token.metadata || '{}') rescue {}
    desired_username = metadata['username']
    user.username = desired_username
    if metadata['password_digest'].present?
      user.password_digest = metadata['password_digest']
    end

    ActiveRecord::Base.transaction do
      user.save!(context: :registration)

      reservation = NameReservation.find_by(
        owner_type: 'UserToken',
        owner_id: token.id,
        name: NameReservation.normalize(desired_username)
      )
      if reservation
        reservation.update!(owner_type: 'User', owner_id: user.id)
      else
        begin
          NameReservation.reserve!(name: desired_username, owner: user)
        rescue ActiveRecord::RecordInvalid
          raise ActiveRecord::RecordInvalid.new(user), "Username is already taken."
        end
      end
    end

    if existing_aliases.exists?
      existing_aliases.update_all(user_id: user.id, verified_at: Time.current)
      primary = existing_aliases.find_by(primary_alias: true) || existing_aliases.first
      primary.update!(primary_alias: true)
    else
      name = metadata['name'] || token.email
      Alias.create!(user: user, name: name, email: token.email, primary_alias: true, verified_at: Time.current)
    end

    reset_session
    session[:user_id] = user.id
    redirect_to root_path, notice: 'Registration complete. You are signed in.'
  end

  def handle_add_alias(token)
    user = token.user
    return redirect_to root_path, alert: 'Invalid token user' unless user

    if user_signed_in? && current_user.id != user.id
      return redirect_to settings_path, alert: 'This verification link belongs to a different user.'
    end

    email = token.email
    if Alias.by_email(email).where.not(user_id: [nil, user.id]).exists?
      return redirect_to settings_path, alert: 'Email is linked to another account. Delete that account first to release it.'
    end

    aliases = Alias.by_email(email)
    if aliases.exists?
      aliases.update_all(user_id: user.id, verified_at: Time.current)
    else
      Alias.create!(user: user, name: email, email: email, verified_at: Time.current)
    end

    redirect_to settings_path, notice: 'Email added and verified.'
  end
end
