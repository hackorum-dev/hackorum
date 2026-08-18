FactoryBot.define do
  factory :commit_topic do
    commit
    topic
    sequence(:external_message_id) { |n| "discussion-#{n}@example.com" }

    # the importer derives last_commit_at from these rows, and the planner
    # reads it to decide whether a patchset predates the commit. A spec that
    # builds the link without it describes a thread that never landed, and
    # then passes while testing nothing. commit_count is deliberately not
    # maintained here: specs set it by hand to exercise the badge, and a
    # wrong value there shows up in the assertion rather than hiding.
    after(:create) do |link|
      last = Commit.where(id: CommitTopic.where(topic_id: link.topic_id).select(:commit_id))
                   .maximum(:committed_at)
      link.topic.update_column(:last_commit_at, last)
    end
  end
end
