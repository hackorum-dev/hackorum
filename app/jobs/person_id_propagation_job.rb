class PersonIdPropagationJob < ApplicationJob
  queue_as :default

  def perform(alias_id, new_person_id, old_person_id)
    # Update topics where this alias is the creator
    Topic.where(creator_id: alias_id)
         .where.not(creator_person_id: new_person_id)
         .update_all(creator_person_id: new_person_id)

    # Update messages where this alias is the sender (in batches for large datasets)
    Message.where(sender_id: alias_id)
           .where.not(sender_person_id: new_person_id)
           .in_batches(of: 1000)
           .update_all(sender_person_id: new_person_id)

    # Update mentions where this alias is mentioned
    Mention.where(alias_id: alias_id)
           .where.not(person_id: new_person_id)
           .update_all(person_id: new_person_id)

    # Merge topic_participants from old person to new person
    merge_topic_participants(old_person_id, new_person_id) if old_person_id && old_person_id != new_person_id
  end

  private

  def merge_topic_participants(old_person_id, new_person_id)
    is_new_contributor = ContributorMembership.exists?(person_id: new_person_id)
    affected_topic_ids = []

    TopicParticipant.where(person_id: old_person_id).find_each do |old_tp|
      existing = TopicParticipant.find_by(topic_id: old_tp.topic_id, person_id: new_person_id)

      if existing
        # Merge stats into existing record
        existing.update!(
          message_count: existing.message_count + old_tp.message_count,
          first_message_at: [ existing.first_message_at, old_tp.first_message_at ].min,
          last_message_at: [ existing.last_message_at, old_tp.last_message_at ].max,
          is_contributor: is_new_contributor
        )
        old_tp.destroy!
      else
        # Just reassign to new person
        old_tp.update!(person_id: new_person_id, is_contributor: is_new_contributor)
      end

      affected_topic_ids << old_tp.topic_id
    end

    # Update denormalized counts on affected topics
    Topic.where(id: affected_topic_ids.uniq).find_each(&:update_denormalized_counts!)
  end
end
