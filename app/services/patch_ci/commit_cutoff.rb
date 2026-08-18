module PatchCi
  # A patchset is superseded by a commit when the thread landed *after* the
  # patchset was sent. Not "the thread has a commit": a fix mailed after the
  # commit is new, uncommitted work, and CI on it is worth more than on most
  # patches, since it is usually repairing something already in master.
  #
  # The commit trailer cannot answer this. commit_topics.external_message_id
  # looks like it names the patchset that landed, but committers reuse whatever
  # Discussion link is at hand - on topic 253226 the third commit credits the
  # thread's first message, two patchsets later. It names the thread. Only the
  # dates are usable.
  #
  # Callers must have joined both topics and messages.
  module CommitCutoff
    # The IS NOT NULL guard sits first so a thread that never landed resolves to
    # false rather than NULL, which is what makes NOT() below true instead of
    # unknown. Do not reorder the two conjuncts.
    SUPERSEDED = "topics.last_commit_at IS NOT NULL " \
                 "AND messages.created_at <= topics.last_commit_at"

    def self.live(relation) = relation.where("NOT (#{SUPERSEDED})")
  end
end
