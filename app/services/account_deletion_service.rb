# frozen_string_literal: true

# Erases an account. The users row stays as a tombstone so global notes,
# audit logs and the username reservation keep pointing somewhere.
# Aliases seen in the archive are detached, the rest are deleted.
class AccountDeletionService
  def initialize(user)
    @user = user
  end

  def call
    identities = Identity.where(user_id: user.id).to_a
    person = user.person

    ActiveRecord::Base.transaction do
      delete_account_data
      delete_notes
      handle_aliases(person)
      user.update_columns(
        username: nil, password_digest: nil, person_id: nil, last_login_at: nil,
        aware_before: nil, deleted_at: Time.current, updated_at: Time.current
      )
      delete_person(person) if person
    end

    identities.each(&:revoke_remotely)
  end

  private

  attr_reader :user

  def delete_account_data
    Identity.where(user_id: user.id).delete_all
    TeamMember.where(user_id: user.id).delete_all
    UserToken.where(user_id: user.id).delete_all
    UserFeature.where(user_id: user.id).delete_all
    TopicStar.where(user_id: user.id).delete_all
    TopicIgnore.where(user_id: user.id).delete_all
    MessageReadRange.where(user_id: user.id).delete_all
    ThreadAwareness.where(user_id: user.id).delete_all
    Activity.where(user_id: user.id).delete_all
    OutgoingDraft.where(user_id: user.id).delete_all
    SavedSearchPreference.where(user_id: user.id).delete_all
    SavedSearch.where(user_id: user.id).destroy_all
    NoteMention.where(mentionable_type: "User", mentionable_id: user.id).delete_all
  end

  # global notes are shared content, they stay under the tombstone
  def delete_notes
    notes = Note.where(author_id: user.id)
    notes.where(global: false).or(notes.where.not(deleted_at: nil)).destroy_all
  end

  def handle_aliases(person)
    Alias.where(user_id: user.id).find_each do |al|
      if in_archive?(al)
        al.update_columns(user_id: nil, verified_at: nil)
      else
        Person.where(default_alias_id: al.id).update_all(default_alias_id: nil)
        delete_or_detach(al)
      end
    end

    if person && person.reload.default_alias_id.nil?
      fallback = person.aliases.order(sender_count: :desc).first
      person.update_columns(default_alias_id: fallback.id) if fallback
    end
  end

  def in_archive?(al)
    al.sender_count.positive? || Message.exists?(sender_id: al.id) || Mention.exists?(alias_id: al.id)
  end

  def delete_or_detach(al)
    ActiveRecord::Base.transaction(requires_new: true) { al.delete }
  rescue ActiveRecord::InvalidForeignKey
    al.update_columns(user_id: nil, verified_at: nil)
  end

  def delete_person(person)
    return if person.aliases.exists?
    ActiveRecord::Base.transaction(requires_new: true) { Person.where(id: person.id).delete_all }
  rescue ActiveRecord::InvalidForeignKey
    nil
  end
end
