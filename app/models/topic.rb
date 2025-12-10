class Topic < ApplicationRecord
  belongs_to :creator, class_name: 'Alias', inverse_of: :topics
  has_many :messages
  has_many :attachments, through: :messages
  has_many :notes, dependent: :destroy
  
  validates :title, presence: true

  def participant_count
    messages.select(:sender_id).distinct.count
  end

  def participant_aliases(limit: 10)
    # Get all unique senders from messages, with their message counts
    sender_counts = messages.group(:sender_id)
                            .select('sender_id, COUNT(*) as message_count')
                            .order('message_count DESC')
                            .limit(50)
                            .index_by(&:sender_id)

    sender_ids = sender_counts.keys
    senders_by_id = Alias.where(id: sender_ids).index_by(&:id)

    first_sender = messages.order(:created_at).first.sender
    last_sender = messages.order(:created_at).last.sender

    participants = []

    participants << first_sender if first_sender

    first_and_last = [first_sender&.id, last_sender&.id].compact.uniq
    other_senders = sender_ids - first_and_last
    other_participants = other_senders
      .map { |id| senders_by_id[id] }
      .compact
      .sort_by { |s| -sender_counts[s.id].message_count }
      .take(limit - first_and_last.length)

    participants.concat(other_participants)

    if last_sender && last_sender.id != first_sender&.id
      participants << last_sender
    end

    participants
  end

  def has_contributor_activity?
    @has_contributor_activity ||= begin
      contributor_alias_ids = Contributor.joins(:aliases).pluck('aliases.id').uniq
      messages.where(sender_id: contributor_alias_ids).exists?
    end
  end

  def has_core_team_activity?
    @has_core_team_activity ||= begin
      core_alias_ids = Contributor.core_team.joins(:aliases).pluck('aliases.id').uniq
      messages.where(sender_id: core_alias_ids).exists?
    end
  end

  def has_committer_activity?
    @has_committer_activity ||= begin
      committer_alias_ids = Contributor.committers.joins(:aliases).pluck('aliases.id').uniq
      messages.where(sender_id: committer_alias_ids).exists?
    end
  end

  def contributor_participants
    @contributor_participants ||= begin
      contributor_alias_ids = Contributor.joins(:aliases).pluck('aliases.id').uniq
      return [] if contributor_alias_ids.empty?

      stats = messages.where(sender_id: contributor_alias_ids)
                      .group(:sender_id)
                      .select('sender_id, COUNT(*) AS message_count, MAX(created_at) AS last_at')

      alias_map = Alias.includes(:contributors).where(id: stats.map(&:sender_id)).index_by(&:id)

      stats.map do |row|
        alias_record = alias_map[row.sender_id]
        next unless alias_record

        {
          alias: alias_record,
          message_count: row.read_attribute(:message_count).to_i,
          last_at: row.read_attribute(:last_at)
        }
      end.compact.sort_by { |p| [-p[:message_count], p[:alias].name] }
    end
  end

  def highest_contributor_activity
    return "core_team" if has_core_team_activity?
    return "committer" if has_committer_activity?
    return "contributor" if has_contributor_activity?
    nil
  end
end
