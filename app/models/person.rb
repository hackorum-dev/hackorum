class Person < ApplicationRecord
  has_one :user
  has_many :aliases
  has_many :contributor_memberships, dependent: :destroy
  has_many :created_topics, class_name: 'Topic', foreign_key: 'creator_person_id'
  has_many :sent_messages, class_name: 'Message', foreign_key: 'sender_person_id'
  has_many :mentions
  has_many :topic_participants

  belongs_to :default_alias, class_name: 'Alias', optional: true

  def display_name
    default_alias&.name || aliases.order(:created_at).first&.name || "Unknown"
  end

  CONTRIBUTOR_RANK = {
    'core_team' => 1,
    'committer' => 2,
    'major_contributor' => 3,
    'significant_contributor' => 4,
    'past_major_contributor' => 5,
    'past_significant_contributor' => 6
  }.freeze

  def contributor_membership_types
    @contributor_membership_types ||= contributor_memberships.load.map(&:contributor_type)
  end

  def contributor?
    contributor_membership_types.any?
  end

  def contributor_type
    types = contributor_membership_types
    return nil if types.empty?
    types.min_by { |t| CONTRIBUTOR_RANK[t] || 99 }
  end

  def contributor_badge
    case contributor_type
    when 'core_team' then 'Core Team'
    when 'committer' then 'Committer'
    when 'major_contributor' then 'Major Contributor'
    when 'significant_contributor' then 'Contributor'
    when 'past_major_contributor' then 'Past Contributor'
    when 'past_significant_contributor' then 'Past Contributor'
    end
  end

  def core_team?
    contributor_membership_types.include?('core_team')
  end

  def committer?
    contributor_membership_types.include?('committer')
  end

  def major_contributor?
    contributor_membership_types.include?('major_contributor')
  end

  def significant_contributor?
    contributor_membership_types.include?('significant_contributor')
  end

  def past_contributor?
    types = contributor_membership_types
    types.include?('past_major_contributor') || types.include?('past_significant_contributor')
  end

  def display_name
    default_alias&.name || aliases.order(:created_at).first&.name || "Unknown"
  end

  def self.find_by_email(email)
    Alias.by_email(email).where.not(person_id: nil).includes(:person).first&.person
  end

  def self.find_or_create_by_email(email)
    find_by_email(email) || create!
  end

  def self.attach_alias_group!(email, person:, user: nil)
    scope = Alias.by_email(email)
    scope = scope.where(user_id: [nil, user.id]) if user
    scope.update_all(person_id: person.id)
  end

  def attach_alias!(alias_record, user: nil)
    old_person = alias_record.person
    alias_record.update!(person_id: id, user_id: user&.id || alias_record.user_id)
    if old_person && old_person.id != id
      merge_contributor_memberships_from(old_person)
      cleanup_orphaned_person(old_person)
    end
  end

  def cleanup_orphaned_person(person)
    return if person.user.present?
    return if Alias.where(person_id: person.id).exists?
    reassign_authored_records(person)
    person.destroy!
  end

  def reassign_authored_records(old_person)
    Topic.where(creator_person_id: old_person.id).update_all(creator_person_id: id)
    Topic.where(last_sender_person_id: old_person.id).update_all(last_sender_person_id: id)
    Message.where(sender_person_id: old_person.id).update_all(sender_person_id: id)
    Mention.where(person_id: old_person.id).update_all(person_id: id)
    TopicParticipant.where(person_id: old_person.id).where.not(topic_id: TopicParticipant.where(person_id: id).select(:topic_id)).update_all(person_id: id)
    TopicParticipant.where(person_id: old_person.id).delete_all
  end

  def merge_contributor_memberships_from(other_person)
    other_person.contributor_memberships.find_each do |membership|
      ContributorMembership.find_or_create_by!(person_id: id, contributor_type: membership.contributor_type) do |record|
        record.description = membership.description
      end
    end
  end

  def recalculate_default_alias!
    best = find_best_default_alias
    update!(default_alias: best) if best && best.id != default_alias_id
  end

  def find_best_default_alias
    candidates = aliases.reload

    # First: non-Noname aliases that have sent messages, ordered by sender_count
    best_sender = candidates.with_sent_messages
                            .where.not(name: 'Noname')
                            .order(sender_count: :desc)
                            .first
    return best_sender if best_sender

    # Second: any non-Noname alias (even mention-only)
    non_noname = candidates.where.not(name: 'Noname').order(sender_count: :desc, created_at: :asc).first
    return non_noname if non_noname

    # Third: Noname alias with highest sender_count (if they actually sent messages)
    noname_sender = candidates.with_sent_messages.order(sender_count: :desc).first
    return noname_sender if noname_sender

    # Last resort: any alias (keep existing or first)
    default_alias || candidates.order(:created_at).first
  end
end
