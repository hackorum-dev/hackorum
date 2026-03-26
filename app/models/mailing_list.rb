class MailingList < ApplicationRecord
  has_many :message_mailing_lists, dependent: :destroy
  has_many :messages, through: :message_mailing_lists
  has_many :topic_mailing_lists, dependent: :destroy
  has_many :topics, through: :topic_mailing_lists

  validates :identifier, presence: true, uniqueness: true
  validates :display_name, presence: true

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
end
