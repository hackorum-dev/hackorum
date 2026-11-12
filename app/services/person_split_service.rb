# frozen_string_literal: true

# Undo a wrong merge: moves every alias of the given emails, and what was sent
# or credited through them, onto a new person. Name-only commit credits are
# cleared, the importer's relink puts them back on the right side.
class PersonSplitService
  class Error < StandardError; end

  Result = Struct.new(:success?, :person, :error, keyword_init: true)

  def initialize(person:, emails:, membership_ids: [])
    @person = person
    @emails = emails.map { |e| e.to_s.downcase.strip }.reject(&:empty?).uniq
    @membership_ids = membership_ids
  end

  def call
    new_person = nil

    ActiveRecord::Base.transaction do
      alias_ids = moved_aliases.pluck(:id)
      validate!(alias_ids)

      new_person = Person.create!
      topic_ids = Message.where(sender_id: alias_ids).distinct.pluck(:topic_id)

      Alias.where(id: alias_ids).update_all(person_id: new_person.id)
      Message.where(sender_id: alias_ids).in_batches(of: 1000).update_all(sender_person_id: new_person.id)
      FeedEvent.sync_authors(alias_ids)
      Topic.where(creator_id: alias_ids).update_all(creator_person_id: new_person.id)
      Mention.where(alias_id: alias_ids).update_all(person_id: new_person.id)

      credits = CommitPerson.where(person_id: person.id)
      by_email = credits.where("lower(trim(raw_email)) IN (?)", emails)
      name_only = credits.where(raw_email: nil)
      moved = by_email.or(name_only).distinct.pluck(:commit_id)
      by_email.update_all(person_id: new_person.id)
      name_only.update_all(person_id: nil)
      moved.each_slice(1000) { |ids| CommitterReviewer.sync!(ids) }

      ContributorMembership.where(person_id: person.id, id: membership_ids).update_all(person_id: new_person.id)

      person.update_columns(default_alias_id: nil) if alias_ids.include?(person.default_alias_id)
      person.recalculate_default_alias!
      new_person.recalculate_default_alias!

      Topic.where(id: topic_ids).find_each(&:recalculate_participants!)
    end

    Result.new(success?: true, person: new_person)
  rescue Error => e
    Result.new(success?: false, error: e.message)
  end

  private

  attr_reader :person, :emails, :membership_ids

  def moved_aliases
    Alias.where(person_id: person.id).where("lower(trim(email)) IN (?)", emails)
  end

  def validate!(alias_ids)
    raise Error, "No aliases of #{person.id} match #{emails.join(', ')}" if alias_ids.empty?
    raise Error, "Would move every alias of #{person.id}" if Alias.where(person_id: person.id).where.not(id: alias_ids).none?
    raise Error, "Aliases claimed by a user account, detach them first" if Alias.where(id: alias_ids).where.not(user_id: nil).exists?
  end
end
