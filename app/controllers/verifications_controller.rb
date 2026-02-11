class VerificationsController < ApplicationController
  # GET /verify?token=...
  def show
    raw = params[:token].to_s
    token = UserToken.consume!(raw)
    return redirect_to root_path, alert: "Invalid or expired token" unless token

    case token.purpose
    when "register"
      handle_register(token)
    when "add_alias"
      handle_add_alias(token)
    when "reset_password"
      redirect_to edit_password_path(token: raw)
    else
      redirect_to root_path, alert: "Invalid token purpose"
    end
  end

  private

  def handle_register(token)
    existing_aliases = Alias.by_email(token.email)
    if existing_aliases.where.not(user_id: nil).exists?
      return redirect_to new_session_path, alert: "This email is already claimed. Please sign in."
    end

    person = Person.find_or_create_by_email(token.email)
    user = User.new(person_id: person.id)
    metadata = JSON.parse(token.metadata || "{}") rescue {}
    desired_username = metadata["username"]
    user.username = desired_username
    if metadata["password_digest"].present?
      user.password_digest = metadata["password_digest"]
    end

    ActiveRecord::Base.transaction do
      user.save!(context: :registration)

      reservation = NameReservation.find_by(
        owner_type: "UserToken",
        owner_id: token.id,
        name: NameReservation.normalize(desired_username)
      )
      if reservation
        reservation.update!(owner_type: "User", owner_id: user.id)
      else
        begin
          NameReservation.reserve!(name: desired_username, owner: user)
        rescue ActiveRecord::RecordInvalid
          raise ActiveRecord::RecordInvalid.new(user), "Username is already taken."
        end
      end
    end

    if existing_aliases.exists?
      existing_aliases.find_each do |al|
        person.attach_alias!(al, user: user)
        al.update_columns(verified_at: Time.current)
      end
      if person.default_alias_id.nil?
        primary = existing_aliases.find_by(primary_alias: true) || existing_aliases.first
        person.update!(default_alias_id: primary.id) if primary
      end
    else
      name = metadata["name"] || token.email
      al = Alias.create!(person: person, user: user, name: name, email: token.email, verified_at: Time.current)
      person.update!(default_alias_id: al.id) if person.default_alias_id.nil?
    end

    reset_session
    session[:user_id] = user.id
    redirect_to root_path, notice: "Registration complete. You are signed in."
  end

  def handle_add_alias(token)
    user = token.user
    return redirect_to root_path, alert: "Invalid token user" unless user
    person = user.person || Person.create!
    user.update!(person_id: person.id) if user.person_id.nil?

    if user_signed_in? && current_user.id != user.id
      return redirect_to settings_account_path, alert: "This verification link belongs to a different user."
    end

    email = token.email
    if Alias.by_email(email).where.not(user_id: [ nil, user.id ]).exists?
      return redirect_to settings_account_path, alert: "Email is linked to another account. Delete that account first to release it."
    end

    metadata = JSON.parse(token.metadata || "{}") rescue {}
    name = metadata["name"].presence

    aliases = Alias.by_email(email)
    if aliases.exists?
      # Associate all existing aliases with this email
      aliases.find_each do |al|
        person.attach_alias!(al, user: user)
        al.update_columns(verified_at: Time.current)
      end
      # If a name was provided and no existing alias has that name, create a new alias
      if name.present? && !aliases.where(name: name).exists?
        Alias.create!(person: person, user: user, name: name, email: email, verified_at: Time.current)
      end
    else
      # No existing aliases - create new one with provided name
      al = Alias.create!(person: person, user: user, name: name, email: email, verified_at: Time.current)
      person.update!(default_alias_id: al.id) if person.default_alias_id.nil?
    end

    redirect_to settings_account_path, notice: "Email added and verified."
  end
end
