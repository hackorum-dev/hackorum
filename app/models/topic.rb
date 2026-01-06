class Topic < ApplicationRecord
  belongs_to :creator, class_name: 'Alias', inverse_of: :topics
  has_many :messages
  has_many :attachments, through: :messages
  has_many :notes, dependent: :destroy
  has_many :commitfest_patch_topics, dependent: :destroy
  has_many :commitfest_patches, through: :commitfest_patch_topics
  
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
end
