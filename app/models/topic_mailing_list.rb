class TopicMailingList < ApplicationRecord
  belongs_to :topic
  belongs_to :mailing_list
end
