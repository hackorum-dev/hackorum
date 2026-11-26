module Classify
  module Scope
    WINDOW_TAG = "REL_16_BETA1".freeze

    def self.topics
      Topic.active.where(id: TopicMailingList.joins(:mailing_list)
                                             .where(mailing_lists: { identifier: LISTS })
                                             .select(:topic_id))
    end

    def self.window_start
      ReleaseTag.find_by!(name: WINDOW_TAG).released_at
    end

    def self.in_window
      topics.where("topics.last_message_at >= ?", window_start)
    end
  end
end
