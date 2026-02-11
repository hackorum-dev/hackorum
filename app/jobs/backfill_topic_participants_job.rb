class BackfillTopicParticipantsJob < ApplicationJob
  queue_as :default

  def perform(topic_id = nil)
    if topic_id
      topic = Topic.find(topic_id)
      topic.recalculate_participants!
    else
      backfill_all
    end
  end

  private

  def backfill_all
    contributor_person_ids = ContributorMembership.distinct.pluck(:person_id).to_set

    Topic.find_each do |topic|
      backfill_topic(topic, contributor_person_ids)
    end
  end

  def backfill_topic(topic, contributor_person_ids)
    stats = topic.messages
                 .group(:sender_person_id)
                 .pluck(
                   Arel.sql("sender_person_id"),
                   Arel.sql("COUNT(*)"),
                   Arel.sql("MIN(messages.created_at)"),
                   Arel.sql("MAX(messages.created_at)")
                 )

    return if stats.empty?

    participants_data = stats.map do |person_id, msg_count, first_at, last_at|
      {
        topic_id: topic.id,
        person_id: person_id,
        message_count: msg_count,
        first_message_at: first_at,
        last_message_at: last_at,
        is_contributor: contributor_person_ids.include?(person_id),
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    TopicParticipant.upsert_all(
      participants_data,
      unique_by: [ :topic_id, :person_id ]
    )

    last_stat = stats.max_by { |_, _, _, last_at| last_at }
    contributor_count = stats.count { |person_id, _, _, _| contributor_person_ids.include?(person_id) }

    highest_type = nil
    if contributor_count > 0
      contributor_ids_in_topic = stats
        .select { |person_id, _, _, _| contributor_person_ids.include?(person_id) }
        .map(&:first)
      types = ContributorMembership.where(person_id: contributor_ids_in_topic).pluck(:contributor_type)
      highest_type = types.min_by { |t| Topic::CONTRIBUTOR_TYPE_RANK[t] || 99 }
    end

    topic.update_columns(
      participant_count: stats.size,
      contributor_participant_count: contributor_count,
      highest_contributor_type: highest_type,
      message_count: stats.sum { |_, count, _, _| count },
      last_message_at: last_stat&.dig(3),
      last_sender_person_id: last_stat&.dig(0)
    )
  end
end
