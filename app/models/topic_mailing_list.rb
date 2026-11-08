class TopicMailingList < ApplicationRecord
  belongs_to :topic
  belongs_to :mailing_list

  after_create { Topic.refresh_hidden_by_default!(topic_id) }
  after_destroy { Topic.refresh_hidden_by_default!(topic_id) }
end
