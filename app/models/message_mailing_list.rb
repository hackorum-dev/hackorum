class MessageMailingList < ApplicationRecord
  belongs_to :message
  belongs_to :mailing_list

  after_create :ensure_topic_mailing_list

  private

  def ensure_topic_mailing_list
    TopicMailingList.find_or_create_by!(
      topic_id: message.topic_id,
      mailing_list_id: mailing_list_id
    )
  end
end
