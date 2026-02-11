class BackfillPeople < ActiveRecord::Migration[8.0]
  class MigrationUser < ApplicationRecord
    self.table_name = 'users'
  end

  class MigrationAlias < ApplicationRecord
    self.table_name = 'aliases'
    has_many :messages, class_name: 'BackfillPeople::MigrationMessage', foreign_key: 'sender_id'

    scope :by_email, ->(email) {
      where("lower(trim(email)) = lower(trim(?))", email)
    }
  end

  class MigrationPerson < ApplicationRecord
    self.table_name = 'people'
  end

  class MigrationMessage < ApplicationRecord
    self.table_name = 'messages'
  end

  def up
    say_with_time "Backfilling people for users and aliases" do
      backfill_people
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def backfill_people
    MigrationUser.reset_column_information
    MigrationAlias.reset_column_information
    MigrationPerson.reset_column_information

    MigrationUser.find_each do |user|
      person = user.person_id && MigrationPerson.find_by(id: user.person_id)
      unless person
        person = MigrationPerson.create!
        user.update_columns(person_id: person.id)
      end

      MigrationAlias.where(user_id: user.id).find_each do |al|
        MigrationAlias.by_email(al.email).where(user_id: [ nil, user.id ]).update_all(person_id: person.id)
      end
    end

    MigrationUser.where(person_id: nil).find_each do |user|
      person = MigrationPerson.create!
      user.update_columns(person_id: person.id)
      MigrationAlias.where(user_id: user.id).update_all(person_id: person.id)
    end

    normalized_emails = MigrationAlias
                          .where(user_id: nil, person_id: nil)
                          .distinct
                          .pluck(Arel.sql("lower(trim(email))"))

    normalized_emails.each do |normalized_email|
      person = MigrationPerson.create!
      MigrationAlias
        .where(user_id: nil, person_id: nil)
        .where("lower(trim(email)) = ?", normalized_email)
        .update_all(person_id: person.id)
    end

    MigrationPerson.where(default_alias_id: nil).find_each do |person|
      alias_scope = MigrationAlias.where(person_id: person.id)
      next unless alias_scope.exists?

      user = MigrationUser.find_by(person_id: person.id)
      default_alias = if user
        MigrationAlias.where(user_id: user.id, primary_alias: true).first
      end

      default_alias ||= alias_scope
                         .left_joins(:messages)
                         .group("aliases.id")
                         .order(Arel.sql("MAX(messages.created_at) DESC NULLS LAST, aliases.created_at DESC"))
                         .first
      person.update_columns(default_alias_id: default_alias.id)
    end
  end
end
