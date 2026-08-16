# frozen_string_literal: true

class PersonMergeService
  class Error < StandardError; end

  Result = Struct.new(:success?, :person_merge, :error, keyword_init: true)

  def initialize(source_person:, target_person:, merged_by:)
    @source_person = source_person
    @target_person = target_person
    @merged_by = merged_by
  end

  def call
    validate!

    moved_alias_ids = source_person.aliases.pluck(:id)
    counts = move_counts
    person_merge = nil

    ActiveRecord::Base.transaction do
      person_merge = create_audit_record!(counts)

      Alias.where(person_id: source_person.id).update_all(person_id: target_person.id)
      target_person.merge_contributor_memberships_from(source_person)
      # must run before reassign_authored_records, which drops any participant
      # row for a topic both people are in instead of summing it
      affected_topic_ids = merge_topic_participants!
      target_person.reassign_authored_records(source_person)
      # reassign_authored_records does not know about commit credits, and the
      # column carries a foreign key, so the destroy below would fail without it
      CommitPerson.where(person_id: source_person.id).update_all(person_id: target_person.id)

      source_person.update_columns(default_alias_id: nil)
      source_person.destroy!
      target_person.recalculate_default_alias!
      Topic.where(id: affected_topic_ids).find_each(&:update_denormalized_counts!)
    end

    # update_all skips the after_commit hook that normally queues these
    moved_alias_ids.each do |alias_id|
      PersonIdPropagationJob.perform_later(alias_id, target_person.id, source_person.id)
    end

    Result.new(success?: true, person_merge: person_merge)
  rescue Error => e
    Result.new(success?: false, error: e.message)
  rescue ActiveRecord::RecordInvalid => e
    Result.new(success?: false, error: e.record.errors.full_messages.join(", "))
  end

  def preview
    {
      source: person_summary(source_person),
      target: person_summary(target_person),
      moves: move_counts
    }
  end

  def validation_error
    validate!
    nil
  rescue Error => e
    e.message
  end

  private

  attr_reader :source_person, :target_person, :merged_by

  def validate!
    raise Error, "Source person not found" unless source_person
    raise Error, "Target person not found" unless target_person
    raise Error, "Cannot merge a person into itself" if source_person.id == target_person.id
    raise Error, "User must be an admin" unless merged_by&.admin?

    if source_person.user.present?
      raise Error, "Source person has a user account. Merge in the other direction, " \
                   "or delete the account first."
    end
  end

  # Both people can sit in the same topic. Sum the two rows into one rather
  # than keeping the target's and dropping the source's, which would lose the
  # source's message_count and pull first_message_at forward.
  def merge_topic_participants!
    contributor = ContributorMembership.exists?(person_id: target_person.id)
    affected_topic_ids = []

    TopicParticipant.where(person_id: source_person.id).find_each do |source_row|
      existing = TopicParticipant.find_by(topic_id: source_row.topic_id, person_id: target_person.id)

      if existing
        existing.update!(
          message_count: existing.message_count + source_row.message_count,
          first_message_at: [ existing.first_message_at, source_row.first_message_at ].compact.min,
          last_message_at: [ existing.last_message_at, source_row.last_message_at ].compact.max,
          is_contributor: contributor
        )
        source_row.destroy!
      else
        source_row.update!(person_id: target_person.id, is_contributor: contributor)
      end

      affected_topic_ids << source_row.topic_id
    end

    affected_topic_ids.uniq
  end

  def move_counts
    {
      aliases: Alias.where(person_id: source_person.id).count,
      topics: Topic.where(creator_person_id: source_person.id).count,
      messages: Message.where(sender_person_id: source_person.id).count,
      mentions: Mention.where(person_id: source_person.id).count
    }
  end

  def create_audit_record!(counts)
    PersonMerge.create!(
      performed_by: merged_by,
      source_person_id: source_person.id,
      target_person_id: target_person.id,
      source_name: source_person.display_name,
      target_name: target_person.display_name,
      source_emails: source_person.aliases.map(&:email).uniq,
      aliases_moved: counts[:aliases],
      topics_moved: counts[:topics],
      messages_moved: counts[:messages]
    )
  end

  def person_summary(person)
    {
      id: person.id,
      name: person.display_name,
      emails: person.aliases.map(&:email).uniq,
      message_count: person.aliases.sum(&:sender_count),
      user: person.user,
      contributor_badge: person.contributor_badge
    }
  end
end
