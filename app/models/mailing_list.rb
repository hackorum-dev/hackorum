class MailingList < ApplicationRecord
  has_many :message_mailing_lists, dependent: :destroy
  has_many :messages, through: :message_mailing_lists
  has_many :topic_mailing_lists, dependent: :destroy
  has_many :topics, through: :topic_mailing_lists

  validates :identifier, presence: true, uniqueness: true
  validates :display_name, presence: true

  after_update :refresh_topic_visibility, if: :saved_change_to_hidden_by_default?

  def all_emails
    [ email, *alternate_emails ].compact.reject(&:blank?).map(&:downcase)
  end

  def self.email_lookup_index
    index = {}
    where.not(email: nil).find_each do |ml|
      ml.all_emails.each { |e| index[e] = ml }
    end
    index
  end

  private

  def refresh_topic_visibility
    Topic.refresh_hidden_by_default!(topic_mailing_lists.select(:topic_id))
  end
end
