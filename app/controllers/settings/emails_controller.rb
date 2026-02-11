# frozen_string_literal: true

module Settings
  class EmailsController < Settings::BaseController
    def create
      email = EmailNormalizer.normalize(params[:email])
      name = params[:name].presence

      if Alias.by_email(email).where.not(user_id: [ nil, current_user.id ]).exists?
        return redirect_to settings_account_path, alert: "Email is linked to another account. Delete that account first to release it."
      end

      existing_in_db = Alias.by_email(email)
      user_has_verified = current_user.aliases.by_email(email).where.not(verified_at: nil).exists?

      # Case 1: No aliases exist in DB for this email - require a name
      if !existing_in_db.exists? && name.blank?
        return redirect_to settings_account_path, alert: "Please provide a display name for this new email address."
      end

      # Case 2: User already has verified alias with this email - require a name to create a new alias
      if user_has_verified
        if name.blank?
          return redirect_to settings_account_path, alert: "This email is already verified. Please provide a display name to add a new alias."
        end
        person = current_user.person
        Alias.create!(person: person, user: current_user, name: name, email: email, verified_at: Time.current)
        return redirect_to settings_account_path, notice: "Alias added."
      end

      # Case 3: Email exists in DB but not associated with user - send verification
      metadata = { name: name }.to_json if name.present?
      token, raw = UserToken.issue!(purpose: "add_alias", user: current_user, email: email, ttl: 1.hour, metadata: metadata)
      UserMailer.verification_email(token, raw).deliver_later
      redirect_to settings_account_path, notice: "Verification email sent."
    end

    def destroy
      al = current_user.person.aliases.find(params[:id])

      if current_user.person&.default_alias_id == al.id
        return redirect_to settings_account_path, alert: "Cannot remove primary alias."
      end

      mention_count = Mention.where(alias_id: al.id).count
      if al.sender_count > 0 || mention_count > 0
        return redirect_to settings_account_path, alert: "Cannot remove alias with message history."
      end

      al.destroy!
      redirect_to settings_account_path, notice: "Alias removed."
    end

    def primary
      al = current_user.person.aliases.find(params[:id])
      current_user.person&.update!(default_alias_id: al.id)
      redirect_to settings_account_path, notice: "Primary email updated."
    end
  end
end
