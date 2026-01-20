class Topic < ApplicationRecord
  CONTRIBUTOR_TYPE_RANK = {
    'core_team' => 1,
    'committer' => 2,
    'major_contributor' => 3,
    'significant_contributor' => 4,
    'past_major_contributor' => 5,
    'past_significant_contributor' => 6
  }.freeze

  belongs_to :creator, class_name: 'Alias', inverse_of: :topics
  belongs_to :creator_person, class_name: 'Person'
  belongs_to :last_sender_person, class_name: 'Person', optional: true
  belongs_to :merged_into_topic, class_name: 'Topic', optional: true
  has_many :messages
  has_many :attachments, through: :messages
  has_many :notes, dependent: :destroy
  has_many :commitfest_patch_topics, dependent: :destroy
  has_many :commitfest_patches, through: :commitfest_patch_topics
  has_many :topic_stars, dependent: :destroy
  has_many :starring_users, through: :topic_stars, source: :user
  has_many :topic_participants, dependent: :delete_all
  has_many :top_topic_participants,
           -> { order(message_count: :desc).limit(5) },
           class_name: 'TopicParticipant'
  has_many :contributor_topic_participants,
           -> { where(is_contributor: true).order(message_count: :desc) },
           class_name: 'TopicParticipant'
  has_many :topics_merged_into_this, class_name: 'Topic', foreign_key: :merged_into_topic_id
  has_one :topic_merge_as_source, class_name: 'TopicMerge', foreign_key: :source_topic_id
  has_many :topic_merges_as_target, class_name: 'TopicMerge', foreign_key: :target_topic_id

  scope :active, -> { where(merged_into_topic_id: nil) }
  scope :merged, -> { where.not(merged_into_topic_id: nil) }

  validates :title, presence: true

  def creator_display_alias
    creator_person&.default_alias || creator
  end

  def participant_aliases(limit: 10)
    # Get all unique senders from messages, with their message counts
    sender_counts = messages.group(:sender_id)
                            .select('sender_id, COUNT(*) as message_count')
                            .order('message_count DESC')
                            .limit(50)
                            .index_by(&:sender_id)

    sender_ids = sender_counts.keys
    senders_by_id = Alias.includes(person: :contributor_memberships).where(id: sender_ids).index_by(&:id)

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

  def participant_alias_stats(limit: 10)
    stats = messages.group(:sender_id)
                    .select('sender_id, COUNT(*) as message_count, MAX(messages.created_at) AS last_at')
                    .order('message_count DESC')
                    .limit(50)
                    .index_by(&:sender_id)

    first_sender = messages.order(:created_at).first&.sender
    last_sender = messages.order(:created_at).last&.sender

    missing_ids = [first_sender&.id, last_sender&.id].compact.uniq - stats.keys
    if missing_ids.any?
      extra_stats = messages.where(sender_id: missing_ids)
                            .group(:sender_id)
                            .select('sender_id, COUNT(*) as message_count, MAX(messages.created_at) AS last_at')
                            .index_by(&:sender_id)
      stats.merge!(extra_stats)
    end

    sender_ids = stats.keys
    senders_by_id = Alias.includes(person: :contributor_memberships).where(id: sender_ids).index_by(&:id)

    entry_for = lambda do |alias_record|
      return nil unless alias_record

      stat = stats[alias_record.id]
      {
        alias: alias_record,
        person: alias_record.person,
        message_count: stat&.read_attribute(:message_count)&.to_i,
        last_at: stat&.read_attribute(:last_at)
      }
    end

    participants = []

    participants << entry_for.call(first_sender) if first_sender

    first_and_last = [first_sender&.id, last_sender&.id].compact.uniq
    other_senders = sender_ids - first_and_last
    remaining = [limit - first_and_last.length, 0].max
    other_participants = other_senders
      .map { |id| senders_by_id[id] }
      .compact
      .sort_by { |s| -stats[s.id].read_attribute(:message_count).to_i }
      .take(remaining)

    participants.concat(other_participants.map { |alias_record| entry_for.call(alias_record) }.compact)

    if last_sender && last_sender.id != first_sender&.id
      participants << entry_for.call(last_sender)
    end

    participants.compact
  end

  def has_contributor_activity?
    @has_contributor_activity ||= begin
      contributor_people = ContributorMembership.select(:person_id).distinct
      messages.joins(sender: :person).where(people: { id: contributor_people }).exists?
    end
  end

  def has_core_team_activity?
    @has_core_team_activity ||= begin
      core_people = ContributorMembership.core_team.select(:person_id)
      messages.joins(sender: :person).where(people: { id: core_people }).exists?
    end
  end

  def has_committer_activity?
    @has_committer_activity ||= begin
      committer_people = ContributorMembership.committer.select(:person_id)
      messages.joins(sender: :person).where(people: { id: committer_people }).exists?
    end
  end

  def contributor_participants
    @contributor_participants ||= begin
      contributor_ids = ContributorMembership.select(:person_id).distinct
      return [] unless contributor_ids.exists?

      stats = messages.joins(sender: :person)
                      .where(people: { id: contributor_ids })
                      .group('people.id')
                      .select('people.id AS person_id, COUNT(*) AS message_count, MAX(messages.created_at) AS last_at')

      people = Person.includes(:default_alias, :contributor_memberships).where(id: stats.map(&:person_id)).index_by(&:id)

      stats.map do |row|
        person = people[row.person_id]
        alias_record = person&.default_alias
        next unless alias_record

        {
          alias: alias_record,
          person: person,
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

  # Rebuild topic_participants from messages and update denormalized counts
  def recalculate_participants!
    contributor_person_ids = ContributorMembership.distinct.pluck(:person_id).to_set

    # Aggregate message stats per person
    stats = messages.group(:sender_person_id)
                    .select(
                      'sender_person_id',
                      'COUNT(*) AS msg_count',
                      'MIN(messages.created_at) AS first_at',
                      'MAX(messages.created_at) AS last_at'
                    )

    # Clear existing participants and rebuild
    topic_participants.delete_all

    stats.each do |row|
      person_id = row.sender_person_id
      TopicParticipant.create!(
        topic_id: id,
        person_id: person_id,
        message_count: row.msg_count,
        first_message_at: row.first_at,
        last_message_at: row.last_at,
        is_contributor: contributor_person_ids.include?(person_id)
      )
    end

    update_denormalized_counts!
  end

  # Update denormalized counts on the topic from topic_participants
  def update_denormalized_counts!
    last_msg = messages.order(created_at: :desc, id: :desc).first

    participants = topic_participants.reload
    contributor_participants_rel = participants.where(is_contributor: true)

    # Calculate highest contributor type from actual contributor memberships
    highest_type = nil
    if contributor_participants_rel.exists?
      contributor_person_ids = contributor_participants_rel.pluck(:person_id)
      types = ContributorMembership.where(person_id: contributor_person_ids).pluck(:contributor_type)
      highest_type = types.min_by { |t| CONTRIBUTOR_TYPE_RANK[t] || 99 }
    end

    update_columns(
      participant_count: participants.count,
      contributor_participant_count: contributor_participants_rel.count,
      highest_contributor_type: highest_type,
      message_count: messages.count,
      last_message_at: last_msg&.created_at,
      last_message_id: last_msg&.id,
      last_sender_person_id: last_msg&.sender_person_id
    )
  end

  def self.commitfest_summaries(topic_ids)
    ids = Array(topic_ids).map(&:to_i).uniq
    return {} if ids.empty?

    sql = ApplicationRecord.sanitize_sql_array([<<~SQL, ids])
      SELECT DISTINCT ON (cptop.topic_id)
        cptop.topic_id,
        cf.external_id AS commitfest_external_id,
        cf.name AS commitfest_name,
        cf.end_date AS commitfest_end_date,
        pcc.status AS status,
        pcc.ci_status AS ci_status,
        pcc.ci_score AS ci_score,
        cp.reviewers AS reviewers,
        cp.committer AS committer,
        cp.external_id AS patch_external_id,
        (
          SELECT array_agg(DISTINCT ct.name)
          FROM commitfest_patch_tags cpt
          JOIN commitfest_tags ct ON ct.id = cpt.commitfest_tag_id
          WHERE cpt.commitfest_patch_id = cp.id
        ) AS tag_names
      FROM commitfest_patch_topics cptop
      JOIN commitfest_patches cp ON cp.id = cptop.commitfest_patch_id
      JOIN commitfest_patch_commitfests pcc ON pcc.commitfest_patch_id = cp.id
      JOIN commitfests cf ON cf.id = pcc.commitfest_id
      WHERE cptop.topic_id IN (?)
      ORDER BY cptop.topic_id, cf.end_date DESC, cf.start_date DESC
    SQL

    rows = connection.select_all(sql)
    rows.each_with_object({}) do |row, acc|
      tags = parse_pg_array(row["tag_names"])
      reviewers = parse_csv_list(row["reviewers"])
      acc[row["topic_id"].to_i] = {
        commitfest_external_id: row["commitfest_external_id"].to_i,
        commitfest_name: row["commitfest_name"].to_s,
        status: row["status"].to_s,
        ci_status: row["ci_status"].to_s.presence,
        ci_score: row["ci_score"],
        reviewers: reviewers,
        committer: row["committer"].to_s.strip.presence,
        patch_external_id: row["patch_external_id"].to_i,
        tags: tags,
        committed: row["status"].to_s == "Committed"
      }
    end
  end

  def self.parse_pg_array(value)
    return [] if value.blank?
    text = value.to_s
    return [] if text == "{}"
    text = text[1..-2] if text.start_with?("{") && text.end_with?("}")
    text.split(",").map { |item| item.delete_prefix('"').delete_suffix('"') }.map(&:strip).reject(&:blank?)
  end

  def self.parse_csv_list(value)
    return [] if value.blank?
    value.to_s.split(",").map(&:strip).reject(&:blank?).uniq
  end

  def merged?
    merged_into_topic_id.present?
  end

  def final_topic
    return self unless merged?

    visited = Set.new([id])
    current = merged_into_topic

    while current&.merged?
      break if visited.include?(current.id) # Prevent infinite loops

      visited << current.id
      current = current.merged_into_topic
    end

    current || self
  end

  def self.normalize_title(title)
    title.to_s
         .gsub(/\A\s*(Re|Fwd|Fw):\s*/i, '')
         .gsub(/\s+/, ' ')
         .strip
  end

  def self.suggest_merge_targets(source_topic, limit: 10)
    normalized = normalize_title(source_topic.title)
    return none if normalized.blank?

    active
      .where.not(id: source_topic.id)
      .where("similarity(title, ?) > 0.3", normalized)
      .order(Arel.sql(sanitize_sql_array(["similarity(title, ?) DESC", normalized])))
      .limit(limit)
  end
end
