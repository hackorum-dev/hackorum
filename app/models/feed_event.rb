class FeedEvent < ApplicationRecord
  MESSAGE_RECEIVED = "message.received".freeze
  PATCHSET_POSTED  = "patchset.posted".freeze
  BRANCH_CREATED   = "branch.created".freeze
  CI_COMPLETED     = "ci.completed".freeze
  TYPES = [ MESSAGE_RECEIVED, PATCHSET_POSTED, BRANCH_CREATED, CI_COMPLETED ].freeze
  MESSAGE_TYPES = [ MESSAGE_RECEIVED, PATCHSET_POSTED ].freeze

  belongs_to :message, optional: true
  belongs_to :patch_branch, optional: true
  belongs_to :patch_ci_run, optional: true
  belongs_to :author_person, class_name: "Person", optional: true

  validates :event_type, inclusion: { in: TYPES }
  validates :occurred_at, presence: true

  AUTHORS = <<~SQL.squish.freeze
    UPDATE feed_events SET author_person_id = messages.sender_person_id
    FROM messages
    WHERE messages.id = feed_events.message_id AND messages.sender_id IN (?)
      AND feed_events.author_person_id IS DISTINCT FROM messages.sender_person_id
  SQL

  # the author of an event is the person its message has now
  def self.sync_authors(sender_ids)
    lease_connection.exec_update(sanitize_sql([ AUTHORS, Array(sender_ids) ]), "FeedEvent Authors")
  end
end
