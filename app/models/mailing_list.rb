class MailingList < ApplicationRecord
  has_many :message_mailing_lists, dependent: :destroy
  has_many :messages, through: :message_mailing_lists
  has_many :topic_mailing_lists, dependent: :destroy
  has_many :topics, through: :topic_mailing_lists

  validates :identifier, presence: true, uniqueness: true
  validates :display_name, presence: true
end
