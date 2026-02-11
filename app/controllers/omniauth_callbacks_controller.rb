class OmniauthCallbacksController < ApplicationController
  def google_oauth2
    auth = request.env["omniauth.auth"]
    provider = auth["provider"]
    uid = auth["uid"]
    info = auth["info"] || {}
    email = info["email"]
    omniauth_params = request.env["omniauth.params"] || {}
    linking = omniauth_params["link"].present?
    current_person = current_user&.person

    if current_user && current_person.nil?
      current_person = Person.create!
      current_user.update!(person_id: current_person.id)
    end

    identity = Identity.find_by(provider: provider, uid: uid)

    if linking && current_user
      if identity
        if identity.user_id != current_user.id
          return redirect_to settings_account_path, alert: "That Google account is already linked to another user."
        end
        return redirect_to settings_account_path, notice: "That Google account is already linked to your account."
      else
        if Alias.by_email(email).where.not(user_id: [ nil, current_user.id ]).exists?
          return redirect_to settings_account_path, alert: "Email is linked to another account. Delete that account first to release it."
        end

        aliases = Alias.by_email(email).where(user_id: [ nil, current_user.id ])
        if aliases.exists?
          aliases.find_each do |al|
            current_person.attach_alias!(al, user: current_user)
            al.update_columns(verified_at: Time.current)
          end
          if current_person.default_alias_id.nil?
            primary = aliases.find_by(primary_alias: true) || aliases.first
            current_person.update!(default_alias_id: primary.id) if primary
          end
        else
          name = info["name"].presence || email
          al = Alias.create!(
            person: current_person,
            user: current_user,
            name: name,
            email: email,
            verified_at: Time.current
          )
          current_person.update!(default_alias_id: al.id) if current_person.default_alias_id.nil?
        end

        identity = Identity.create!(user: current_user, provider: provider, uid: uid, email: email, raw_info: auth.to_json, last_used_at: Time.current)
      end

      identity.update!(last_used_at: Time.current, email: email, raw_info: auth.to_json)
      return redirect_to settings_account_path, notice: "Google account linked."
    end

    if identity
      user = identity.user
    else
      # Do not attach to existing users from the login flow.
      alias_user = Alias.by_email(email).where.not(user_id: nil).includes(:user).first&.user
      if alias_user
        return redirect_to new_session_path, alert: "That Google account is already associated with an existing user. Link it from Settings instead."
      end
      person = Person.find_or_create_by_email(email)
      user = User.create!(person_id: person.id)

      # If no aliases exist for this email, create one
      aliases = Alias.by_email(email).where(user_id: [ nil, user.id ])
      if aliases.exists?
        aliases.find_each do |al|
          person.attach_alias!(al, user: user)
          al.update_columns(verified_at: Time.current)
        end
        if person.default_alias_id.nil?
          primary = aliases.find_by(primary_alias: true) || aliases.first
          person.update!(default_alias_id: primary.id) if primary
        end
      else
        name = info["name"].presence || email
        al = Alias.create!(person: person, user: user, name: name, email: email, verified_at: Time.current)
        person.update!(default_alias_id: al.id) if person.default_alias_id.nil?
      end

      identity = Identity.create!(user: user, provider: provider, uid: uid, email: email, raw_info: auth.to_json, last_used_at: Time.current)
    end

    identity.update!(last_used_at: Time.current)

    reset_session
    session[:user_id] = identity.user_id
    redirect_to root_path, notice: "Signed in with Google"
  rescue => e
    Rails.logger.error("OIDC error: #{e.class}: #{e.message}")
    redirect_to new_session_path, alert: "Could not sign in with Google."
  end
end
