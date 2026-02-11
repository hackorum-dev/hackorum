class Alias < ApplicationRecord
  belongs_to :person
  belongs_to :user, optional: true
  has_many :topics, class_name: "Topic", foreign_key: "creator_id", inverse_of: :creator
  has_many :messages, class_name: "Message", foreign_key: "sender_id", inverse_of: :sender
  has_many :attachments, through: :messages

  validates :name, presence: true
  validates :email, presence: true
  validates :name, uniqueness: { scope: :email }

  after_commit :auto_star_recent_topics, if: :saved_change_to_user_id?
  after_commit :queue_person_id_propagation, if: :saved_change_to_person_id?


  scope :by_email, ->(email) {
    where("lower(trim(email)) = lower(trim(?))", email)
  }

  scope :with_sent_messages, -> { where("sender_count > 0") }
  scope :mention_only, -> { where(sender_count: 0) }

  def mention_only?
    sender_count == 0
  end

  def noname?
    name == "Noname"
  end

  def gravatar_url(size: 80)
    require "digest/md5"
    hash = Digest::MD5.hexdigest(email.downcase.strip)
    "https://www.gravatar.com/avatar/#{hash}?s=#{size}&d=identicon"
  end

  def display_gravatar_url(size: 80)
    (person&.default_alias || self).gravatar_url(size: size)
  end

  def contributor
    person
  end

  CONTRIBUTOR_RANK = {
    "core_team" => 1,
    "committer" => 2,
    "major_contributor" => 3,
    "significant_contributor" => 4,
    "past_major_contributor" => 5,
    "past_significant_contributor" => 6
  }.freeze

  def contributor?
    contributor_membership_types.any?
  end

  def contributor_type
    types = contributor_membership_types
    return nil if types.empty?

    types.min_by { |t| CONTRIBUTOR_RANK[t] || 99 }
  end

  def core_team?
    contributor_membership_types.include?("core_team")
  end

  def committer?
    contributor_membership_types.include?("committer")
  end

  def past_contributor?
    types = contributor_membership_types
    types.include?("past_major_contributor") || types.include?("past_significant_contributor")
  end

  def current_contributor?
    contributor? && !past_contributor?
  end

  def major_contributor?
    contributor_membership_types.include?("major_contributor")
  end

  def significant_contributor?
    contributor_membership_types.include?("significant_contributor")
  end

  def contributor_membership_types
    return [] unless person

    @contributor_membership_types ||= person.contributor_memberships.load.map(&:contributor_type)
  end

  def contributor_badge
    return nil unless contributor?

    case contributor_type
    when "core_team" then "Core Team"
    when "committer" then "Committer"
    when "major_contributor" then "Major Contributor"
    when "significant_contributor" then "Contributor"
    when "past_major_contributor" then "Past Contributor"
    when "past_significant_contributor" then "Past Contributor"
    end
  end

  private

  def queue_person_id_propagation
    return unless person_id.present?

    old_person_id = person_id_before_last_save
    PersonIdPropagationJob.perform_later(id, person_id, old_person_id)
  end

  def auto_star_recent_topics
    return unless user_id.present?

    one_year_ago = 1.year.ago

    topic_ids = Message.joins("INNER JOIN topics ON topics.id = messages.topic_id")
                       .where(messages: { sender_id: id })
                       .where("topics.updated_at >= ?", one_year_ago)
                       .distinct
                       .pluck(:topic_id)

    topic_ids.each do |topic_id|
      TopicStar.find_or_create_by(user_id: user_id, topic_id: topic_id)
    rescue ActiveRecord::RecordNotUnique
    end
  end
end
