class BackfillTopicParticipants < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    contributor_person_ids = ContributorMembership.distinct.pluck(:person_id).to_set

    say_with_time "Backfilling topic_participants" do
      Topic.find_each.with_index do |topic, index|
        backfill_topic(topic, contributor_person_ids)
        say("Processed #{index + 1} topics", true) if (index + 1) % 1000 == 0
      end
    end
  end

  def down
    TopicParticipant.delete_all
    Topic.update_all(
      participant_count: 0,
      contributor_participant_count: 0,
      highest_contributor_type: nil,
      message_count: 0,
      last_message_at: nil,
      last_sender_person_id: nil
    )
  end

  private

  def backfill_topic(topic, contributor_person_ids)
    stats = topic.messages
                 .group(:sender_person_id)
                 .pluck(
                   Arel.sql('sender_person_id'),
                   Arel.sql('COUNT(*)'),
                   Arel.sql('MIN(messages.created_at)'),
                   Arel.sql('MAX(messages.created_at)')
                 )

    return if stats.empty?

    now = Time.current

    participants_data = stats.map do |person_id, msg_count, first_at, last_at|
      {
        topic_id: topic.id,
        person_id: person_id,
        message_count: msg_count,
        first_message_at: first_at,
        last_message_at: last_at,
        is_contributor: contributor_person_ids.include?(person_id),
        created_at: now,
        updated_at: now
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
