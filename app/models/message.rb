class Message < ApplicationRecord
  belongs_to :topic
  belongs_to :sender, class_name: "Alias", inverse_of: :messages, counter_cache: :sender_count
  belongs_to :sender_person, class_name: "Person"
  belongs_to :reply_to, class_name: "Message", inverse_of: :replies, optional: true

  has_many :replies, class_name: "Message", foreign_key: "reply_to_id", inverse_of: :reply_to
  has_many :attachments

  has_many :mentions
  has_many :mentioned_aliases, through: :mentions, source: :alias
  has_many :notes

  validates :subject, presence: true
  # Body may be blank for some historical imports; allow blank but keep presence on subject.
  validates :body, presence: true, allow_blank: true
  validates :message_id, uniqueness: true, allow_nil: true

  after_create :update_topic_participant_on_create
  after_destroy :update_topic_participant_on_destroy

  def sender_display_alias
    sender_person&.default_alias || sender
  end

  private

  def update_topic_participant_on_create
    is_contributor = ContributorMembership.exists?(person_id: sender_person_id)

    participant = TopicParticipant.find_or_initialize_by(
      topic_id: topic_id,
      person_id: sender_person_id
    )

    if participant.new_record?
      participant.assign_attributes(
        message_count: 1,
        first_message_at: created_at,
        last_message_at: created_at,
        is_contributor: is_contributor
      )
      participant.save!

      # Update topic counts
      topic.increment!(:participant_count)
      topic.increment!(:contributor_participant_count) if is_contributor
    else
      participant.increment!(:message_count)
      participant.update_columns(last_message_at: created_at) if created_at > participant.last_message_at
    end

    # Update topic message stats
    topic.increment!(:message_count)
    if topic.last_message_at.nil? || created_at > topic.last_message_at
      updates = { last_message_at: created_at, last_message_id: id, last_sender_person_id: sender_person_id }

      # Update highest_contributor_type if needed
      if is_contributor && topic.highest_contributor_type.nil?
        contributor_type = ContributorMembership.where(person_id: sender_person_id)
                                                 .pluck(:contributor_type)
                                                 .min_by { |t| Topic::CONTRIBUTOR_TYPE_RANK[t] || 99 }
        updates[:highest_contributor_type] = contributor_type if contributor_type
      elsif is_contributor
        # Check if this contributor has a higher rank
        contributor_type = ContributorMembership.where(person_id: sender_person_id)
                                                 .pluck(:contributor_type)
                                                 .min_by { |t| Topic::CONTRIBUTOR_TYPE_RANK[t] || 99 }
        current_rank = Topic::CONTRIBUTOR_TYPE_RANK[topic.highest_contributor_type] || 99
        new_rank = Topic::CONTRIBUTOR_TYPE_RANK[contributor_type] || 99
        updates[:highest_contributor_type] = contributor_type if new_rank < current_rank
      end

      topic.update_columns(updates)
    end
  end

  def update_topic_participant_on_destroy
    participant = TopicParticipant.find_by(topic_id: topic_id, person_id: sender_person_id)
    return unless participant

    if participant.message_count <= 1
      was_contributor = participant.is_contributor
      participant.destroy!

      # Update topic counts
      topic.decrement!(:participant_count)
      topic.decrement!(:contributor_participant_count) if was_contributor

      # Recalculate highest_contributor_type if we removed a contributor
      if was_contributor
        topic.reload
        recalculate_highest_contributor_type
      end
    else
      participant.decrement!(:message_count)
      # Recalculate last_message_at for this participant
      new_last_at = topic.messages.where(sender_person_id: sender_person_id).maximum(:created_at)
      participant.update_columns(last_message_at: new_last_at) if new_last_at
    end

    # Update topic message stats
    topic.decrement!(:message_count)

    # Recalculate last message info if this was the last message
    if topic.last_message_id == id
      last_msg = topic.messages.where.not(id: id).order(created_at: :desc, id: :desc).first
      topic.update_columns(
        last_message_at: last_msg&.created_at,
        last_message_id: last_msg&.id,
        last_sender_person_id: last_msg&.sender_person_id
      )
    end
  end

  def recalculate_highest_contributor_type
    contributor_participants = topic.topic_participants.where(is_contributor: true)
    if contributor_participants.exists?
      contributor_person_ids = contributor_participants.pluck(:person_id)
      types = ContributorMembership.where(person_id: contributor_person_ids).pluck(:contributor_type)
      highest_type = types.min_by { |t| Topic::CONTRIBUTOR_TYPE_RANK[t] || 99 }
      topic.update_columns(highest_contributor_type: highest_type)
    else
      topic.update_columns(highest_contributor_type: nil)
    end
  end
end
